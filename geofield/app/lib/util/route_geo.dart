import 'crs.dart';

/// Чистые геопомощники схемы маршрута — общие для ENU-схемы (CustomPainter) и
/// растровой подложки (flutter_map). Вынесены сюда, чтобы оба экрана зависели
/// от utils, а не друг от друга (без циклического импорта).

/// Мировые метры кратные [step] в пределах [min]..[max] — линии координатной
/// сетки. Пустой список при абсурдном шаге (страховка от зависания на нуле/∞).
List<double> gridLinesMeters(double min, double max, double step) {
  if (step <= 0 || !step.isFinite || max < min) return const [];
  final first = (min / step).ceil();
  final last = (max / step).floor();
  if (last - first > 2000) return const []; // шаг мельче пикселя — не рисуем
  return [for (var k = first; k <= last; k++) k * step];
}

/// Подпись СК-42 угла схемы: X/Y Гаусса-Крюгера в ЦЕЛЫХ метрах — тот же формат,
/// что в форме точки (`_writeCoordFields`) и в выгрузке CSV (`[zone, x, y]`):
/// X — северный, Y — восточный с префиксом зоны (Y сам несёт номер зоны в
/// старших цифрах). Одна координатная запись на всё приложение, без ложной
/// точности (метры, не «км с округлением», которое можно принять за координату
/// точки). Это РЕАЛЬНЫЕ координаты угла охвата (метровый датум) — честный
/// георефер; метровая сетка внутри — НЕ клетки ГК (схема в локальной ENU).
String sk42CornerLabel(double lat, double lon) {
  // Нечисловая координата (NaN/∞) уронила бы wgs84ToSk42Gk на gkZone→floor;
  // для валидированных полевых точек недостижимо, но подпись должна быть
  // тотальной — прочерк, а не исключение/буквальное «NaN».
  if (!lat.isFinite || !lon.isFinite) return 'X— Y—';
  final gk = wgs84ToSk42Gk(lat, lon);
  if (!gk.x.isFinite || !gk.y.isFinite) return 'X— Y—';
  return 'X${gk.x.round()} Y${gk.y.round()}';
}

/// Многострочный блок георефера СК-42 для угла схемы: зона(ы) + координаты
/// северо-западного и юго-восточного углов охвата. [zones] — множество зон ГК
/// всех точек (одна → показываем осевой меридиан).
String sk42Georef({
  required double nwLat,
  required double nwLon,
  required double seLat,
  required double seLon,
  required Set<int> zones,
  bool degenerate = false,
}) {
  final sorted = zones.toList()..sort();
  // Диапазон «21–25» только если зоны идут подряд; при разрыве (например
  // {25,27} — точки в несмежных зонах) перечисляем через запятую, чтобы не
  // подразумевать зону 26, которой в наборе нет.
  final contiguous =
      sorted.isNotEmpty && sorted.last - sorted.first + 1 == sorted.length;
  final head = zones.length == 1
      ? 'СК-42 з.${zones.first} · ОМ ${gkCentralMeridian(zones.first).toStringAsFixed(0)}°'
      : contiguous
          ? 'СК-42 Гаусса-Крюгера, зоны ${sorted.first}–${sorted.last}'
          : 'СК-42 Гаусса-Крюгера, зоны ${sorted.join(', ')}';
  if (degenerate) {
    return '$head\n${sk42CornerLabel(nwLat, nwLon)} м';
  }
  return '$head\n'
      'СЗ ${sk42CornerLabel(nwLat, nwLon)}\n'
      'ЮВ ${sk42CornerLabel(seLat, seLon)} м';
}
