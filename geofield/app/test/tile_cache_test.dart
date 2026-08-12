import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:geofield/data/tile_cache.dart';

/// Северо-западный угол тайла (lon, lat) — обратная slippy-map формула, для
/// проверки, что точка реально попадает в свой тайл.
({double lon, double lat}) _tileNW(int z, int x, int y) {
  final n = 1 << z;
  final lon = x / n * 360.0 - 180.0;
  final latRad = math.atan(_sinh(math.pi * (1 - 2 * y / n)));
  return (lon: lon, lat: latRad * 180.0 / math.pi);
}

double _sinh(double v) => (math.exp(v) - math.exp(-v)) / 2;

void main() {
  group('tileForLonLat', () {
    test('зум 0 — единственный тайл (0,0,0) для любой точки', () {
      expect(tileForLonLat(148.16, 62.78, 0), const TileId(0, 0, 0));
      expect(tileForLonLat(-73.9, -40.0, 0), const TileId(0, 0, 0));
    });

    test('полушария на зуме 1: СВ→(1,0), ЮЗ→(0,1)', () {
      expect(tileForLonLat(0.01, 0.01, 1), const TileId(1, 1, 0));
      expect(tileForLonLat(-0.01, -0.01, 1), const TileId(1, 0, 1));
    });

    test('точка попадает в границы своего тайла (инвариант проекции)', () {
      for (final (lon, lat) in const [
        (148.16, 62.78), // Сусуман
        (13.3777, 52.5163), // Берлин
        (129.7, 62.0), // запад Якутии
        (160.0, 65.0), // восток Магаданской обл.
      ]) {
        for (final z in const [8, 11, 14]) {
          final t = tileForLonLat(lon, lat, z);
          final nw = _tileNW(z, t.x, t.y);
          final se = _tileNW(z, t.x + 1, t.y + 1);
          expect(lon >= nw.lon && lon < se.lon, isTrue,
              reason: 'lon $lon вне тайла $t на z$z');
          expect(lat <= nw.lat && lat > se.lat, isTrue,
              reason: 'lat $lat вне тайла $t на z$z');
        }
      }
    });

    test('за пределами веб-меркатора широта зажимается (без NaN/переполнения)',
        () {
      final t = tileForLonLat(0, 89.0, 5);
      expect(t.y, inInclusiveRange(0, (1 << 5) - 1));
      expect(t.x, inInclusiveRange(0, (1 << 5) - 1));
    });
  });

  group('tilesForRegion / count', () {
    test('маленький bbox на одном зуме — прямоугольник тайлов', () {
      // Узкая область вокруг Сусумана на z10.
      final tiles = tilesForRegion(
        west: 148.10,
        south: 62.75,
        east: 148.25,
        north: 62.82,
        minZoom: 10,
        maxZoom: 10,
      );
      expect(tiles, isNotEmpty);
      // count и материализация согласованы.
      expect(
          tiles.length,
          countTilesForRegion(
              west: 148.10,
              south: 62.75,
              east: 148.25,
              north: 62.82,
              minZoom: 10,
              maxZoom: 10));
      // Все тайлы уникальны и на нужном зуме.
      expect(tiles.map((t) => t.key).toSet().length, tiles.length);
      expect(tiles.every((t) => t.z == 10), isTrue);
    });

    test('число тайлов растёт ~×4 на каждый уровень зума', () {
      int at(int z) => countTilesForRegion(
          west: 148.0,
          south: 62.5,
          east: 149.0,
          north: 63.0,
          minZoom: z,
          maxZoom: z);
      expect(at(11), greaterThan(at(9)));
    });

    test('слишком крупный регион/зум — ошибка, а не OOM', () {
      expect(
          () => tilesForRegion(
                west: 140,
                south: 55,
                east: 165,
                north: 72, // вся Магаданская обл.+
                minZoom: 0,
                maxZoom: 18,
                maxTiles: 100000,
              ),
          throwsArgumentError);
    });
  });

  group('TileCacheIndex', () {
    test('has по множеству ключей; пустой индекс — всё отсутствует', () {
      final idx = TileCacheIndex(null, {'10/1/2', '10/1/3'});
      expect(idx.has(10, 1, 2), isTrue);
      expect(idx.has(10, 9, 9), isFalse);
      expect(TileCacheIndex.empty().has(0, 0, 0), isFalse);
      expect(TileCacheIndex.empty().isEmpty, isTrue);
    });

    test('coverage: доля присутствующих тайлов', () {
      final needed = [
        const TileId(10, 1, 1),
        const TileId(10, 1, 2),
        const TileId(10, 1, 3),
        const TileId(10, 1, 4),
      ];
      final idx = TileCacheIndex(null, {'10/1/1', '10/1/2'});
      expect(idx.coverage(needed), 0.5);
      expect(idx.coverage(const []), 1.0, reason: 'нечего покрывать');
      expect(TileCacheIndex.empty().coverage(needed), 0.0);
    });
  });
}
