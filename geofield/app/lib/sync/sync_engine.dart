import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import 'packetizer.dart';
import 'relay_client.dart';

/// Прогресс сеанса для экрана (ТЗ 6.8).
class SyncProgress {
  const SyncProgress({
    required this.phase, // 'push' | 'pull' | 'done'
    required this.packetsDone,
    required this.packetsTotal,
    required this.bytesSent,
    required this.pulledApplied,
    this.message,
  });

  final String phase;
  final int packetsDone;
  final int packetsTotal;
  final int bytesSent;
  final int pulledApplied;
  final String? message;
}

/// Итог сеанса — в лог сеансов (sync_state['last_session']).
class SyncResult {
  const SyncResult({
    required this.pushedChanges,
    required this.pushedPackets,
    required this.bytesSent,
    required this.pulledApplied,
    required this.conflicts,
    required this.completed, // false — пауза/обрыв, возобновляемо
    this.error,
  });

  final int pushedChanges;
  final int pushedPackets;
  final int bytesSent;
  final int pulledApplied;
  final int conflicts;
  final bool completed;
  final String? error;

  Map<String, Object?> toMap() => {
        'pushed_changes': pushedChanges,
        'pushed_packets': pushedPackets,
        'bytes_sent': bytesSent,
        'pulled_applied': pulledApplied,
        'conflicts': conflicts,
        'completed': completed,
        'error': error,
      };
}

/// Управляемый сбой сеанса. Именно Exception (не Error): ловится ветвью
/// `on Exception` в run() и превращается в возобновляемый итог сеанса.
class SyncException implements Exception {
  SyncException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Таблицы, чьи мутации применяются при PULL. Неизвестная таблица — в
/// conflicts на ручной разбор, а не молчаливый пропуск.
const _applyTables = {
  'projects',
  'routes',
  'observation_points',
  'structural_measurements',
  'samples',
  'sample_results',
  'dictionaries',
};

/// Движок дельта-синхронизации (sync-protocol.md §3, §5).
/// Сначала PUSH (не потерять собранное), затем PULL. Обрыв на любом пакете —
/// возобновление: PUSH продолжится с первого неподтверждённого (synced=0),
/// PULL — с сохранённого курсора.
class SyncEngine {
  SyncEngine(
    this._db,
    this._client, {
    required this.deviceId,
    this.packetBytes = 128 * 1024, // sync.packet_size_kb по умолчанию
  });

  final Database _db;
  final RelayClient _client;
  final String deviceId;
  final int packetBytes;
  final Uuid _uuid = const Uuid();

  bool _paused = false;

  /// Пауза после текущего пакета (кнопка «Пауза», ТЗ 6.8).
  void pause() => _paused = true;

  /// Объём неотправленного — для «что уйдёт: N записей · X КБ» до сеанса.
  Future<({int count, int bytes})> pendingSize() async {
    final rows = await _pendingRows();
    var bytes = 0;
    for (final r in rows) {
      bytes += utf8.encode(jsonEncode(_wireChange(r))).length;
    }
    return (count: rows.length, bytes: bytes);
  }

  Future<SyncResult> run({void Function(SyncProgress)? onProgress}) async {
    _paused = false;
    var pushedChanges = 0, pushedPackets = 0, bytesSent = 0;
    var pulledApplied = 0, conflicts = 0;

    try {
      // --- PUSH: только дельта, пакетами, с подтверждением ---------------------
      final pending = await _pendingRows();
      final packets = splitIntoPackets(
        [for (final r in pending) _wireChange(r)],
        maxBytes: packetBytes,
      );
      for (var i = 0; i < packets.length; i++) {
        if (_paused) {
          return _finish(SyncResult(
            pushedChanges: pushedChanges,
            pushedPackets: pushedPackets,
            bytesSent: bytesSent,
            pulledApplied: pulledApplied,
            conflicts: conflicts,
            completed: false,
          ));
        }
        final packet = packets[i];
        final ack = await _client.push(deviceId, packet);
        // Подтверждено — только то, что relay назвал (accepted + duplicates:
        // дубликат значит «уже принят раньше», тоже подтверждение §8.1).
        final confirmed = {...ack.accepted, ...ack.duplicates};
        await _markSynced(confirmed, ack.batchId);
        final unconfirmed =
            packet.where((c) => !confirmed.contains(c['change_id'])).length;
        if (unconfirmed > 0) {
          // Relay не подтвердил часть пакета — не идём дальше, чинить разбором.
          // SyncException (не StateError!): Error не ловится `on Exception`.
          throw SyncException(
              'relay не подтвердил $unconfirmed мутаций из пакета ${i + 1}');
        }
        pushedChanges += packet.length;
        pushedPackets++;
        bytesSent += utf8.encode(jsonEncode(packet)).length;
        onProgress?.call(SyncProgress(
          phase: 'push',
          packetsDone: pushedPackets,
          packetsTotal: packets.length,
          bytesSent: bytesSent,
          pulledApplied: 0,
        ));
      }

      // --- PULL: чужие мутации с сохранённого курсора --------------------------
      var cursor = await _getCursor();
      var hasMore = true;
      while (hasMore) {
        if (_paused) {
          return _finish(SyncResult(
            pushedChanges: pushedChanges,
            pushedPackets: pushedPackets,
            bytesSent: bytesSent,
            pulledApplied: pulledApplied,
            conflicts: conflicts,
            completed: false,
          ));
        }
        final page = await _client.pull(deviceId, cursor);
        if (page.changes.isEmpty && !page.hasMore) {
          await _setCursor(page.nextCursor);
          break;
        }
        // Страница применяется одной транзакцией вместе с курсором:
        // падение между «применил» и «сдвинул курсор» невозможно (§8.3).
        final applied = await _applyPage(page.changes, page.nextCursor);
        pulledApplied += applied.applied;
        conflicts += applied.conflicts;
        cursor = page.nextCursor;
        hasMore = page.hasMore;
        onProgress?.call(SyncProgress(
          phase: 'pull',
          packetsDone: pushedPackets,
          packetsTotal: pushedPackets,
          bytesSent: bytesSent,
          pulledApplied: pulledApplied,
        ));
      }

      return _finish(SyncResult(
        pushedChanges: pushedChanges,
        pushedPackets: pushedPackets,
        bytesSent: bytesSent,
        pulledApplied: pulledApplied,
        conflicts: conflicts,
        completed: true,
      ));
    } on Exception catch (e) {
      // Обрыв канала/отказ relay: состояние согласовано (ack по пакетам,
      // курсор в транзакции) — следующий сеанс продолжит с места обрыва.
      return _finish(SyncResult(
        pushedChanges: pushedChanges,
        pushedPackets: pushedPackets,
        bytesSent: bytesSent,
        pulledApplied: pulledApplied,
        conflicts: conflicts,
        completed: false,
        error: e.toString(),
      ));
    }
  }

  // --- PUSH внутренности ---------------------------------------------------------

  Future<List<Map<String, Object?>>> _pendingRows() {
    return _db.query('change_log',
        where: 'synced = 0', orderBy: 'seq', columns: [
      'seq',
      'change_id',
      'entity_table',
      'entity_id',
      'op',
      'payload',
      'author_id',
      'logical_ts',
    ]);
  }

  /// Строка change_log → мутация протокола (payload — вложенным объектом).
  Map<String, Object?> _wireChange(Map<String, Object?> row) => {
        'change_id': row['change_id'],
        'entity_table': row['entity_table'],
        'entity_id': row['entity_id'],
        'op': row['op'],
        'payload': jsonDecode((row['payload'] as String?) ?? '{}'),
        'author_id': row['author_id'] ?? 'unknown',
        'logical_ts': row['logical_ts'],
      };

  Future<void> _markSynced(Set<String> changeIds, String batchId) async {
    if (changeIds.isEmpty) return;
    await _db.transaction((txn) async {
      final batch = txn.batch();
      for (final id in changeIds) {
        batch.update('change_log', {'synced': 1, 'ack_batch': batchId},
            where: 'change_id = ?', whereArgs: [id]);
      }
      await batch.commit(noResult: true);
    });
  }

  // --- PULL внутренности ---------------------------------------------------------

  Future<int> _getCursor() async {
    final rows = await _db.query('sync_state',
        where: "key = 'last_pulled_seq'", limit: 1);
    if (rows.isEmpty) return 0;
    return int.tryParse((rows.first['value'] as String?) ?? '0') ?? 0;
  }

  Future<void> _setCursor(int cursor) => _db.insert(
        'sync_state',
        {'key': 'last_pulled_seq', 'value': '$cursor'},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

  Future<({int applied, int conflicts})> _applyPage(
      List<Map<String, Object?>> changes, int nextCursor) async {
    var applied = 0, conflicts = 0;
    await _db.transaction((txn) async {
      for (final c in changes) {
        final ok = await _applyOne(txn, c);
        if (ok) {
          applied++;
        } else {
          conflicts++;
        }
      }
      await txn.insert(
        'sync_state',
        {'key': 'last_pulled_seq', 'value': '$nextCursor'},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
    return (applied: applied, conflicts: conflicts);
  }

  /// Применение одной чужой мутации (LWW + история, §5).
  /// true — применена/идемпотентно пропущена; false — ушла в conflicts.
  Future<bool> _applyOne(Transaction txn, Map<String, Object?> c) async {
    final table = c['entity_table'] as String?;
    final entityId = c['entity_id'] as String?;
    final op = c['op'] as String?;
    final incomingTs = (c['logical_ts'] as String?) ?? '';
    final payload = (c['payload'] as Map?)?.cast<String, Object?>() ?? {};

    if (table == null || entityId == null || !_applyTables.contains(table)) {
      await _recordConflict(txn, table ?? '?', entityId ?? '?',
          field: 'entity_table',
          remote: jsonEncode(c),
          note: 'неизвестная таблица');
      return false;
    }

    final existing = await txn.query(table,
        where: 'id = ?', whereArgs: [entityId], limit: 1);

    switch (op) {
      case 'insert':
        if (existing.isNotEmpty) return true; // идемпотентный повтор
        // Колонки, которых локальная схема не знает (более новый клиент), —
        // отбрасываем с фиксацией в conflicts, а не роняем вставку.
        final known = await _knownColumns(txn, table);
        final unknown =
            payload.keys.where((k) => !known.contains(k)).toList();
        final filtered = {
          for (final e in payload.entries)
            if (known.contains(e.key)) e.key: e.value,
        };
        if (filtered['id'] == null) {
          await _recordConflict(txn, table, entityId,
              remote: jsonEncode(payload), note: 'insert без id');
          return false;
        }
        await txn.insert(table, filtered);
        if (unknown.isNotEmpty) {
          await _recordConflict(txn, table, entityId,
              field: unknown.join(','),
              remote: jsonEncode(payload),
              note: 'поля новее локальной схемы отброшены');
        }
        return true;

      case 'update':
        if (existing.isEmpty) {
          // Дельта без базовой строки (мутации могли прийти не по порядку
          // причинности) — на разбор.
          await _recordConflict(txn, table, entityId,
              remote: jsonEncode(payload), note: 'update без базовой строки');
          return false;
        }
        final row = existing.first;
        final localTs = (row['modified_at'] as String?) ?? '';
        if (incomingTs.compareTo(localTs) <= 0) {
          // Локальная новее/та же: входящая проигрывает, но не стирается (§5.3).
          await _archive(txn, table, entityId,
              version: _asInt(row['version']),
              snapshot: jsonEncode({'losing_remote_delta': payload}),
              author: c['author_id'] as String?);
          return true;
        }
        // Входящая новее. Локальные неотправленные правки тех же полей —
        // конфликт на разбор, но LWW применяем (§5.4).
        final localPending = row['sync_status'] == 'pending';
        await _archive(txn, table, entityId,
            version: _asInt(row['version']),
            snapshot: jsonEncode(row),
            author: row['author_id'] as String?);
        final known = await _knownColumns(txn, table);
        final filtered = {
          for (final e in payload.entries)
            if (known.contains(e.key) && e.key != 'id') e.key: e.value,
        };
        if (filtered.isNotEmpty) {
          await txn.update(table, filtered,
              where: 'id = ?', whereArgs: [entityId]);
        }
        if (localPending) {
          for (final f in filtered.keys) {
            await _recordConflict(txn, table, entityId,
                field: f,
                local: jsonEncode(row[f]),
                remote: jsonEncode(filtered[f]),
                note: 'параллельная правка: применён LWW, требует решения');
          }
        }
        return true;

      case 'delete':
        if (existing.isEmpty) return true; // нечего удалять — идемпотентно
        final row = existing.first;
        await _archive(txn, table, entityId,
            version: _asInt(row['version']),
            snapshot: jsonEncode(row),
            author: row['author_id'] as String?);
        await txn.update(table, {'deleted': 1},
            where: 'id = ?', whereArgs: [entityId]);
        return true;

      default:
        await _recordConflict(txn, table, entityId,
            remote: jsonEncode(c), note: 'неизвестная операция $op');
        return false;
    }
  }

  final Map<String, Set<String>> _columnsCache = {};

  Future<Set<String>> _knownColumns(Transaction txn, String table) async {
    final cached = _columnsCache[table];
    if (cached != null) return cached;
    final info = await txn.rawQuery('PRAGMA table_info($table)');
    final cols = {for (final r in info) r['name'] as String};
    _columnsCache[table] = cols;
    return cols;
  }

  Future<void> _archive(Transaction txn, String table, String entityId,
      {required int version,
      required String snapshot,
      String? author}) {
    return txn.insert('record_history', {
      'id': _uuid.v4(),
      'entity_table': table,
      'entity_id': entityId,
      'version': version,
      'snapshot': snapshot,
      'author_id': author,
      'archived_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  Future<void> _recordConflict(Transaction txn, String table, String entityId,
      {String? field, String? local, String? remote, String? note}) {
    return txn.insert('conflicts', {
      'id': _uuid.v4(),
      'entity_table': table,
      'entity_id': entityId,
      'field': field,
      'local_value': local,
      'remote_value': note == null ? remote : '$remote · $note',
      'detected_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  static int _asInt(Object? v) => v is int ? v : int.tryParse('$v') ?? 0;

  Future<SyncResult> _finish(SyncResult r) async {
    await _db.insert(
      'sync_state',
      {
        'key': 'last_session',
        'value': jsonEncode({
          ...r.toMap(),
          'at': DateTime.now().toUtc().toIso8601String(),
        }),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    return r;
  }
}
