import 'package:flutter/material.dart';

/// Типы проб и их устойчивая цветовая семантика (ТЗ 4.3): один и тот же цвет
/// у типа во всём приложении — на плитке, на карте, на бирке, в таблице.
/// Коды совпадают с samples.sample_type в схеме (core|sludge|schlich|soil|channel|grab).
enum SampleType {
  core('core', 'Керн', Color(0xFF4FB286)),
  sludge('sludge', 'Шлам', Color(0xFFB08968)),
  schlich('schlich', 'Шлих', Color(0xFF9A7FBF)),
  soil('soil', 'Почва', Color(0xFF8A9A5B)),
  channel('channel', 'Борозда', Color(0xFFE0925F)),
  grab('grab', 'Штуф', Color(0xFF6E8CA0));

  const SampleType(this.code, this.label, this.color);

  final String code;
  final String label;
  final Color color;

  static SampleType fromCode(String code) =>
      values.firstWhere((t) => t.code == code, orElse: () => SampleType.core);
}
