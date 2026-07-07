import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geofield/models/observation_point.dart';
import 'package:geofield/screens/route_map_basemap.dart';

import 'helpers.dart';

/// Каркас подложки карты (за флагом mapBasemap): точки/трек/георефер поверх
/// офлайн-тайлов. Тайлов нет (cacheDir=null) — провайдер даёт прозрачную
/// плитку, сеть не трогается; проверяем оверлеи и тап по точке.
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
      {void Function(ObservationPoint)? onTap}) async {
    tallPhone(tester);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RouteBasemapView(
          points: points,
          samplesByPoint: const {},
          onTapPoint: onTap ?? (_) {},
          tileCacheDir: null, // офлайн-тайлов нет — прозрачные плитки
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

  testWidgets('провайдер тайлов: есть кэш — FileImage, нет — прозрачная плитка',
      (tester) async {
    final provider = OfflineRasterTileProvider(null);
    final img = provider.getImage(
        const TileCoordinates(1, 2, 3), TileLayer(urlTemplate: ''));
    expect(img, isA<MemoryImage>(),
        reason: 'без каталога кэша — плитка-заглушка, не сетевой запрос');
  });
}
