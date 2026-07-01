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
  });

  group('toCsv', () {
    test('заголовок + строки + BOM', () {
      final csv = toCsv(['a', 'b'], [
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
        () => toCsv(['a', 'b'], [
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
