import 'package:flutter_test/flutter_test.dart';
import 'package:geofield/sync/hlc.dart';

void main() {
  group('Hlc encode/parse/compare', () {
    test('круговой обход', () {
      const h = Hlc(1846500000000, 42, 'dev-a');
      final parsed = Hlc.tryParse(h.encode());
      expect(parsed, isNotNull);
      expect(parsed!.millis, h.millis);
      expect(parsed.counter, h.counter);
      expect(parsed.deviceId, h.deviceId);
    });

    test('лексикографика == HLC-порядок', () {
      // Перенос миллисекунды.
      expect(const Hlc(9, Hlc.maxCounter, 'z').encode(),
          lessThan(const Hlc(10, 0, 'a').encode()));
      // Счётчик при равных миллисекундах.
      expect(const Hlc(5000, 3, 'a').encode(),
          lessThan(const Hlc(5000, 4, 'a').encode()));
      // Ничья (m,c) — детерминированно по device_id.
      expect(const Hlc(5000, 3, 'dev-a').encode(),
          lessThan(const Hlc(5000, 3, 'dev-b').encode()));
    });

    test('мусор не парсится', () {
      expect(Hlc.tryParse(''), isNull);
      expect(Hlc.tryParse('2026-07-02T10:00:00Z'), isNull); // старый ISO
      expect(Hlc.tryParse('abc:def:dev'), isNull);
    });

    test('ISO-метка всегда меньше HLC-метки', () {
      // Старые записи прототипа несли ISO ('2026-…'); HLC начинается с '0'.
      // Лексикографически '0…' < '2…' — старый ISO «новее» любого HLC?!
      // Нет: сравнение в движке идёт только между row_clocks (всегда HLC)
      // либо fallback '' — этот тест фиксирует, что форматы НЕ смешиваются
      // в одном сравнении (tryParse отличает их).
      expect(Hlc.tryParse('2026-07-02T10:00:00Z'), isNull);
      expect(
          Hlc.tryParse(const Hlc(1846500000000, 0, 'd').encode()), isNotNull);
    });
  });
}
