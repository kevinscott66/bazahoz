import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geofield/data/demo_seed.dart';
import 'package:geofield/models/sample.dart';
import 'package:geofield/screens/sync_screen.dart';

import 'helpers.dart';

void main() {
  Future<TestHarness> pumpSync(WidgetTester tester) async {
    final h = await TestHarness.create();
    addTearDown(h.close);
    await tester.pumpWidget(h.wrap(SyncScreen(
      db: h.db,
      deviceId: demoDeviceId,
      clock: h.clock,
    )));
    await tester.pumpAndSettle();
    return h;
  }

  testWidgets('без настроек relay кнопка честно неактивна', (tester) async {
    await pumpSync(tester);
    expect(find.text('Relay не настроен'), findsOneWidget);
    final btn = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(btn.onPressed, isNull);
    expect(find.text('Всё отправлено'), findsOneWidget);
  });

  testWidgets('после ввода URL и токена кнопка активируется', (tester) async {
    await pumpSync(tester);
    await tester.enterText(
        find.widgetWithText(TextField, 'https://relay.example.com'),
        'http://127.0.0.1:1');
    await tester.enterText(find.widgetWithText(TextField, 'Токен'), 'tt');
    await tester.pumpAndSettle();
    expect(find.text('Синхронизировать'), findsOneWidget);
    final btn = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(btn.onPressed, isNotNull);
  });

  testWidgets('неотправленное показывается в записях и КБ wire-метрикой',
      (tester) async {
    final h = await pumpSync(tester);
    final now = DateTime.now().toUtc().toIso8601String();
    await h.samples.save(
        Sample(
          id: 's-p',
          projectId: demoProjectId,
          sampleNumber: 'SUZ-00001',
          sampleType: 'core',
          note: 'кириллица в примечании для веса',
          authorId: demoAuthorId,
          createdAt: now,
          modifiedAt: now,
        ),
        isNew: true);
    // Повторный pump того же типа без ключа не пересоздаёт State —
    // новый key заставляет initState (и _refreshPending) выполниться заново.
    await tester.pumpWidget(h.wrap(SyncScreen(
        key: UniqueKey(), db: h.db, deviceId: demoDeviceId, clock: h.clock)));
    await tester.pumpAndSettle();
    expect(find.textContaining('Уйдёт: 1 запись'), findsOneWidget);
    expect(find.textContaining('КБ (до сжатия)'), findsOneWidget);
  });

  testWidgets('обрыв (недоступный relay) деградирует в понятный лог сеанса',
      (tester) async {
    final h = await pumpSync(tester);
    await tester.enterText(
        find.widgetWithText(TextField, 'https://relay.example.com'),
        'http://127.0.0.1:9'); // порт закрыт — соединение упадёт
    await tester.enterText(find.widgetWithText(TextField, 'Токен'), 'tt');
    await tester.pumpAndSettle();
    // Есть что отправлять — иначе PUSH нечего ронять.
    final now = DateTime.now().toUtc().toIso8601String();
    await h.samples.save(
        Sample(
          id: 's-x',
          projectId: demoProjectId,
          sampleNumber: 'SUZ-00002',
          sampleType: 'core',
          authorId: demoAuthorId,
          createdAt: now,
          modifiedAt: now,
        ),
        isNew: true);
    await tester.tap(find.text('Синхронизировать'));
    // Реальному сокету (connection refused) нужно настоящее время,
    // не фейковое: даём событию дойти внутри runAsync.
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 800)));
    await tester.pumpAndSettle(const Duration(seconds: 2));
    // Сеанс завершился неуспехом, но управляемо: карточка сеанса с «обрыв».
    expect(find.textContaining('ПОСЛЕДНИЙ СЕАНС'), findsOneWidget);
    expect(find.textContaining('обрыв'), findsWidgets);
    // Мутация не потеряна и не помечена отправленной.
    final log =
        (await h.db.query('change_log', where: "entity_id = 's-x'")).single;
    expect(log['synced'], 0);
  });
}
