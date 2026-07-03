import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geofield/data/database.dart';
import 'package:geofield/data/demo_seed.dart';
import 'package:geofield/data/dictionary_repository.dart';
import 'package:geofield/data/point_repository.dart';
import 'package:geofield/data/sample_repository.dart';
import 'package:geofield/screens/journal_screen.dart';
import 'package:geofield/sync/hlc.dart';
import 'package:geofield/theme/tokens.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Живой стенд: реальная SQLite (in-memory, ffi) с демо-сидом + репозитории.
class TestHarness {
  TestHarness._(this.db, this.clock, this.points, this.samples, this.dicts);

  final Database db;
  final HlcClock clock;
  final PointRepository points;
  final SampleRepository samples;
  final DictionaryRepository dicts;

  static Future<TestHarness> create() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    // Отдельная in-memory база на тест — без взаимных следов.
    final db = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 1,
        onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON'),
        onCreate: (d, _) => AppDatabase.migrate001(d),
      ),
    );
    await seedDemo(db);
    final clock = await HlcClock.load(db, demoDeviceId);
    final points = PointRepository(db,
        deviceId: demoDeviceId, authorId: demoAuthorId, clock: clock);
    final samples = SampleRepository(db,
        deviceId: demoDeviceId, authorId: demoAuthorId, clock: clock);
    final dicts = DictionaryRepository(db,
        deviceId: demoDeviceId, authorId: demoAuthorId, clock: clock);
    return TestHarness._(db, clock, points, samples, dicts);
  }

  Widget journal() => MaterialApp(
        theme: buildGeoFieldTheme(),
        home: JournalScreen(
          points: points,
          samples: samples,
          dictionaries: dicts,
          projectId: demoProjectId,
          routeId: demoRouteId,
          authorId: demoAuthorId,
          sampleNumbering: demoNumbering,
          deviceId: demoDeviceId,
          clock: clock,
        ),
      );

  Widget wrap(Widget screen) =>
      MaterialApp(theme: buildGeoFieldTheme(), home: screen);

  Future<void> close() => db.close();
}

/// Прогнать дебаунс автосохранения (400 мс) и микротаски.
Future<void> settleSave(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 450));
  await tester.pumpAndSettle();
}
