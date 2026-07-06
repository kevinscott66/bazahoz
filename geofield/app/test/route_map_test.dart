import 'package:flutter_test/flutter_test.dart';
import 'package:geofield/screens/route_map_screen.dart';
import 'package:geofield/util/crs.dart';

/// Чистые помощники схемы маршрута: метрическая сетка и георефер СК-42.
/// (Сама отрисовка проверяется голденом; здесь — математика подписей.)
void main() {
  group('gridLinesMeters', () {
    test('кратные шага строго внутри диапазона', () {
      expect(gridLinesMeters(-1200, 3300, 1000), [-1000, 0, 1000, 2000, 3000]);
    });

    test('границы включаются, если попадают ровно на кратное', () {
      expect(gridLinesMeters(0, 2000, 1000), [0, 1000, 2000]);
    });

    test('вырожденный/абсурдный шаг — пустой список, не зависаем', () {
      expect(gridLinesMeters(0, 100, 0), isEmpty);
      expect(gridLinesMeters(0, 100, double.infinity), isEmpty);
      expect(gridLinesMeters(100, 0, 10), isEmpty); // max < min
      expect(gridLinesMeters(0, 1e9, 1), isEmpty); // мельче пикселя — не рисуем
    });
  });

  group('sk42CornerLabel', () {
    test('Сусуман (≈62.78N,148.16E) — зона 25, X/Y в километрах', () {
      final gk = wgs84ToSk42Gk(62.78, 148.16);
      expect(gk.zone, 25, reason: '148°E → 6-градусная зона 25');
      final label = sk42CornerLabel(62.78, 148.16);
      expect(label, startsWith('з25 X'));
      expect(label, contains(' Y'));
      // X (северный) ~6960 км на этой широте; Y (с ложным сдвигом 500 км) ~400–600.
      final xkm = gk.x / 1000;
      expect(xkm, closeTo(6960, 30));
    });
  });

  group('sk42Georef', () {
    test('одна зона — осевой меридиан и оба угла', () {
      final s = sk42Georef(
        nwLat: 62.79,
        nwLon: 148.10,
        seLat: 62.77,
        seLon: 148.22,
        zones: {25},
      );
      expect(s, contains('СК-42 з.25'));
      expect(s, contains('ОМ 147°')); // 25*6-3
      expect(s, contains('\nСЗ з25 '));
      expect(s, contains('\nЮВ з25 '));
      expect(s, endsWith(' км'));
    });

    test('несколько зон — диапазон зон, без осевого меридиана', () {
      final s = sk42Georef(
        nwLat: 63.0,
        nwLon: 120.0, // Якутия, зона 21
        seLat: 62.0,
        seLon: 148.0, // Магадан, зона 25
        zones: {21, 25},
      );
      expect(s, contains('зоны 21–25'));
      expect(s, isNot(contains('ОМ')));
    });

    test('вырожденный охват (одна точка) — одна строка координат', () {
      final s = sk42Georef(
        nwLat: 62.78,
        nwLon: 148.16,
        seLat: 62.78,
        seLon: 148.16,
        zones: {25},
        degenerate: true,
      );
      expect('\n'.allMatches(s).length, 1, reason: 'заголовок + один угол');
      expect(s, contains('з25 X'));
    });
  });
}
