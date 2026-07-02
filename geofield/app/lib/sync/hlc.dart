import 'package:sqflite/sqflite.dart';

/// Гибридные логические часы (sync-protocol.md §4).
/// Времени устройств доверять нельзя: порядок мутаций определяется парой
/// (физ_время_мс, счётчик) с детерминированным разрывом ничьей по device_id.
///
/// Кодирование — сортируемая строка фиксированной ширины:
///   `000001846500000000:000042:device-id`
///   (15 цифр миллисекунд · 6 цифр счётчика · device_id)
/// Лексикографическое сравнение строк == сравнению HLC, включая ничью.
class Hlc {
  const Hlc(this.millis, this.counter, this.deviceId);

  final int millis;
  final int counter;
  final String deviceId;

  static const _mw = 15; // ширина миллисекунд: хватает до ~33658 года
  static const _cw = 6; // ширина счётчика
  static const maxCounter = 999999;

  String encode() => '${millis.toString().padLeft(_mw, '0')}:'
      '${counter.toString().padLeft(_cw, '0')}:$deviceId';

  /// Разбор кодированной метки. Null — не HLC-формат (мусор/чужая версия).
  static Hlc? tryParse(String s) {
    // device_id может содержать ':'? — запрещено форматом; первые два поля
    // фиксированной ширины, поэтому режем по позициям, не по split.
    if (s.length < _mw + 1 + _cw + 2) return null;
    if (s[_mw] != ':' || s[_mw + 1 + _cw] != ':') return null;
    final m = int.tryParse(s.substring(0, _mw));
    final c = int.tryParse(s.substring(_mw + 1, _mw + 1 + _cw));
    final d = s.substring(_mw + 1 + _cw + 1);
    if (m == null || c == null || d.isEmpty) return null;
    return Hlc(m, c, d);
  }

  @override
  String toString() => encode();
}

/// Часы устройства: локальный тик на каждую мутацию, подтягивание при приёме
/// чужой метки. Состояние переживает рестарт (sync_state['hlc_state']) и
/// пишется в ту же транзакцию, что и мутация — часы не «откатываются» падением.
class HlcClock {
  HlcClock._(this.deviceId, this._millis, this._counter);

  final String deviceId;
  int _millis;
  int _counter;

  static const _stateKey = 'hlc_state';

  /// Загрузка состояния из базы (0:0 у новой).
  static Future<HlcClock> load(DatabaseExecutor db, String deviceId) async {
    final rows = await db.query('sync_state',
        where: 'key = ?', whereArgs: [_stateKey], limit: 1);
    var millis = 0, counter = 0;
    if (rows.isNotEmpty) {
      final parts = ((rows.first['value'] as String?) ?? '').split(':');
      if (parts.length == 2) {
        millis = int.tryParse(parts[0]) ?? 0;
        counter = int.tryParse(parts[1]) ?? 0;
      }
    }
    return HlcClock._(deviceId, millis, counter);
  }

  /// Локальное событие: метка строго больше всех выданных и виденных.
  /// Персистит состояние в переданной транзакции.
  Future<Hlc> tick(DatabaseExecutor txn) async {
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    if (now > _millis) {
      _millis = now;
      _counter = 0;
    } else {
      // Часы устройства стоят/ушли назад — движемся счётчиком.
      _counter++;
      if (_counter > Hlc.maxCounter) {
        _millis++; // переполнение счётчика: шаг «виртуальной» миллисекундой
        _counter = 0;
      }
    }
    await _persist(txn);
    return Hlc(_millis, _counter, deviceId);
  }

  /// Приём чужой метки: подтянуть свои часы до max(свои, чужие) так, чтобы
  /// следующий локальный tick был строго больше принятой метки.
  Future<void> receive(DatabaseExecutor txn, Hlc remote) async {
    if (remote.millis > _millis) {
      _millis = remote.millis;
      _counter = remote.counter;
    } else if (remote.millis == _millis && remote.counter > _counter) {
      _counter = remote.counter;
    } // иначе свои уже впереди — не трогаем
    await _persist(txn);
  }

  Future<void> _persist(DatabaseExecutor txn) => txn.insert(
        'sync_state',
        {'key': _stateKey, 'value': '$_millis:$_counter'},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
}

/// HLC последнего писателя строки (для LWW при PULL) — локальная
/// вспомогательная таблица row_clocks. Обновляется в той же транзакции,
/// что и мутация/применение.
Future<void> upsertRowClock(DatabaseExecutor txn, String table,
    String entityId, String hlcTs) {
  return txn.insert(
    'row_clocks',
    {'entity_table': table, 'entity_id': entityId, 'hlc_ts': hlcTs},
    conflictAlgorithm: ConflictAlgorithm.replace,
  );
}

Future<String?> rowClock(
    DatabaseExecutor txn, String table, String entityId) async {
  final rows = await txn.query('row_clocks',
      where: 'entity_table = ? AND entity_id = ?',
      whereArgs: [table, entityId],
      limit: 1);
  return rows.isEmpty ? null : rows.first['hlc_ts'] as String?;
}
