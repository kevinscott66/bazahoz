import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:geofield/data/tile_cache.dart';
import 'package:geofield/data/tile_downloader.dart';

/// Оркестрация скачивания региона — без сети: фейковый fetcher, реальный
/// временный каталог кэша.
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('gf_tiles_test');
  });
  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Uint8List bytes(int n) => Uint8List.fromList(List.filled(n, 7));

  test('missing отфильтровывает уже скачанные', () {
    const needed = [TileId(10, 1, 1), TileId(10, 1, 2), TileId(10, 1, 3)];
    final index = TileCacheIndex(dir, {'10/1/2'});
    final dl = TileDownloader(cacheDir: dir, fetcher: (_) async => bytes(10));
    expect(dl.missing(needed, index), [
      const TileId(10, 1, 1),
      const TileId(10, 1, 3),
    ]);
  });

  test('качает недостающие, пропускает скачанные, пишет файлы и прогресс',
      () async {
    const needed = [TileId(10, 5, 5), TileId(10, 5, 6), TileId(10, 5, 7)];
    final index = TileCacheIndex(dir, {'10/5/6'}); // один уже есть
    final progress = <(int, int)>[];
    final dl = TileDownloader(cacheDir: dir, fetcher: (_) async => bytes(100));
    final r = await dl.downloadRegion(
      needed: needed,
      index: index,
      onProgress: (done, total) => progress.add((done, total)),
    );
    expect(r.downloaded, 2);
    expect(r.skipped, 1);
    expect(r.failed, 0);
    expect(r.cancelled, isFalse);
    // Файлы легли по slippy-пути.
    expect(await File('${dir.path}/10/5/5.png').exists(), isTrue);
    expect(await File('${dir.path}/10/5/7.png').exists(), isTrue);
    // Прогресс шёл до 2 из 2 (всего к загрузке — только недостающие).
    expect(progress.last, (2, 2));
  });

  test('ошибка загрузки (null) считается failed, файл не пишется', () async {
    const needed = [TileId(11, 1, 1), TileId(11, 1, 2)];
    final dl = TileDownloader(
      cacheDir: dir,
      // Первый тайл не скачивается, второй — ок.
      fetcher: (t) async => t.y == 1 ? null : bytes(50),
    );
    final r =
        await dl.downloadRegion(needed: needed, index: TileCacheIndex.empty());
    expect(r.downloaded, 1);
    expect(r.failed, 1);
    expect(await File('${dir.path}/11/1/1.png').exists(), isFalse);
    expect(await File('${dir.path}/11/1/2.png').exists(), isTrue);
  });

  test('отмена прерывает загрузку, помечает cancelled', () async {
    final needed = [for (var y = 0; y < 20; y++) TileId(12, 0, y)];
    final cancel = CancelToken();
    var fetched = 0;
    final dl = TileDownloader(
      cacheDir: dir,
      fetcher: (_) async {
        fetched++;
        if (fetched >= 3) cancel.cancel(); // отменяем после трёх
        return bytes(10);
      },
    );
    final r = await dl.downloadRegion(
        needed: needed, index: TileCacheIndex.empty(), cancel: cancel);
    expect(r.cancelled, isTrue);
    expect(r.downloaded, lessThan(needed.length));
  });

  test('лимит кэша: после скачивания сверх maxBytes размер уложен в лимит',
      () async {
    // 10 тайлов по 1000 байт = 10000; лимит 3500 → останется ≤ 3 тайла.
    final needed = [for (var y = 0; y < 10; y++) TileId(13, 0, y)];
    final dl = TileDownloader(
      cacheDir: dir,
      fetcher: (_) async => bytes(1000),
      maxBytes: 3500,
    );
    await dl.downloadRegion(needed: needed, index: TileCacheIndex.empty());
    var total = 0;
    await for (final e in dir.list(recursive: true)) {
      if (e is File && e.path.endsWith('.png')) total += await e.length();
    }
    expect(total, lessThanOrEqualTo(3500),
        reason: 'старые тайлы вытеснены до лимита');
    expect(total, greaterThan(0), reason: 'что-то осталось');
  });

  test('TileCacheIndex.scan собирает ключи с диска', () async {
    // Разложим тайлы {z}/{x}/{y}.png и мусор, который надо игнорировать.
    for (final key in const ['10/1/1', '10/1/2', '11/512/300']) {
      final f = File('${dir.path}/$key.png');
      await f.parent.create(recursive: true);
      await f.writeAsBytes(bytes(4));
    }
    await File('${dir.path}/readme.txt').writeAsString('not a tile');
    final idx = await TileCacheIndex.scan(dir);
    expect(idx.has(10, 1, 1), isTrue);
    expect(idx.has(10, 1, 2), isTrue);
    expect(idx.has(11, 512, 300), isTrue);
    expect(idx.has(10, 9, 9), isFalse);
    expect(idx.length, 3, reason: 'readme.txt не считается тайлом');
  });
}
