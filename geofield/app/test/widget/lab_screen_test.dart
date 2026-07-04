import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geofield/data/demo_seed.dart';
import 'package:geofield/models/sample.dart';
import 'package:geofield/screens/lab_screen.dart';

import 'helpers.dart';

void main() {
  Future<TestHarness> pumpLab(WidgetTester tester,
      {List<Sample> seed = const []}) async {
    tallPhone(tester);
    final h = await TestHarness.create();
    addTearDown(h.close);
    for (final s in seed) {
      await h.samples.save(s, isNew: true);
    }
    await tester.pumpWidget(h.wrap(LabScreen(
      samples: h.samples,
      dictionaries: h.dicts,
      lab: h.lab,
      projectId: demoProjectId,
    )));
    await tester.pumpAndSettle();
    return h;
  }

  Sample mk(String id, String number,
      {SampleStatus status = SampleStatus.collected}) {
    final now = DateTime.now().toUtc().toIso8601String();
    return Sample(
      id: id,
      projectId: demoProjectId,
      sampleNumber: number,
      sampleType: 'core',
      barcode: number,
      status: status,
      authorId: demoAuthorId,
      createdAt: now,
      modifiedAt: now,
    );
  }

  testWidgets('пустой экран: секции на месте, ведомость неактивна',
      (tester) async {
    await pumpLab(tester);
    expect(find.text('К ОТПРАВКЕ (0)'), findsOneWidget);
    expect(find.text('ОТПРАВЛЕНЫ (0)'), findsOneWidget);
    expect(find.text('РЕЗУЛЬТАТ ПОЛУЧЕН (0)'), findsOneWidget);
    expect(find.text('Нечего отправлять'), findsOneWidget);
    final btn = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(btn.onPressed, isNull);
  });

  testWidgets('ведомость: подтверждение, CSV-файл, статусы в «отправлена»',
      (tester) async {
    final h = await pumpLab(tester, seed: [
      mk('s1', 'SUZ-00001'),
      mk('s2', 'SUZ-00002', status: SampleStatus.packed),
      mk('s3', 'SUZ-00003', status: SampleStatus.sent),
    ]);
    expect(find.text('К ОТПРАВКЕ (2)'), findsOneWidget);
    expect(find.text('ОТПРАВЛЕНЫ (1)'), findsOneWidget);

    await tester.tap(find.text('Ведомость (2)'));
    await tester.pumpAndSettle();
    expect(find.textContaining('2 проб будут помечены'), findsOneWidget);
    await tester.tap(find.text('Сформировать'));
    // Синхронная запись файла + перезагрузка списков.
    await realIo(tester);
    await tester.pumpAndSettle();

    expect(find.textContaining('отправлено проб: 2'), findsOneWidget);
    expect(find.text('К ОТПРАВКЕ (0)'), findsOneWidget);
    expect(find.text('ОТПРАВЛЕНЫ (3)'), findsOneWidget);
    final rows = await h.db.query('samples');
    expect(rows.map((r) => r['status']), everyElement('sent'));
  });

  testWidgets('повторная ведомость по отправленным: файл без переходов',
      (tester) async {
    final h = await pumpLab(tester, seed: [
      mk('s1', 'SUZ-00001', status: SampleStatus.sent),
    ]);
    // Очередь пуста, но кнопка предлагает повторную печать.
    expect(find.text('Ведомость повторно (1)'), findsOneWidget);
    await tester.tap(find.text('Ведомость повторно (1)'));
    await tester.pumpAndSettle();
    expect(find.textContaining('статусы не изменятся'), findsOneWidget);
    await tester.tap(find.text('Сформировать'));
    await realIo(tester);
    await tester.pumpAndSettle();
    expect(find.textContaining('отправлено проб: 0'), findsOneWidget);
    final row = (await h.db.query('samples')).single;
    expect(row['status'], 'sent', reason: 'повторная печать без переходов');
  });

  testWidgets('импорт: файл с результатами закрывает пробу', (tester) async {
    final h = await pumpLab(tester, seed: [
      mk('s1', 'SUZ-00001', status: SampleStatus.sent),
    ]);
    final f = File(
        '${Directory.systemTemp.path}/lab_results_${DateTime.now().microsecondsSinceEpoch}.csv')
      ..writeAsStringSync('Штрихкод;Элемент;Содержание\nSUZ-00001;Au;3,1\n');
    addTearDown(() => f.delete());

    await tester.tap(find.text('Импорт результатов'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Путь к CSV-файлу лаборатории'),
        f.path);
    await tester.tap(find.text('Импортировать'));
    await realIo(tester);
    await tester.pumpAndSettle();

    expect(find.textContaining('Принято результатов: 1'), findsOneWidget);
    expect(find.text('РЕЗУЛЬТАТ ПОЛУЧЕН (1)'), findsOneWidget);
    final results = await h.db.query('sample_results');
    expect(results.single['element'], 'Au');
    expect(results.single['value'], 3.1);
  });

  testWidgets('импорт несуществующего файла — понятная ошибка', (tester) async {
    await pumpLab(tester);
    await tester.tap(find.text('Импорт результатов'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Путь к CSV-файлу лаборатории'),
        '/нет/такого/файла.csv');
    await tester.tap(find.text('Импортировать'));
    await realIo(tester);
    await tester.pumpAndSettle();
    expect(find.textContaining('Файл не прочитан'), findsOneWidget);
  });
}
