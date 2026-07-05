/// Мелкие форматтеры, общие для экранов и сервисов.
library;

/// Русская плюрализация: `plural(3, 'точка', 'точки', 'точек')` → «3 точки».
/// 1/21/31 — one, 2–4/22–24 — few, остальное (и 11–14) — many.
String plural(int n, String one, String few, String many) {
  final m10 = n % 10;
  final m100 = n % 100;
  final word = (m10 == 1 && m100 != 11)
      ? one
      : (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14))
          ? few
          : many;
  return '$n $word';
}

/// Текущий момент в ISO-8601 UTC — единый формат меток времени записи.
String nowIso() => DateTime.now().toUtc().toIso8601String();

/// Число из полевого ввода: терпит запятую как десятичный разделитель.
double? parseDouble(String s) {
  final t = s.trim().replaceAll(',', '.');
  if (t.isEmpty) return null;
  return double.tryParse(t);
}
