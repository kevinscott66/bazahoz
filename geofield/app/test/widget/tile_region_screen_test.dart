import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geofield/data/tile_cache.dart';
import 'package:geofield/data/tile_downloader.dart';
import 'package:geofield/models/observation_point.dart';
import 'package:geofield/screens/tile_region_screen.dart';

import 'helpers.dart';

/// Экран заготовки региона (за флагом mapBasemap): оценка тайлов, скачивание с
/// прогрессом/отменой, честная блокировка без адреса сервера. Зависимости
/// инъектируются — фейк-fetcher, реальный временный каталог; без сети.
void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('gf_region'));
  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  ObservationPoint pt(String id, double lat, double lon) => ObservationPoint(
        id: id,
        routeId: 'r',
        number: id,
        lat: lat,
        lon: lon,
        authorId: 'a',
        createdAt: '2026-01-01T00:00:00Z',
        modifiedAt: '2026-01-01T00:00:00Z',
      );

  Future<void> pump(WidgetTester tester,
      {required List<ObservationPoint> points,
      TileFetcher? fetcher,
      TileCacheIndex? index}) async {
    tallPhone(tester);
    await tester.pumpWidget(MaterialApp(
      home: TileRegionScreen(
        points: points,
        cacheDir: dir,
        index: index ?? TileCacheIndex.empty(),
        fetcher: fetcher,
      ),
    ));
    await tester.pump();
  }

  testWidgets('нет координат — честное сообщение, без выбора региона',
      (tester) async {
    await pump(tester, points: [
      ObservationPoint(
          id: 'p',
          routeId: 'r',
          number: 'p',
          authorId: 'a',
          createdAt: '2026-01-01T00:00:00Z',
          modifiedAt: '2026-01-01T00:00:00Z'),
    ]);
    expect(find.textContaining('Нет точек с координатами'), findsOneWidget);
    expect(find.text('Скачать'), findsNothing);
  });

  testWidgets('оценка тайлов показана; без адреса сервера — скачивание закрыто',
      (tester) async {
    await pump(tester, points: [pt('p1', 62.78, 148.15), pt('p2', 62.80, 148.20)]);
    // Число тайлов и ориентировочный вес.
    expect(find.textContaining('ориентировочно'), findsOneWidget);
    expect(find.textContaining('уже в кэше'), findsOneWidget);
    // fetcher == null → честная блокировка, кнопки «Скачать» нет.
    expect(find.textContaining('Адрес тайл-сервера не задан'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Скачать'), findsNothing);
  });

  // Скачивание пишет реальные файлы — реальный I/O не завершается под FakeAsync,
  // поэтому крутим под runAsync, опрашивая до появления итога.
  Future<void> tapAndAwaitResult(WidgetTester tester) async {
    await tester.runAsync(() async {
      await tester.tap(find.text('Скачать'));
      await tester.pump();
      for (var i = 0;
          i < 100 && find.textContaining('Готово').evaluate().isEmpty;
          i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await tester.pump();
      }
    });
  }

  testWidgets('скачивание: файлы в кэше, итог «Готово»', (tester) async {
    var fetched = 0;
    await pump(
      tester,
      points: [pt('p1', 62.78, 148.15), pt('p2', 62.785, 148.16)],
      fetcher: (t) async {
        fetched++;
        return Uint8List.fromList(List.filled(30, 1));
      },
    );
    expect(find.text('Скачать'), findsOneWidget);
    await tapAndAwaitResult(tester);

    expect(fetched, greaterThan(0));
    expect(find.textContaining('Готово: скачано'), findsOneWidget);
    final files = dir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.png'));
    expect(files, isNotEmpty);
  });

  testWidgets('уже скачанные пропускаются (индекс)', (tester) async {
    // Индекс с «всеми» тайлами обзорного пресета → всё пропущено, 0 скачано.
    const b = (
      west: 148.10,
      south: 62.75,
      east: 148.25,
      north: 62.82,
    );
    final all = tilesForRegion(
        west: b.west,
        south: b.south,
        east: b.east,
        north: b.north,
        minZoom: 6,
        maxZoom: 14);
    final full = TileCacheIndex(dir, {for (final t in all) t.key});
    var fetched = 0;
    await pump(
      tester,
      points: [pt('p1', 62.78, 148.15), pt('p2', 62.80, 148.20)],
      index: full,
      fetcher: (t) async {
        fetched++;
        return Uint8List.fromList(List.filled(10, 1));
      },
    );
    await tapAndAwaitResult(tester);
    // Индекс покрывает охват — качать нечего (пропуск), fetcher не дёрнут.
    expect(find.textContaining('пропущено'), findsOneWidget);
    expect(fetched, 0, reason: 'всё уже в кэше — сеть не трогаем');
  });
}
