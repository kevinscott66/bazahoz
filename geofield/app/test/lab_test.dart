import 'package:flutter_test/flutter_test.dart';
import 'package:geofield/data/database.dart';
import 'package:geofield/data/demo_seed.dart';
import 'package:geofield/data/sample_repository.dart';
import 'package:geofield/lab/lab_service.dart';
import 'package:geofield/lab/results_import.dart';
import 'package:geofield/models/sample.dart';
import 'package:geofield/sync/hlc.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  group('parseLabResults — гибкий маппинг форматов', () {
    test('русские заголовки, ; и запятая-десятичная', () {
      final r = parseLabResults('Штрихкод;Элемент;Содержание;Ед. изм.;Метод\n'
          'SUZ-00001;Au;1,25;г/т;ПробирныЙ\n'
          'SUZ-00002;Ag;12,0;г/т;ААС\n');
      expect(r.issues, isEmpty);
      expect(r.rows, hasLength(2));
      expect(r.rows.first.barcode, 'SUZ-00001');
      expect(r.rows.first.element, 'Au');
      expect(r.rows.first.value, 1.25);
      expect(r.rows.first.unit, 'г/т');
    });

    test('английские заголовки, запятая-разделитель, BOM', () {
      final r = parseLabResults('\u{FEFF}Sample,Element,Result,Units\n'
          'SUZ-00001,Au,0.85,g/t\n');
      expect(r.issues, isEmpty);
      expect(r.rows.single.value, 0.85);
    });

    test('«ниже предела» <0.005 берётся числом-оценкой', () {
      final r = parseLabResults('barcode;element;value\nS-1;Au;<0.005\n');
      expect(r.rows.single.value, 0.005);
    });

    test('нечисловое значение — issue, строка не теряется', () {
      final r = parseLabResults('barcode;element;value\nS-1;Au;н/д\n');
      expect(r.rows.single.value, isNull);
      expect(r.issues, hasLength(1));
    });

    test('нет обязательных колонок — понятная диагностика', () {
      final r = parseLabResults('a;b;c\n1;2;3\n');
      expect(r.rows, isEmpty);
      expect(r.issues.single, contains('не распознаны обязательные колонки'));
    });

    test('кавычки и разделитель внутри ячейки', () {
      final r = parseLabResults('barcode;element;value\n"S-1;x";Au;1.0\n');
      expect(r.rows.single.barcode, 'S-1;x');
    });

    test('колонка «Номер» не перехватывает штрихкод (приоритет синонимов)', () {
      final r = parseLabResults('Номер;Штрихкод;Элемент;Содержание\n'
          '1;SUZ-00007;Au;0.5\n');
      expect(r.rows.single.barcode, 'SUZ-00007',
          reason: 'порядковый номер строки — не идентификатор пробы');
    });

    test('случайный ; в заголовке не ломает выбор запятой-разделителя', () {
      final r = parseLabResults('Sample,Element,Result,Unit (mg/kg; ppm)\n'
          'S-1,Au,1.5,g/t\n'
          'S-2,Ag,7.0,g/t\n');
      expect(r.rows, hasLength(2));
      expect(r.rows.first.barcode, 'S-1');
    });
  });

  group('LabService на реальной базе', () {
    late Database db;
    late SampleRepository samples;
    late LabService lab;

    Future<Sample> addSample(String id, String number,
        {SampleStatus status = SampleStatus.collected}) async {
      final now = DateTime.now().toUtc().toIso8601String();
      final s = Sample(
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
      await samples.save(s, isNew: true);
      return s;
    }

    setUp(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      db = await databaseFactory.openDatabase(inMemoryDatabasePath,
          options: OpenDatabaseOptions(
              version: 1, onCreate: (d, _) => AppDatabase.migrate001(d)));
      await seedDemo(db);
      final clock = await HlcClock.load(db, demoDeviceId);
      samples = SampleRepository(db,
          deviceId: demoDeviceId, authorId: demoAuthorId, clock: clock);
      lab = LabService(db, samples,
          deviceId: demoDeviceId, authorId: demoAuthorId, clock: clock);
    });

    tearDown(() => db.close());

    test('ведомость: CSV со всеми пробами, статусы уходят в sent', () async {
      final a = await addSample('s1', 'SUZ-00001');
      final b =
          await addSample('s2', 'SUZ-00002', status: SampleStatus.collected);
      final csv = lab.buildDispatchCsv([a, b], typeLabel: (c) => c);
      expect(csv.split('\n').where((l) => l.isNotEmpty), hasLength(3));
      expect(csv, contains('SUZ-00001'));

      final n = await lab.markDispatched([a, b]);
      expect(n, 2);
      final rows = await db.query('samples', orderBy: 'sample_number');
      expect(rows.map((r) => r['status']), everyElement('sent'));
      // Переход статуса — мутация; она СКЛЕИВАЕТСЯ с неотправленным
      // insert той же пробы: на провод уйдёт по одной строке на пробу
      // с итоговым статусом.
      final log =
          await db.query('change_log', where: "entity_table = 'samples'");
      expect(log, hasLength(2));
      for (final r in log) {
        expect(r['op'], 'insert');
        expect(r['payload'], contains('"status":"sent"'));
      }
    });

    test('переход мимо цепочки статусов — ошибка', () async {
      final a = await addSample('s1', 'SUZ-00001');
      expect(() => samples.advanceStatus(a, SampleStatus.resultReceived),
          throwsArgumentError);
    });

    test('импорт: автопривязка по штрихкоду, статус закрывается', () async {
      final a = await addSample('s1', 'SUZ-00001');
      await lab.markDispatched([a]);
      final sent = (await samples.byBarcode(demoProjectId, 'SUZ-00001')).single;

      final outcome = await lab.importResults(
          demoProjectId,
          'Штрихкод;Элемент;Содержание;Ед\n'
          'SUZ-00001;Au;2,4;г/т\n'
          'SUZ-00001;Ag;15;г/т\n');
      expect(outcome.applied, 2);
      expect(outcome.samplesUpdated, 1);
      expect(outcome.issues, isEmpty);

      final results = await db.query('sample_results');
      expect(results, hasLength(2));
      expect(results.map((r) => r['sample_id']), everyElement(sent.id));
      final row = (await db.query('samples', where: "id = 's1'")).single;
      expect(row['status'], 'result_received');
    });

    test('нестыковки: нет пробы, дубль штрихкода, не отправлялась', () async {
      await addSample('s1', 'SUZ-00001'); // collected, не отправлена
      await addSample('s2', 'SUZ-00002');
      await addSample('s3', 'SUZ-00002'); // дубль штрихкода

      final outcome = await lab.importResults(
          demoProjectId,
          'barcode;element;value\n'
          'SUZ-00001;Au;1.0\n'
          'SUZ-00002;Au;2.0\n'
          'SUZ-09999;Au;3.0\n');
      // SUZ-00001 привязан (запись есть), но статус не закрыт — нестыковка;
      // SUZ-00002 неоднозначен; SUZ-09999 не найден.
      expect(outcome.applied, 1);
      expect(outcome.samplesUpdated, 0);
      expect(outcome.issues, hasLength(3));
      expect(outcome.issues.join('\n'), contains('не найдена'));
      expect(outcome.issues.join('\n'), contains('неоднозначен'));
      expect(outcome.issues.join('\n'), contains('не значилась отправленной'));
      final row = (await db.query('samples', where: "id = 's1'")).single;
      expect(row['status'], 'collected', reason: 'статус не прыгнул');
    });

    test('повторная ведомость по уже отправленным — ноль переходов', () async {
      final a = await addSample('s1', 'SUZ-00001');
      await lab.markDispatched([a]);
      final again =
          (await samples.byBarcode(demoProjectId, 'SUZ-00001')).single;
      expect(await lab.markDispatched([again]), 0);
    });

    test(
        'двойной вызов со stale-объектами: один переход, версия растёт один раз',
        () async {
      final a = await addSample('s1', 'SUZ-00001');
      // Оба вызова с ОДНИМ устаревшим снапшотом (двойной тап).
      expect(await lab.markDispatched([a]), 1);
      expect(await lab.markDispatched([a]), 0,
          reason: 'advanceStatus читает свежий статус, не снапшот');
      final row = (await db.query('samples', where: "id = 's1'")).single;
      expect(row['version'], 2, reason: 'ровно один инкремент версии');
      final log =
          await db.query('change_log', where: "entity_table = 'samples'");
      expect(log, hasLength(1), reason: 'одна склеенная мутация, не две');
      expect(log.single['payload'], contains('"version":2'));
    });

    test('мягко удалённая проба не «оживает» переводом статуса', () async {
      final a = await addSample('s1', 'SUZ-00001');
      await samples.softDelete(a);
      expect(
          () => samples.advanceStatus(a, SampleStatus.sent,
              allowSkipPacked: true),
          throwsArgumentError);
      final row = (await db.query('samples', where: "id = 's1'")).single;
      expect(row['status'], 'collected');
      expect(row['deleted'], 1);
    });

    test('повторный импорт того же файла — дубли не плодятся', () async {
      final a = await addSample('s1', 'SUZ-00001');
      await lab.markDispatched([a]);
      const file = 'barcode;element;value;unit\nSUZ-00001;Au;2.4;г/т\n';
      final first = await lab.importResults(demoProjectId, file);
      expect(first.applied, 1);
      final second = await lab.importResults(demoProjectId, file);
      expect(second.applied, 0);
      expect(second.issues.single, contains('уже принят'));
      expect(await db.query('sample_results'), hasLength(1));

      // Пере-анализ с другим значением — вставляется, но подсвечен.
      final third = await lab.importResults(
          demoProjectId, 'barcode;element;value;unit\nSUZ-00001;Au;2.6;г/т\n');
      expect(third.applied, 1);
      expect(third.issues.single, contains('на разбор'));
      expect(await db.query('sample_results'), hasLength(2));
    });
  });
}
