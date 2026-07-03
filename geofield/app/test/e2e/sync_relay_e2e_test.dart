@Timeout(Duration(minutes: 5))
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:geofield/data/database.dart';
import 'package:geofield/data/sample_repository.dart';
import 'package:geofield/models/sample.dart';
import 'package:geofield/sync/hlc.dart';
import 'package:geofield/sync/relay_client.dart';
import 'package:geofield/sync/sync_engine.dart';

/// Живой e2e: два «устройства» (две реальные SQLite-базы) синхронизируются
/// через настоящий relay (Go-бинарь из geofield/relay). Требует `go` в PATH;
/// без него тест честно пропускается (на CI без Go не красный, а skipped).
void main() {
  test('A → relay → B, правка на B → A (LWW, история, подтверждения)',
      () async {
    // --- сборка и запуск relay -------------------------------------------------
    final goCheck = await Process.run('go', ['version'])
        .then<ProcessResult?>((r) => r)
        .catchError((_) => null);
    if (goCheck == null || goCheck.exitCode != 0) {
      markTestSkipped('go не найден — e2e с relay пропущен');
      return;
    }
    final tmp = await Directory.systemTemp.createTemp('geofield_e2e');
    addTearDown(() => tmp.delete(recursive: true));

    final relayDir = Directory('../relay').absolute.path;
    final relayBin = '${tmp.path}/relay';
    final build = await Process.run('go', ['build', '-o', relayBin, '.'],
        workingDirectory: relayDir);
    expect(build.exitCode, 0, reason: 'go build: ${build.stderr}');

    const port = 18734;
    const token = 'e2e-token';
    final relay = await Process.start(
      relayBin,
      ['-addr', '127.0.0.1:$port', '-data', '${tmp.path}/journal.jsonl'],
      environment: {'RELAY_TOKEN': token},
    );
    addTearDown(relay.kill);

    // Дождаться готовности healthz.
    final probe = HttpClient();
    var up = false;
    for (var i = 0; i < 50 && !up; i++) {
      try {
        final req =
            await probe.getUrl(Uri.parse('http://127.0.0.1:$port/healthz'));
        final resp = await req.close();
        up = resp.statusCode == 200;
        await resp.drain<void>();
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    probe.close(force: true);
    expect(up, isTrue, reason: 'relay не поднялся');

    // --- два устройства ---------------------------------------------------------
    Future<
        ({
          AppDatabase db,
          SampleRepository repo,
          SyncEngine engine,
          RelayClient client,
        })> device(String deviceId, String author) async {
      final db = await AppDatabase.open(path: '${tmp.path}/$deviceId.db');
      // Бутстрап проекта (FK для samples) — как сид, вне change_log.
      await db.db.insert('projects', {
        'id': 'p1',
        'name': 'e2e',
        'created_at': 't',
        'modified_at': 't',
        'sync_status': 'confirmed',
      });
      final clock = await HlcClock.load(db.db, deviceId);
      final repo = SampleRepository(db.db,
          deviceId: deviceId, authorId: author, clock: clock);
      final client =
          RelayClient(baseUrl: 'http://127.0.0.1:$port', token: token);
      final engine =
          SyncEngine(db.db, client, deviceId: deviceId, clock: clock);
      return (db: db, repo: repo, engine: engine, client: client);
    }

    final a = await device('dev-a', 'geoA');
    final b = await device('dev-b', 'geoB');
    addTearDown(() {
      a.client.close();
      b.client.close();
    });

    // --- A создаёт пробу и отправляет -------------------------------------------
    final now = DateTime.now().toUtc().toIso8601String();
    final s1 = Sample(
      id: 'sample-1',
      projectId: 'p1',
      sampleNumber: 'SUZ-00001',
      sampleType: 'core',
      barcode: 'SUZ-00001',
      note: 'первичное описание',
      authorId: 'geoA',
      createdAt: now,
      modifiedAt: now,
    );
    await a.repo.save(s1, isNew: true);

    final resA1 = await a.engine.run();
    expect(resA1.completed, isTrue, reason: 'сеанс A: ${resA1.error}');
    expect(resA1.pushedChanges, 1);

    // Подтверждения на A: change_log помечен, сущность confirmed.
    final logA = await a.db.db
        .query('change_log', where: 'synced = 0');
    expect(logA, isEmpty, reason: 'на A остались неотправленные мутации');
    final rowA = (await a.db.db
            .query('samples', where: "id = 'sample-1'"))
        .single;
    expect(rowA['sync_status'], 'confirmed');

    // --- B принимает -------------------------------------------------------------
    final resB1 = await b.engine.run();
    expect(resB1.completed, isTrue, reason: 'сеанс B: ${resB1.error}');
    expect(resB1.pulledApplied, 1);
    expect(resB1.conflicts, 0);

    final rowB = (await b.db.db
            .query('samples', where: "id = 'sample-1'"))
        .single;
    expect(rowB['note'], 'первичное описание');
    expect(rowB['sync_status'], 'confirmed',
        reason: 'принятая с relay запись не «своя неотправленная»');
    final clockB = (await b.db.db.query('row_clocks',
            where: "entity_table = 'samples' AND entity_id = 'sample-1'"))
        .single;
    expect(Hlc.tryParse(clockB['hlc_ts'] as String), isNotNull);

    // --- B правит, A получает (LWW + история) ------------------------------------
    final s1onB = Sample.fromMap(rowB);
    await b.repo.save(
        s1onB.copyWith(
            note: 'уточнено на B',
            modifiedAt: DateTime.now().toUtc().toIso8601String(),
            version: s1onB.version + 1),
        isNew: false);
    final resB2 = await b.engine.run();
    expect(resB2.completed, isTrue, reason: 'сеанс B2: ${resB2.error}');
    expect(resB2.pushedChanges, 1);

    final resA2 = await a.engine.run();
    expect(resA2.completed, isTrue, reason: 'сеанс A2: ${resA2.error}');
    expect(resA2.pulledApplied, 1);
    expect(resA2.conflicts, 0, reason: 'на A не было pending-правок — LWW без конфликта');

    final rowA2 = (await a.db.db
            .query('samples', where: "id = 'sample-1'"))
        .single;
    expect(rowA2['note'], 'уточнено на B',
        reason: 'правка B не доехала до A');
    // Старая версия A — в истории, не стёрта (§5.3).
    final histA = await a.db.db.query('record_history',
        where: "entity_table = 'samples' AND entity_id = 'sample-1'");
    expect(histA, isNotEmpty, reason: 'проигравшая версия не заархивирована');

    // --- идемпотентность: повторный сеанс ничего не меняет ------------------------
    final resA3 = await a.engine.run();
    expect(resA3.completed, isTrue);
    expect(resA3.pushedChanges, 0);
    expect(resA3.pulledApplied, 0);
  });
}
