import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../sync/hlc.dart';

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

/// Запись мутации в журнал изменений: HLC-метка, часы последнего писателя
/// строки и строка change_log — в ТОЙ ЖЕ транзакции, что и сама мутация
/// (sync-protocol.md §4, §8.5): падение не рассинхронизирует их.
/// Единая точка для всех репозиториев — инвариант не расходится по копиям.
Future<void> logChange(
  DatabaseExecutor txn, {
  required HlcClock clock,
  required String table,
  required String entityId,
  required String op, // insert | update | delete
  required Map<String, Object?> payload,
  required String authorId,
  required String deviceId,
}) async {
  final ts = (await clock.tick(txn)).encode();
  await upsertRowClock(txn, table, entityId, ts);
  await txn.insert('change_log', {
    'change_id': const Uuid().v4(),
    'entity_table': table,
    'entity_id': entityId,
    'op': op,
    'payload': jsonEncode(payload),
    'author_id': authorId,
    'device_id': deviceId,
    'logical_ts': ts,
  });
}
