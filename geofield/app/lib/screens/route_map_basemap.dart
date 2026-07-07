import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../models/observation_point.dart';
import '../models/sample.dart' show SyncStatus;
import '../theme/tokens.dart';
import '../util/crs.dart';
import 'route_map_screen.dart' show sk42Georef;

/// Растровая ПОДЛОЖКА карты под схемой маршрута (за флагом `mapBasemap`,
/// UNFINISHED.md). Точки, трек и георефер СК-42 ложатся поверх тайлов. Тайлы —
/// строго ОФЛАЙН из локального кэша (регионы, скачанные заранее): без связи в
/// поле сеть недоступна и не нужна (ТЗ §6.8). Пока офлайн-тайлы не заготовлены
/// — подложка пуста (фон темы), но точки/трек/привязка уже работают; заготовка
/// тайлов Магадана и Якутии и скачивание регионами — следующий заход.

/// Провайдер тайлов из локального кэша `{dir}/{z}/{x}/{y}.png`. Тайла нет —
/// прозрачная плитка (просвечивает фон карты). НИКОГДА не ходит в сеть.
class OfflineRasterTileProvider extends TileProvider {
  OfflineRasterTileProvider(this.cacheDir);

  /// Каталог офлайн-тайлов. null — тайлов нет вовсе (пустая подложка).
  final Directory? cacheDir;

  // 1×1 прозрачный PNG (8-бит RGBA) — плитка-заглушка, когда тайла в кэше нет.
  static final Uint8List _blank = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4'
      '2mNgAAIAAAUAAen63NgAAAAASUVORK5CYII=');

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) {
    final dir = cacheDir;
    if (dir != null) {
      final f = File(
          '${dir.path}/${coordinates.z}/${coordinates.x}/${coordinates.y}.png');
      if (f.existsSync()) return FileImage(f);
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
    this.tileCacheDir,
  });

  final List<ObservationPoint> points;
  final Map<String, int> samplesByPoint;
  final void Function(ObservationPoint) onTapPoint;

  /// Каталог офлайн-тайлов (null — подложки нет, только точки/трек).
  final Directory? tileCacheDir;

  @override
  Widget build(BuildContext context) {
    // Порядок обхода — по времени создания (как в ENU-схеме): трек показывает
    // путь и возвраты.
    final located = points
        .where((p) => p.lat != null && p.lon != null)
        .toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    final coords = [for (final p in located) LatLng(p.lat!, p.lon!)];

    return Stack(
      children: [
        FlutterMap(
          options: MapOptions(
            backgroundColor: GfColors.bg,
            initialCenter:
                coords.isEmpty ? const LatLng(62.78, 148.16) : coords.first,
            initialZoom: 11,
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
              tileProvider: OfflineRasterTileProvider(tileCacheDir),
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
        if (tileCacheDir == null)
          const Positioned(
            left: GfSpace.x12,
            bottom: GfSpace.x12,
            child: _Chip('Офлайн-тайлы не загружены — только точки'),
          ),
      ],
    );
  }
}

/// Точка на карте: кольцо статуса синхронизации + заливка (черновик/акцент),
/// теми же цветами, что в ENU-схеме и журнале.
class _PointDot extends StatelessWidget {
  const _PointDot({super.key, required this.point, required this.onTap});

  final ObservationPoint point;
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
      child: Center(
        child: Container(
          width: 18,
          height: 18,
          decoration: BoxDecoration(
            color: ring,
            shape: BoxShape.circle,
          ),
          child: Center(
            child: Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(color: fill, shape: BoxShape.circle),
            ),
          ),
        ),
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
