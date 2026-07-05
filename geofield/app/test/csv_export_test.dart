import 'package:flutter_test/flutter_test.dart';
import 'package:geofield/util/csv_export.dart';

void main() {
  group('csvCell', () {
    test('простое значение — как есть', () {
      expect(csvCell('SUZ-00001'), 'SUZ-00001');
      expect(csvCell(12.5), '12.5');
    });

    test('null — пустая ячейка', () {
      expect(csvCell(null), '');
    });

    test('разделитель внутри — в кавычках', () {
      expect(csvCell('гранит; выветрелый'), '"гранит; выветрелый"');
    });

    test('кавычки удваиваются', () {
      expect(csvCell('жила "мощная"'), '"жила ""мощная"""');
    });

    test('перевод строки — в кавычках', () {
      expect(csvCell('строка1\nстрока2'), '"строка1\nстрока2"');
    });

    test('другой разделитель учитывается', () {
      expect(csvCell('a,b', delimiter: ','), '"a,b"');
      expect(csvCell('a,b', delimiter: ';'), 'a,b');
    });

    test('инъекция формул нейтрализуется префиксом-апострофом', () {
      // Примечание пробы «=HYPERLINK(...)» не должно исполниться в Excel.
      expect(csvCell('=SUM(A1)'), "'=SUM(A1)");
      expect(csvCell('+7 900 000-00-00'), "'+7 900 000-00-00");
      expect(csvCell('-1|calc'), "'-1|calc");
      expect(csvCell('@cmd'), "'@cmd");
      // Кавычки внутри формулы: сначала префикс, потом обычное RFC-экранирование.
      expect(csvCell('=HYPERLINK("http://evil")'),
          '"\'=HYPERLINK(""http://evil"")"');
    });

    test('числа (в т.ч. отрицательные) формулами не считаются', () {
      expect(csvCell(-42.5), '-42.5');
      expect(csvCell(-1), '-1');
    });
  });

  group('toCsv', () {
    test('заголовок + строки + BOM', () {
      final csv = toCsv([
        'a',
        'b'
      ], [
        ['1', '2'],
        ['3', 'x;y'],
      ]);
      expect(csv.startsWith(csvBom), isTrue);
      final lines = csv.substring(1).trim().split('\n');
      expect(lines, ['a;b', '1;2', '3;"x;y"']);
    });

    test('несовпадение длины строки с заголовком — ошибка, а не потеря полей',
        () {
      expect(
        () => toCsv([
          'a',
          'b'
        ], [
          ['только-одно']
        ]),
        throwsArgumentError,
      );
    });

    test('без BOM по запросу', () {
      expect(toCsv(['a'], [], bom: false).startsWith(csvBom), isFalse);
    });
  });
}
