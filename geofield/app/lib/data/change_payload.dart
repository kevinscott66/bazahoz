/// Локальные мета-поля устройства: описывают состояние синхронизации ЭТОГО
/// устройства, а не сущность. В wire-payload не попадают — иначе бухгалтерия
/// устройства A перезаписывает состояние устройства B при PULL.
const Set<String> localMetaColumns = {'sync_status'};

/// Дельта для change_log при op='update': только изменённые поля
/// (sync-protocol.md §1 — «update: только изменённые поля»). Полный payload
/// ломает пополевую логику конфликтов (§5.4): нельзя понять, что менялось.
/// Локальные мета-поля исключаются всегда.
Map<String, Object?> changedFields(
    Map<String, Object?> oldRow, Map<String, Object?> newRow) {
  final delta = <String, Object?>{};
  for (final e in newRow.entries) {
    if (localMetaColumns.contains(e.key)) continue;
    if (oldRow[e.key] != e.value) delta[e.key] = e.value;
  }
  return delta;
}

/// Payload для op='insert': полная запись без локальных мета-полей.
Map<String, Object?> insertPayload(Map<String, Object?> row) => {
      for (final e in row.entries)
        if (!localMetaColumns.contains(e.key)) e.key: e.value,
    };
