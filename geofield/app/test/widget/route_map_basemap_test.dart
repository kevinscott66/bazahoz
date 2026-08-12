import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geofield/data/tile_cache.dart';
import 'package:geofield/models/observation_point.dart';
import 'package:geofield/screens/route_map_basemap.dart';

import 'helpers.dart';

/// Каркас подложки карты (за флагом mapBasemap): точки/трек/георефер поверх
/// офлайн-тайлов. Тайлов нет (tileIndex=null) — провайдер даёт прозрачную
/// плитку, сеть не трогается; проверяем оверлеи, тап по точке и метку покрытия.
void main() {
  ObservationPoint pt(String id, double lat, double lon,
          {bool draft = false}) =>
      ObservationPoint(
        id: id,
        routeId: 'r',
        number: id,
        lat: lat,
        lon: lon,
        isDraft: draft,
        authorId: 'a',
        createdAt: '2026-01-0${id.length}T00:00:00Z',
        modifiedAt: '2026-01-01T00:00:00Z',
      );

  Future<void> pumpMap(WidgetTester tester, List<ObservationPoint> points,
      {void Function(ObservationPoint)? onTap,
      Map<String, int> samplesByPoint = const {},
      TileCacheIndex? tileIndex}) async {
    tallPhone(tester);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RouteBasemapView(
          points: points,
          samplesByPoint: samplesByPoint,
          onTapPoint: onTap ?? (_) {},
          tileIndex: tileIndex, // null — офлайн-тайлов нет, прозрачные плитки
        ),
      ),
    ));
    await tester.pump(); // без pumpAndSettle: тайлы грузятся асинхронно
  }

  testWidgets('карта рисуется, точки-маркеры на месте, георефер и метка тайлов',
      (tester) async {
    await pumpMap(tester, [
      pt('p1', 62.781, 148.150),
      pt('p2', 62.784, 148.160, draft: true),
    ]);
    expect(find.byType(FlutterMap), findsOneWidget);
    // Оба маркера-точки в дереве (по ключам).
    expect(find.byKey(const ValueKey('map-pt-p1')), findsOneWidget);
    expect(find.byKey(const ValueKey('map-pt-p2')), findsOneWidget);
    // Георефер СК-42 и честная метка отсутствующих тайлов.
    expect(find.textContaining('СК-42'), findsOneWidget);
    expect(find.textContaining('Офлайн-тайлы не загружены'), findsOneWidget);
  });

  testWidgets('точка с пробами несёт бейдж-счётчик, без проб — нет',
      (tester) async {
    await pumpMap(tester, [
      pt('p1', 62.781, 148.150),
      pt('p2', 62.784, 148.160),
    ], samplesByPoint: const {'p1': 3});
    // Паритет с ENU-схемой: точка с пробами отличается от пустой.
    expect(find.text('3'), findsOneWidget);
  });

  testWidgets('тап по маркеру открывает его точку', (tester) async {
    ObservationPoint? tapped;
    await pumpMap(tester, [
      pt('p1', 62.781, 148.150),
      pt('p2', 62.784, 148.160),
    ], onTap: (p) => tapped = p);
    await tester.tap(find.byKey(const ValueKey('map-pt-p2')));
    await tester.pump();
    expect(tapped?.id, 'p2');
  });

  testWidgets('провайдер: тайл в индексе → FileImage, вне — прозрачная плитка',
      (tester) async {
    // Индекс с одним тайлом z1/x2/y3 и каталогом (файл существовать не обязан:
    // FileImage не читает диск при конструировании).
    final idx = TileCacheIndex(Directory('/tmp/tiles'), {'1/2/3'});
    final provider = OfflineRasterTileProvider(idx);
    // TileCoordinates(x, y, z): (2,3,1) → z1/x2/y3 — есть в индексе.
    expect(
        provider.getImage(
            const TileCoordinates(2, 3, 1), TileLayer(urlTemplate: '')),
        isA<FileImage>());
    // Отсутствующий тайл → заглушка, не сеть.
    expect(
        provider.getImage(
            const TileCoordinates(9, 9, 9), TileLayer(urlTemplate: '')),
        isA<MemoryImage>());
    // null-индекс → всегда заглушка.
    expect(
        OfflineRasterTileProvider(null).getImage(
            const TileCoordinates(2, 3, 1), TileLayer(urlTemplate: '')),
        isA<MemoryImage>());
  });

  testWidgets('метка покрытия: полный кэш — без метки, частичный — «частично»',
      (tester) async {
    final points = [pt('p1', 62.781, 148.150), pt('p2', 62.784, 148.160)];
    // Все тайлы охвата маршрута на z10..12 — что и считает _tileNotice.
    final needed = tilesForRegion(
        west: 148.150,
        south: 62.781,
        east: 148.160,
        north: 62.784,
        minZoom: 10,
        maxZoom: 12);
    final full = TileCacheIndex(
        Directory('/tmp/tiles'), {for (final t in needed) t.key});

    // Полное покрытие — метки нет.
    await pumpMap(tester, points, tileIndex: full);
    expect(find.textContaining('Тайлы загружены частично'), findsNothing);
    expect(find.textContaining('не загружены'), findsNothing);

    // Половина тайлов — честная метка «частично».
    final half = TileCacheIndex(Directory('/tmp/tiles'),
        {for (final t in needed.take(needed.length ~/ 2)) t.key});
    await pumpMap(tester, points, tileIndex: half);
    expect(find.textContaining('Тайлы загружены частично'), findsOneWidget);
  });
}
