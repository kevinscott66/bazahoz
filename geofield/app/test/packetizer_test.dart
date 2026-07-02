import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:geofield/sync/packetizer.dart';

Map<String, Object?> mut(String id, {int noteLen = 0}) => {
      'change_id': id,
      'entity_table': 'samples',
      'op': 'insert',
      'payload': {'note': 'x' * noteLen},
    };

int sizeOf(Map<String, Object?> m) => utf8.encode(jsonEncode(m)).length;

void main() {
  group('splitIntoPackets', () {
    test('пусто — ноль пакетов', () {
      expect(splitIntoPackets([], maxBytes: 100), isEmpty);
    });

    test('порядок сохраняется, лимит соблюдается', () {
      final changes = [for (var i = 0; i < 10; i++) mut('c$i', noteLen: 40)];
      final one = sizeOf(changes.first);
      final packets = splitIntoPackets(changes, maxBytes: one * 3);
      // Каждый пакет ≤ лимита и порядок сквозной.
      final flat = packets.expand((p) => p).toList();
      expect(flat.map((c) => c['change_id']),
          changes.map((c) => c['change_id']));
      for (final p in packets) {
        final bytes = p.fold<int>(0, (s, c) => s + sizeOf(c));
        expect(bytes, lessThanOrEqualTo(one * 3));
      }
      expect(packets.length, greaterThan(1));
    });

    test('мутация тяжелее лимита уходит одиночным пакетом, не теряется', () {
      final big = mut('big', noteLen: 500);
      final packets =
          splitIntoPackets([mut('a'), big, mut('b')], maxBytes: 100);
      final flat = packets.expand((p) => p).toList();
      expect(flat.length, 3);
      expect(packets.any((p) => p.length == 1 && p.first['change_id'] == 'big'),
          isTrue);
    });

    test('невалидный лимит — ошибка', () {
      expect(() => splitIntoPackets([], maxBytes: 0), throwsArgumentError);
    });
  });
}
