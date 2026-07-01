import 'package:flutter_test/flutter_test.dart';
import 'package:geofield/models/observation_point.dart';

void main() {
  group('encodeMineralCodes / decodeMineralCodes', () {
    test('круговой обход, сортировка стабильна', () {
      final json = encodeMineralCodes({'pyrite', 'native_gold'});
      expect(json, '[{"code":"native_gold"},{"code":"pyrite"}]');
      expect(decodeMineralCodes(json), ['native_gold', 'pyrite']);
    });

    test('старая плоская форма читается', () {
      expect(decodeMineralCodes('["pyrite","galena"]'), ['pyrite', 'galena']);
    });

    test('будущая форма с интенсивностью не теряет код', () {
      expect(decodeMineralCodes('[{"code":"pyrite","intensity":"high"}]'),
          ['pyrite']);
    });

    test('мусор терпим: пусто, не-JSON, чужие типы', () {
      expect(decodeMineralCodes(null), isEmpty);
      expect(decodeMineralCodes(''), isEmpty);
      expect(decodeMineralCodes('not json'), isEmpty);
      expect(decodeMineralCodes('[42, {"x":1}]'), isEmpty);
    });
  });
}
