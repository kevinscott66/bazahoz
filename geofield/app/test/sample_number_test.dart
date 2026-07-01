import 'package:flutter_test/flutter_test.dart';
import 'package:geofield/util/sample_number.dart';

void main() {
  group('SampleNumberTemplate', () {
    test('нулевое дополнение до ширины', () {
      expect(const SampleNumberTemplate('SUZ-{seq:05}').format(7), 'SUZ-00007');
      expect(const SampleNumberTemplate('SUZ-{seq:05}').format(12345),
          'SUZ-12345');
    });

    test('без ширины — как есть', () {
      expect(const SampleNumberTemplate('{seq}').format(7), '7');
    });

    test('плейсхолдер в середине', () {
      expect(const SampleNumberTemplate('P-{seq:03}-A').format(9), 'P-009-A');
    });

    test('переполнение ширины не обрезает', () {
      expect(const SampleNumberTemplate('SUZ-{seq:05}').format(123456),
          'SUZ-123456');
    });
  });
}
