import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geofield/data/demo_seed.dart';
import 'package:geofield/models/sample.dart';
import 'package:geofield/screens/sample_capture_screen.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'helpers.dart';

void main() {
  Future<TestHarness> pumpSample(WidgetTester tester,
      {Sample? existing}) async {
    tallPhone(tester);
    final h = await TestHarness.create();
    addTearDown(h.close);
    await tester.pumpWidget(h.wrap(SampleCaptureScreen(
      repository: h.samples,
      photos: h.photos,
      projectId: demoProjectId,
      authorId: demoAuthorId,
      initialNumber: existing?.sampleNumber ?? 'SUZ-00001',
      existing: existing,
      binding:
          const ParentBinding(type: 'point', id: 'pt-1', label: 'Точка № 1'),
    )));
    await settleSave(tester);
    return h;
  }

  testWidgets('автосохранение при открытии: проба уже в базе с привязкой',
      (tester) async {
    final h = await pumpSample(tester);
    final rows = await h.db.query('samples');
    expect(rows, hasLength(1));
    expect(rows.single['sample_number'], 'SUZ-00001');
    expect(rows.single['parent_id'], 'pt-1');
    expect(rows.single['status'], 'collected');
    // Мутация в журнале изменений с HLC-меткой.
    final log = await h.db.query('change_log');
    expect(log, hasLength(1));
    expect(log.single['op'], 'insert');
    expect(find.text('сохранено · не отправлено'), findsOneWidget);
    expect(find.text('Привязано к: Точка № 1'), findsOneWidget);
  });

  testWidgets(
      'поля зависят от типа: керн — От/До, борозда — длина, штуф — ничего',
      (tester) async {
    final h = await pumpSample(tester);
    // Керн (по умолчанию): интервал видим.
    expect(find.text('ИНТЕРВАЛ ОТБОРА (м)'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Длина, м'), findsNothing);

    await tester.tap(find.text('Борозда'));
    await settleSave(tester);
    expect(find.text('ИНТЕРВАЛ ОТБОРА (м)'), findsNothing);
    expect(find.widgetWithText(TextField, 'Длина, м'), findsOneWidget);

    await tester.ensureVisible(find.text('Штуф'));
    await tester.tap(find.text('Штуф'));
    await settleSave(tester);
    expect(find.text('ИНТЕРВАЛ ОТБОРА (м)'), findsNothing);
    expect(find.widgetWithText(TextField, 'Длина, м'), findsNothing);
    final row = (await h.db.query('samples')).single;
    expect(row['sample_type'], 'grab');
  });

  testWidgets(
      '«До < От» блокирует, исправление сохраняет; смена типа снимает блок',
      (tester) async {
    final h = await pumpSample(tester);
    await tester.enterText(find.widgetWithText(TextField, 'От'), '10');
    await tester.enterText(find.widgetWithText(TextField, 'До'), '5');
    await settleSave(tester);
    expect(find.text('«До» не может быть меньше «От»'), findsOneWidget);
    var row = (await h.db.query('samples')).single;
    expect(row['depth_from'], isNull, reason: 'противоречие не персистится');

    // «Готово» не закрывает при невалидном.
    await tester.tap(find.text('Готово'));
    await tester.pumpAndSettle();
    expect(find.byType(SampleCaptureScreen), findsOneWidget);

    // Смена типа на штуф прячет поля — блок снят, сохранение проходит.
    await tester.tap(find.text('Штуф'));
    await settleSave(tester);
    expect(find.text('сохранено · не отправлено'), findsOneWidget);

    // Обратно керн, валидный интервал — персистится.
    await tester.tap(find.text('Керн'));
    await settleSave(tester);
    await tester.enterText(find.widgetWithText(TextField, 'До'), '12');
    await settleSave(tester);
    row = (await h.db.query('samples')).single;
    expect(row['depth_from'], 10.0);
    expect(row['depth_to'], 12.0);
  });

  testWidgets('пустой номер: ошибка, «Готово» не закрывает', (tester) async {
    await pumpSample(tester);
    await tester.enterText(find.widgetWithText(TextField, 'SUZ-00001'), '');
    await settleSave(tester);
    expect(find.text('Номер пробы обязателен'), findsOneWidget);
    await tester.tap(find.text('Готово'));
    await tester.pumpAndSettle();
    expect(find.byType(SampleCaptureScreen), findsOneWidget);
  });

  testWidgets('«Показать код» рисует QR с номером; «Печать» честно о принтере',
      (tester) async {
    await pumpSample(tester);
    await tester.ensureVisible(find.text('Показать код'));
    await tester.tap(find.text('Показать код'));
    await tester.pumpAndSettle();
    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.text('SUZ-00001'), findsWidgets);
    // Закрыть шторку.
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Печать бирки'));
    await tester.tap(find.text('Печать бирки'));
    await tester.pumpAndSettle();
    expect(
        find.textContaining('Принтер этикеток не подключён'), findsOneWidget);
  });

  testWidgets('удаление: подтверждение, deleted=1 и delete-мутация в логе',
      (tester) async {
    final h = await pumpSample(tester);
    await tester.ensureVisible(find.text('Удалить пробу'));
    await tester.tap(find.text('Удалить пробу'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Удалить')); // подтверждение в диалоге
    await tester.pumpAndSettle();
    final row = (await h.db.query('samples')).single;
    expect(row['deleted'], 1);
    final ops = (await h.db.query('change_log', columns: ['op']))
        .map((r) => r['op'])
        .toList();
    expect(ops, containsAll(['insert', 'delete']));
  });

  testWidgets('режим редактирования: статус и привязка не сбрасываются правкой',
      (tester) async {
    final now = DateTime.now().toUtc().toIso8601String();
    final existing = Sample(
      id: 's-ed',
      projectId: demoProjectId,
      parentType: null, // свободная проба
      parentId: null,
      sampleNumber: 'SUZ-00042',
      sampleType: 'schlich',
      status: SampleStatus.packed,
      authorId: demoAuthorId,
      createdAt: now,
      modifiedAt: now,
      version: 3,
    );
    final h = await pumpSample(tester, existing: existing);
    // Вставить строку как будто она была в базе (экран в режиме existing
    // не делает insert — записи нужна база).
    await h.samples.save(existing, isNew: true);

    await tester.enterText(find.widgetWithText(TextField, 'Масса, кг'), '2,5');
    await settleSave(tester);
    final row = (await h.db.query('samples', where: "id = 's-ed'")).single;
    expect(row['status'], 'packed',
        reason: 'правка не откатывает жизненный цикл');
    expect(row['parent_type'], isNull, reason: 'свободная не перепривязана');
    expect(row['mass'], 2.5, reason: 'запятая как десятичный разделитель');
    expect((row['version'] as int) > 3, isTrue);
  });
}
