import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:geofield/data/tile_cache.dart';
import 'package:geofield/data/tile_http.dart';

/// Транспорт тайлов: подстановка URL (чисто) и HTTP-загрузка против ЛОКАЛЬНОГО
/// сервера (как e2e relay — реальный HTTP, без внешней сети).
void main() {
  group('validateTileServerUrl / tileFetcherFromUrl', () {
    test('валидный https-шаблон с {z}/{x}/{y} — ок', () {
      expect(validateTileServerUrl('https://ts.example/{z}/{x}/{y}.png'), isNull);
      expect(
          validateTileServerUrl('https://{s}.ts/{z}/{x}/{y}@2x.png'), isNull);
    });

    test('нет плейсхолдера — ошибка с указанием какого', () {
      expect(validateTileServerUrl('https://ts/{z}/{x}.png'), contains('{y}'));
      expect(validateTileServerUrl(''), isNotNull);
    });

    test('http запрещён (кроме localhost)', () {
      expect(validateTileServerUrl('http://ts.example/{z}/{x}/{y}.png'),
          contains('https'));
      expect(
          validateTileServerUrl('http://localhost:8080/{z}/{x}/{y}.png'), isNull);
      expect(validateTileServerUrl('http://127.0.0.1/{z}/{x}/{y}.png'), isNull);
    });

    test('фабрика: невалидный/пустой → null, валидный → загрузчик', () {
      expect(tileFetcherFromUrl(null), isNull);
      expect(tileFetcherFromUrl('http://ts/{z}/{x}/{y}.png'), isNull);
      final f = tileFetcherFromUrl('https://ts/{z}/{x}/{y}.png');
      expect(f, isNotNull);
      f!.close();
    });
  });

  group('tileUrl', () {
    test('подстановка {z}/{x}/{y}', () {
      expect(tileUrl('https://ts.example/{z}/{x}/{y}.png', const TileId(10, 5, 7)),
          'https://ts.example/10/5/7.png');
    });

    test('поддомен {s}', () {
      expect(
          tileUrl('https://{s}.ts/{z}/{x}/{y}.png', const TileId(3, 1, 2),
              subdomain: 'b'),
          'https://b.ts/3/1/2.png');
    });
  });

  group('HttpTileFetcher (локальный HttpServer)', () {
    late HttpServer server;
    late String base;
    final requested = <String>[];

    setUp(() async {
      requested.clear();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = 'http://127.0.0.1:${server.port}';
      server.listen((req) async {
        requested.add(req.uri.path);
        // /10/5/7.png → 200 с байтами; /oversize → гигантский ответ; иначе 404.
        if (req.uri.path == '/10/5/7.png') {
          req.response.add(List.filled(120, 9));
        } else if (req.uri.path == '/big/9/9/9.png') {
          req.response.add(List.filled(5000, 1));
        } else {
          req.response.statusCode = HttpStatus.notFound;
        }
        await req.response.close();
      });
    });
    tearDown(() async => server.close(force: true));

    test('200 → байты тайла, запрошен правильный путь', () async {
      final f = HttpTileFetcher(urlTemplate: '$base/{z}/{x}/{y}.png');
      addTearDown(f.close);
      final bytes = await f.fetch(const TileId(10, 5, 7));
      expect(bytes, isNotNull);
      expect(bytes!.length, 120);
      expect(requested, contains('/10/5/7.png'));
    });

    test('404 → null (битый тайл не роняет заготовку)', () async {
      final f = HttpTileFetcher(urlTemplate: '$base/{z}/{x}/{y}.png');
      addTearDown(f.close);
      expect(await f.fetch(const TileId(0, 0, 0)), isNull);
    });

    test('оверсайз ответа → null (защита от не-тайла)', () async {
      final f = HttpTileFetcher(
          urlTemplate: '$base/big/{z}/{x}/{y}.png', maxTileBytes: 1024);
      addTearDown(f.close);
      expect(await f.fetch(const TileId(9, 9, 9)), isNull);
    });

    test('годится как TileFetcher для TileDownloader', () async {
      final f = HttpTileFetcher(urlTemplate: '$base/{z}/{x}/{y}.png');
      addTearDown(f.close);
      // Тот же контракт, что фейк в tile_downloader_test.
      final bytes = await f.fetch(const TileId(10, 5, 7));
      expect(bytes, isNotNull);
    });
  });
}
