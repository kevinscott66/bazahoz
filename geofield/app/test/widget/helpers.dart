import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geofield/data/database.dart';
import 'package:geofield/data/demo_seed.dart';
import 'package:geofield/data/dictionary_repository.dart';
import 'package:geofield/data/photo_repository.dart';
import 'package:geofield/data/point_repository.dart';
import 'package:geofield/data/sample_repository.dart';
import 'package:geofield/lab/lab_service.dart';
import 'package:geofield/screens/journal_screen.dart';
import 'package:geofield/sync/hlc.dart';
import 'package:geofield/theme/tokens.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Живой стенд: реальная SQLite (in-memory, ffi) с демо-сидом + репозитории.
class TestHarness {
  TestHarness._(this.db, this.clock, this.points, this.samples, this.dicts,
      this.photos, this.lab);

  final Database db;
  final HlcClock clock;
  final PointRepository points;
  final SampleRepository samples;
  final DictionaryRepository dicts;
  final PhotoRepository photos;
  final LabService lab;

  static Future<TestHarness> create() async {
    sqfliteFfiInit();
    // NoIsolate: под FakeAsync-зоной testWidgets ответы из другого изолята
    // не доставляются — база в том же изоляте завершает futures микротасками,
    // которые прокачивает pump().
    databaseFactory = databaseFactoryFfiNoIsolate;
    // Отдельная in-memory база на тест — без взаимных следов.
    final db = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 2,
        onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON'),
        onCreate: (d, _) async {
          await AppDatabase.migrate001(d);
          await AppDatabase.migrate002(d);
        },
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
    final photos = PhotoRepository(db,
        deviceId: demoDeviceId, authorId: demoAuthorId, clock: clock);
    final lab = LabService(db, samples,
        deviceId: demoDeviceId, authorId: demoAuthorId, clock: clock);
    return TestHarness._(db, clock, points, samples, dicts, photos, lab);
  }

  Widget journal() => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildGeoFieldTheme(),
        home: JournalScreen(
          points: points,
          samples: samples,
          dictionaries: dicts,
          photos: photos,
          projectId: demoProjectId,
          routeId: demoRouteId,
          authorId: demoAuthorId,
          sampleNumbering: demoNumbering,
          deviceId: demoDeviceId,
          clock: clock,
          lab: lab,
        ),
      );

  Widget wrap(Widget screen) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildGeoFieldTheme(),
      home: screen);

  Future<void> close() => db.close();
}

/// Прогнать дебаунс автосохранения (400 мс) и микротаски.
Future<void> settleSave(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 450));
  await tester.pumpAndSettle();
}

/// Высокий «полевой» вьюпорт: ListView в дефолтных 600px не строит секции
/// ниже сгиба (viewport culling) — финдеры не видят СТРУКТУРУ/кнопки/индикатор.
void tallPhone(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// TextField по фактическому значению контроллера: find.widgetWithText
/// ловит и label, и hint (у полей точки они совпадают со значением) и
/// возвращает один TextField трижды.
Finder textFieldValued(String value) => find
    .byWidgetPredicate((w) => w is TextField && w.controller?.text == value);

/// TextField по labelText оформления — однозначно (одно поле на подпись).
/// widgetWithText у поля с совпадающими label и hint матчит два Text-потомка
/// ОДНОГО поля и падает как «нашлось два».
Finder textFieldLabeled(String label) => find.byWidgetPredicate(
    (w) => w is TextField && w.decoration?.labelText == label);

/// Дать реальному вводу-выводу (файлы, сокеты) завершиться под FakeAsync.
Future<void> realIo(WidgetTester tester,
    [Duration d = const Duration(milliseconds: 500)]) {
  return tester.runAsync(() => Future<void>.delayed(d));
}
