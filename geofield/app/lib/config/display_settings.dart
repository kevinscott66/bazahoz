import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

/// Настройки отображения (ТЗ §4.5): масштаб шрифта для чтения на ярком солнце
/// и в мороз. Хранится в sync_state (локально, не синхронизируется — это
/// предпочтение устройства/человека, а не данные проекта).
class DisplaySettings extends ChangeNotifier {
  DisplaySettings(this._db, this._textScale);

  final Database _db;
  double _textScale;

  /// Множитель размера шрифта. 1.0 — обычный; 1.15 — крупный; 1.3 — очень
  /// крупный (проверено голденом на переполнение).
  double get textScale => _textScale;

  static const scales = <(String, double)>[
    ('Обычный', 1.0),
    ('Крупный', 1.15),
    ('Очень крупный', 1.3),
  ];

  static const _key = 'text_scale';

  static Future<DisplaySettings> load(Database db) async {
    final rows = await db.query('sync_state',
        where: 'key = ?', whereArgs: [_key], limit: 1);
    final v = rows.isEmpty
        ? 1.0
        : (double.tryParse((rows.first['value'] as String?) ?? '') ?? 1.0);
    // На случай мусора — держим в разумных пределах.
    return DisplaySettings(db, v.clamp(1.0, 1.3));
  }

  Future<void> setTextScale(double scale) async {
    final s = scale.clamp(1.0, 1.3);
    if (s == _textScale) return;
    _textScale = s;
    notifyListeners();
    await _db.insert(
      'sync_state',
      {'key': _key, 'value': '$s'},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }
}
