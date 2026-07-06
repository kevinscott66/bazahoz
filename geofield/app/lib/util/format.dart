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

/// Градусы-минуты-секунды для показа WGS-84 рядом с десятичными (ТЗ §6.2):
/// топокарты подписаны в ГМС, геологу удобно сверять по рамке. Полусфера
/// словами (с.ш./ю.ш., в.д./з.д.), секунды до 0.1″ (~3 м — полевая точность).
/// Счёт в десятых долях секунды целыми — секунды/минуты переносятся без дрейфа
/// (59.96″ не остаётся «60.0″», а прибавляет минуту).
String formatGms(double deg, {required bool isLat}) {
  if (!deg.isFinite) return '—';
  final hem = isLat
      ? (deg < 0 ? 'ю.ш.' : 'с.ш.')
      : (deg < 0 ? 'з.д.' : 'в.д.');
  var tenths = (deg.abs() * 36000).round(); // десятые доли угловой секунды
  final d = tenths ~/ 36000;
  tenths %= 36000;
  final m = tenths ~/ 600;
  tenths %= 600;
  final s = (tenths / 10.0).toStringAsFixed(1).padLeft(4, '0'); // 05.0
  return '$d°${m.toString().padLeft(2, '0')}′$s″ $hem';
}
