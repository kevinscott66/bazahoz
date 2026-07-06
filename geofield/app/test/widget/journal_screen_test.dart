import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geofield/screens/point_form_screen.dart';
import 'package:geofield/screens/sync_screen.dart';
import 'package:geofield/theme/tokens.dart';

import 'helpers.dart';

void main() {
  testWidgets('пустой журнал: сводка нулевая, подсказка, FAB на месте',
      (tester) async {
    tallPhone(tester);
    final h = await TestHarness.create();
    addTearDown(h.close);
    await tester.pumpWidget(h.journal());
    await tester.pumpAndSettle();

    expect(find.text('Пока пусто — начните с «+ Точка»'), findsOneWidget);
    expect(find.textContaining('0 точек · 0 проб'), findsOneWidget);
    expect(find.text('+ Точка'), findsOneWidget);
    expect(find.text('Все'), findsOneWidget);
    expect(find.text('Черновики'), findsOneWidget);
    expect(find.text('Не отправлено'), findsOneWidget);
  });

  testWidgets(
      'FAB открывает форму точки с автономером; возврат обновляет журнал',
      (tester) async {
    tallPhone(tester);
    final h = await TestHarness.create();
    addTearDown(h.close);
    await tester.pumpWidget(h.journal());
    await tester.pumpAndSettle();

    await tester.tap(find.text('+ Точка'));
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
    expect(
        find.textContaining('1 точка · 0 проб · 1 черновик'), findsOneWidget);
    expect(find.text('Точка Т-001'), findsOneWidget);
  });

  testWidgets('фильтры отбирают черновики и неотправленное', (tester) async {
    final h = await TestHarness.create();
    addTearDown(h.close);
    // Черновик руками в базе + подтверждённая точка.
    await tester.pumpWidget(h.journal());
    await tester.pumpAndSettle();
    await tester.tap(find.text('+ Точка'));
    await tester.pumpAndSettle();
    await settleSave(tester);
    await tester.tap(find.text('Готово'));
    await tester.pumpAndSettle();
    // Пометить как подтверждённую (как после успешного синка).
    await h.db.update('observation_points', {'sync_status': 'confirmed'});

    await tester.tap(find.text('+ Точка'));
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

  testWidgets('размер шрифта: выбор сохраняется и применяется', (tester) async {
    tallPhone(tester);
    final h = await TestHarness.create();
    addTearDown(h.close);
    await tester.pumpWidget(h.journal());
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Размер шрифта'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Крупный'));
    await tester.pumpAndSettle();

    expect(h.display.textScale, 1.15, reason: 'настройка применена');
    final row =
        await h.db.query('sync_state', where: "key = 'text_scale'", limit: 1);
    expect(row.single['value'], '1.15', reason: 'сохранено в sync_state');
  });

  testWidgets('«день на снегу»: выбор темы применяется и перекрашивает экран',
      (tester) async {
    addTearDown(() => GfColors.use(GfPalette.dark)); // не течь в соседние тесты
    tallPhone(tester);
    final h = await TestHarness.create();
    addTearDown(h.close);
    await tester.pumpWidget(h.journal());
    await tester.pumpAndSettle();
    expect(GfColors.active.brightness, Brightness.dark);

    await tester.tap(find.byTooltip('Размер шрифта'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('День на снегу'));
    await tester.pumpAndSettle();

    expect(h.display.daylight, isTrue, reason: 'настройка применена');
    expect(GfColors.active.brightness, Brightness.light,
        reason: 'активная палитра переключилась на светлую');
    final row = await h.db
        .query('sync_state', where: "key = 'daylight_theme'", limit: 1);
    expect(row.single['value'], '1', reason: 'сохранено в sync_state');

    // Экран действительно перекрашен: AppBar взял светлый фон из палитры.
    final appBar = tester.widget<AppBar>(find.byType(AppBar));
    expect(appBar.backgroundColor, GfPalette.daylight.bg);
  });

  testWidgets('шторка настроек перекрашивается при смене темы прямо в ней',
      (tester) async {
    addTearDown(() => GfColors.use(GfPalette.dark));
    tallPhone(tester);
    final h = await TestHarness.create();
    addTearDown(h.close);
    await tester.pumpWidget(h.journal());
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Размер шрифта'));
    await tester.pumpAndSettle();
    // Переключаем на светлую тему НЕ закрывая шторку.
    await tester.tap(find.text('День на снегу'));
    await tester.pumpAndSettle();

    // Панель самой шторки (не только её контент) взяла светлую палитру —
    // иначе был бы тёмный текст на тёмном фоне ровно в компоненте читаемости.
    final repainted = tester.widgetList<Container>(find.byType(Container)).where(
        (c) =>
            c.decoration is BoxDecoration &&
            (c.decoration as BoxDecoration).color ==
                GfPalette.daylight.surfaceHi);
    expect(repainted, isNotEmpty, reason: 'фон шторки перекрасился в светлый');
  });

  testWidgets('поиск по номеру отбирает точки и пробы', (tester) async {
    tallPhone(tester);
    final h = await TestHarness.create();
    addTearDown(h.close);
    await tester.pumpWidget(h.journal());
    await tester.pumpAndSettle();
    // Две точки с автономерами Т-001 и Т-002.
    for (var i = 0; i < 2; i++) {
      await tester.tap(find.text('+ Точка'));
      await tester.pumpAndSettle();
      await settleSave(tester);
      await tester.tap(find.text('Готово'));
      await tester.pumpAndSettle();
    }
    expect(find.textContaining('Точка Т-'), findsNWidgets(2));

    // Поиск «002» оставляет только Т-002.
    await tester.enterText(
        find.widgetWithText(TextField, 'Поиск по номеру (точка или проба)'),
        '002');
    await tester.pumpAndSettle();
    expect(find.text('Точка Т-002'), findsOneWidget);
    expect(find.text('Точка Т-001'), findsNothing);

    // Несуществующий номер — «Ничего не найдено».
    await tester.enterText(
        find.widgetWithText(TextField, 'Поиск по номеру (точка или проба)'),
        'Т-999');
    await tester.pumpAndSettle();
    expect(find.text('Ничего не найдено'), findsOneWidget);
  });

  testWidgets('тап по карточке точки открывает редактирование с её данными',
      (tester) async {
    tallPhone(tester);
    final h = await TestHarness.create();
    addTearDown(h.close);
    await tester.pumpWidget(h.journal());
    await tester.pumpAndSettle();
    await tester.tap(find.text('+ Точка'));
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
    // Файловому I/O нужно реальное время; ждём появления снека итерациями.
    var found = false;
    for (var i = 0; i < 10 && !found; i++) {
      await realIo(tester, const Duration(milliseconds: 300));
      await tester.pump();
      found = tester.any(find.byType(SnackBar));
    }
    await tester.pumpAndSettle();
    expect(find.textContaining('Выгружено 3 файла'), findsOneWidget);
  });
}
