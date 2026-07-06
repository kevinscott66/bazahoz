import 'dart:math' as math;
import 'dart:ui' show Offset, Size;

/// Проекция набора точек (в метрах) на холст: равный масштаб по осям (форма
/// не искажается), центрирование, север вверху (экранный Y растёт вниз —
/// инвертируем). Чистая, без Flutter-виджетов — тестируется напрямую.
class PlotTransform {
  const PlotTransform({
    required this.scale, // метры → пиксели
    required this.originEast, // мировой восток, ложащийся в левый край поля
    required this.originNorth, // мировой север, ложащийся в НИЗ поля
    required this.padX,
    required this.padY,
  });

  final double scale;
  final double originEast;
  final double originNorth;
  final double padX;
  final double padY;

  /// Мировые (восток, север) метры → экранный Offset. Инверсия по северу:
  /// самый северный (originNorth) ложится наверх поля, дальше — вниз.
  Offset project(double east, double north) => Offset(
        padX + (east - originEast) * scale,
        padY - (north - originNorth) * scale,
      );

  /// Длина отрезка в метрах на экране (для масштабной линейки).
  double metersToPixels(double meters) => meters * scale;
}

/// Уложить облако точек в холст с полями [pad]. Пустой список или нулевой
/// разброс — безопасный дефолт (одна точка окажется в центре).
PlotTransform fitPlot(
  List<double> east,
  List<double> north,
  Size canvas, {
  double pad = 24.0,
}) {
  assert(east.length == north.length);
  final w = math.max(1.0, canvas.width - 2 * pad);
  final h = math.max(1.0, canvas.height - 2 * pad);
  if (east.isEmpty) {
    return PlotTransform(
        scale: 1, originEast: 0, originNorth: 0, padX: pad, padY: pad);
  }
  var minE = east.first, maxE = east.first;
  var minN = north.first, maxN = north.first;
  for (var i = 0; i < east.length; i++) {
    minE = math.min(minE, east[i]);
    maxE = math.max(maxE, east[i]);
    minN = math.min(minN, north[i]);
    maxN = math.max(maxN, north[i]);
  }
  final spanE = maxE - minE;
  final spanN = maxN - minN;
  // Равный масштаб: ограничивающая ось диктует. Нулевой разброс (одна точка
  // или совпадающие) → фиксированный масштаб, точки в центре.
  double scale;
  if (spanE <= 0 && spanN <= 0) {
    scale = 1.0;
  } else {
    final sE = spanE > 0 ? w / spanE : double.infinity;
    final sN = spanN > 0 ? h / spanN : double.infinity;
    scale = math.min(sE, sN);
  }
  // Центрируем облако в поле: считаем реальный занятый размер и добавляем
  // симметричные отступы поверх pad.
  final usedW = spanE * scale;
  final usedH = spanN * scale;
  final padX = pad + (w - usedW) / 2;
  final padY = pad + (h - usedH) / 2;
  // Экранный низ соответствует minN (север вверх): север-инверсия в project
  // отсчитывается от maxN, чтобы самая северная точка была вверху.
  return PlotTransform(
    scale: scale,
    originEast: minE,
    originNorth: maxN,
    padX: padX,
    padY: padY,
  );
}
