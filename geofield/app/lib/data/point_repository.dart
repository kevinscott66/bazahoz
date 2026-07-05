import 'package:sqflite/sqflite.dart';

import '../models/observation_point.dart';
import '../models/sample.dart';
import '../sync/hlc.dart';
import '../util/format.dart';
import 'change_payload.dart';

/// Доступ к точкам наблюдения и структурным замерам. Тот же инвариант, что и
/// у проб: каждая мутация — строка сущности + запись в change_log, атомарно
/// в одной транзакции (sync-protocol.md §1, §8.5).
class PointRepository {
  PointRepository(this._db,
      {required this.deviceId, required this.authorId, required this.clock});

  final Database _db;
  final String deviceId;
  final String authorId;
  final HlcClock clock;

  /// Доступ к базе для экранов, работающих поверх нескольких таблиц
  /// (синхронизация, диагностика).
  Database get db => _db;

  /// Следующий порядковый номер точки в маршруте. Считаются все строки,
  /// включая мягко удалённые — номер удалённой точки не переиспользуется
  /// (тот же принцип, что для проб: дубль идентификатора хуже дыры).
  Future<int> nextSeq(String routeId) async {
    final r = await _db.rawQuery(
      'SELECT COUNT(*) AS c FROM observation_points WHERE route_id = ?',
      [routeId],
    );
    return (Sqflite.firstIntValue(r) ?? 0) + 1;
  }

  Future<void> save(ObservationPoint point, {required bool isNew}) async {
    final map = point.toMap();
    await _db.transaction((txn) async {
      if (isNew) {
        await txn.insert('observation_points', map);
        await _log(
            txn, 'observation_points', point.id, 'insert', insertPayload(map));
      } else {
        // Дельта до update, в той же транзакции (payload update = только
        // изменённые поля, sync-protocol.md §1).
        final old = await txn.query('observation_points',
            where: 'id = ?', whereArgs: [point.id], limit: 1);
        final delta = old.isEmpty ? map : changedFields(old.first, map);
        await txn.update('observation_points', map,
            where: 'id = ?', whereArgs: [point.id]);
        await _log(txn, 'observation_points', point.id, 'update', delta);
      }
    });
  }

  Future<void> softDelete(ObservationPoint point) async {
    await _db.transaction((txn) async {
      await txn.update(
        'observation_points',
        {
          'deleted': 1,
          'version': point.version + 1,
          'modified_at': nowIso(),
          'sync_status': SyncStatus.pending.db,
        },
        where: 'id = ?',
        whereArgs: [point.id],
      );
      await _log(txn, 'observation_points', point.id, 'delete', const {});
    });
  }

  Future<List<ObservationPoint>> listByRoute(String routeId) async {
    final rows = await _db.query(
      'observation_points',
      where: 'route_id = ? AND deleted = 0',
      whereArgs: [routeId],
      orderBy: 'created_at DESC',
    );
    return rows.map(ObservationPoint.fromMap).toList();
  }

  Future<ObservationPoint?> byId(String id) async {
    final rows = await _db.query('observation_points',
        where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : ObservationPoint.fromMap(rows.first);
  }

  // --- структурные замеры -----------------------------------------------------

  Future<void> addMeasurement(StructuralMeasurement m) async {
    final map = m.toMap();
    await _db.transaction((txn) async {
      await txn.insert('structural_measurements', map);
      // insertPayload — как у точек/проб: если модель замера обзаведётся
      // локальными мета-полями, они не утекут на провод.
      await _log(
          txn, 'structural_measurements', m.id, 'insert', insertPayload(map));
    });
  }

  Future<List<StructuralMeasurement>> measurementsFor(String pointId) async {
    final rows = await _db.query(
      'structural_measurements',
      where: "parent_type = 'point' AND parent_id = ? AND deleted = 0",
      whereArgs: [pointId],
      orderBy: 'created_at',
    );
    return rows.map(StructuralMeasurement.fromMap).toList();
  }

  /// Название и дата маршрута — для шапки выгрузки.
  Future<({String? title, String? date})?> routeInfo(String routeId) async {
    final rows = await _db.query('routes',
        columns: ['title', 'route_date'],
        where: 'id = ?',
        whereArgs: [routeId],
        limit: 1);
    if (rows.isEmpty) return null;
    return (
      title: rows.first['title'] as String?,
      date: rows.first['route_date'] as String?,
    );
  }

  /// Все замеры точек маршрута — для выгрузки CSV.
  Future<List<StructuralMeasurement>> measurementsForRoute(
      String routeId) async {
    final rows = await _db.rawQuery('''
      SELECT m.* FROM structural_measurements m
      WHERE m.deleted = 0 AND m.parent_type = 'point' AND m.parent_id IN
        (SELECT id FROM observation_points WHERE route_id = ?)
      ORDER BY m.created_at
    ''', [routeId]);
    return rows.map(StructuralMeasurement.fromMap).toList();
  }

  Future<void> _log(DatabaseExecutor txn, String table, String entityId,
          String op, Map<String, Object?> payload) =>
      logChange(txn,
          clock: clock,
          table: table,
          entityId: entityId,
          op: op,
          payload: payload,
          authorId: authorId,
          deviceId: deviceId);
}
