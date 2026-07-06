import 'package:flutter_test/flutter_test.dart';
import 'package:geofield/util/format.dart';

void main() {
  group('formatGms', () {
    test('Сусуман: широта и долгота с полусферой словами', () {
      // 62.78341° = 62°47′00.3″ с.ш.
      expect(formatGms(62.78341, isLat: true), '62°47′00.3″ с.ш.');
      // 148.15702° = 148°09′25.3″ в.д.
      expect(formatGms(148.15702, isLat: false), '148°09′25.3″ в.д.');
    });

    test('южное/западное полушарие по знаку', () {
      expect(formatGms(-33.5, isLat: true), '33°30′00.0″ ю.ш.');
      expect(formatGms(-70.25, isLat: false), '70°15′00.0″ з.д.');
    });

    test('минуты/секунды с ведущим нулём (ширина колонки)', () {
      // 60°05′05.0″ — минуты и секунды двузначные (05, 05.0).
      expect(formatGms(60 + 5 / 60 + 5 / 3600, isLat: true), '60°05′05.0″ с.ш.');
    });

    test('перенос секунд: 59.98″ не остаётся «60.0″», а даёт минуту', () {
      // 0°00′59.98″ округляется к 60.0 → переносится в 0°01′00.0″.
      const v = 59.98 / 3600;
      expect(formatGms(v, isLat: true), '0°01′00.0″ с.ш.');
    });

    test('перенос минут через 59′59.98″ → следующий градус', () {
      const v = 61 - (0.02 / 3600); // чуть меньше 61° → 60°59′59.98″ → 61°
      expect(formatGms(v, isLat: true), '61°00′00.0″ с.ш.');
    });

    test('нечисловое — прочерк, не «NaN»', () {
      expect(formatGms(double.nan, isLat: true), '—');
      expect(formatGms(double.infinity, isLat: false), '—');
    });

    test('ноль — экватор/гринвич без знака', () {
      expect(formatGms(0, isLat: true), '0°00′00.0″ с.ш.');
    });
  });
}
