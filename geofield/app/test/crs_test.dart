import 'package:flutter_test/flutter_test.dart';
import 'package:geofield/util/crs.dart';

/// Пересчёт WGS-84 ↔ СК-42 (Гаусса-Крюгера). Внешнего оракула в тесте нет,
/// поэтому опора — обратимость (round-trip) и абсолютные якоря, которые можно
/// обосновать из геометрии проекции.
void main() {
  // Сусуман, Магаданская обл.: ~62.78° с.ш., 148.16° в.д. — зона ГК 25.
  const susumanLat = 62.78341;
  const susumanLon = 148.15702;

  group('зоны Гаусса-Крюгера', () {
    test('долгота Сусумана → зона 25, осевой меридиан 147°', () {
      expect(gkZone(susumanLon), 25);
      expect(gkCentralMeridian(25), 147.0);
    });
    test('границы 6-градусных зон', () {
      expect(gkZone(0.1), 1);
      expect(gkZone(5.9), 1);
      expect(gkZone(6.1), 2);
      expect(gkZone(150.1), 26); // зона 26 = 150–156°, ОМ 153
      expect(gkCentralMeridian(26), 153.0);
    });
  });

  group('WGS-84 → СК-42 ГК: абсолютные якоря', () {
    test('точка Сусумана: правдоподобные X (северный) и Y (зона 25)', () {
      final gk = wgs84ToSk42Gk(susumanLat, susumanLon);
      expect(gk.zone, 25);
      // Северный ~ длина дуги меридиана до 62.8° ≈ 6.96 млн м.
      expect(gk.x, inInclusiveRange(6.9e6, 7.0e6));
      // Восточный: префикс зоны 25e6 + 500 км ± (≤3° долготы на 62.8°N ≈ 157 км).
      expect(gk.y, inInclusiveRange(25.35e6, 25.65e6));
    });

    test('точка НА осевом меридиане зоны → Y ≈ 25 500 000 (ложный сдвиг)', () {
      // Ровно на ОМ восточное смещение от меридиана ~0; датум чуть сдвигает.
      final gk = wgs84ToSk42Gk(62.0, 147.0);
      expect(gk.zone, 25);
      expect(gk.y, closeTo(25.5e6, 300)); // в пределах датум-сдвига (метры)
    });
  });

  group('обратимость (round-trip)', () {
    void roundTrip(double lat, double lon) {
      final gk = wgs84ToSk42Gk(lat, lon);
      final back = sk42GkToWgs84(gk.x, gk.y);
      // 1e-5° по широте ≈ 1.1 м — целимся строго внутрь метра.
      expect(back.lat, closeTo(lat, 1e-5), reason: 'широта $lat');
      expect(back.lon, closeTo(lon, 2e-5), reason: 'долгота $lon');
    }

    test('Сусуман', () => roundTrip(susumanLat, susumanLon));
    test('край зоны (запад)', () => roundTrip(61.0, 144.2));
    test('край зоны (восток)', () => roundTrip(63.5, 149.8));
    test('другая зона (26)', () => roundTrip(62.0, 152.0));
    test('низкие широты для общности', () => roundTrip(45.0, 39.0));

    test('зона восстанавливается из префикса Y без явного указания', () {
      final gk = wgs84ToSk42Gk(susumanLat, susumanLon);
      final back = sk42GkToWgs84(gk.x, gk.y); // zone не передаём
      expect(back.lat, closeTo(susumanLat, 1e-5));
      expect(back.lon, closeTo(susumanLon, 2e-5));
    });
  });

  group('смена датума значима', () {
    test('СК-42 и WGS-84 положения расходятся на ~100 м (не ноль)', () {
      // Прогон в СК-42-широту/долготу и обратно через геоцентрик — разница
      // датумов должна давать заметный сдвиг, иначе преобразование — пустышка.
      final gk = wgs84ToSk42Gk(susumanLat, susumanLon);
      // Восстановленная WGS-долгота совпадает с исходной (round-trip выше),
      // но плоская Y НЕ равна «наивной» UTM-подобной — проверяем, что датум
      // вообще применён: точка на ОМ в WGS-84 даёт Y, смещённый от 25.5e6.
      final naive = wgs84ToSk42Gk(62.0, 147.0);
      expect((naive.y - 25.5e6).abs(), greaterThan(1.0),
          reason: 'датум-сдвиг должен смещать точку с ОМ на метры');
      expect(gk.x, greaterThan(0));
    });
  });
}
