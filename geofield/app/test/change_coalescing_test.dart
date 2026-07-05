import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:geofield/data/change_payload.dart';
import 'package:geofield/data/database.dart';
import 'package:geofield/data/sample_repository.dart';
import 'package:geofield/models/sample.dart';
import 'package:geofield/sync/hlc.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Склейка неотправленных мутаций (logChange): N автосейвов одной записи —
/// одна строка на провод; черновик, умерший до синхронизации, — ноль строк.
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Database db;
  late SampleRepository samples;

  Future<Sample> sample(String id, {int version = 1}) async {
    final now = DateTime.now().toUtc().toIso8601String();
    return Sample(
      id: id,
      projectId: 'p1',
      sampleNumber: 'SUZ-$id',
      sampleType: 'core',
      authorId: 'geo',
      createdAt: now,
      modifiedAt: now,
      version: version,
    );
  }

  setUp(() async {
    db = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 3,
        onCreate: (d, _) async {
          await AppDatabase.migrate001(d);
          await AppDatabase.migrate002(d);
        },
      ),
    );
    await db.insert('projects', {
      'id': 'p1',
      'name': 'Т',
      'created_at': 't',
      'modified_at': 't',
    });
    final clock = await HlcClock.load(db, 'dev-t');
    samples = SampleRepository(db,
        deviceId: 'dev-t', authorId: 'geo', clock: clock);
  });

  tearDown(() => db.close());

  test('insert + N автосейвов = одна insert-мутация с итоговым состоянием',
      () async {
    await samples.save(await sample('s1'), isNew: true);
    var s = Sample.fromMap((await db.query('samples')).single);
    for (var i = 2; i <= 4; i++) {
      s = (await sample('s1', version: i));
      await samples.save(s, isNew: false);
    }
    final log = await db.query('change_log');
    expect(log, hasLength(1));
    expect(log.single['op'], 'insert');
    final payload =
        (jsonDecode(log.single['payload'] as String) as Map);
    expect(payload['version'], 4, reason: 'итоговое состояние, не первое');
  });

  test('после подтверждения relay склейка прекращается: новая строка',
      () async {
    await samples.save(await sample('s1'), isNew: true);
    await db.update('change_log', {'synced': 1}); // как после сеанса
    await samples.save(await sample('s1', version: 2), isNew: false);
    final unsynced =
        await db.query('change_log', where: 'synced = 0');
    expect(unsynced, hasLength(1));
    expect(unsynced.single['op'], 'update',
        reason: 'подтверждённую мутацию трогать нельзя — дельта отдельно');
  });

  test('черновик умер до синхронизации — журнал пуст (без tombstone)',
      () async {
    await samples.save(await sample('s1'), isNew: true);
    await samples.save(await sample('s1', version: 2), isNew: false);
    await samples.softDelete(await sample('s1', version: 2));
    expect(await db.query('change_log'), isEmpty);
  });

  test('удаление УЖЕ известной миру записи оставляет tombstone', () async {
    await samples.save(await sample('s1'), isNew: true);
    await db.update('change_log', {'synced': 1});
    await samples.softDelete(await sample('s1'));
    final unsynced = await db.query('change_log', where: 'synced = 0');
    expect(unsynced, hasLength(1));
    expect(unsynced.single['op'], 'delete');
  });

  test('compactChangeLog сжимает бэклог, записанный до склейки (миграция v3)',
      () async {
    // Старый стиль: по строке на каждый автосейв, руками — мимо logChange.
    Future<void> raw(String id, String op, Map<String, Object?> payload,
        {int synced = 0}) {
      return db.insert('change_log', {
        'change_id': '$id-$op-${payload['version']}',
        'entity_table': 'samples',
        'entity_id': id,
        'op': op,
        'payload': jsonEncode(payload),
        'logical_ts': 't${payload['version']}',
        'synced': synced,
      });
    }

    // s1: жив, 1 insert + 3 дельты → должна остаться 1 insert-строка.
    await raw('s1', 'insert', {'id': 's1', 'note': 'а', 'version': 1});
    await raw('s1', 'update', {'note': 'аб', 'version': 2});
    await raw('s1', 'update', {'note': 'абв', 'version': 3});
    await raw('s1', 'update', {'mass': 1.5, 'version': 4});
    // s2: родился и умер неотправленным → ноль строк.
    await raw('s2', 'insert', {'id': 's2', 'version': 1});
    await raw('s2', 'update', {'note': 'x', 'version': 2});
    await raw('s2', 'delete', {'version': 3});
    // s3: insert уже подтверждён, 2 неотправленные дельты → 1 update-строка.
    await raw('s3', 'insert', {'id': 's3', 'version': 1}, synced: 1);
    await raw('s3', 'update', {'note': 'y', 'version': 2});
    await raw('s3', 'update', {'note': 'yz', 'version': 3});

    await compactChangeLog(db);

    final s1 = await db.query('change_log',
        where: "entity_id = 's1' AND synced = 0");
    expect(s1, hasLength(1));
    expect(s1.single['op'], 'insert');
    final p1 = jsonDecode(s1.single['payload'] as String) as Map;
    expect(p1['note'], 'абв');
    expect(p1['mass'], 1.5);
    expect(p1['version'], 4);
    expect(s1.single['logical_ts'], 't4');

    expect(await db.query('change_log', where: "entity_id = 's2'"), isEmpty);

    final s3 = await db.query('change_log',
        where: "entity_id = 's3' AND synced = 0");
    expect(s3, hasLength(1));
    expect(s3.single['op'], 'update');
    expect((jsonDecode(s3.single['payload'] as String) as Map)['note'], 'yz');
    // Подтверждённая история s3 не тронута.
    expect(await db.query('change_log', where: "entity_id = 's3' AND synced = 1"),
        hasLength(1));
  });
}
