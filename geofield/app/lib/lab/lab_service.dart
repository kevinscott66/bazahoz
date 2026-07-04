import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../data/sample_repository.dart';
import '../models/sample.dart';
import '../sync/hlc.dart';
import '../util/csv_export.dart';
import 'results_import.dart';

/// Итог применения файла результатов (ТЗ §6.9: результаты сами ложатся на
/// свои пробы, нестыковки подсвечиваются).
class ImportOutcome {
  const ImportOutcome({
    required this.applied,
    required this.samplesUpdated,
    required this.issues,
  });

  final int applied; // записано строк результатов
  final int samplesUpdated; // проб получили статус «результат получен»
  final List<String> issues; // нестыковки — на ручной разбор
}

/// Связка с лабораторией: ведомость отправки и приём результатов.
class LabService {
  LabService(
    this._db,
    this._samples, {
    required this.deviceId,
    required this.authorId,
    required this.clock,
  });

  final Database _db;
  final SampleRepository _samples;
  final String deviceId;
  final String authorId;
  final HlcClock clock;
  final Uuid _uuid = const Uuid();

  /// Колонки ведомости отправки (печать/файл — ТЗ §6.5, §6.9).
  static const dispatchHeader = [
    '№ п/п',
    'Номер пробы',
    'Штрихкод',
    'Тип',
    'От, м',
    'До, м',
    'Длина, м',
    'Масса, кг',
    'Примечание',
  ];

  /// CSV ведомости отправки по списку проб.
  String buildDispatchCsv(List<Sample> samples,
      {required String Function(String code) typeLabel}) {
    return toCsv(dispatchHeader, [
      for (var i = 0; i < samples.length; i++)
        [
          i + 1,
          samples[i].sampleNumber,
          samples[i].barcode,
          typeLabel(samples[i].sampleType),
          samples[i].depthFrom,
          samples[i].depthTo,
          samples[i].lengthM,
          samples[i].mass,
          samples[i].note,
        ],
    ]);
  }

  /// Отправка партии: перевод статусов в «отправлена» (collected — со
  /// пропуском packed: упаковка и отправка одним действием). Возвращает
  /// число отправленных.
  Future<int> markDispatched(List<Sample> samples) async {
    var n = 0;
    for (final s in samples) {
      if (s.status == SampleStatus.sent ||
          s.status == SampleStatus.resultReceived) {
        continue; // уже отправлена — ведомость можно печатать повторно
      }
      await _samples.advanceStatus(s, SampleStatus.sent,
          allowSkipPacked: true);
      n++;
    }
    return n;
  }

  /// Приём файла результатов: разбор → привязка по штрихкоду → запись
  /// sample_results + перевод проб в «результат получен». Нестыковки
  /// (нет пробы, дубль штрихкода, проба не отправлялась) — в issues,
  /// файл не отвергается целиком.
  Future<ImportOutcome> importResults(String projectId, String text) async {
    final parsed = parseLabResults(text);
    final issues = [...parsed.issues];
    var applied = 0;
    final touched = <String, Sample>{};

    for (final row in parsed.rows) {
      final matches = await _samples.byBarcode(projectId, row.barcode);
      if (matches.isEmpty) {
        issues.add('строка ${row.line}: проба со штрихкодом '
            '«${row.barcode}» не найдена');
        continue;
      }
      if (matches.length > 1) {
        issues.add('строка ${row.line}: штрихкод «${row.barcode}» '
            'неоднозначен (${matches.length} пробы) — на разбор');
        continue;
      }
      final sample = matches.single;
      await _insertResult(sample.id, row);
      applied++;
      touched[sample.id] = sample;
    }

    var updated = 0;
    for (final sample in touched.values) {
      if (sample.status == SampleStatus.resultReceived) continue;
      if (sample.status != SampleStatus.sent) {
        issues.add('проба ${sample.sampleNumber}: результат пришёл, но проба '
            'не значилась отправленной (${sample.status.label}) — статус '
            'оставлен, на разбор');
        continue;
      }
      await _samples.advanceStatus(sample, SampleStatus.resultReceived);
      updated++;
    }
    return ImportOutcome(
        applied: applied, samplesUpdated: updated, issues: issues);
  }

  Future<void> _insertResult(String sampleId, LabResultRow row) async {
    final now = DateTime.now().toUtc().toIso8601String();
    final map = <String, Object?>{
      'id': _uuid.v4(),
      'sample_id': sampleId,
      'element': row.element,
      'value': row.value,
      'unit': row.unit,
      'method': row.method,
      'author_id': authorId,
      'created_at': now,
      'modified_at': now,
    };
    // Тот же инвариант, что у всех мутаций: строка + change_log + row_clock
    // атомарно (§8.5) — результаты тоже синхронизируются между устройствами.
    await _db.transaction((txn) async {
      final ts = (await clock.tick(txn)).encode();
      await upsertRowClock(txn, 'sample_results', map['id'] as String, ts);
      await txn.insert('sample_results', map);
      await txn.insert('change_log', {
        'change_id': _uuid.v4(),
        'entity_table': 'sample_results',
        'entity_id': map['id'],
        'op': 'insert',
        'payload': jsonEncode(map),
        'author_id': authorId,
        'device_id': deviceId,
        'logical_ts': ts,
      });
    });
  }

}
