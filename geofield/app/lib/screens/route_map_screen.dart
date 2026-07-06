import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/observation_point.dart';
import '../models/sample.dart';
import '../theme/tokens.dart';
import '../util/plot_projection.dart';

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
        title: const Text('Схема маршрута', style: GfText.screenTitle),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: located.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(GfSpace.x24),
                        child: Text(
                          'Пока нет точек с координатами — снимите GPS или '
                          'введите координаты в форме точки',
                          style: GfText.hint,
                          textAlign: TextAlign.center,
                        ),
                      ),
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
                  const Icon(Icons.location_off_outlined,
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
  });

  final List<ObservationPoint> points;
  final List<({double east, double north})> enu;
  final PlotTransform transform;
  final Map<String, int> samplesByPoint;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = GfColors.bg);
    _drawScaleBar(canvas, size);
    _drawNorth(canvas, size);
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
      text: const TextSpan(text: 'С', style: GfText.hint),
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
