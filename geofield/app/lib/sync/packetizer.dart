import 'dart:convert';

/// Нарезка мутаций на пакеты фиксированного веса (sync-protocol.md §3.1):
/// уходит только дельта, порезанная на пакеты, возобновляемая с места обрыва.
/// Вес считается по несжатому JSON мутации — стабильная, простая метрика;
/// gzip сверху только уменьшает фактический трафик.
///
/// Гарантии:
/// - порядок мутаций сохраняется (seq возрастает внутри и между пакетами);
/// - пакет не превышает [maxBytes], КРОМЕ случая одиночной мутации тяжелее
///   лимита — она уходит пакетом из одного элемента (иначе тупик: мутацию
///   нельзя ни поделить, ни бросить — данные не теряются никогда).
List<List<Map<String, Object?>>> splitIntoPackets(
  List<Map<String, Object?>> changes, {
  required int maxBytes,
}) {
  if (maxBytes <= 0) {
    throw ArgumentError.value(
        maxBytes, 'maxBytes', 'должен быть положительным');
  }
  final packets = <List<Map<String, Object?>>>[];
  var current = <Map<String, Object?>>[];
  var currentBytes = 0;

  for (final c in changes) {
    final size = utf8.encode(jsonEncode(c)).length;
    if (current.isNotEmpty && currentBytes + size > maxBytes) {
      packets.add(current);
      current = [];
      currentBytes = 0;
    }
    current.add(c);
    currentBytes += size;
  }
  if (current.isNotEmpty) packets.add(current);
  return packets;
}
