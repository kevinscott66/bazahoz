import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../config/features.dart';
import '../models/observation_point.dart';
import '../models/sample.dart';
import '../theme/tokens.dart';
import '../util/crs.dart';
import '../util/plot_projection.dart';
import 'route_map_basemap.dart';

/// Схема маршрута (ТЗ §6.7, шаг к карте §6.2): точки маршрута, разложенные по
/// их координатам. Без подложки/рельефа — это следующий шаг (UNFINISHED);
/// здесь честная геометрия точек: видно охват, пропуски и координаты-выбросы
/// (опечатка сразу торчит из облака).
///
/// Проекция — ЛОКАЛЬНАЯ (ENU от центра облака), а НЕ Гаусса-Крюгера: партия
/// работает по всей Магаданской обл. и Якутии, точки маршрута могут лечь в
/// разные зоны ГК, а их метровые Y отличаются на префикс зоны (~10⁶ м) — по
/// сырому ГК картинка рвалась бы на границе зон. ENU непрерывна.
class RouteMapScreen extends StatelessWidget {
  const RouteMapScreen({
    super.key,
    required this.points,
    required this.samplesByPoint,
    required this.onTapPoint,
  });

  final List<ObservationPoint> points;

  /// Число проб на точку (id → count) — для подписи на схеме.
  final Map<String, int> samplesByPoint;
  final void Function(ObservationPoint) onTapPoint;

  @override
  Widget build(BuildContext context) {
    final located = points.where((p) => p.lat != null && p.lon != null).toList()
      // Порядок обхода — по времени создания: линия трека показывает путь и
      // возвраты (журнал отдаёт точки новыми-сверху, для трека нужен хронологич.).
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    final noCoords = points.length - located.length;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: GfColors.bg,
        title: Text('Схема маршрута', style: GfText.screenTitle),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: located.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(GfSpace.x24),
                        child: Text(
                          'Пока нет точек с координатами — снимите GPS или '
                          'введите координаты в форме точки',
                          style: GfText.hint,
                          textAlign: TextAlign.center,
                        ),
                      ),
                    )
                  // Подложка карты — за флагом (офлайн-тайлы ещё не заготовлены,
                  // рендер тайлов проверяется на устройстве). По умолчанию —
                  // честная ENU-схема без пустой подложки.
                  : AppFeatures.mapBasemap
                      ? RouteBasemapView(
                          points: located,
                          samplesByPoint: samplesByPoint,
                          onTapPoint: onTapPoint,
                        )
                      : _PlotArea(
                          points: located,
                          samplesByPoint: samplesByPoint,
                          onTapPoint: onTapPoint,
                        ),
            ),
            if (noCoords > 0)
              Padding(
                padding: const EdgeInsets.all(GfSpace.x16),
                child: Row(children: [
                  Icon(Icons.location_off_outlined,
                      size: 18, color: GfColors.textSecondary),
                  const SizedBox(width: GfSpace.x8),
                  Expanded(
                    child: Text('$noCoords без координат — не на схеме',
                        style: GfText.hint),
                  ),
                ]),
              ),
          ],
        ),
      ),
    );
  }
}

/// Локальная ENU-проекция точки (метры от опорной широты/долготы).
({double east, double north}) _enu(
    double lat, double lon, double lat0, double lon0) {
  const mPerDegLat = 110540.0;
  final mPerDegLon = 111320.0 * math.cos(lat0 * math.pi / 180.0);
  return (
    east: (lon - lon0) * mPerDegLon,
    north: (lat - lat0) * mPerDegLat,
  );
}

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

class _PlotArea extends StatelessWidget {
  const _PlotArea({
    required this.points,
    required this.samplesByPoint,
    required this.onTapPoint,
  });

  final List<ObservationPoint> points;
  final Map<String, int> samplesByPoint;
  final void Function(ObservationPoint) onTapPoint;

  @override
  Widget build(BuildContext context) {
    // Опора — центр облака (среднее), чтобы ENU-искажения были минимальны.
    final lat0 =
        points.map((p) => p.lat!).reduce((a, b) => a + b) / points.length;
    final lon0 =
        points.map((p) => p.lon!).reduce((a, b) => a + b) / points.length;
    final enu = [for (final p in points) _enu(p.lat!, p.lon!, lat0, lon0)];

    // Георефер СК-42: реальные координаты СЗ/ЮВ углов охвата + зоны ГК всех
    // точек. Считается один раз (не в paint) — тяжёлая тригонометрия датума.
    final lats = points.map((p) => p.lat!);
    final lons = points.map((p) => p.lon!);
    final minLat = lats.reduce(math.min), maxLat = lats.reduce(math.max);
    final minLon = lons.reduce(math.min), maxLon = lons.reduce(math.max);
    final degenerate = minLat == maxLat && minLon == maxLon;
    final zones = {for (final p in points) wgs84ToSk42Gk(p.lat!, p.lon!).zone};
    final georef = sk42Georef(
      nwLat: maxLat, // север-запад охвата: макс. широта, мин. долгота
      nwLon: minLon,
      seLat: minLat,
      seLon: maxLon,
      zones: zones,
      degenerate: degenerate,
    );

    return LayoutBuilder(builder: (context, box) {
      final size = Size(box.maxWidth, box.maxHeight);
      final t = fitPlot(
        [for (final e in enu) e.east],
        [for (final e in enu) e.north],
        size,
        pad: 40,
      );
      return GestureDetector(
        onTapUp: (d) {
          // Ближайшая точка в пределах пальца — открыть её.
          var bestI = -1;
          var bestD = 32.0; // порог, px
          for (var i = 0; i < enu.length; i++) {
            final o = t.project(enu[i].east, enu[i].north);
            final dist = (o - d.localPosition).distance;
            if (dist < bestD) {
              bestD = dist;
              bestI = i;
            }
          }
          if (bestI >= 0) onTapPoint(points[bestI]);
        },
        child: CustomPaint(
          size: size,
          painter: _RoutePainter(
            points: points,
            enu: enu,
            transform: t,
            samplesByPoint: samplesByPoint,
            georef: georef,
          ),
        ),
      );
    });
  }
}

class _RoutePainter extends CustomPainter {
  _RoutePainter({
    required this.points,
    required this.enu,
    required this.transform,
    required this.samplesByPoint,
    required this.georef,
  });

  final List<ObservationPoint> points;
  final List<({double east, double north})> enu;
  final PlotTransform transform;
  final Map<String, int> samplesByPoint;
  final String georef;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = GfColors.bg);
    _drawGrid(canvas, size);
    _drawScaleBar(canvas, size);
    _drawNorth(canvas, size);
    _drawGeoref(canvas, size);
    _drawTrack(canvas);

    for (var i = 0; i < points.length; i++) {
      final p = points[i];
      final o = transform.project(enu[i].east, enu[i].north);
      final color = p.isDraft ? GfColors.draft : GfColors.accent;
      // Кольцо статуса синхронизации.
      final ring = switch (p.syncStatus) {
        SyncStatus.confirmed => GfColors.syncConfirmed,
        SyncStatus.sent => GfColors.syncSent,
        SyncStatus.queued => GfColors.syncQueued,
        SyncStatus.pending => GfColors.outline,
      };
      canvas.drawCircle(o, 9, Paint()..color = ring);
      canvas.drawCircle(o, 6, Paint()..color = color);

      final samples = samplesByPoint[p.id] ?? 0;
      final label = samples > 0 ? '${p.number} · $samplesп' : p.number;
      final tp = TextPainter(
        text: TextSpan(text: label, style: GfText.hint),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, o + const Offset(12, -8));
    }
  }

  /// Линия трека — точки в порядке обхода. Тонкая, приглушённая, под точками.
  void _drawTrack(Canvas canvas) {
    if (points.length < 2) return;
    final path = Path();
    for (var i = 0; i < points.length; i++) {
      final o = transform.project(enu[i].east, enu[i].north);
      i == 0 ? path.moveTo(o.dx, o.dy) : path.lineTo(o.dx, o.dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = GfColors.textFaint
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  /// Метрическая опорная сетка (север вверх): помогает на глаз оценивать
  /// расстояния между точками и форму облака. Шаг — «красивый» (как линейка).
  /// Это НЕ клетки Гаусса-Крюгера (см. sk42CornerLabel) — метрический референс.
  void _drawGrid(Canvas canvas, Size size) {
    final scale = transform.scale;
    if (scale <= 0 || !scale.isFinite) return;
    final step = _niceMeters((size.width / scale) / 5);
    if (step <= 0) return;
    final visMinE = transform.originEast + (0 - transform.padX) / scale;
    final visMaxE = transform.originEast + (size.width - transform.padX) / scale;
    final visMaxN = transform.originNorth + transform.padY / scale;
    final visMinN =
        transform.originNorth - (size.height - transform.padY) / scale;
    final paint = Paint()
      ..color = GfColors.outline.withValues(alpha: 0.45)
      ..strokeWidth = 1;
    for (final e in gridLinesMeters(visMinE, visMaxE, step)) {
      final x = transform.project(e, transform.originNorth).dx;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (final n in gridLinesMeters(visMinN, visMaxN, step)) {
      final y = transform.project(transform.originEast, n).dy;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  /// Блок георефера СК-42 в левом верхнем углу: зона(ы) и реальные координаты
  /// углов охвата — привязка к бумажной карте, честно (без ложной сетки ГК).
  void _drawGeoref(Canvas canvas, Size size) {
    final tp = TextPainter(
      text: TextSpan(
          text: georef,
          style: GfText.hint.copyWith(
              color: GfColors.textSecondary,
              fontFeatures: const [FontFeature.tabularFigures()])),
      textDirection: TextDirection.ltr,
      maxLines: 3,
    )..layout(maxWidth: size.width - 32);
    // Полупрозрачная подложка, чтобы читалось поверх сетки и точек.
    final rect = Rect.fromLTWH(12, 10, tp.width + 12, tp.height + 8);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(GfRadius.r8)),
      Paint()..color = GfColors.bg.withValues(alpha: 0.7),
    );
    tp.paint(canvas, const Offset(18, 14));
  }

  void _drawScaleBar(Canvas canvas, Size size) {
    if (transform.scale <= 0 || !transform.scale.isFinite) return;
    // Целевая длина ~1/4 ширины, округлённая к «красивому» числу метров.
    final targetM = (size.width / 4) / transform.scale;
    final nice = _niceMeters(targetM);
    final px = transform.metersToPixels(nice);
    final y = size.height - 20;
    const x0 = 20.0;
    final paint = Paint()
      ..color = GfColors.textSecondary
      ..strokeWidth = 2;
    canvas.drawLine(Offset(x0, y), Offset(x0 + px, y), paint);
    canvas.drawLine(Offset(x0, y - 4), Offset(x0, y + 4), paint);
    canvas.drawLine(Offset(x0 + px, y - 4), Offset(x0 + px, y + 4), paint);
    final label = nice >= 1000
        ? '${(nice / 1000).toStringAsFixed(nice % 1000 == 0 ? 0 : 1)} км'
        : '${nice.toStringAsFixed(0)} м';
    (TextPainter(
      text: TextSpan(text: label, style: GfText.hint),
      textDirection: TextDirection.ltr,
    )..layout())
        .paint(canvas, Offset(x0, y - 20));
  }

  void _drawNorth(Canvas canvas, Size size) {
    final x = size.width - 24.0;
    const y = 28.0;
    final paint = Paint()
      ..color = GfColors.textSecondary
      ..strokeWidth = 2;
    canvas.drawLine(Offset(x, y + 12), Offset(x, y - 12), paint);
    canvas.drawLine(Offset(x, y - 12), Offset(x - 4, y - 6), paint);
    canvas.drawLine(Offset(x, y - 12), Offset(x + 4, y - 6), paint);
    (TextPainter(
      text: TextSpan(text: 'С', style: GfText.hint),
      textDirection: TextDirection.ltr,
    )..layout())
        .paint(canvas, Offset(x - 4, y - 30));
  }

  /// Округление к 1/2/5·10ⁿ — привычная шкала линейки.
  double _niceMeters(double m) {
    if (m <= 0) return 1;
    final p = math.pow(10, (math.log(m) / math.ln10).floor()).toDouble();
    final f = m / p;
    final nice = f < 1.5
        ? 1.0
        : f < 3.5
            ? 2.0
            : f < 7.5
                ? 5.0
                : 10.0;
    return nice * p;
  }

  @override
  bool shouldRepaint(_RoutePainter old) =>
      old.points != points || old.transform != transform;
}
