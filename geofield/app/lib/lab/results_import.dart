/// Импорт результатов анализов из лаборатории (ТЗ §6.9, этап 3).
/// Форматы у лабораторий разные (реестр рисков: «хаос форматов — гибкий
/// импорт-маппинг, не хардкод») — заголовки распознаются по синонимам,
/// разделитель определяется автоматически, кириллица и BOM терпимы.
library;

/// Одна строка результатов из файла лаборатории.
class LabResultRow {
  const LabResultRow({
    required this.barcode,
    required this.element,
    required this.value,
    this.unit,
    this.method,
    this.line,
  });

  final String barcode;
  final String element;
  final double? value;
  final String? unit;
  final String? method;
  final int? line; // строка файла — для сообщений о нестыковках
}

/// Итог разбора файла: строки + проблемы (файл не отвергается целиком —
/// нестыковки подсвечиваются для ручного разбора, ТЗ §6.9).
class ParsedResults {
  const ParsedResults({required this.rows, required this.issues});

  final List<LabResultRow> rows;
  final List<String> issues;
}

/// Синонимы заголовков (нижний регистр). Порядок внутри списка не важен —
/// берётся первое совпадение по колонкам файла.
const Map<String, List<String>> _headerSynonyms = {
  'barcode': [
    'штрихкод',
    'штрих-код',
    'barcode',
    'код',
    'номер пробы',
    'номер',
    'проба',
    'sample',
    'sample id',
    'sampleid',
    'lab no',
  ],
  'element': ['элемент', 'element', 'analyte', 'показатель', 'компонент'],
  'value': [
    'содержание',
    'значение',
    'результат',
    'value',
    'result',
    'концентрация',
    'grade',
  ],
  'unit': ['ед', 'ед.', 'ед. изм.', 'единицы', 'unit', 'units', 'разм'],
  'method': ['метод', 'method', 'анализ', 'assay'],
};

/// Определить разделитель по строке заголовка: берём тот, что даёт больше
/// колонок (лаборатории шлют и ';', и ',', и табуляцию).
String detectDelimiter(String headerLine) {
  var best = ';';
  var bestCount = -1;
  for (final d in const [';', ',', '\t']) {
    final count = _splitCsvLine(headerLine, d).length;
    if (count > bestCount) {
      bestCount = count;
      best = d;
    }
  }
  return best;
}

/// Разбор CSV-строки с кавычками по RFC 4180.
List<String> _splitCsvLine(String line, String delimiter) {
  final cells = <String>[];
  final buf = StringBuffer();
  var inQuotes = false;
  for (var i = 0; i < line.length; i++) {
    final ch = line[i];
    if (inQuotes) {
      if (ch == '"') {
        if (i + 1 < line.length && line[i + 1] == '"') {
          buf.write('"');
          i++;
        } else {
          inQuotes = false;
        }
      } else {
        buf.write(ch);
      }
    } else if (ch == '"') {
      inQuotes = true;
    } else if (ch == delimiter) {
      cells.add(buf.toString());
      buf.clear();
    } else {
      buf.write(ch);
    }
  }
  cells.add(buf.toString());
  return cells;
}

int? _findColumn(List<String> headers, String field) {
  final synonyms = _headerSynonyms[field]!;
  for (var i = 0; i < headers.length; i++) {
    final h = headers[i].trim().toLowerCase();
    if (synonyms.contains(h)) return i;
  }
  // Частичное совпадение (например «штрихкод пробы»).
  for (var i = 0; i < headers.length; i++) {
    final h = headers[i].trim().toLowerCase();
    if (synonyms.any((s) => s.length > 2 && h.contains(s))) return i;
  }
  return null;
}

double? _parseValue(String s) {
  var t = s.trim().replaceAll(',', '.').replaceAll(' ', '');
  if (t.isEmpty) return null;
  // «<0.005» (ниже предела обнаружения) — берём предел как значение-оценку;
  // сырое значение остаётся в файле лаборатории, спорное — на разбор.
  if (t.startsWith('<') || t.startsWith('>')) t = t.substring(1);
  return double.tryParse(t);
}

/// Разбор текста файла результатов. Никогда не бросает: проблемы — в issues.
ParsedResults parseLabResults(String text) {
  final issues = <String>[];
  final rows = <LabResultRow>[];

  // BOM и пустые строки терпимы.
  final clean = text.startsWith('﻿') ? text.substring(1) : text;
  final lines = clean
      .split(RegExp(r'\r?\n'))
      .where((l) => l.trim().isNotEmpty)
      .toList();
  if (lines.isEmpty) {
    return const ParsedResults(rows: [], issues: ['файл пуст']);
  }

  final delimiter = detectDelimiter(lines.first);
  final headers = _splitCsvLine(lines.first, delimiter);
  final iBarcode = _findColumn(headers, 'barcode');
  final iElement = _findColumn(headers, 'element');
  final iValue = _findColumn(headers, 'value');
  final iUnit = _findColumn(headers, 'unit');
  final iMethod = _findColumn(headers, 'method');

  if (iBarcode == null || iElement == null || iValue == null) {
    final missing = [
      if (iBarcode == null) 'штрихкод/номер пробы',
      if (iElement == null) 'элемент',
      if (iValue == null) 'содержание',
    ].join(', ');
    return ParsedResults(
        rows: const [],
        issues: ['не распознаны обязательные колонки: $missing '
            '(заголовок: ${lines.first})']);
  }

  String? cell(List<String> cells, int? i) =>
      (i != null && i < cells.length) ? cells[i].trim() : null;

  for (var n = 1; n < lines.length; n++) {
    final cells = _splitCsvLine(lines[n], delimiter);
    final barcode = cell(cells, iBarcode) ?? '';
    final element = cell(cells, iElement) ?? '';
    final valueText = cell(cells, iValue) ?? '';
    if (barcode.isEmpty || element.isEmpty) {
      issues.add('строка ${n + 1}: пустой штрихкод или элемент — пропущена');
      continue;
    }
    final value = _parseValue(valueText);
    if (value == null && valueText.isNotEmpty) {
      issues.add(
          'строка ${n + 1}: «$valueText» не число — значение оставлено пустым');
    }
    rows.add(LabResultRow(
      barcode: barcode,
      element: element,
      value: value,
      unit: cell(cells, iUnit),
      method: cell(cells, iMethod),
      line: n + 1,
    ));
  }
  return ParsedResults(rows: rows, issues: issues);
}
