import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../data/tile_cache.dart';
import '../models/observation_point.dart';
import '../models/sample.dart' show SyncStatus;
import '../theme/tokens.dart';
import '../util/crs.dart';
import '../util/route_geo.dart' show sk42Georef;

/// Растровая ПОДЛОЖКА карты под схемой маршрута (за флагом `mapBasemap`,
/// UNFINISHED.md). Точки, трек и георефер СК-42 ложатся поверх тайлов. Тайлы —
/// строго ОФЛАЙН из локального кэша (регионы, скачанные заранее): без связи в
/// поле сеть недоступна и не нужна (ТЗ §6.8). Пока офлайн-тайлы не заготовлены
/// — подложка пуста (фон темы), но точки/трек/привязка уже работают; заготовка
/// тайлов Магадана и Якутии и скачивание регионами — следующий заход.

/// Провайдер тайлов из локального кэша `{dir}/{z}/{x}/{y}.png`. Наличие тайла —
/// по индексу [TileCacheIndex] (Set-поиск, БЕЗ синхронного existsSync на каждый
/// тайл в горячем пути — долг аудита закрыт). Тайла нет — прозрачная плитка.
/// НИКОГДА не ходит в сеть.
class OfflineRasterTileProvider extends TileProvider {
  OfflineRasterTileProvider(this.index);

  /// Индекс офлайн-тайлов. null — тайлов нет вовсе (пустая подложка).
  final TileCacheIndex? index;

  // 1×1 прозрачный PNG (8-бит RGBA) — плитка-заглушка, когда тайла в кэше нет.
  static final Uint8List _blank = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4'
      '2mNgAAIAAAUAAen63NgAAAAASUVORK5CYII=');

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) {
    final idx = index;
    final dir = idx?.baseDir;
    if (idx != null &&
        dir != null &&
        idx.has(coordinates.z, coordinates.x, coordinates.y)) {
      return FileImage(File(
          '${dir.path}/${coordinates.z}/${coordinates.x}/${coordinates.y}.png'));
    }
    return MemoryImage(_blank);
  }
}

class RouteBasemapView extends StatelessWidget {
  const RouteBasemapView({
    super.key,
    required this.points,
    required this.samplesByPoint,
    required this.onTapPoint,
    this.tileIndex,
  });

  final List<ObservationPoint> points;
  final Map<String, int> samplesByPoint;
  final void Function(ObservationPoint) onTapPoint;

  /// Индекс офлайн-тайлов (null — подложки нет, только точки/трек).
  final TileCacheIndex? tileIndex;

  /// Честная метка состояния подложки по РЕАЛЬНОМУ покрытию охвата маршрута
  /// тайлами (а не по «каталог задан/нет»): нет тайлов → «не загружены»,
  /// неполно → «частично N%», полно → без метки. Крупный охват (оценка тайлов
  /// не влезает) — молча без метки, чтобы не пугать.
  String? _tileNotice(List<LatLng> coords) {
    final idx = tileIndex;
    if (idx == null || idx.isEmpty) {
      return 'Офлайн-тайлы не загружены — только точки';
    }
    if (coords.isEmpty) return null;
    var minLat = coords.first.latitude, maxLat = minLat;
    var minLon = coords.first.longitude, maxLon = minLon;
    for (final c in coords) {
      minLat = c.latitude < minLat ? c.latitude : minLat;
      maxLat = c.latitude > maxLat ? c.latitude : maxLat;
      minLon = c.longitude < minLon ? c.longitude : minLon;
      maxLon = c.longitude > maxLon ? c.longitude : maxLon;
    }
    try {
      final needed = tilesForRegion(
        west: minLon,
        south: minLat,
        east: maxLon,
        north: maxLat,
        minZoom: 10,
        maxZoom: 12,
        maxTiles: 20000,
      );
      final cov = idx.coverage(needed);
      if (cov >= 0.999) return null; // полное покрытие — без метки
      return 'Тайлы загружены частично (${(cov * 100).round()}%)';
    } on ArgumentError {
      return null; // охват слишком крупный для быстрой оценки — без метки
    }
  }

  @override
  Widget build(BuildContext context) {
    // Порядок обхода — по времени создания (как в ENU-схеме): трек показывает
    // путь и возвраты.
    final located = points
        .where((p) => p.lat != null && p.lon != null)
        .toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    final coords = [for (final p in located) LatLng(p.lat!, p.lon!)];
    final notice = _tileNotice(coords);

    return Stack(
      children: [
        FlutterMap(
          options: MapOptions(
            backgroundColor: GfColors.bg,
            initialCenter:
                coords.isEmpty ? const LatLng(62.78, 148.16) : coords.first,
            initialZoom: 11,
            // Камера подгоняется под весь маршрут ОДИН РАЗ при открытии
            // (flutter_map применяет initialCameraFit единожды за жизнь карты).
            // Экран открывается снимком точек из журнала, поэтому этого хватает.
            // Когда карта станет живой (текущий GPS, добавление точек на месте),
            // понадобится MapController + повторный fit — следующий заход.
            initialCameraFit: coords.isEmpty
                ? null
                : CameraFit.coordinates(
                    coordinates: coords,
                    padding: const EdgeInsets.all(56),
                    maxZoom: 15,
                  ),
          ),
          children: [
            TileLayer(
              tileProvider: OfflineRasterTileProvider(tileIndex),
              maxNativeZoom: 16,
              // Офлайн: без User-Agent-сети; провайдер не делает запросов.
              tileDisplay: const TileDisplay.instantaneous(),
            ),
            if (coords.length >= 2)
              PolylineLayer(polylines: [
                Polyline(
                  points: coords,
                  color: GfColors.textFaint,
                  strokeWidth: 2,
                ),
              ]),
            MarkerLayer(markers: [
              for (var i = 0; i < located.length; i++)
                Marker(
                  point: coords[i],
                  width: 30,
                  height: 30,
                  child: _PointDot(
                    key: ValueKey('map-pt-${located[i].id}'),
                    point: located[i],
                    samples: samplesByPoint[located[i].id] ?? 0,
                    onTap: () => onTapPoint(located[i]),
                  ),
                ),
            ]),
          ],
        ),
        if (located.isNotEmpty)
          Positioned(
            left: GfSpace.x12,
            top: GfSpace.x8,
            child: _GeorefBadge(points: located),
          ),
        if (notice != null)
          Positioned(
            left: GfSpace.x12,
            bottom: GfSpace.x12,
            child: _Chip(notice),
          ),
      ],
    );
  }
}

/// Точка на карте: кольцо статуса синхронизации + заливка (черновик/акцент),
/// теми же цветами, что в ENU-схеме и журнале.
class _PointDot extends StatelessWidget {
  const _PointDot({
    super.key,
    required this.point,
    required this.samples,
    required this.onTap,
  });

  final ObservationPoint point;

  /// Число проб на точке — маленький бейдж, чтобы точка с пробами отличалась
  /// от пустой (паритет с ENU-схемой, где у точки подписано «· Nп»).
  final int samples;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ring = switch (point.syncStatus) {
      SyncStatus.confirmed => GfColors.syncConfirmed,
      SyncStatus.sent => GfColors.syncSent,
      SyncStatus.queued => GfColors.syncQueued,
      SyncStatus.pending => GfColors.outline,
    };
    final fill = point.isDraft ? GfColors.draft : GfColors.accent;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: [
          Container(
            width: 18,
            height: 18,
            decoration: BoxDecoration(color: ring, shape: BoxShape.circle),
            child: Center(
              child: Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(color: fill, shape: BoxShape.circle),
              ),
            ),
          ),
          if (samples > 0)
            Positioned(
              right: 0,
              top: 0,
              child: Container(
                constraints: const BoxConstraints(minWidth: 14, minHeight: 14),
                padding: const EdgeInsets.symmetric(horizontal: 3),
                decoration: BoxDecoration(
                  color: GfColors.surfaceHi,
                  shape: BoxShape.rectangle,
                  borderRadius: BorderRadius.circular(7),
                  border: Border.all(color: GfColors.bg, width: 1),
                ),
                child: Text(
                  '$samples',
                  textAlign: TextAlign.center,
                  style: GfText.hint.copyWith(
                      fontSize: 10, color: GfColors.textPrimary, height: 1.2),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Блок георефера СК-42 углов охвата — тот же, что на ENU-схеме.
class _GeorefBadge extends StatelessWidget {
  const _GeorefBadge({required this.points});

  final List<ObservationPoint> points;

  @override
  Widget build(BuildContext context) {
    final lats = points.map((p) => p.lat!);
    final lons = points.map((p) => p.lon!);
    final minLat = lats.reduce((a, b) => a < b ? a : b);
    final maxLat = lats.reduce((a, b) => a > b ? a : b);
    final minLon = lons.reduce((a, b) => a < b ? a : b);
    final maxLon = lons.reduce((a, b) => a > b ? a : b);
    final degenerate = minLat == maxLat && minLon == maxLon;
    // Зона берётся из ПОЛНОГО трансформа (а не дешёвого gkZone по WGS-долготе)
    // намеренно: так зона в шапке совпадает с зоной, зашитой в Y угловых
    // подписей (датум-сдвиг у границы зоны может дать другую зону). Считается
    // один раз при открытии экрана, не на жест — в бюджете.
    final zones = {for (final p in points) wgs84ToSk42Gk(p.lat!, p.lon!).zone};
    final text = sk42Georef(
      nwLat: maxLat,
      nwLon: minLon,
      seLat: minLat,
      seLon: maxLon,
      zones: zones,
      degenerate: degenerate,
    );
    return _Chip(text);
  }
}

/// Полупрозрачная плашка поверх карты (читается на любой подложке).
class _Chip extends StatelessWidget {
  const _Chip(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: GfSpace.x8, vertical: GfSpace.x4),
      decoration: BoxDecoration(
        color: GfColors.bg.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(GfRadius.r8),
      ),
      child: Text(text,
          style: GfText.hint.copyWith(
              color: GfColors.textSecondary,
              fontFeatures: const [FontFeature.tabularFigures()])),
    );
  }
}
