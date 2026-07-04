import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../models/sample.dart';
import '../sync/hlc.dart';
import 'change_payload.dart';

/// Доступ к пробам. Каждая мутация пишется атомарно: строка `samples` +
/// запись в `change_log` (event sourcing, sync-protocol.md §1). Так база
/// готова к дельта-синхронизации с первого дня, а данные не теряются.
class SampleRepository {
  SampleRepository(this._db,
      {required this.deviceId, required this.authorId, required this.clock});

  final Database _db;
  final String deviceId;
  final String authorId;
  final HlcClock clock;
  final Uuid _uuid = const Uuid();

  /// Следующий сквозной номер пробы в проекте (для sample_numbering).
  /// Считаем ВСЕ строки, включая мягко удалённые (deleted=1): иначе номер и
  /// штрихкод удалённой пробы переиспользуются → дубль штрихкода, и результат
  /// из лаборатории нельзя однозначно сопоставить (ТЗ §2, §6.9).
  /// Прод (этап 2): выделенный монотонный счётчик на проект — устойчив к ручной
  /// правке номеров и к многоустройственной работе.
  Future<int> nextSeq(String projectId) async {
    final r = await _db.rawQuery(
      'SELECT COUNT(*) AS c FROM samples WHERE project_id = ?',
      [projectId],
    );
    return (Sqflite.firstIntValue(r) ?? 0) + 1;
  }

  Future<List<Sample>> listByParent(String parentType, String parentId) async {
    final rows = await _db.query(
      'samples',
      where: 'parent_type = ? AND parent_id = ? AND deleted = 0',
      whereArgs: [parentType, parentId],
      orderBy: 'created_at',
    );
    return rows.map(Sample.fromMap).toList();
  }

  /// Пробы маршрута: привязанные к точкам маршрута + свободные пробы проекта
  /// (без привязки), чтобы ничто не пряталось из журнала (ТЗ §6.7 — журнал
  /// «за день/маршрут», а не свалка всего проекта).
  Future<List<Sample>> listByRoute(String routeId,
      {required String projectId}) async {
    final rows = await _db.rawQuery('''
      SELECT s.* FROM samples s
      WHERE s.deleted = 0 AND (
        (s.parent_type = 'point' AND s.parent_id IN
          (SELECT id FROM observation_points WHERE route_id = ?))
        OR (s.parent_type IS NULL AND s.project_id = ?)
      )
      ORDER BY s.created_at DESC
    ''', [routeId, projectId]);
    return rows.map(Sample.fromMap).toList();
  }

  Future<List<Sample>> listByProject(String projectId) async {
    final rows = await _db.query(
      'samples',
      where: 'project_id = ? AND deleted = 0',
      whereArgs: [projectId],
      orderBy: 'created_at DESC',
    );
    return rows.map(Sample.fromMap).toList();
  }

  /// Upsert пробы + мутация в журнал изменений, в одной транзакции.
  /// [isNew] — вставка (op=insert) или правка (op=update).
  Future<void> save(Sample sample, {required bool isNew}) async {
    final map = sample.toMap();
    await _db.transaction((txn) async {
      Map<String, Object?> payload = insertPayload(map);
      if (isNew) {
        await txn.insert('samples', map);
      } else {
        // Дельта до update (payload update = только изменённые поля,
        // sync-protocol.md §1).
        final old = await txn.query('samples',
            where: 'id = ?', whereArgs: [sample.id], limit: 1);
        if (old.isNotEmpty) payload = changedFields(old.first, map);
        await txn.update('samples', map,
            where: 'id = ?', whereArgs: [sample.id]);
      }
      final ts = (await clock.tick(txn)).encode();
      await upsertRowClock(txn, 'samples', sample.id, ts);
      await txn.insert('change_log', {
        'change_id': _uuid.v4(),
        'entity_table': 'samples',
        'entity_id': sample.id,
        'op': isNew ? 'insert' : 'update',
        'payload': jsonEncode(payload),
        'author_id': authorId,
        'device_id': deviceId,
        'logical_ts': ts,
      });
    });
  }

  /// Разрешённые переходы жизненного цикла пробы (ТЗ §2, §6.5).
  static const Map<SampleStatus, SampleStatus> _nextStatus = {
    SampleStatus.collected: SampleStatus.packed,
    SampleStatus.packed: SampleStatus.sent,
    SampleStatus.sent: SampleStatus.resultReceived,
  };

  /// Перевод статуса. Только вперёд по цепочке collected→packed→sent→
  /// result_received; прыжок или откат — ArgumentError.
  /// [allowSkipPacked] — ведомость отправки переводит collected сразу в sent
  /// (упаковка и отправка одним действием — обычная полевая практика).
  ///
  /// Полностью транзакционен ОТ СВЕЖЕГО чтения строки: переданный объект —
  /// только id. Иначе двойной тап/повторный вызов со stale-снапшотом
  /// перезаписывал строку старыми полями и не двигал version (§8.4-8.5).
  /// Возвращает true — переход выполнен; false — строка уже в целевом
  /// статусе (идемпотентный повтор).
  Future<bool> advanceStatus(Sample sample, SampleStatus to,
      {bool allowSkipPacked = false}) async {
    return _db.transaction((txn) async {
      final rows = await txn.query('samples',
          where: 'id = ?', whereArgs: [sample.id], limit: 1);
      if (rows.isEmpty) {
        throw ArgumentError('проба ${sample.id} не найдена');
      }
      final fresh = Sample.fromMap(rows.first);
      if (fresh.status == to) return false; // уже там — повтор безопасен
      final valid = _nextStatus[fresh.status] == to ||
          (allowSkipPacked &&
              fresh.status == SampleStatus.collected &&
              to == SampleStatus.sent);
      if (!valid) {
        throw ArgumentError(
            'недопустимый переход статуса: ${fresh.status.db} → ${to.db}');
      }
      final delta = <String, Object?>{
        'status': to.db,
        'modified_at': DateTime.now().toUtc().toIso8601String(),
        'version': fresh.version + 1,
      };
      await txn.update('samples', {...delta, 'sync_status': 'pending'},
          where: 'id = ?', whereArgs: [sample.id]);
      final ts = (await clock.tick(txn)).encode();
      await upsertRowClock(txn, 'samples', sample.id, ts);
      await txn.insert('change_log', {
        'change_id': _uuid.v4(),
        'entity_table': 'samples',
        'entity_id': sample.id,
        'op': 'update',
        'payload': jsonEncode(delta),
        'author_id': authorId,
        'device_id': deviceId,
        'logical_ts': ts,
      });
      return true;
    });
  }

  /// Пробы проекта по статусу (для ведомости и разбора).
  Future<List<Sample>> listByStatus(
      String projectId, List<SampleStatus> statuses) async {
    final placeholders = List.filled(statuses.length, '?').join(',');
    final rows = await _db.query(
      'samples',
      where: 'project_id = ? AND deleted = 0 AND status IN ($placeholders)',
      whereArgs: [projectId, ...statuses.map((s) => s.db)],
      orderBy: 'sample_number',
    );
    return rows.map(Sample.fromMap).toList();
  }

  /// Проба по штрихкоду (привязка результатов лаборатории).
  Future<List<Sample>> byBarcode(String projectId, String barcode) async {
    final rows = await _db.query(
      'samples',
      where: 'project_id = ? AND deleted = 0 AND barcode = ?',
      whereArgs: [projectId, barcode],
    );
    return rows.map(Sample.fromMap).toList();
  }

  /// Мягкое удаление: deleted=1 + мутация op=delete (факт удаления
  /// доедет до сервера синхронизацией).
  Future<void> softDelete(Sample sample) async {
    await _db.transaction((txn) async {
      await txn.update(
        'samples',
        {
          'deleted': 1,
          'version': sample.version + 1,
          'modified_at': DateTime.now().toUtc().toIso8601String(),
          'sync_status': SyncStatus.pending.db,
        },
        where: 'id = ?',
        whereArgs: [sample.id],
      );
      final ts = (await clock.tick(txn)).encode();
      await upsertRowClock(txn, 'samples', sample.id, ts);
      await txn.insert('change_log', {
        'change_id': _uuid.v4(),
        'entity_table': 'samples',
        'entity_id': sample.id,
        'op': 'delete',
        'payload': '{}',
        'author_id': authorId,
        'device_id': deviceId,
        'logical_ts': ts,
      });
    });
  }
}
