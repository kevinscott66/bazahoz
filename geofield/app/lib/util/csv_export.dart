/// Выгрузка в CSV «без потери полей» (чек-лист MVP, мастер-план §3).
/// Разделитель по умолчанию ';' — русская локаль Excel ожидает точку с запятой.
/// Файл начинается с UTF-8 BOM, чтобы Excel корректно открыл кириллицу.
library;

const csvBom = '﻿';

/// Экранирование одной ячейки по RFC 4180: если содержит разделитель, кавычку
/// или перевод строки — оборачиваем в кавычки, кавычки внутри удваиваем.
String csvCell(Object? value, {String delimiter = ';'}) {
  if (value == null) return '';
  final s = value.toString();
  final needsQuoting = s.contains(delimiter) ||
      s.contains('"') ||
      s.contains('\n') ||
      s.contains('\r');
  if (!needsQuoting) return s;
  return '"${s.replaceAll('"', '""')}"';
}

/// Собрать CSV-документ: первая строка — заголовки, дальше данные.
/// Каждая строка данных обязана совпадать по длине с заголовком —
/// расхождение бросает ArgumentError (потеря/сдвиг полей недопустимы).
String toCsv(
  List<String> header,
  List<List<Object?>> rows, {
  String delimiter = ';',
  bool bom = true,
}) {
  final buf = StringBuffer();
  if (bom) buf.write(csvBom);
  buf.writeln(
      header.map((h) => csvCell(h, delimiter: delimiter)).join(delimiter));
  for (var i = 0; i < rows.length; i++) {
    final row = rows[i];
    if (row.length != header.length) {
      throw ArgumentError(
          'Строка ${i + 1}: ${row.length} полей при ${header.length} в заголовке');
    }
    buf.writeln(
        row.map((c) => csvCell(c, delimiter: delimiter)).join(delimiter));
  }
  return buf.toString();
}

/// Колонки выгрузки точек наблюдения — все содержательные поля таблицы.
const pointCsvHeader = [
  'Номер',
  'Широта (WGS-84)',
  'Долгота (WGS-84)',
  'Высота, м',
  'Источник координат',
  'Точность GPS, м',
  'Время наблюдения',
  'Тип объекта',
  'Порода',
  'Цвет',
  'Зернистость',
  'Изменения',
  'Примечание',
  'Черновик',
  'Автор',
  'Создано',
  'Изменено',
];

/// Колонки выгрузки проб.
const sampleCsvHeader = [
  'Номер пробы',
  'Тип',
  'Штрихкод',
  'Привязка (тип)',
  'Привязка (id)',
  'От, м',
  'До, м',
  'Масса, кг',
  'Статус',
  'Примечание',
  'Автор',
  'Создано',
  'Изменено',
];
