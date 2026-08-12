import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geofield/data/demo_seed.dart';
import 'package:geofield/screens/sync_screen.dart';

import 'helpers.dart';

/// Настройка адреса тайл-сервера офлайн-карты (конфиг оператора, как relay_url):
/// валидация {z}/{x}/{y} + https, хранение в sync_state.
void main() {
  Future<TestHarness> pumpSync(WidgetTester tester) async {
    tallPhone(tester);
    final h = await TestHarness.create();
    addTearDown(h.close);
    await tester.pumpWidget(MaterialApp(
      theme: h.themeData,
      home: SyncScreen(
        db: h.db,
        deviceId: demoDeviceId,
        clock: h.clock,
      ),
    ));
    await tester.pumpAndSettle();
    return h;
  }

  Finder tileField() => find.widgetWithText(
      TextField, 'https://tiles.example/{z}/{x}/{y}.png');

  testWidgets('пусто — пояснение, без ошибки', (tester) async {
    await pumpSync(tester);
    expect(find.textContaining('Адрес тайл-сервера оператора'), findsOneWidget);
  });

  testWidgets('невалидный адрес — ошибка, валидный — принят и сохранён',
      (tester) async {
    final h = await pumpSync(tester);

    // http (не localhost) — запрещён.
    await tester.enterText(tileField(), 'http://ts.example/{z}/{x}/{y}.png');
    await tester.pumpAndSettle();
    expect(find.textContaining('https'), findsWidgets);

    // Нет плейсхолдера {y}.
    await tester.enterText(tileField(), 'https://ts.example/{z}/{x}.png');
    await tester.pumpAndSettle();
    expect(find.textContaining('нет {y}'), findsOneWidget);

    // Валидный — принят и записан в sync_state.
    await tester.enterText(
        tileField(), 'https://ts.example/{z}/{x}/{y}.png');
    await tester.pumpAndSettle();
    expect(find.textContaining('адрес принят'), findsOneWidget);
    final row = await h.db.query('sync_state',
        where: "key = 'tile_server_url'", limit: 1);
    expect(row.single['value'], 'https://ts.example/{z}/{x}/{y}.png');
  });
}
