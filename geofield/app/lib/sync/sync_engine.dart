import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../data/change_payload.dart' show localMetaColumns;
import 'hlc.dart';
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

/// Объём неотправленного в БАЙТАХ wire-формата (конверт мутации целиком,
/// UTF-8) — та же метрика, которой пакетайзер режет на пакеты. Общая точка
/// для экрана и движка: две разные оценки неизбежно разъехались бы.
Future<({int count, int bytes})> pendingWireSize(Database db) async {
  final rows = await db
      .query('change_log', where: 'synced = 0', orderBy: 'seq', columns: [
    'change_id',
    'entity_table',
    'entity_id',
    'op',
    'payload',
    'author_id',
    'logical_ts',
  ]);
  var bytes = 0;
  for (final r in rows) {
    bytes += utf8.encode(jsonEncode(SyncEngine.wireChange(r))).length;
  }
  return (count: rows.length, bytes: bytes);
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
  // Метаданные фото; файлы по спутнику не идут (defer_until_office, ТЗ §6.6).
  'photos',
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
    required this.clock,
    this.packetBytes = 128 * 1024, // sync.packet_size_kb по умолчанию
  });

  final Database _db;
  final RelayClient _client;
  final String deviceId;
  final HlcClock clock;
  final int packetBytes;
  final Uuid _uuid = const Uuid();

  bool _paused = false;

  /// Пауза после текущего пакета (кнопка «Пауза», ТЗ 6.8).
  void pause() => _paused = true;

  Future<SyncResult> run({void Function(SyncProgress)? onProgress}) async {
    _paused = false;
    var pushedChanges = 0, pushedPackets = 0, bytesSent = 0;
    var pulledApplied = 0, conflicts = 0;

    try {
      // --- PUSH: только дельта, пакетами, с подтверждением ---------------------
      final pending = await _pendingRows();
      // Заявка на весь снимок ДО отправки: помечаем строки «в отправке»
      // (ack_batch). Экран синхронизации не блокирует правки, и без заявки
      // конкурентный автосейв склеил бы новую дельту в строку, уже ушедшую в
      // пакет — ack за старое содержимое пометил бы synced=1 новое, и правка
      // потерялась бы. Склейка (logChange) обходит заявленные строки, поэтому
      // такая правка ложится отдельной строкой и уйдёт следующим сеансом.
      await _claimForPush(pending);
      final packets = splitIntoPackets(
        [for (final r in pending) wireChange(r)],
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

  /// Пометить снимок «в отправке» (ack_batch != NULL), чтобы склейка мутаций
  /// его не трогала. Идемпотентно: повторная заявка после сбоя сеанса не
  /// вредит, строки всё ещё synced=0 и переотправятся (relay дедуплицирует
  /// по change_id). Реальный batch_id проставит _markSynced по ack.
  Future<void> _claimForPush(List<Map<String, Object?>> rows) async {
    if (rows.isEmpty) return;
    final ids = [for (final r in rows) r['change_id'] as String];
    await _db.transaction((txn) async {
      const chunk = 500; // потолок переменных SQLite
      for (var i = 0; i < ids.length; i += chunk) {
        final part =
            ids.sublist(i, i + chunk > ids.length ? ids.length : i + chunk);
        final ph = List.filled(part.length, '?').join(',');
        await txn.rawUpdate(
          "UPDATE change_log SET ack_batch = 'sending' "
          "WHERE change_id IN ($ph) AND synced = 0 AND ack_batch IS NULL",
          part,
        );
      }
    });
  }

  Future<List<Map<String, Object?>>> _pendingRows() {
    return _db
        .query('change_log', where: 'synced = 0', orderBy: 'seq', columns: [
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
  static Map<String, Object?> wireChange(Map<String, Object?> row) => {
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
      final placeholders = List.filled(changeIds.length, '?').join(',');
      final args = changeIds.toList();
      // Какие сущности затронуты — до пометки, из тех же строк лога.
      final entities = await txn.rawQuery(
          'SELECT DISTINCT entity_table, entity_id FROM change_log '
          'WHERE change_id IN ($placeholders)',
          args);
      await txn.rawUpdate(
          'UPDATE change_log SET synced = 1, ack_batch = ? '
          'WHERE change_id IN ($placeholders)',
          [batchId, ...args]);
      // Сущность подтверждена, когда по ней не осталось неотправленных
      // мутаций. Прямой UPDATE sync_status: это мета-поле, НЕ пользовательская
      // мутация — без инкремента version и без записи в change_log.
      for (final e in entities) {
        final table = e['entity_table'] as String;
        final entityId = e['entity_id'] as String;
        if (!_applyTables.contains(table)) continue;
        final remaining = Sqflite.firstIntValue(await txn.rawQuery(
                'SELECT COUNT(*) FROM change_log '
                'WHERE entity_table = ? AND entity_id = ? AND synced = 0',
                [table, entityId])) ??
            0;
        if (remaining == 0) {
          await txn.update(table, {'sync_status': 'confirmed'},
              where: 'id = ?', whereArgs: [entityId]);
        }
      }
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
        bool ok;
        try {
          ok = await _applyOne(txn, c);
        } on DatabaseException catch (e) {
          // Отказ одной мутации (ошибка уровня стейтмента — транзакция
          // жива) не должен ронять страницу и блокировать PULL навсегда.
          await _recordConflict(txn, (c['entity_table'] as String?) ?? '?',
              (c['entity_id'] as String?) ?? '?',
              remote: jsonEncode(c), note: 'мутация отклонена базой: $e');
          ok = false;
        }
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

    // Метка обязана быть HLC (§4). Не-HLC (мусор, старый ISO-формат) — на
    // разбор: LWW со смешанными форматами дал бы бессмысленный порядок.
    final incomingHlc = Hlc.tryParse(incomingTs);
    if (incomingHlc == null) {
      await _recordConflict(txn, table ?? '?', entityId ?? '?',
          remote: jsonEncode(c), note: 'logical_ts не в формате HLC');
      return false;
    }
    // Подтянуть свои часы ДО любых проверок применимости: метку мы УВИДЕЛИ,
    // и следующая локальная обязана быть строго больше (§4) — даже если сама
    // мутация уйдёт в conflicts (неизвестная таблица от нового клиента).
    await clock.receive(txn, incomingHlc);

    if (table == null || entityId == null || !_applyTables.contains(table)) {
      await _recordConflict(txn, table ?? '?', entityId ?? '?',
          field: 'entity_table',
          remote: jsonEncode(c),
          note: 'неизвестная таблица');
      return false;
    }
    // HLC последнего писателя строки; '' — строки ещё нет/не писалась.
    final localTs = await rowClock(txn, table, entityId) ?? '';

    final existing = await txn.query(table,
        where: 'id = ?', whereArgs: [entityId], limit: 1);

    switch (op) {
      case 'insert':
        if (existing.isNotEmpty) return true; // идемпотентный повтор
        // Колонки, которых локальная схема не знает (более новый клиент), —
        // отбрасываем с фиксацией в conflicts, а не роняем вставку.
        final known = await _knownColumns(txn, table);
        final unknown = payload.keys.where((k) => !known.contains(k)).toList();
        final filtered = {
          for (final e in payload.entries)
            if (known.contains(e.key) && !localMetaColumns.contains(e.key))
              e.key: e.value,
        };
        if (filtered['id'] == null) {
          await _recordConflict(txn, table, entityId,
              remote: jsonEncode(payload), note: 'insert без id');
          return false;
        }
        // Запись пришла с relay — для ЭТОГО устройства она подтверждена:
        // отправлять её обратно нечего, журнал не должен счесть её «своей
        // неотправленной».
        filtered['sync_status'] = 'confirmed';
        try {
          await txn.insert(table, filtered);
        } on DatabaseException catch (e) {
          // Коллизия натурального ключа: два устройства офлайн завели одно
          // и то же под разными id (напр., dictionaries с одним code,
          // UNIQUE(project_id,dict_type,code)). На разбор — и дальше:
          // иначе исключение откатит всю страницу и PULL заблокируется
          // навсегда на этом же пакете.
          await _recordConflict(txn, table, entityId,
              remote: jsonEncode(payload),
              note: 'insert отклонён базой (дубль натурального ключа?): $e');
          return false;
        }
        await upsertRowClock(txn, table, entityId, incomingTs);
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
        if (incomingTs.compareTo(localTs) <= 0) {
          // Локальная новее/та же по HLC: входящая проигрывает, но не
          // стирается (§5.3). Равенство меток при разных device_id
          // невозможно (device_id — часть метки).
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
        // id и локальные мета-поля (sync_status) не применяются: состояние
        // синхронизации устройства B не должно перезаписываться бухгалтерией A.
        final filtered = {
          for (final e in payload.entries)
            if (known.contains(e.key) &&
                e.key != 'id' &&
                !localMetaColumns.contains(e.key))
              e.key: e.value,
        };
        if (filtered.isNotEmpty) {
          await txn
              .update(table, filtered, where: 'id = ?', whereArgs: [entityId]);
        }
        await upsertRowClock(txn, table, entityId, incomingTs);
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
        if (incomingTs.compareTo(localTs) <= 0) {
          // Локальная правка новее чужого удаления по HLC — LWW как в
          // update (§5.3): удаление проигрывает, след остаётся в истории.
          await _archive(txn, table, entityId,
              version: _asInt(row['version']),
              snapshot: jsonEncode({'losing_remote_delete': c}),
              author: c['author_id'] as String?);
          return true;
        }
        final localPending = row['sync_status'] == 'pending';
        await _archive(txn, table, entityId,
            version: _asInt(row['version']),
            snapshot: jsonEncode(row),
            author: row['author_id'] as String?);
        await txn.update(table, {'deleted': 1},
            where: 'id = ?', whereArgs: [entityId]);
        await upsertRowClock(txn, table, entityId, incomingTs);
        if (localPending) {
          // Чужое удаление поверх неотправленной локальной правки —
          // на разбор, как параллельная правка в update.
          await _recordConflict(txn, table, entityId,
              field: 'deleted',
              local: jsonEncode(row),
              remote: jsonEncode(c),
              note: 'удаление поверх неотправленной правки: применён LWW');
        }
        return true;

      default:
        await _recordConflict(txn, table, entityId,
            remote: jsonEncode(c), note: 'неизвестная операция $op');
        return false;
    }
  }

  final Map<String, Set<String>> _columnsCache = {};

  Future<Set<String>> _knownColumns(Transaction txn, String table) async {
    // Защита в глубину: имя таблицы интерполируется в PRAGMA — whitelist
    // обязан выполняться здесь, а не только в вызывающем коде.
    if (!_applyTables.contains(table)) {
      throw SyncException('таблица вне whitelist: $table');
    }
    final cached = _columnsCache[table];
    if (cached != null) return cached;
    final info = await txn.rawQuery('PRAGMA table_info($table)');
    final cols = {for (final r in info) r['name'] as String};
    _columnsCache[table] = cols;
    return cols;
  }

  Future<void> _archive(Transaction txn, String table, String entityId,
      {required int version, required String snapshot, String? author}) {
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
