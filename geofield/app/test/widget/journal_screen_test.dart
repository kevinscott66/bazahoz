import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geofield/screens/point_form_screen.dart';
import 'package:geofield/screens/sync_screen.dart';

import 'helpers.dart';

void main() {
  testWidgets('пустой журнал: сводка нулевая, подсказка, FAB на месте',
      (tester) async {
    tallPhone(tester);
    final h = await TestHarness.create();
    addTearDown(h.close);
    await tester.pumpWidget(h.journal());
    await tester.pumpAndSettle();

    expect(find.text('Пока пусто — начните с «＋ Точка»'), findsOneWidget);
    expect(find.textContaining('0 точек · 0 проб'), findsOneWidget);
    expect(find.text('＋ Точка'), findsOneWidget);
    expect(find.text('Все'), findsOneWidget);
    expect(find.text('Черновики'), findsOneWidget);
    expect(find.text('Не отправлено'), findsOneWidget);
  });

  testWidgets('FAB открывает форму точки с автономером; возврат обновляет журнал',
      (tester) async {
    tallPhone(tester);
    final h = await TestHarness.create();
    addTearDown(h.close);
    await tester.pumpWidget(h.journal());
    await tester.pumpAndSettle();

    await tester.tap(find.text('＋ Точка'));
    await tester.pumpAndSettle();
    expect(find.byType(PointFormScreen), findsOneWidget);
    expect(textFieldValued('Т-001'), findsOneWidget); // автономер
    expect(find.text('черновик'), findsOneWidget); // бейдж черновика

    // Немедленный черновик уже в базе (ТЗ §0 пр.2) — до любого ввода.
    await settleSave(tester);
    final rows = await h.db.query('observation_points');
    expect(rows, hasLength(1));
    expect(rows.single['is_draft'], 1);

    // Назад — журнал перезагрузился и показывает точку.
    await tester.tap(find.text('Готово'));
    await tester.pumpAndSettle();
    expect(find.textContaining('1 точек · 0 проб · 1 черновиков'),
        findsOneWidget);
    expect(find.text('Точка Т-001'), findsOneWidget);
  });

  testWidgets('фильтры отбирают черновики и неотправленное', (tester) async {
    final h = await TestHarness.create();
    addTearDown(h.close);
    // Черновик руками в базе + подтверждённая точка.
    await tester.pumpWidget(h.journal());
    await tester.pumpAndSettle();
    await tester.tap(find.text('＋ Точка'));
    await tester.pumpAndSettle();
    await settleSave(tester);
    await tester.tap(find.text('Готово'));
    await tester.pumpAndSettle();
    // Пометить как подтверждённую (как после успешного синка).
    await h.db.update('observation_points', {'sync_status': 'confirmed'});

    await tester.tap(find.text('＋ Точка'));
    await tester.pumpAndSettle();
    await settleSave(tester);
    await tester.tap(find.text('Готово'));
    await tester.pumpAndSettle();

    // «Все» — обе; «Не отправлено» — только вторая (pending).
    expect(find.textContaining('Точка Т-'), findsNWidgets(2));
    await tester.tap(find.text('Не отправлено'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Точка Т-'), findsNWidgets(1));
    // «Черновики» — обе (обязательные поля не заполнялись).
    await tester.tap(find.text('Черновики'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Точка Т-'), findsNWidgets(2));
  });

  testWidgets('тап по карточке точки открывает редактирование с её данными',
      (tester) async {
    tallPhone(tester);
    final h = await TestHarness.create();
    addTearDown(h.close);
    await tester.pumpWidget(h.journal());
    await tester.pumpAndSettle();
    await tester.tap(find.text('＋ Точка'));
    await tester.pumpAndSettle();
    await tester.enterText(textFieldValued('Т-001'), 'Т-777');
    await settleSave(tester);
    await tester.tap(find.text('Готово'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Точка Т-777'));
    await tester.pumpAndSettle();
    expect(find.byType(PointFormScreen), findsOneWidget);
    expect(textFieldValued('Т-777'), findsOneWidget);
    expect(find.text('сохранено · не отправлено'), findsOneWidget);
  });

  testWidgets('кнопка синхронизации открывает SyncScreen', (tester) async {
    tallPhone(tester);
    final h = await TestHarness.create();
    addTearDown(h.close);
    await tester.pumpWidget(h.journal());
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Синхронизация'));
    await tester.pumpAndSettle();
    expect(find.byType(SyncScreen), findsOneWidget);
  });

  testWidgets('выгрузка CSV пишет 3 файла и показывает снек', (tester) async {
    tallPhone(tester);
    final h = await TestHarness.create();
    addTearDown(h.close);
    await tester.pumpWidget(h.journal());
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Выгрузка CSV'));
    await realIo(tester, const Duration(milliseconds: 1500));
    await tester.pumpAndSettle();
    expect(find.textContaining('Выгружено 3 файла'), findsOneWidget);
  });
}
