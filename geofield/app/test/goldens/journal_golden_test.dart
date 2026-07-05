import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geofield/data/demo_seed.dart';
import 'package:geofield/models/observation_point.dart';
import 'package:geofield/models/sample.dart';

import '../widget/helpers.dart';

/// Скрин-рендер главного экрана (журнал) в PNG — headless, без устройства.
/// Запуск: GOLDEN=1 flutter test test/goldens --update-goldens
/// В CI пропускается: рендер шрифтов чуть плавает между версиями SDK.
void main() {
  final enabled = Platform.environment.containsKey('GOLDEN');

  /// Реальные шрифты вместо тестовых квадратов Ahem.
  Future<void> loadFonts() async {
    final sdkFonts = () {
      final flutterBin = Platform.environment['PATH']!
          .split(':')
          .firstWhere((p) => p.contains('flutter/bin'));
      return '$flutterBin/cache/artifacts/material_fonts';
    }();
    Future<ByteData> read(String file) async {
      final bytes = await File('$sdkFonts/$file').readAsBytes();
      return ByteData.view(bytes.buffer);
    }

    // Дефолтная гарнитура текста.
    final roboto = FontLoader('Roboto')
      ..addFont(read('Roboto-Regular.ttf'))
      ..addFont(read('Roboto-Medium.ttf'))
      ..addFont(read('Roboto-Bold.ttf'));
    await roboto.load();
    // Числовые поля просят 'monospace' — подставляем Roboto, чтобы не квадраты.
    final mono = FontLoader('monospace')..addFont(read('Roboto-Regular.ttf'));
    await mono.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(read('MaterialIcons-Regular.otf'));
    await icons.load();
  }

  testWidgets('журнал: наполненный экран → PNG', (tester) async {
    await loadFonts();
    // Телефонный вьюпорт (логика ~390x844 @3x).
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final h = await TestHarness.create();
    addTearDown(h.close);

    // Демо-наполнение: точки (одна черновик, одна подтверждена) и пробы
    // разных типов — видна цветовая семантика и статусы синхронизации.
    final now = DateTime.now().toUtc().toIso8601String();
    Future<void> point(String id, String n,
        {bool draft = false, String sync = 'pending'}) async {
      await h.points.save(
          ObservationPoint(
            id: id,
            routeId: demoRouteId,
            number: n,
            lat: 62.78341,
            lon: 148.15702,
            objectType: 'outcrop',
            rockCode: 'granite',
            isDraft: draft,
            authorId: demoAuthorId,
            createdAt: now,
            modifiedAt: now,
          ),
          isNew: true);
      if (sync != 'pending') {
        await h.db.update('observation_points', {'sync_status': sync},
            where: 'id = ?', whereArgs: [id]);
      }
    }

    Future<void> sample(String id, String n, String type,
        {String parent = 'p1', String sync = 'pending'}) async {
      await h.samples.save(
          Sample(
            id: id,
            projectId: demoProjectId,
            parentType: 'point',
            parentId: parent,
            sampleNumber: n,
            sampleType: type,
            barcode: n,
            authorId: demoAuthorId,
            createdAt: now,
            modifiedAt: now,
          ),
          isNew: true);
      if (sync != 'pending') {
        await h.db.update('samples', {'sync_status': sync},
            where: 'id = ?', whereArgs: [id]);
      }
    }

    await point('p1', 'Т-001', sync: 'confirmed');
    await point('p2', 'Т-002');
    await point('p3', 'Т-003', draft: true);
    await sample('s1', 'SUZ-00001', 'core', sync: 'confirmed');
    await sample('s2', 'SUZ-00002', 'schlich', parent: 'p2');
    await sample('s3', 'SUZ-00003', 'channel', parent: 'p2');
    await sample('s4', 'SUZ-00004', 'bulk', parent: 'p2');

    await tester.pumpWidget(h.journal());
    await tester.pumpAndSettle();

    await expectLater(
        find.byType(MaterialApp), matchesGoldenFile('journal_main.png'));
  }, skip: !enabled);
}
