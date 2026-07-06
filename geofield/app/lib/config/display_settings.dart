import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../theme/tokens.dart';

/// Настройки отображения (ТЗ §4.5): масштаб шрифта для чтения на ярком солнце
/// и в мороз + светлая тема «день на снегу» (высокий контраст на солнце).
/// Хранится в sync_state (локально, не синхронизируется — это предпочтение
/// устройства/человека, а не данные проекта).
class DisplaySettings extends ChangeNotifier {
  DisplaySettings(this._db, this._textScale, this._daylight) {
    // Применяем палитру сразу при создании, до первого кадра приложения.
    GfColors.use(palette);
  }

  final Database _db;
  double _textScale;
  bool _daylight;

  /// Множитель размера шрифта. 1.0 — обычный; 1.15 — крупный; 1.3 — очень
  /// крупный (проверено голденом на переполнение).
  double get textScale => _textScale;

  /// «День на снегу» — светлая высококонтрастная тема (ТЗ §4.5). false —
  /// тёмная тема по умолчанию (ночь/OLED).
  bool get daylight => _daylight;

  /// Активная палитра для текущего режима.
  GfPalette get palette => _daylight ? GfPalette.daylight : GfPalette.dark;

  static const scales = <(String, double)>[
    ('Обычный', 1.0),
    ('Крупный', 1.15),
    ('Очень крупный', 1.3),
  ];

  static const _key = 'text_scale';
  static const _themeKey = 'daylight_theme';

  static Future<DisplaySettings> load(Database db) async {
    Future<String?> read(String key) async {
      final rows = await db.query('sync_state',
          where: 'key = ?', whereArgs: [key], limit: 1);
      return rows.isEmpty ? null : rows.first['value'] as String?;
    }

    final v = double.tryParse(await read(_key) ?? '') ?? 1.0;
    final daylight = (await read(_themeKey)) == '1';
    // На случай мусора — держим в разумных пределах.
    return DisplaySettings(db, v.clamp(1.0, 1.3), daylight);
  }

  Future<void> _persist(String key, String value) => _db.insert(
        'sync_state',
        {'key': key, 'value': value},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

  Future<void> setTextScale(double scale) async {
    final s = scale.clamp(1.0, 1.3);
    if (s == _textScale) return;
    _textScale = s;
    notifyListeners();
    await _persist(_key, '$s');
  }

  Future<void> setDaylight(bool on) async {
    if (on == _daylight) return;
    _daylight = on;
    // Палитра меняется ДО notify — дерево перестроится уже на новой теме.
    GfColors.use(palette);
    notifyListeners();
    await _persist(_themeKey, on ? '1' : '0');
  }
}
