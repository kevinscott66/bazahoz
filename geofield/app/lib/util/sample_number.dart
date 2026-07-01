/// Генерация номера пробы по схеме проекта (projects.sample_numbering).
/// Поддерживает плейсхолдеры `{seq}` и `{seq:0N}` (нулевое дополнение до N разрядов).
/// Пример: 'SUZ-{seq:05}' + 7 -> 'SUZ-00007'.
class SampleNumberTemplate {
  const SampleNumberTemplate(this.template);

  final String template;

  static final RegExp _seq = RegExp(r'\{seq(?::0(\d+))?\}');

  String format(int seq) {
    return template.replaceAllMapped(_seq, (m) {
      final width = m.group(1);
      final s = seq.toString();
      return width == null ? s : s.padLeft(int.parse(width), '0');
    });
  }
}
