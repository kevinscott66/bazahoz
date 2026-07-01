/// Дельта для change_log при op='update': только изменённые поля
/// (sync-protocol.md §1 — «update: только изменённые поля»). Полный payload
/// ломает пополевую логику конфликтов (§5.4): нельзя понять, что менялось.
Map<String, Object?> changedFields(
    Map<String, Object?> oldRow, Map<String, Object?> newRow) {
  final delta = <String, Object?>{};
  for (final e in newRow.entries) {
    if (oldRow[e.key] != e.value) delta[e.key] = e.value;
  }
  return delta;
}
