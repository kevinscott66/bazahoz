import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../data/change_payload.dart';
import '../data/sample_repository.dart';
import '../models/sample.dart';
import '../sync/hlc.dart';
import '../util/csv_export.dart';
import '../util/format.dart';
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

  /// Отправка партии: перевод статусов в «отправлена» (collected — с
  /// пропуском packed: упаковка и отправка одним действием). Возвращает
  /// число реально переведённых. Идемпотентен: advanceStatus сам читает
  /// свежий статус в транзакции, повтор/двойной тап даёт 0 переходов.
  /// Пробы независимы: сбой на N-й не откатывает предыдущие — повторный
  /// вызов доведёт остальных.
  Future<int> markDispatched(List<Sample> samples) async {
    var n = 0;
    for (final s in samples) {
      if (s.status == SampleStatus.resultReceived) continue; // конечный статус
      try {
        final advanced = await _samples.advanceStatus(s, SampleStatus.sent,
            allowSkipPacked: true);
        if (advanced) n++;
      } on ArgumentError {
        // Список на экране мог устареть: конкурентный импорт результатов уже
        // закрыл пробу (result_received) — это не сбой партии, просто не переход.
        continue;
      }
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
            'неоднозначен (${plural(matches.length, 'проба', 'пробы', 'проб')})'
            ' — на разбор');
        continue;
      }
      final sample = matches.single;
      // Дедуп: повторный импорт того же файла не плодит строки результатов.
      final existing = await _db.query('sample_results',
          where: 'sample_id = ? AND element = ? AND deleted = 0',
          whereArgs: [sample.id, row.element]);
      final exactDup = existing.any(
          (r) => r['value'] == row.value && (r['unit'] as String?) == row.unit);
      if (exactDup) {
        issues.add('строка ${row.line}: результат ${row.element} по '
            '«${row.barcode}» уже принят — пропущен (повторный импорт?)');
        continue;
      }
      if (existing.isNotEmpty) {
        // Пере-анализ/контрольная проба: вставляем, но подсвечиваем.
        issues.add('строка ${row.line}: повторный результат ${row.element} '
            'по «${row.barcode}» с другим значением — на разбор');
      }
      await _insertResult(sample.id, row);
      applied++;
      touched[sample.id] = sample;
    }

    var updated = 0;
    for (final sample in touched.values) {
      try {
        // advanceStatus читает СВЕЖИЙ статус в транзакции: sent →
        // result_received; уже result_received → false (повтор безопасен).
        final advanced =
            await _samples.advanceStatus(sample, SampleStatus.resultReceived);
        if (advanced) updated++;
      } on ArgumentError {
        issues.add('проба ${sample.sampleNumber}: результат пришёл, но проба '
            'не значилась отправленной — статус оставлен, на разбор');
      }
    }
    return ImportOutcome(
        applied: applied, samplesUpdated: updated, issues: issues);
  }

  Future<void> _insertResult(String sampleId, LabResultRow row) async {
    final now = nowIso();
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
      await txn.insert('sample_results', map);
      await logChange(txn,
          clock: clock,
          table: 'sample_results',
          entityId: map['id'] as String,
          op: 'insert',
          payload: map,
          authorId: authorId,
          deviceId: deviceId);
    });
  }
}
