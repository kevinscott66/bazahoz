import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geofield/data/demo_seed.dart';
import 'package:geofield/models/sample.dart';
import 'package:geofield/screens/point_form_screen.dart';
import 'package:geofield/screens/sample_capture_screen.dart';
import 'package:geofield/util/crs.dart';
import 'package:geofield/util/gps.dart';
import 'package:geofield/widgets/photo_strip.dart';
import 'package:path/path.dart' as p;

import 'helpers.dart';

void main() {
  Future<TestHarness> pumpPoint(WidgetTester tester,
      {GpsProvider? gps, PhotoPicker? picker}) async {
    tallPhone(tester);
    final h = await TestHarness.create();
    addTearDown(h.close);
    await tester.pumpWidget(h.wrap(PointFormScreen(
      points: h.points,
      samples: h.samples,
      dictionaries: h.dicts,
      photos: h.photos,
      projectId: demoProjectId,
      routeId: demoRouteId,
      authorId: demoAuthorId,
      sampleNumbering: demoNumbering,
      initialNumber: 'Т-001',
      gps: gps ?? acquireGpsFix,
      photoPicker: picker,
    )));
    await settleSave(tester);
    return h;
  }

  testWidgets('черновик пишется сразу; все разделы формы на экране',
      (tester) async {
    final h = await pumpPoint(tester);
    final rows = await h.db.query('observation_points');
    expect(rows, hasLength(1));
    expect(rows.single['is_draft'], 1);
    expect(find.text('черновик'), findsOneWidget);
    for (final section in [
      'НОМЕР ТОЧКИ',
      'КООРДИНАТЫ (WGS-84)',
      'ОПИСАНИЕ',
      'МИНЕРАЛИЗАЦИЯ',
      'СТРУКТУРА',
      'ПРОБЫ',
      'ФОТО',
    ]) {
      expect(find.text(section), findsOneWidget, reason: section);
    }
    expect(find.text('Готово'), findsOneWidget);
    expect(find.text('Удалить точку'), findsOneWidget);
  });

  testWidgets(
      'СК-42: ввод X/Y сохраняется каноническим WGS-84; '
      'переключение СК не двигает точку', (tester) async {
    final h = await pumpPoint(tester);
    // Переключить систему координат на СК-42 через шторку-пикер.
    await tester.tap(find.text('Система координат'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('СК-42'));
    await tester.pumpAndSettle();
    // Поля переименовались в Север (X) / Восток (Y).
    expect(textFieldLabeled('Север (X), м'), findsOneWidget);
    expect(textFieldLabeled('Восток (Y), м'), findsOneWidget);

    // Ввести плоские координаты Сусумана и проверить, что в базе — WGS-84.
    final gk = wgs84ToSk42Gk(62.78341, 148.15702);
    await tester.enterText(
        textFieldLabeled('Север (X), м'), gk.x.toStringAsFixed(0));
    await tester.enterText(
        textFieldLabeled('Восток (Y), м'), gk.y.toStringAsFixed(0));
    await settleSave(tester);
    final row = (await h.db.query('observation_points')).single;
    expect(row['lat'] as double, closeTo(62.78341, 1e-4),
        reason: 'СК-42 X/Y приведены к каноническому WGS-84');
    expect(row['lon'] as double, closeTo(148.15702, 1e-4));

    // Вернуть WGS-84 — координата не должна «переехать» от round-trip.
    await tester.tap(find.text('Система координат'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('WGS-84'));
    await tester.pumpAndSettle();
    expect(textFieldLabeled('Широта'), findsOneWidget);
    final row2 = (await h.db.query('observation_points')).single;
    expect(row2['lat'] as double, closeTo(62.78341, 1e-4));
    expect(row2['lon'] as double, closeTo(148.15702, 1e-4));
  });

  testWidgets(
      'координаты: половина пары и выход за диапазон — invalid, не пишутся',
      (tester) async {
    final h = await pumpPoint(tester);
    await tester.enterText(find.widgetWithText(TextField, 'Широта'), '62.5');
    await settleSave(tester);
    expect(find.text('Укажите обе координаты или ни одной'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, 'Долгота'), '999');
    await settleSave(tester);
    expect(find.text('Долгота вне диапазона ±180'), findsOneWidget);
    final row = (await h.db.query('observation_points')).single;
    expect(row['lat'], isNull, reason: 'противоречие не персистится');

    await tester.enterText(find.widgetWithText(TextField, 'Долгота'), '148.15');
    await settleSave(tester);
    final row2 = (await h.db.query('observation_points')).single;
    expect(row2['lat'], 62.5);
    expect(row2['lon'], 148.15);
    expect(row2['coord_source'], 'manual');
  });

  testWidgets(
      'заполнение обязательного снимает черновик; порода из справочника по коду',
      (tester) async {
    final h = await pumpPoint(tester);
    // Тип объекта из шторки-пикера.
    await tester.tap(find.text('Тип объекта'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Шурф'));
    await tester.pumpAndSettle();
    // Порода — автоподсказка из справочника.
    await tester.enterText(
        find.widgetWithText(
            TextField, 'Порода (справочник; новое — «на проверку»)'),
        'Гранит');
    // Координаты.
    await tester.enterText(find.widgetWithText(TextField, 'Широта'), '62.1');
    await tester.enterText(find.widgetWithText(TextField, 'Долгота'), '149.9');
    await settleSave(tester);

    final row = (await h.db.query('observation_points')).single;
    expect(row['is_draft'], 0, reason: 'обязательные поля заполнены');
    expect(row['object_type'], 'shurf');
    expect(row['rock_code'], 'granite', reason: 'код из справочника, не текст');
    expect(find.text('черновик'), findsNothing);
    expect(find.text('сохранено · не отправлено'), findsOneWidget);
  });

  testWidgets('новая порода уходит в справочник «на проверку»', (tester) async {
    final h = await pumpPoint(tester);
    await tester.enterText(
        find.widgetWithText(
            TextField, 'Порода (справочник; новое — «на проверку»)'),
        'Новопородит');
    await settleSave(tester);
    final dict = await h.db.query('dictionaries',
        where: "dict_type = 'rock' AND is_pending_review = 1");
    expect(dict, hasLength(1));
    expect(dict.single['label'], 'Новопородит');
    final row = (await h.db.query('observation_points')).single;
    expect(row['rock_code'], dict.single['code']);
  });

  testWidgets('минерализация: чипы пишут JSON-массив объектов', (tester) async {
    final h = await pumpPoint(tester);
    await tester.ensureVisible(find.text('Пирит'));
    await tester.tap(find.text('Пирит'));
    await tester.tap(find.text('Видимое золото'));
    await settleSave(tester);
    final row = (await h.db.query('observation_points')).single;
    expect(row['minerals'], '[{"code":"native_gold"},{"code":"pyrite"}]');
    // Снятие чипа убирает код.
    await tester.tap(find.text('Пирит'));
    await settleSave(tester);
    final row2 = (await h.db.query('observation_points')).single;
    expect(row2['minerals'], '[{"code":"native_gold"}]');
  });

  testWidgets(
      'структурный замер: диапазоны валидируются, тип обязателен и сохраняется',
      (tester) async {
    final h = await pumpPoint(tester);
    await tester.ensureVisible(find.text('+ Замер'));
    await tester.tap(find.text('+ Замер'));
    await tester.pumpAndSettle();
    // Тип по умолчанию «Слоистость» — меняем на «Жила» через шторку.
    await tester.tap(find.text('Слоистость'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Жила'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Азимут падения, 0–359'), '400');
    await tester.enterText(
        find.widgetWithText(TextField, 'Угол падения, 0–90'), '95');
    await tester.tap(find.text('Добавить'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Азимут 0–359, угол 0–90'), findsOneWidget);
    expect(await h.db.query('structural_measurements'), isEmpty);

    // Валидные значения проходят и попадают в список и в базу.
    await tester.tap(find.text('+ Замер'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Слоистость'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Жила'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Азимут падения, 0–359'), '120');
    await tester.enterText(
        find.widgetWithText(TextField, 'Угол падения, 0–90'), '45');
    await tester.tap(find.text('Добавить'));
    await settleSave(tester);
    final ms = await h.db.query('structural_measurements');
    expect(ms, hasLength(1));
    expect(ms.single['measure_type'], 'vein');
    expect(ms.single['dip_azimuth'], 120.0);
    expect(ms.single['is_true_angle'], 0, reason: 'по умолчанию магнитный');
    expect(find.textContaining('Жила: аз. пад. 120°'), findsOneWidget);
    expect(find.textContaining('магн.'), findsOneWidget);
  });

  testWidgets('замер: истинный азимут помечается и виден в списке',
      (tester) async {
    final h = await pumpPoint(tester);
    await tester.ensureVisible(find.text('+ Замер'));
    await tester.tap(find.text('+ Замер'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Азимут падения, 0–359'), '90');
    await tester.enterText(
        find.widgetWithText(TextField, 'Угол падения, 0–90'), '30');
    // Переключить азимут на истинный через шторку-пикер.
    await tester.tap(find.text('Азимут'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Истинный'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Добавить'));
    await settleSave(tester);
    final ms = await h.db.query('structural_measurements');
    expect(ms.single['is_true_angle'], 1);
    expect(find.textContaining('ист.'), findsOneWidget);
  });

  testWidgets('кнопка датчика честно сообщает о недоступности', (tester) async {
    // GPS теперь настоящий (см. тесты «С приёмника» ниже) — за флагом
    // остаётся только компас для структурных замеров.
    await pumpPoint(tester);
    await tester.ensureVisible(find.text('С датчика'));
    await tester.tap(find.text('С датчика'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Датчики не подключены'), findsOneWidget);
  });

  testWidgets('«+ Проба» открывает экран пробы с привязкой и автономером',
      (tester) async {
    await pumpPoint(tester);
    await tester.ensureVisible(find.text('+ Проба'));
    await tester.tap(find.text('+ Проба'));
    await tester.pumpAndSettle();
    expect(find.byType(SampleCaptureScreen), findsOneWidget);
    expect(find.text('Привязано к: Точка № Т-001'), findsOneWidget);
    expect(textFieldValued('SUZ-00001'), findsOneWidget);
  });

  testWidgets('удаление точки с пробами запрещено; без проб — мягкое удаление',
      (tester) async {
    final h = await pumpPoint(tester);
    // Привязать пробу напрямую в базу.
    final pointId =
        (await h.db.query('observation_points')).single['id'] as String;
    final now = DateTime.now().toUtc().toIso8601String();
    await h.samples.save(
        Sample(
          id: 's-1',
          projectId: demoProjectId,
          parentType: 'point',
          parentId: pointId,
          sampleNumber: 'SUZ-00001',
          sampleType: 'core',
          authorId: demoAuthorId,
          createdAt: now,
          modifiedAt: now,
        ),
        isNew: true);

    await tester.ensureVisible(find.text('Удалить точку'));
    await tester.tap(find.text('Удалить точку'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Сначала удалите или отвяжите пробы'),
        findsOneWidget);
    expect((await h.db.query('observation_points')).single['deleted'], 0);

    // Убрать пробу — удаление проходит через подтверждение.
    await h.samples
        .softDelete(Sample.fromMap((await h.db.query('samples')).single));
    await tester.tap(find.text('Удалить точку'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Удалить'));
    await tester.pumpAndSettle();
    expect((await h.db.query('observation_points')).single['deleted'], 1);
  });

  testWidgets(
      '«С приёмника»: координаты с точностью, источник gps; '
      'ручная правка возвращает manual', (tester) async {
    final h = await pumpPoint(tester,
        gps: () async =>
            (lat: 62.123456, lon: 148.654321, elevation: 812.0, accuracy: 4.0));
    await tester.ensureVisible(find.text('С приёмника'));
    await tester.tap(find.text('С приёмника'));
    await settleSave(tester);

    expect(find.textContaining('точность ±4 м'), findsOneWidget);
    final row = (await h.db.query('observation_points')).single;
    expect(row['lat'], 62.123456);
    expect(row['lon'], 148.654321);
    expect(row['coord_source'], 'gps');
    expect(row['gps_accuracy_m'], 4.0);

    // Поправил широту рукой — источник честно деградирует до manual.
    await tester.enterText(textFieldValued('62.123456'), '62.2');
    await settleSave(tester);
    final row2 = (await h.db.query('observation_points')).single;
    expect(row2['coord_source'], 'manual');
    expect(row2['gps_accuracy_m'], isNull);
  });

  testWidgets('GPS не дался (нет разрешения) — снек, координаты не тронуты',
      (tester) async {
    final h = await pumpPoint(tester,
        gps: () async => throw GpsException('Нет разрешения на геолокацию'));
    await tester.ensureVisible(find.text('С приёмника'));
    await tester.tap(find.text('С приёмника'));
    await settleSave(tester);
    expect(find.textContaining('Нет разрешения'), findsOneWidget);
    final row = (await h.db.query('observation_points')).single;
    expect(row['lat'], isNull);
  });

  testWidgets('«+ Фото»: снимок копируется, строка и мутация в базе',
      (tester) async {
    final src = File(p.join(
        Directory.systemTemp.createTempSync('geofield_pf').path, 'cam.jpg'))
      ..writeAsBytesSync([0xFF, 0xD8, 0xFF, 0xD9]); // минимальный jpeg-маркер
    final h = await pumpPoint(tester, picker: (_) async => src.path);

    await tester.ensureVisible(find.text('+ Фото'));
    await tester.tap(find.text('+ Фото'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Камера'));
    await settleSave(tester);
    await realIo(tester); // копия файла — настоящий I/O

    final rows = await h.db.query('photos');
    expect(rows, hasLength(1));
    expect(rows.single['parent_type'], 'point');
    expect(File(rows.single['file_path'] as String).existsSync(), isTrue);
    final log = await h.db
        .query('change_log', where: 'entity_table = ?', whereArgs: ['photos']);
    expect(log, hasLength(1));
  });
}
