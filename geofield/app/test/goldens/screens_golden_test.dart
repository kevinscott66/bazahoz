import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geofield/data/demo_seed.dart';
import 'package:geofield/models/observation_point.dart';
import 'package:geofield/models/sample.dart';
import 'package:geofield/screens/lab_screen.dart';
import 'package:geofield/screens/point_form_screen.dart';
import 'package:geofield/screens/sample_capture_screen.dart';
import 'package:geofield/screens/sync_screen.dart';
import 'package:sqflite/sqflite.dart';

import '../widget/helpers.dart';

/// Скрин-рендеры остальных экранов (см. journal_golden_test.dart).
/// Запуск: GOLDEN=1 flutter test test/goldens --update-goldens
void main() {
  final enabled = Platform.environment.containsKey('GOLDEN');

  setUpAll(() async {
    if (!enabled) return;
    final flutterBin = Platform.environment['PATH']!
        .split(':')
        .firstWhere((p) => p.contains('flutter/bin'));
    final sdkFonts = '$flutterBin/cache/artifacts/material_fonts';
    Future<ByteData> read(String file) {
      final bytes = File('$sdkFonts/$file').readAsBytesSync();
      return Future.value(ByteData.view(bytes.buffer));
    }

    final roboto = FontLoader('Roboto')
      ..addFont(read('Roboto-Regular.ttf'))
      ..addFont(read('Roboto-Medium.ttf'))
      ..addFont(read('Roboto-Bold.ttf'));
    await roboto.load();
    final mono = FontLoader('monospace')..addFont(read('Roboto-Regular.ttf'));
    await mono.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(read('MaterialIcons-Regular.otf'));
    await icons.load();
  });

  void phone(WidgetTester tester, {double height = 844}) {
    tester.view.physicalSize = Size(1170, height * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
  }

  final now = DateTime.now().toUtc().toIso8601String();

  testWidgets('форма точки: заполненная, с замером и пробой', (tester) async {
    phone(tester, height: 1560); // длинный кадр — вся форма целиком
    final h = await TestHarness.create();
    addTearDown(h.close);

    final pt = ObservationPoint(
      id: 'p1',
      routeId: demoRouteId,
      number: 'Т-012',
      lat: 62.78341,
      lon: 148.15702,
      elevation: 812,
      objectType: 'trench',
      rockCode: 'vein_quartz',
      alterationCode: 'silicification',
      minerals: '[{"code":"pyrite"},{"code":"native_gold"}]',
      colorCode: 'светло-серый',
      grain: 'мелкозернистая',
      note: 'Кварцевая жила в зоне дробления, мощность 0.4 м',
      isDraft: false,
      authorId: demoAuthorId,
      createdAt: now,
      modifiedAt: now,
    );
    await h.points.save(pt, isNew: true);
    await h.points.addMeasurement(StructuralMeasurement(
      id: 'm1',
      parentType: 'point',
      parentId: 'p1',
      measureType: 'vein',
      dipAzimuth: 120,
      dipAngle: 45,
      source: 'manual',
      authorId: demoAuthorId,
      createdAt: now,
      modifiedAt: now,
    ));
    await h.samples.save(
        Sample(
          id: 's1',
          projectId: demoProjectId,
          parentType: 'point',
          parentId: 'p1',
          sampleNumber: 'SUZ-00034',
          sampleType: 'grab',
          barcode: 'SUZ-00034',
          authorId: demoAuthorId,
          createdAt: now,
          modifiedAt: now,
        ),
        isNew: true);

    await tester.pumpWidget(h.wrap(PointFormScreen(
      points: h.points,
      samples: h.samples,
      dictionaries: h.dicts,
      projectId: demoProjectId,
      routeId: demoRouteId,
      authorId: demoAuthorId,
      sampleNumbering: demoNumbering,
      existing: pt,
    )));
    await tester.pumpAndSettle();
    await expectLater(
        find.byType(MaterialApp), matchesGoldenFile('point_form.png'));
  }, skip: !enabled);

  testWidgets('проба: керн с интервалом', (tester) async {
    phone(tester, height: 1300);
    final h = await TestHarness.create();
    addTearDown(h.close);
    await tester.pumpWidget(h.wrap(SampleCaptureScreen(
      repository: h.samples,
      projectId: demoProjectId,
      authorId: demoAuthorId,
      initialNumber: 'SUZ-00034',
      binding: const ParentBinding(
        type: 'interval',
        id: 'i1',
        label: 'Скв. С-3, инт. 12.0–13.4',
        depthFrom: 12.0,
        depthTo: 13.4,
      ),
    )));
    await settleSave(tester);
    await tester.enterText(find.widgetWithText(TextField, 'Масса, кг'), '2,4');
    await settleSave(tester);
    await expectLater(
        find.byType(MaterialApp), matchesGoldenFile('sample_capture.png'));
  }, skip: !enabled);

  testWidgets('проба: шторка с QR-биркой', (tester) async {
    phone(tester);
    final h = await TestHarness.create();
    addTearDown(h.close);
    await tester.pumpWidget(h.wrap(SampleCaptureScreen(
      repository: h.samples,
      projectId: demoProjectId,
      authorId: demoAuthorId,
      initialNumber: 'SUZ-00034',
      binding:
          const ParentBinding(type: 'point', id: 'p1', label: 'Точка № Т-012'),
    )));
    await settleSave(tester);
    await tester.ensureVisible(find.text('Показать код'));
    await tester.tap(find.text('Показать код'));
    await tester.pumpAndSettle();
    await expectLater(
        find.byType(MaterialApp), matchesGoldenFile('sample_qr.png'));
  }, skip: !enabled);

  testWidgets('синхронизация: настроенный relay, очередь и лог сеанса',
      (tester) async {
    phone(tester);
    final h = await TestHarness.create();
    addTearDown(h.close);
    // Очередь: пара мутаций; настройки и лог прошлого сеанса.
    await h.samples.save(
        Sample(
          id: 's1',
          projectId: demoProjectId,
          sampleNumber: 'SUZ-00035',
          sampleType: 'core',
          barcode: 'SUZ-00035',
          authorId: demoAuthorId,
          createdAt: now,
          modifiedAt: now,
        ),
        isNew: true);
    Future<void> kv(String k, String v) =>
        h.db.insert('sync_state', {'key': k, 'value': v},
            conflictAlgorithm: ConflictAlgorithm.replace);
    await kv('relay_url', 'https://relay.susuman.example');
    await kv('relay_token', 'secret');
    await kv(
        'last_session',
        jsonEncode({
          'at': '2026-07-04T18:32:11Z',
          'pushed_changes': 46,
          'pushed_packets': 2,
          'bytes_sent': 187 * 1024,
          'pulled_applied': 12,
          'conflicts': 0,
          'completed': true,
        }));
    await tester.pumpWidget(
        h.wrap(SyncScreen(db: h.db, deviceId: demoDeviceId, clock: h.clock)));
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('sync.png'));
  }, skip: !enabled);

  testWidgets('лаборатория: три статуса жизненного цикла', (tester) async {
    phone(tester);
    final h = await TestHarness.create();
    addTearDown(h.close);
    Future<void> mk(String id, String n, String type, SampleStatus st) =>
        h.samples.save(
            Sample(
              id: id,
              projectId: demoProjectId,
              sampleNumber: n,
              sampleType: type,
              barcode: n,
              status: st,
              authorId: demoAuthorId,
              createdAt: now,
              modifiedAt: now,
            ),
            isNew: true);
    await mk('s1', 'SUZ-00031', 'core', SampleStatus.collected);
    await mk('s2', 'SUZ-00032', 'channel', SampleStatus.packed);
    await mk('s3', 'SUZ-00033', 'schlich', SampleStatus.sent);
    await mk('s4', 'SUZ-00030', 'core', SampleStatus.resultReceived);
    await tester.pumpWidget(h.wrap(LabScreen(
      samples: h.samples,
      dictionaries: h.dicts,
      lab: h.lab,
      projectId: demoProjectId,
    )));
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('lab.png'));
  }, skip: !enabled);
}
