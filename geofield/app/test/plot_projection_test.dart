import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:geofield/util/plot_projection.dart';

/// Укладка облака точек в холст: равный масштаб, центрирование, север вверх.
void main() {
  const canvas = Size(400, 300);

  test('пустой список — безопасный дефолт, не падает', () {
    final t = fitPlot([], [], canvas);
    expect(t.scale, 1);
    expect(t.project(0, 0).dx.isFinite, isTrue);
  });

  test('одна точка — по центру холста', () {
    final t = fitPlot(<double>[100], <double>[200], canvas);
    final o = t.project(100, 200);
    expect(o.dx, closeTo(canvas.width / 2, 0.5));
    expect(o.dy, closeTo(canvas.height / 2, 0.5));
  });

  test('север вверх: большая северная координата — меньший экранный Y', () {
    final t = fitPlot(<double>[0, 0], <double>[0, 1000], canvas);
    final south = t.project(0, 0);
    final north = t.project(0, 1000);
    expect(north.dy, lessThan(south.dy), reason: 'север выше по экрану');
  });

  test('восток вправо: большая восточная — больший экранный X', () {
    final t = fitPlot(<double>[0, 1000], <double>[0, 0], canvas);
    expect(t.project(1000, 0).dx, greaterThan(t.project(0, 0).dx));
  });

  test('равный масштаб по осям (форма не искажается)', () {
    // Широкое по востоку, узкое по северу — масштаб диктует восток,
    // облако центрируется по вертикали.
    final t = fitPlot(<double>[0, 4000], <double>[0, 100], canvas);
    final metersPerPixelEast =
        (t.project(4000, 0).dx - t.project(0, 0).dx) / 4000;
    final metersPerPixelNorth =
        (t.project(0, 0).dy - t.project(0, 100).dy) / 100;
    expect(metersPerPixelEast, closeTo(metersPerPixelNorth, 1e-6),
        reason: 'масштаб одинаков по обеим осям');
  });

  test('все точки попадают внутрь холста с полями', () {
    final east = <double>[0, 1000, 500, 250];
    final north = <double>[0, 800, 400, 1000];
    final t = fitPlot(east, north, canvas, pad: 24);
    for (var i = 0; i < east.length; i++) {
      final o = t.project(east[i], north[i]);
      expect(o.dx, inInclusiveRange(20, canvas.width - 20));
      expect(o.dy, inInclusiveRange(20, canvas.height - 20));
    }
  });

  test('совпадающие координаты не роняют (нулевой разброс)', () {
    final t = fitPlot(<double>[500, 500, 500], <double>[700, 700, 700], canvas);
    final o = t.project(500, 700);
    expect(o.dx, closeTo(canvas.width / 2, 0.5));
    expect(o.dy, closeTo(canvas.height / 2, 0.5));
  });
}
