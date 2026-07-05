import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart' show getDatabasesPath;

import '../data/dictionary_repository.dart';
import '../data/point_repository.dart';
import '../data/sample_repository.dart';
import '../lab/lab_service.dart';
import '../models/observation_point.dart';
import '../models/sample.dart';
import '../sync/hlc.dart';
import '../theme/sample_type.dart';
import '../theme/tokens.dart';
import '../util/csv_export.dart';
import '../util/format.dart';
import 'point_form_screen.dart';
import 'sample_capture_screen.dart';
import 'lab_screen.dart';
import 'sync_screen.dart';

/// Фильтры журнала (ТЗ §6.7).
enum _Filter { all, drafts, unsent }

/// Журнал маршрута — что собрано за день (ТЗ §6.7): карточки точек и проб со
/// статусами, фильтры, сводка, «+ Точка», выгрузка CSV.
class JournalScreen extends StatefulWidget {
  const JournalScreen({
    super.key,
    required this.points,
    required this.samples,
    required this.dictionaries,
    required this.projectId,
    required this.routeId,
    required this.authorId,
    required this.sampleNumbering,
    required this.deviceId,
    required this.clock,
    required this.lab,
  });

  final PointRepository points;
  final SampleRepository samples;
  final DictionaryRepository dictionaries;
  final String projectId;
  final String routeId;
  final String authorId;
  final String sampleNumbering;
  final String deviceId;
  final HlcClock clock;
  final LabService lab;

  @override
  State<JournalScreen> createState() => _JournalScreenState();
}

class _JournalScreenState extends State<JournalScreen> {
  List<ObservationPoint> _points = const [];
  List<Sample> _samples = const [];
  _Filter _filter = _Filter.all;
  bool _loading = true;
  int _reloadGen = 0;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    // Поколение запроса: медленный старый ответ не затирает свежие данные.
    final gen = ++_reloadGen;
    final pts = await widget.points.listByRoute(widget.routeId);
    final smp = await widget.samples
        .listByRoute(widget.routeId, projectId: widget.projectId);
    if (!mounted || gen != _reloadGen) return;
    setState(() {
      _points = pts;
      _samples = smp;
      _loading = false;
    });
  }

  // --- отбор по фильтру ---------------------------------------------------------

  bool _pointVisible(ObservationPoint pt) => switch (_filter) {
        _Filter.all => true,
        _Filter.drafts => pt.isDraft,
        _Filter.unsent => pt.syncStatus != SyncStatus.confirmed,
      };

  bool _sampleVisible(Sample s) => switch (_filter) {
        _Filter.all => true,
        _Filter.drafts => false, // у проб черновиков нет: номер обязателен
        _Filter.unsent => s.syncStatus != SyncStatus.confirmed,
      };

  @override
  Widget build(BuildContext context) {
    final points = _points.where(_pointVisible).toList();
    final samples = _samples.where(_sampleVisible).toList();
    final drafts = _points.where((p) => p.isDraft).length;
    final unsent =
        _points.where((p) => p.syncStatus != SyncStatus.confirmed).length +
            _samples.where((s) => s.syncStatus != SyncStatus.confirmed).length;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: GfColors.bg,
        title: const Text('Маршрут · журнал', style: GfText.screenTitle),
        actions: [
          IconButton(
            tooltip: 'Выгрузка CSV',
            icon: const Icon(Icons.ios_share, color: GfColors.textSecondary),
            onPressed: _onExport,
          ),
          IconButton(
            tooltip: 'Лаборатория',
            icon: const Icon(Icons.science_outlined,
                color: GfColors.textSecondary),
            onPressed: () async {
              await Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => LabScreen(
                  samples: widget.samples,
                  dictionaries: widget.dictionaries,
                  lab: widget.lab,
                  projectId: widget.projectId,
                ),
              ));
              await _reload();
            },
          ),
          IconButton(
            tooltip: 'Синхронизация',
            icon: const Icon(Icons.sync, color: GfColors.textSecondary),
            onPressed: () async {
              await Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => SyncScreen(
                    db: widget.points.db,
                    deviceId: widget.deviceId,
                    clock: widget.clock),
              ));
              await _reload();
            },
          ),
        ],
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                        GfSpace.x16, GfSpace.x8, GfSpace.x16, 0),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '${plural(_points.length, 'точка', 'точки', 'точек')} · '
                        '${plural(_samples.length, 'проба', 'пробы', 'проб')} · '
                        '${plural(drafts, 'черновик', 'черновика', 'черновиков')} · '
                        '$unsent не отправлено',
                        style: GfText.hint,
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(GfSpace.x16),
                    child: Row(children: [
                      _chip('Все', _Filter.all),
                      const SizedBox(width: GfSpace.x8),
                      _chip('Черновики', _Filter.drafts),
                      const SizedBox(width: GfSpace.x8),
                      _chip('Не отправлено', _Filter.unsent),
                    ]),
                  ),
                  Expanded(
                    child: (points.isEmpty && samples.isEmpty)
                        ? const Center(
                            child: Text('Пока пусто — начните с «+ Точка»',
                                style: GfText.hint))
                        // .builder — виртуализация (ТЗ §10.5): строятся только
                        // видимые карточки, многодневный журнал не жрёт память
                        // и кадры на открытии.
                        : ListView.builder(
                            padding: const EdgeInsets.fromLTRB(
                                GfSpace.x16, 0, GfSpace.x16, GfSpace.x24 * 3),
                            itemCount: points.length + samples.length,
                            itemBuilder: (_, i) => i < points.length
                                ? _pointCard(points[i])
                                : _sampleCard(samples[i - points.length]),
                          ),
                  ),
                ],
              ),
      ),
      floatingActionButton: SizedBox(
        height: GfTouch.min,
        child: FloatingActionButton.extended(
          onPressed: _onAddPoint,
          backgroundColor: GfColors.accent,
          foregroundColor: GfColors.onAccent,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(GfRadius.r16)),
          label: const Text('+ Точка', style: GfText.button),
        ),
      ),
    );
  }

  Widget _chip(String label, _Filter f) {
    final selected = _filter == f;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => setState(() => _filter = f),
      selectedColor: gfChipSelectedColor(),
      backgroundColor: GfColors.surface,
      side: gfChipSide(selected),
      labelStyle: gfChipLabel(selected),
    );
  }

  Widget _pointCard(ObservationPoint pt) {
    return Padding(
      padding: const EdgeInsets.only(bottom: GfSpace.x8),
      child: InkWell(
        borderRadius: BorderRadius.circular(GfRadius.r12),
        onTap: () => _openPoint(pt),
        child: Container(
          padding: const EdgeInsets.all(GfSpace.x12),
          decoration: gfCard(
              borderColor: pt.isDraft ? GfColors.draft : GfColors.outline),
          child: Row(children: [
            const Icon(Icons.place_outlined,
                size: 22, color: GfColors.textSecondary),
            const SizedBox(width: GfSpace.x12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Точка ${pt.number}',
                      style: GfText.body.copyWith(fontWeight: FontWeight.w600)),
                  Text(
                    pt.isDraft
                        ? 'черновик'
                        : (pt.lat != null
                            ? '${pt.lat!.toStringAsFixed(5)}, ${pt.lon!.toStringAsFixed(5)}'
                            : 'без координат'),
                    style: GfText.hint,
                  ),
                ],
              ),
            ),
            _syncDot(pt.syncStatus),
          ]),
        ),
      ),
    );
  }

  Widget _sampleCard(Sample s) {
    final t = SampleType.fromCode(s.sampleType);
    return Padding(
      padding: const EdgeInsets.only(bottom: GfSpace.x8),
      child: InkWell(
        borderRadius: BorderRadius.circular(GfRadius.r12),
        onTap: () => _openSample(s),
        child: Container(
          padding: const EdgeInsets.all(GfSpace.x12),
          decoration: gfCard(),
          child: Row(children: [
            Container(
              width: 14,
              height: 14,
              decoration: BoxDecoration(color: t.color, shape: BoxShape.circle),
            ),
            const SizedBox(width: GfSpace.x12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(s.sampleNumber, style: GfText.numberSmall),
                  Text('${t.label} · ${s.status.label}', style: GfText.hint),
                ],
              ),
            ),
            _syncDot(s.syncStatus),
          ]),
        ),
      ),
    );
  }

  Widget _syncDot(SyncStatus s) {
    final color = switch (s) {
      SyncStatus.pending => GfColors.textFaint,
      SyncStatus.queued => GfColors.syncQueued,
      SyncStatus.sent => GfColors.syncSent,
      SyncStatus.confirmed => GfColors.syncConfirmed,
    };
    return Tooltip(
      message: s.label,
      child: Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
    );
  }

  // --- действия -------------------------------------------------------------------

  Future<void> _onAddPoint() async {
    final seq = await widget.points.nextSeq(widget.routeId);
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => PointFormScreen(
        points: widget.points,
        samples: widget.samples,
        dictionaries: widget.dictionaries,
        projectId: widget.projectId,
        routeId: widget.routeId,
        authorId: widget.authorId,
        sampleNumbering: widget.sampleNumbering,
        initialNumber: 'Т-${seq.toString().padLeft(3, '0')}',
      ),
    ));
    await _reload();
  }

  Future<void> _openPoint(ObservationPoint pt) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => PointFormScreen(
        points: widget.points,
        samples: widget.samples,
        dictionaries: widget.dictionaries,
        projectId: widget.projectId,
        routeId: widget.routeId,
        authorId: widget.authorId,
        sampleNumbering: widget.sampleNumbering,
        existing: pt,
      ),
    ));
    await _reload();
  }

  Future<void> _openSample(Sample s) async {
    // Подпись привязки: номер родительской точки, если она есть.
    var label = 'без привязки';
    if (s.parentType == 'point' && s.parentId != null) {
      final pt = await widget.points.byId(s.parentId!);
      if (pt != null) label = 'Точка № ${pt.number}';
    }
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => SampleCaptureScreen(
        repository: widget.samples,
        projectId: widget.projectId,
        authorId: widget.authorId,
        initialNumber: s.sampleNumber,
        existing: s,
        binding: ParentBinding(
          type: s.parentType ?? 'point',
          id: s.parentId ?? '',
          label: label,
        ),
      ),
    ));
    await _reload();
  }

  Future<void> _onExport() async {
    try {
      final dir = await getDatabasesPath();
      Future<Map<String, String>> labels(String type) async => {
            for (final e
                in await widget.dictionaries.list(widget.projectId, type))
              e.code: e.label,
          };
      final rockLabels = await labels('rock');
      final typeLabels = await labels('object_type');
      final alterationLabels = await labels('alteration');
      final mineralLabels = await labels('mineral');
      final route = await widget.points.routeInfo(widget.routeId);
      final measurements =
          await widget.points.measurementsForRoute(widget.routeId);
      final pointById = {for (final pt in _points) pt.id: pt};

      String mineralsText(String? json) =>
          decodeMineralCodes(json).map((c) => mineralLabels[c] ?? c).join(', ');

      final pointsCsv = toCsv(pointCsvHeader, [
        for (final pt in _points)
          [
            route?.title ?? widget.routeId,
            route?.date,
            pt.number,
            pt.lat,
            pt.lon,
            pt.elevation,
            pt.coordSource,
            pt.gpsAccuracyM,
            pt.observedAt,
            typeLabels[pt.objectType] ?? pt.objectType,
            rockLabels[pt.rockCode] ?? pt.rockCode,
            pt.colorCode,
            pt.grain,
            alterationLabels[pt.alterationCode] ?? pt.alterationCode,
            mineralsText(pt.minerals),
            pt.note,
            pt.isDraft ? 'да' : 'нет',
            pt.authorId,
            pt.createdAt,
            pt.modifiedAt,
          ],
      ]);
      final samplesCsv = toCsv(sampleCsvHeader, [
        for (final s in _samples)
          [
            s.sampleNumber,
            SampleType.fromCode(s.sampleType).label,
            s.barcode,
            s.parentType == 'point' ? pointById[s.parentId]?.number : null,
            s.parentType == 'point' ? pointById[s.parentId]?.lat : null,
            s.parentType == 'point' ? pointById[s.parentId]?.lon : null,
            s.depthFrom,
            s.depthTo,
            s.lengthM,
            s.mass,
            s.status.label,
            s.note,
            s.authorId,
            s.createdAt,
            s.modifiedAt,
            s.parentType,
            s.parentId,
          ],
      ]);
      final structuresCsv = toCsv(structureCsvHeader, [
        for (final m in measurements)
          [
            pointById[m.parentId]?.number ?? m.parentId,
            measureTypes[m.measureType] ?? m.measureType,
            m.dipAzimuth,
            m.dipAngle,
            m.source,
            m.note,
            m.authorId,
            m.createdAt,
          ],
      ]);

      // Синхронная запись: объём — килобайты, действие явное и редкое;
      // async-файловый I/O к тому же не завершается под FakeAsync тестов.
      Directory(dir).createSync(recursive: true);
      final pFile = File(p.join(dir, 'geofield_points.csv'))
        ..writeAsStringSync(pointsCsv);
      File(p.join(dir, 'geofield_samples.csv')).writeAsStringSync(samplesCsv);
      File(p.join(dir, 'geofield_structures.csv'))
          .writeAsStringSync(structuresCsv);
      if (!mounted) return;
      context.snack(
          'Выгружено 3 файла в ${p.dirname(pFile.path)}: точки, пробы, замеры',
          duration: const Duration(seconds: 6));
    } catch (e) {
      if (!mounted) return;
      context.snack('Выгрузка не удалась — проверьте память устройства');
    }
  }
}
