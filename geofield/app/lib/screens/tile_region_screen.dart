import 'dart:io';

import 'package:flutter/material.dart';

import '../data/tile_cache.dart';
import '../data/tile_downloader.dart';
import '../models/observation_point.dart';
import '../theme/tokens.dart';
import '../util/format.dart';

/// Экран заготовки офлайн-карты (за флагом `mapBasemap`): выбрать охват (по
/// маршруту), увидеть число тайлов и ориентировочный вес, скачать регион с
/// прогрессом/отменой. Делается В ГОРОДЕ/ПРИ СВЯЗИ; в поле — только чтение
/// кэша. Зависимости инъектируются (каталог кэша, индекс, загрузчик) —
/// тестируется без сети; прод-обвязка (path_provider + URL из настроек) —
/// снаружи.
///
/// Пресеты зума: обзор (мельче, легче) и рабочий (детальнее, тяжелее). Регион —
/// bbox точек маршрута с полем 15% (не впритык к краю). Огромный охват/зум —
/// честно предупреждаем, а не пытаемся скачать миллионы тайлов.
class TileRegionScreen extends StatefulWidget {
  const TileRegionScreen({
    super.key,
    required this.points,
    required this.cacheDir,
    required this.index,
    required this.fetcher,
    this.maxBytes = 500 * 1024 * 1024,
  });

  final List<ObservationPoint> points;
  final Directory cacheDir;
  final TileCacheIndex index;

  /// Загрузчик тайла (прод — HTTP по URL оператора). null — адрес не задан,
  /// скачивание недоступно (честно, без имитации).
  final TileFetcher? fetcher;
  final int maxBytes;

  @override
  State<TileRegionScreen> createState() => _TileRegionScreenState();
}

/// Пресет диапазона зумов: подпись + границы.
class _ZoomPreset {
  const _ZoomPreset(this.label, this.minZoom, this.maxZoom);
  final String label;
  final int minZoom;
  final int maxZoom;
}

class _TileRegionScreenState extends State<TileRegionScreen> {
  static const _presets = [
    _ZoomPreset('Обзор (z6–11)', 6, 11),
    _ZoomPreset('Рабочий (z6–14)', 6, 14),
  ];
  // Ориентир веса: типичный растровый тайл ~20 КБ (реальный размер плывёт от
  // насыщенности; показываем как «≈» для планирования, не как точную цифру).
  static const _avgTileBytes = 20 * 1024;

  int _preset = 0;
  bool _downloading = false;
  int _done = 0, _total = 0;
  TileDownloadResult? _result;
  CancelToken? _cancel;

  ({double west, double south, double east, double north})? _bbox() {
    final located =
        widget.points.where((p) => p.lat != null && p.lon != null).toList();
    if (located.isEmpty) return null;
    var minLat = located.first.lat!, maxLat = minLat;
    var minLon = located.first.lon!, maxLon = minLon;
    for (final p in located) {
      minLat = p.lat! < minLat ? p.lat! : minLat;
      maxLat = p.lat! > maxLat ? p.lat! : maxLat;
      minLon = p.lon! < minLon ? p.lon! : minLon;
      maxLon = p.lon! > maxLon ? p.lon! : maxLon;
    }
    // Поле 15% охвата (мин. ~0.02° ≈ 2 км, чтобы одна точка не дала нулевой bbox).
    final padLat = ((maxLat - minLat) * 0.15).clamp(0.02, 90.0);
    final padLon = ((maxLon - minLon) * 0.15).clamp(0.02, 90.0);
    return (
      west: minLon - padLon,
      south: minLat - padLat,
      east: maxLon + padLon,
      north: maxLat + padLat,
    );
  }

  /// Число тайлов пресета (null — охват слишком крупный для оценки/скачивания).
  int? _tileCount(({double west, double south, double east, double north}) b) {
    final p = _presets[_preset];
    final n = countTilesForRegion(
        west: b.west,
        south: b.south,
        east: b.east,
        north: b.north,
        minZoom: p.minZoom,
        maxZoom: p.maxZoom);
    return n > 500000 ? null : n;
  }

  Future<void> _download(
      ({double west, double south, double east, double north}) b) async {
    final fetcher = widget.fetcher;
    if (fetcher == null || _downloading) return;
    final p = _presets[_preset];
    final List<TileId> needed;
    try {
      needed = tilesForRegion(
          west: b.west,
          south: b.south,
          east: b.east,
          north: b.north,
          minZoom: p.minZoom,
          maxZoom: p.maxZoom);
    } on ArgumentError {
      if (mounted) context.snack('Охват слишком большой — выберите обзорный зум');
      return;
    }
    final cancel = CancelToken();
    setState(() {
      _downloading = true;
      _result = null;
      _done = 0;
      _total = 0;
      _cancel = cancel;
    });
    final downloader = TileDownloader(
        cacheDir: widget.cacheDir, fetcher: fetcher, maxBytes: widget.maxBytes);
    final r = await downloader.downloadRegion(
      needed: needed,
      index: widget.index,
      cancel: cancel,
      onProgress: (done, total) {
        if (!mounted) return;
        setState(() {
          _done = done;
          _total = total;
        });
      },
    );
    if (!mounted) return;
    setState(() {
      _downloading = false;
      _result = r;
      _cancel = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final bbox = _bbox();
    return Scaffold(
      appBar: AppBar(
        backgroundColor: GfColors.bg,
        title: Text('Скачать карту', style: GfText.screenTitle),
      ),
      body: SafeArea(
        child: bbox == null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(GfSpace.x24),
                  child: Text(
                    'Нет точек с координатами — охват маршрута неизвестен. '
                    'Снимите GPS или введите координаты хотя бы одной точки.',
                    style: GfText.hint,
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            : _body(bbox),
      ),
    );
  }

  Widget _body(({double west, double south, double east, double north}) b) {
    final count = _tileCount(b);
    final inCache = widget.index.length;
    return ListView(
      padding: const EdgeInsets.all(GfSpace.x16),
      children: [
        Text('ОХВАТ — ПО МАРШРУТУ', style: GfText.sectionLabel),
        const SizedBox(height: GfSpace.x8),
        Text(
          'СЗ ${b.north.toStringAsFixed(3)}, ${b.west.toStringAsFixed(3)}   '
          'ЮВ ${b.south.toStringAsFixed(3)}, ${b.east.toStringAsFixed(3)}',
          style: GfText.body,
        ),
        const SizedBox(height: GfSpace.x24),
        Text('ДЕТАЛЬНОСТЬ', style: GfText.sectionLabel),
        const SizedBox(height: GfSpace.x8),
        for (var i = 0; i < _presets.length; i++)
          InkWell(
            onTap: _downloading ? null : () => setState(() => _preset = i),
            child: Container(
              constraints: const BoxConstraints(minHeight: GfTouch.min),
              alignment: Alignment.centerLeft,
              child: Row(children: [
                Icon(
                  _preset == i
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 22,
                  color: _preset == i ? GfColors.accent : GfColors.textSecondary,
                ),
                const SizedBox(width: GfSpace.x12),
                Expanded(child: Text(_presets[i].label, style: GfText.body)),
              ]),
            ),
          ),
        const SizedBox(height: GfSpace.x16),
        if (count == null)
          Text(
            'Охват слишком большой для этого зума — выберите обзорный или '
            'сузьте маршрут.',
            style: GfText.hint.copyWith(color: GfColors.error),
          )
        else
          Text(
            '${plural(count, 'тайл', 'тайла', 'тайлов')} · '
            '≈${_fmtSize(count * _avgTileBytes)} (ориентировочно)\n'
            'уже в кэше: $inCache',
            style: GfText.hint,
          ),
        const SizedBox(height: GfSpace.x24),
        if (widget.fetcher == null)
          Text('Адрес тайл-сервера не задан в настройках — скачивание недоступно.',
              style: GfText.hint.copyWith(color: GfColors.error))
        else if (_downloading)
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LinearProgressIndicator(
                value: _total == 0 ? null : _done / _total,
                backgroundColor: GfColors.surfaceHi,
                color: GfColors.accent,
              ),
              const SizedBox(height: GfSpace.x8),
              Text('Скачано $_done из $_total', style: GfText.hint),
              const SizedBox(height: GfSpace.x8),
              OutlinedButton(
                style: gfOutlinedStyle(),
                onPressed: () => _cancel?.cancel(),
                child: const Text('Отмена', style: GfText.button),
              ),
            ],
          )
        else
          SizedBox(
            height: GfTouch.min,
            child: FilledButton(
              style: gfFilledStyle(),
              onPressed: count == null ? null : () => _download(b),
              child: const Text('Скачать', style: GfText.button),
            ),
          ),
        if (_result != null) ...[
          const SizedBox(height: GfSpace.x16),
          Text(_resultText(_result!), style: GfText.body),
        ],
      ],
    );
  }

  String _resultText(TileDownloadResult r) {
    if (r.cancelled) {
      return 'Отменено. Скачано ${r.downloaded}, осталось незагруженным.';
    }
    final base = 'Готово: скачано ${r.downloaded}, пропущено ${r.skipped}'
        ' (уже были).';
    return r.failed > 0 ? '$base Не удалось: ${r.failed}.' : base;
  }

  static String _fmtSize(int bytes) {
    if (bytes >= 1 << 30) return '${(bytes / (1 << 30)).toStringAsFixed(1)} ГБ';
    if (bytes >= 1 << 20) return '${(bytes / (1 << 20)).toStringAsFixed(0)} МБ';
    return '${(bytes / (1 << 10)).toStringAsFixed(0)} КБ';
  }
}
