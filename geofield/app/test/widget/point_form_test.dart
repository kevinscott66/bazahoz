import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geofield/data/demo_seed.dart';
import 'package:geofield/models/sample.dart';
import 'package:geofield/screens/point_form_screen.dart';
import 'package:geofield/screens/sample_capture_screen.dart';

import 'helpers.dart';

void main() {
  Future<TestHarness> pumpPoint(WidgetTester tester) async {
    final h = await TestHarness.create();
    addTearDown(h.close);
    await tester.pumpWidget(h.wrap(PointFormScreen(
      points: h.points,
      samples: h.samples,
      dictionaries: h.dicts,
      projectId: demoProjectId,
      routeId: demoRouteId,
      authorId: demoAuthorId,
      sampleNumbering: demoNumbering,
      initialNumber: 'Т-001',
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
    ]) {
      expect(find.text(section), findsOneWidget, reason: section);
    }
    expect(find.text('Готово'), findsOneWidget);
    expect(find.text('Удалить точку'), findsOneWidget);
  });

  testWidgets('координаты: половина пары и выход за диапазон — invalid, не пишутся',
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

    await tester.enterText(
        find.widgetWithText(TextField, 'Долгота'), '148.15');
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
    // Тип объекта из выпадающего списка.
    await tester.tap(find.text('Тип объекта'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Шурф').last);
    await tester.pumpAndSettle();
    // Порода — автоподсказка из справочника.
    await tester.enterText(
        find.widgetWithText(TextField,
            'Порода (справочник; новое — «на проверку»)'),
        'Гранит');
    // Координаты.
    await tester.enterText(find.widgetWithText(TextField, 'Широта'), '62.1');
    await tester.enterText(
        find.widgetWithText(TextField, 'Долгота'), '149.9');
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
        find.widgetWithText(TextField,
            'Порода (справочник; новое — «на проверку»)'),
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
    expect(row['minerals'],
        '[{"code":"native_gold"},{"code":"pyrite"}]');
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
    await tester.ensureVisible(find.text('＋ Замер'));
    await tester.tap(find.text('＋ Замер'));
    await tester.pumpAndSettle();
    // Тип по умолчанию «Слоистость» — меняем на «Жила».
    await tester.tap(find.text('Слоистость'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Жила').last);
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
    await tester.tap(find.text('＋ Замер'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Слоистость'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Жила').last);
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
    expect(find.textContaining('Жила: аз. пад. 120°'), findsOneWidget);
  });

  testWidgets('кнопки GPS и датчика честно сообщают о недоступности',
      (tester) async {
    await pumpPoint(tester);
    await tester.ensureVisible(find.text('С приёмника'));
    await tester.tap(find.text('С приёмника'));
    await tester.pumpAndSettle();
    expect(find.textContaining('GPS-приёмник не подключён'), findsOneWidget);

    await tester.ensureVisible(find.text('С датчика'));
    await tester.tap(find.text('С датчика'));
    await tester.pump(const Duration(seconds: 4)); // прежний снек уходит
    await tester.pumpAndSettle();
    expect(find.textContaining('Датчики не подключены'), findsOneWidget);
  });

  testWidgets('«＋ Проба» открывает экран пробы с привязкой и автономером',
      (tester) async {
    await pumpPoint(tester);
    await tester.ensureVisible(find.text('＋ Проба'));
    await tester.tap(find.text('＋ Проба'));
    await tester.pumpAndSettle();
    expect(find.byType(SampleCaptureScreen), findsOneWidget);
    expect(find.text('Привязано к: Точка № Т-001'), findsOneWidget);
    expect(find.text('SUZ-00001'), findsOneWidget);
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
}
