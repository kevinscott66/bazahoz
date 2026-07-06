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
    test('Сусуман (≈62.78N,148.16E) — X/Y целыми метрами, формат как в CSV', () {
      final gk = wgs84ToSk42Gk(62.78, 148.16);
      expect(gk.zone, 25, reason: '148°E → 6-градусная зона 25');
      final label = sk42CornerLabel(62.78, 148.16);
      // Тот же формат, что выгрузка [zone, x, y]: X целые метры, Y с зоной.
      expect(label, 'X${gk.x.round()} Y${gk.y.round()}');
      expect(label, matches(RegExp(r'^X\d{7} Y25\d{6}$')),
          reason: 'X ~6.96 млн м (7 цифр), Y несёт зону 25 в старших цифрах');
      expect(gk.x / 1000, closeTo(6960, 30));
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
      expect(s, contains('\nСЗ X'));
      expect(s, contains('\nЮВ X'));
      expect(s, endsWith(' м'));
    });

    test('несколько смежных зон — диапазон, без осевого меридиана', () {
      final s = sk42Georef(
        nwLat: 63.0,
        nwLon: 120.0,
        seLat: 62.0,
        seLon: 148.0,
        zones: {21, 22, 23, 24, 25},
      );
      expect(s, contains('зоны 21–25'));
      expect(s, isNot(contains('ОМ')));
    });

    test('несмежные зоны — перечисление, а не мнимый диапазон', () {
      // {25,27} без 26: «25–27» подразумевало бы точку в зоне 26, которой нет.
      final s = sk42Georef(
        nwLat: 63.0,
        nwLon: 148.0, // зона 25
        seLat: 62.0,
        seLon: 160.0, // зона 27
        zones: {25, 27},
      );
      expect(s, contains('зоны 25, 27'));
      expect(s, isNot(contains('25–27')));
    });

    test('нечисловая координата даёт прочерк, а не буквальное «NaN»', () {
      // Защита от NaN, просочившегося в координату: прочерк вместо текста «NaN».
      final label = sk42CornerLabel(double.nan, 148.0);
      expect(label, isNot(contains('NaN')));
      expect(label, contains('—'));
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
      expect(s, contains('X'));
      expect(s, endsWith(' м'));
    });
  });
}
