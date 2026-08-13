import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geofield/data/tile_cache.dart';
import 'package:geofield/data/tile_downloader.dart';
import 'package:geofield/data/tile_http.dart';
import 'package:geofield/screens/route_map_basemap.dart';

/// Сквозной прогон офлайн-тайлового конвейера БЕЗ устройства: локальный
/// тайл-сервер → HTTP-загрузчик → скачивание региона → кэш на диске →
/// TileCacheIndex.scan → OfflineRasterTileProvider отдаёт реальный тайл.
/// Проверяет, что раздельно оттестированные части СОБИРАЮТСЯ вместе (то, чего
/// юнит-тесты по отдельности не ловят) — капстоун движка карты.
void main() {
  test('сервер → загрузка → кэш → индекс → провайдер отдаёт тайл', () async {
    // Уникальные байты «тайла» по пути — чтобы проверить, что провайдер отдаёт
    // именно скачанный файл, а не заглушку.
    Uint8List tileBytes(String path) =>
        Uint8List.fromList('TILE:$path'.codeUnits);

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final served = <String>{};
    server.listen((req) async {
      // Обслуживаем только зумы 10–11 (имитируем частичное покрытие сервера).
      final path = req.uri.path; // /{z}/{x}/{y}.png
      final ok = RegExp(r'^/1[01]/\d+/\d+\.png$').hasMatch(path);
      if (ok) {
        served.add(path);
        req.response.add(tileBytes(path));
      } else {
        req.response.statusCode = HttpStatus.notFound;
      }
      await req.response.close();
    });

    final cacheDir = await Directory.systemTemp.createTemp('gf_pipeline');
    addTearDown(() async {
      if (await cacheDir.exists()) await cacheDir.delete(recursive: true);
    });

    // 1. Транспорт из URL оператора (валидный https-эквивалент — localhost).
    final fetcher = tileFetcherFromUrl('http://127.0.0.1:${server.port}/{z}/{x}/{y}.png');
    expect(fetcher, isNotNull, reason: 'localhost-http допустим для оператора');

    // 2. Регион (маленький bbox у Сусумана) на зумах 10–11.
    final needed = tilesForRegion(
        west: 148.10,
        south: 62.75,
        east: 148.20,
        north: 62.82,
        minZoom: 10,
        maxZoom: 11);
    expect(needed, isNotEmpty);

    // 3. Скачать в кэш.
    final downloader =
        TileDownloader(cacheDir: cacheDir, fetcher: fetcher!.fetch);
    final result = await downloader.downloadRegion(
        needed: needed, index: TileCacheIndex.empty());
    expect(result.downloaded, needed.length);
    expect(result.failed, 0);
    expect(served, isNotEmpty, reason: 'сервер реально отдавал тайлы');

    // 4. Индекс из скачанного кэша.
    final index = await TileCacheIndex.scan(cacheDir);
    expect(index.length, needed.length);
    expect(index.coverage(needed), 1.0, reason: 'весь регион в кэше');

    // 5. Провайдер отдаёт СКАЧАННЫЙ тайл (FileImage с байтами сервера)…
    final provider = OfflineRasterTileProvider(index);
    final t = needed.first;
    final img = provider.getImage(
        TileCoordinates(t.x, t.y, t.z), TileLayer(urlTemplate: ''));
    expect(img, isA<FileImage>());
    final onDisk =
        await File('${cacheDir.path}/${t.z}/${t.x}/${t.y}.png').readAsBytes();
    expect(onDisk, tileBytes('/${t.z}/${t.x}/${t.y}.png'),
        reason: 'на диске — именно байты сервера');

    // 6. …а для НЕ скачанного тайла (зум 12, сервер бы дал 404) — заглушка.
    final miss = provider.getImage(
        const TileCoordinates(0, 0, 12), TileLayer(urlTemplate: ''));
    expect(miss, isA<MemoryImage>());

    fetcher.close();
  });

  test('повторный проход пропускает уже скачанное (индекс), сеть не дёргает',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var hits = 0;
    server.listen((req) async {
      hits++;
      req.response.add(Uint8List.fromList(List.filled(20, 1)));
      await req.response.close();
    });
    final cacheDir = await Directory.systemTemp.createTemp('gf_pipeline2');
    addTearDown(() async {
      if (await cacheDir.exists()) await cacheDir.delete(recursive: true);
    });

    final fetcher =
        tileFetcherFromUrl('http://127.0.0.1:${server.port}/{z}/{x}/{y}.png')!;
    addTearDown(fetcher.close);
    final needed = tilesForRegion(
        west: 148.10,
        south: 62.75,
        east: 148.20,
        north: 62.82,
        minZoom: 10,
        maxZoom: 10);
    final dl = TileDownloader(cacheDir: cacheDir, fetcher: fetcher.fetch);

    await dl.downloadRegion(needed: needed, index: TileCacheIndex.empty());
    final firstHits = hits;
    expect(firstHits, needed.length);

    // Второй проход с индексом уже скачанного — качать нечего.
    final index = await TileCacheIndex.scan(cacheDir);
    final r2 = await dl.downloadRegion(needed: needed, index: index);
    expect(r2.downloaded, 0);
    expect(r2.skipped, needed.length);
    expect(hits, firstHits, reason: 'сеть не дёрнута повторно');
  });
}
