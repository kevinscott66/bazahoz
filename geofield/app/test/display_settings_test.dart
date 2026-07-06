import 'package:flutter/material.dart' show Brightness;
import 'package:flutter_test/flutter_test.dart';
import 'package:geofield/config/display_settings.dart';
import 'package:geofield/theme/tokens.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Масштаб шрифта (ТЗ §4.5): сохраняется в sync_state, переживает перезапуск,
/// держится в разумных пределах.
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  Future<Database> openDb() => databaseFactory.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (d, _) => d.execute(
              'CREATE TABLE sync_state (key TEXT PRIMARY KEY, value TEXT)'),
        ),
      );

  test('по умолчанию 1.0; setTextScale сохраняет и уведомляет', () async {
    final db = await openDb();
    addTearDown(db.close);
    final s = await DisplaySettings.load(db);
    expect(s.textScale, 1.0);

    var notified = 0;
    s.addListener(() => notified++);
    await s.setTextScale(1.15);
    expect(s.textScale, 1.15);
    expect(notified, 1);

    // Тот же масштаб повторно — без записи и без уведомления.
    await s.setTextScale(1.15);
    expect(notified, 1);
  });

  test('масштаб переживает перезапуск (перечитан из sync_state)', () async {
    final db = await openDb();
    addTearDown(db.close);
    await (await DisplaySettings.load(db)).setTextScale(1.3);
    final reloaded = await DisplaySettings.load(db);
    expect(reloaded.textScale, 1.3);
  });

  test('мусор/выход за пределы зажимается в 1.0–1.3', () async {
    final db = await openDb();
    addTearDown(db.close);
    await db.insert('sync_state', {'key': 'text_scale', 'value': '9.9'});
    expect((await DisplaySettings.load(db)).textScale, 1.3);
    await db.update('sync_state', {'value': 'мусор'},
        where: "key = 'text_scale'");
    expect((await DisplaySettings.load(db)).textScale, 1.0);
  });

  group('«день на снегу» (светлая тема, ТЗ §4.5)', () {
    // Активная палитра — глобальная; возвращаем тёмную после каждого теста,
    // чтобы режим не протекал в соседние.
    tearDown(() => GfColors.use(GfPalette.dark));

    test('по умолчанию тёмная; setDaylight переключает палитру и уведомляет',
        () async {
      final db = await openDb();
      addTearDown(db.close);
      final s = await DisplaySettings.load(db);
      expect(s.daylight, isFalse);
      expect(s.palette.brightness, Brightness.dark);
      expect(GfColors.active.brightness, Brightness.dark);

      var notified = 0;
      s.addListener(() => notified++);
      await s.setDaylight(true);
      expect(s.daylight, isTrue);
      expect(notified, 1);
      // Глобальная палитра уже светлая — экраны читают её при перестройке.
      expect(GfColors.active.brightness, Brightness.light);
      expect(GfColors.textPrimary, GfPalette.daylight.textPrimary);

      // Тот же режим повторно — без записи и без уведомления.
      await s.setDaylight(true);
      expect(notified, 1);
    });

    test('режим темы переживает перезапуск', () async {
      final db = await openDb();
      addTearDown(db.close);
      await (await DisplaySettings.load(db)).setDaylight(true);
      GfColors.use(GfPalette.dark); // сбросим, чтобы проверить именно загрузку
      final reloaded = await DisplaySettings.load(db);
      expect(reloaded.daylight, isTrue);
      // load сам применяет палитру при создании.
      expect(GfColors.active.brightness, Brightness.light);
    });
  });
}
