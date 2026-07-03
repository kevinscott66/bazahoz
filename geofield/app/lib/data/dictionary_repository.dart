import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../sync/hlc.dart';

/// Запись справочника (dictionaries).
class DictEntry {
  const DictEntry({
    required this.code,
    required this.label,
    this.isPendingReview = false,
  });

  final String code;
  final String label;
  final bool isPendingReview;
}

/// Справочники проекта (породы, типы объектов…). Правило ТЗ §6.3: нельзя ввести
/// породу, которой нет в справочнике, но можно добавить с пометкой «на проверку».
class DictionaryRepository {
  DictionaryRepository(this._db,
      {required this.deviceId, required this.authorId, required this.clock});

  final Database _db;
  final String deviceId;
  final String authorId;
  final HlcClock clock;
  final Uuid _uuid = const Uuid();

  Future<List<DictEntry>> list(String projectId, String dictType) async {
    final rows = await _db.query(
      'dictionaries',
      where: 'project_id = ? AND dict_type = ? AND deleted = 0',
      whereArgs: [projectId, dictType],
      orderBy: 'sort_order, label',
    );
    return rows
        .map((r) => DictEntry(
              code: r['code'] as String,
              label: r['label'] as String,
              isPendingReview: (r['is_pending_review'] as int? ?? 0) != 0,
            ))
        .toList();
  }

  /// Найти код по видимой подписи (регистронезависимо) или по коду.
  /// Сравнение — в Dart: LOWER() в SQLite понижает только ASCII, кириллица
  /// «Гранит» не находилась и дублировалась «на проверку». Справочники
  /// невелики, полный проход дешевле собственной collation.
  Future<String?> codeForLabel(
      String projectId, String dictType, String text) async {
    final t = text.trim().toLowerCase();
    if (t.isEmpty) return null;
    final rows = await _db.query(
      'dictionaries',
      columns: ['code', 'label'],
      where: 'project_id = ? AND dict_type = ? AND deleted = 0',
      whereArgs: [projectId, dictType],
    );
    for (final r in rows) {
      final code = r['code'] as String;
      if (code == t || (r['label'] as String).toLowerCase() == t) {
        return code;
      }
    }
    return null;
  }

  /// Добавить значение «на проверку» (ТЗ §6.3), идемпотентно. Возвращает код.
  /// change_log пишется только при реальной вставке, не при повторе.
  Future<String> ensurePending(
      String projectId, String dictType, String label) async {
    final existing = await codeForLabel(projectId, dictType, label);
    if (existing != null) return existing;

    final code = 'pending:${label.trim().toLowerCase()}';
    final now = DateTime.now().toUtc().toIso8601String();
    final map = <String, Object?>{
      'id': _uuid.v4(),
      'project_id': projectId,
      'dict_type': dictType,
      'code': code,
      'label': label.trim(),
      'is_pending_review': 1,
      'author_id': authorId,
      'created_at': now,
      'modified_at': now,
    };
    await _db.transaction((txn) async {
      final rowId = await txn.insert('dictionaries', map,
          conflictAlgorithm: ConflictAlgorithm.ignore);
      // rowId == 0 — запись уже была (гонка/повтор): мутацию не логируем.
      if (rowId != 0) {
        final ts = (await clock.tick(txn)).encode();
        await upsertRowClock(txn, 'dictionaries', map['id'] as String, ts);
        await txn.insert('change_log', {
          'change_id': _uuid.v4(),
          'entity_table': 'dictionaries',
          'entity_id': map['id'],
          'op': 'insert',
          'payload': jsonEncode(map),
          'author_id': authorId,
          'device_id': deviceId,
          'logical_ts': ts,
        });
      }
    });
    return code;
  }

  /// Подпись по коду (для отображения сохранённого значения).
  Future<String?> labelForCode(
      String projectId, String dictType, String code) async {
    final rows = await _db.query(
      'dictionaries',
      where: 'project_id = ? AND dict_type = ? AND code = ? AND deleted = 0',
      whereArgs: [projectId, dictType, code],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['label'] as String;
  }
}
