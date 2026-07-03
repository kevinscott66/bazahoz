import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../config/features.dart';
import '../data/dictionary_repository.dart';
import '../data/point_repository.dart';
import '../data/sample_repository.dart';
import '../models/observation_point.dart';
import '../models/sample.dart';
import '../theme/sample_type.dart';
import '../theme/tokens.dart';
import '../util/sample_number.dart';
import '../util/save_queue.dart';
import 'sample_capture_screen.dart';

/// Точка наблюдения — форма ввода (ТЗ §6.3).
/// Черновик ≠ ошибка: незаполненные обязательные поля дают статус «черновик»
/// (точка сохраняется и НЕ теряется), а противоречие (координата вне диапазона,
/// половина пары широта/долгота) — invalid и не пишется в базу.
class PointFormScreen extends StatefulWidget {
  const PointFormScreen({
    super.key,
    required this.points,
    required this.samples,
    required this.dictionaries,
    required this.projectId,
    required this.routeId,
    required this.authorId,
    required this.sampleNumbering,
    this.initialNumber,
    this.existing,
  }) : assert(existing != null || initialNumber != null,
            'нужен либо existing, либо initialNumber');

  final PointRepository points;
  final SampleRepository samples;
  final DictionaryRepository dictionaries;
  final String projectId;
  final String routeId;
  final String authorId;
  final String sampleNumbering;
  final String? initialNumber;
  final ObservationPoint? existing;

  @override
  State<PointFormScreen> createState() => _PointFormScreenState();
}

class _PointFormScreenState extends State<PointFormScreen> {
  late final String _id;
  late final String _createdAt;
  late final String _observedAt;

  final _numberCtrl = TextEditingController();
  final _latCtrl = TextEditingController();
  final _lonCtrl = TextEditingController();
  final _elevCtrl = TextEditingController();
  final _rockCtrl = TextEditingController();
  final _rockFocus = FocusNode();
  final _alterationCtrl = TextEditingController();
  final _alterationFocus = FocusNode();
  final _colorCtrl = TextEditingController();
  final _grainCtrl = TextEditingController();
  final _noteCtrl = TextEditingController();

  String? _objectType;
  final Set<String> _selectedMinerals = {};
  List<DictEntry> _objectTypes = const [];
  List<DictEntry> _rocks = const [];
  List<DictEntry> _alterations = const [];
  List<DictEntry> _mineralDict = const [];
  List<StructuralMeasurement> _measurements = const [];
  List<Sample> _boundSamples = const [];

  final _queue = SaveQueue();
  bool _persistedOnce = false;
  int _version = 1;
  String _saveState = 'сохранение…';
  bool _saveIsError = false;
  bool _isDraft = true;

  @override
  void initState() {
    super.initState();
    final ex = widget.existing;
    if (ex != null) {
      _id = ex.id;
      _createdAt = ex.createdAt;
      _observedAt = ex.observedAt ?? ex.createdAt;
      _persistedOnce = true;
      _version = ex.version;
      _numberCtrl.text = ex.number;
      if (ex.lat != null) _latCtrl.text = ex.lat.toString();
      if (ex.lon != null) _lonCtrl.text = ex.lon.toString();
      if (ex.elevation != null) _elevCtrl.text = ex.elevation.toString();
      _objectType = ex.objectType;
      _colorCtrl.text = ex.colorCode ?? '';
      _grainCtrl.text = ex.grain ?? '';
      _noteCtrl.text = ex.note ?? '';
      _isDraft = ex.isDraft;
      _saveState = 'сохранено · не отправлено';
      _selectedMinerals.addAll(decodeMineralCodes(ex.minerals));
    } else {
      _id = const Uuid().v4();
      _createdAt = _nowIso();
      _observedAt = _createdAt;
      _numberCtrl.text = widget.initialNumber!;
    }
    _loadRefs(rockCode: ex?.rockCode, alterationCode: ex?.alterationCode);
    if (ex == null) {
      // Немедленный черновик: точка существует с первого тапа (ТЗ §0, пр.2).
      WidgetsBinding.instance.addPostFrameCallback((_) => _saveNow());
    } else {
      _reloadChildren();
    }
  }

  Future<void> _loadRefs({String? rockCode, String? alterationCode}) async {
    // Запросы независимы — параллельно, а не 6 последовательных round-trip
    // на каждый тап «＋ Точка» (perf-audit: отзывчивость главного жеста).
    final d = widget.dictionaries;
    final results = await Future.wait<Object?>([
      d.list(widget.projectId, 'object_type'),
      d.list(widget.projectId, 'rock'),
      d.list(widget.projectId, 'alteration'),
      d.list(widget.projectId, 'mineral'),
      if (rockCode != null) d.labelForCode(widget.projectId, 'rock', rockCode),
      if (alterationCode != null)
        d.labelForCode(widget.projectId, 'alteration', alterationCode),
    ]);
    final types = results[0]! as List<DictEntry>;
    final rocks = results[1]! as List<DictEntry>;
    final alterations = results[2]! as List<DictEntry>;
    final minerals = results[3]! as List<DictEntry>;
    var i = 4;
    final rockLabel =
        rockCode == null ? '' : (results[i++] as String? ?? rockCode);
    final alterationLabel = alterationCode == null
        ? ''
        : (results[i] as String? ?? alterationCode);
    if (!mounted) return;
    setState(() {
      _objectTypes = types;
      _rocks = rocks;
      _alterations = alterations;
      _mineralDict = minerals;
      if (rockLabel.isNotEmpty) _rockCtrl.text = rockLabel;
      if (alterationLabel.isNotEmpty) _alterationCtrl.text = alterationLabel;
    });
  }


  Future<void> _reloadChildren() async {
    final ms = await widget.points.measurementsFor(_id);
    final ss = await widget.samples.listByParent('point', _id);
    if (!mounted) return;
    setState(() {
      _measurements = ms;
      _boundSamples = ss;
    });
  }

  @override
  void dispose() {
    _queue.dispose();
    _numberCtrl.dispose();
    _latCtrl.dispose();
    _lonCtrl.dispose();
    _elevCtrl.dispose();
    _rockCtrl.dispose();
    _rockFocus.dispose();
    _alterationCtrl.dispose();
    _alterationFocus.dispose();
    _colorCtrl.dispose();
    _grainCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  // --- сохранение ---------------------------------------------------------------

  void _scheduleSave() {
    _setSave('сохранение…');
    _queue.schedule(_doSave);
  }

  Future<SaveResult> _saveNow() => _queue.flush(_doSave);

  Future<SaveResult> _doSave() async {
    final number = _numberCtrl.text.trim();
    final lat = _parse(_latCtrl.text);
    final lon = _parse(_lonCtrl.text);
    final elev = _parse(_elevCtrl.text);

    // Противоречия — invalid, не пишем (ТЗ §0, правило 3).
    if (number.isEmpty) {
      _setSave('Номер точки обязателен', error: true);
      return SaveResult.invalid;
    }
    final latText = _latCtrl.text.trim();
    final lonText = _lonCtrl.text.trim();
    if (latText.isNotEmpty != lonText.isNotEmpty) {
      _setSave('Укажите обе координаты или ни одной', error: true);
      return SaveResult.invalid;
    }
    if ((latText.isNotEmpty && lat == null) ||
        (lonText.isNotEmpty && lon == null)) {
      _setSave('Координаты — числа', error: true);
      return SaveResult.invalid;
    }
    if (lat != null && (lat < -90 || lat > 90)) {
      _setSave('Широта вне диапазона ±90', error: true);
      return SaveResult.invalid;
    }
    if (lon != null && (lon < -180 || lon > 180)) {
      _setSave('Долгота вне диапазона ±180', error: true);
      return SaveResult.invalid;
    }

    // Порода и изменения: код из справочника; новое — «на проверку» (ТЗ §6.3).
    String? rockCode;
    String? alterationCode;
    final rockText = _rockCtrl.text.trim();
    final alterationText = _alterationCtrl.text.trim();
    try {
      if (rockText.isNotEmpty) {
        rockCode = await widget.dictionaries
                .codeForLabel(widget.projectId, 'rock', rockText) ??
            await widget.dictionaries
                .ensurePending(widget.projectId, 'rock', rockText);
      }
      if (alterationText.isNotEmpty) {
        alterationCode = await widget.dictionaries
                .codeForLabel(widget.projectId, 'alteration', alterationText) ??
            await widget.dictionaries
                .ensurePending(widget.projectId, 'alteration', alterationText);
      }

      // Черновик, пока не заполнено обязательное (тип, порода, координаты).
      final draft = _objectType == null || rockCode == null || lat == null;

      final isNew = !_persistedOnce;
      final nextVersion = isNew ? 1 : _version + 1;
      final point = ObservationPoint(
        id: _id,
        routeId: widget.routeId,
        number: number,
        lat: lat,
        lon: lon,
        elevation: elev,
        coordSource: lat == null ? null : 'manual',
        observedAt: _observedAt,
        objectType: _objectType,
        rockCode: rockCode,
        colorCode: _emptyNull(_colorCtrl.text),
        grain: _emptyNull(_grainCtrl.text),
        alterationCode: alterationCode,
        minerals: _selectedMinerals.isEmpty
            ? null
            : encodeMineralCodes(_selectedMinerals),
        note: _emptyNull(_noteCtrl.text),
        isDraft: draft,
        authorId: widget.authorId,
        createdAt: _createdAt,
        modifiedAt: _nowIso(),
        version: nextVersion,
      );
      await widget.points.save(point, isNew: isNew);
      _persistedOnce = true;
      _version = nextVersion;
      _isDraft = draft;
      _setSave(draft
          ? 'черновик сохранён · заполните обязательные поля'
          : 'сохранено · не отправлено');
      return SaveResult.saved;
    } catch (e) {
      _setSave('ошибка сохранения', error: true);
      return SaveResult.failed;
    }
  }

  void _setSave(String s, {bool error = false}) {
    _saveState = s;
    _saveIsError = error;
    if (mounted) setState(() {});
  }

  // --- UI -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final navigator = Navigator.of(context); // до async-разрыва
        final r = await _saveNow();
        if (r == SaveResult.failed) {
          _snack('Не удалось сохранить — проверьте память устройства');
          return;
        }
        if (mounted) navigator.pop();
      },
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: GfColors.bg,
          title: const Text('Точка наблюдения', style: GfText.screenTitle),
          actions: [
            if (_isDraft)
              Padding(
                padding: const EdgeInsets.only(right: GfSpace.x16),
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: GfSpace.x8, vertical: GfSpace.x4),
                    decoration: BoxDecoration(
                      color: const Color(0xFF4A4222),
                      borderRadius: BorderRadius.circular(GfRadius.r8),
                    ),
                    child: const Text('черновик',
                        style: TextStyle(
                            fontSize: 12, color: Color(0xFFE0C766))),
                  ),
                ),
              ),
          ],
        ),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(GfSpace.x16),
            children: [
              _header(),
              const SizedBox(height: GfSpace.x24),
              _section('ОПИСАНИЕ', _descriptionBlock()),
              const SizedBox(height: GfSpace.x24),
              _section('СТРУКТУРА', _structureBlock()),
              const SizedBox(height: GfSpace.x24),
              _section('ПРОБЫ', _samplesBlock()),
              const SizedBox(height: GfSpace.x24),
              _saveIndicator(),
              const SizedBox(height: GfSpace.x8),
              _deleteButton(),
            ],
          ),
        ),
        bottomNavigationBar: _doneBar(),
      ),
    );
  }

  Widget _section(String title, Widget child) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: GfText.sectionLabel),
        const SizedBox(height: GfSpace.x12),
        child,
      ],
    );
  }

  Widget _header() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('НОМЕР ТОЧКИ', style: GfText.sectionLabel),
        const SizedBox(height: GfSpace.x8),
        TextField(
          controller: _numberCtrl,
          style: GfText.numberField,
          onChanged: (_) => _scheduleSave(),
          decoration: _dec('Т-001'),
        ),
        const SizedBox(height: GfSpace.x16),
        const Text('КООРДИНАТЫ (WGS-84)', style: GfText.sectionLabel),
        const SizedBox(height: GfSpace.x8),
        Row(children: [
          Expanded(child: _numField(_latCtrl, 'Широта')),
          const SizedBox(width: GfSpace.x12),
          Expanded(child: _numField(_lonCtrl, 'Долгота')),
        ]),
        const SizedBox(height: GfSpace.x12),
        Row(children: [
          Expanded(child: _numField(_elevCtrl, 'Высота, м')),
          const SizedBox(width: GfSpace.x12),
          Expanded(
            child: SizedBox(
              height: GfTouch.min,
              child: OutlinedButton.icon(
                onPressed: _onGps,
                icon: const Icon(Icons.gps_fixed, size: 20),
                label: const Text('С приёмника'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: GfColors.textPrimary,
                  side: const BorderSide(color: GfColors.outline),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(GfRadius.r12)),
                ),
              ),
            ),
          ),
        ]),
      ],
    );
  }

  Widget _descriptionBlock() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DropdownButtonFormField<String>(
          initialValue: _objectType,
          items: _objectTypes
              .map((e) =>
                  DropdownMenuItem(value: e.code, child: Text(e.label)))
              .toList(),
          onChanged: (v) {
            setState(() => _objectType = v);
            _scheduleSave();
          },
          dropdownColor: GfColors.surfaceHi,
          style: GfText.body,
          decoration: _dec('Тип объекта'),
        ),
        const SizedBox(height: GfSpace.x12),
        _dictAutocomplete(_rockCtrl, _rockFocus, _rocks,
            'Порода (справочник; новое — «на проверку»)'),
        const SizedBox(height: GfSpace.x12),
        _dictAutocomplete(_alterationCtrl, _alterationFocus, _alterations,
            'Вторичные изменения (окварцевание, серицитизация…)'),
        const SizedBox(height: GfSpace.x12),
        const Text('МИНЕРАЛИЗАЦИЯ', style: GfText.sectionLabel),
        const SizedBox(height: GfSpace.x8),
        _mineralChips(),
        const SizedBox(height: GfSpace.x12),
        Row(children: [
          Expanded(child: _textField(_colorCtrl, 'Цвет')),
          const SizedBox(width: GfSpace.x12),
          Expanded(child: _textField(_grainCtrl, 'Зернистость')),
        ]),
        const SizedBox(height: GfSpace.x12),
        TextField(
          controller: _noteCtrl,
          style: GfText.body,
          minLines: 2,
          maxLines: 4,
          onChanged: (_) => _scheduleSave(),
          decoration: _dec('Примечание'),
        ),
      ],
    );
  }

  Widget _mineralChips() {
    if (_mineralDict.isEmpty) {
      return const Text('Справочник минералов пуст — обновите с сервера',
          style: GfText.hint);
    }
    return Wrap(
      spacing: GfSpace.x8,
      runSpacing: GfSpace.x8,
      children: _mineralDict.map((m) {
        final selected = _selectedMinerals.contains(m.code);
        return FilterChip(
          label: Text(m.label),
          selected: selected,
          onSelected: (v) {
            setState(() {
              if (v) {
                _selectedMinerals.add(m.code);
              } else {
                _selectedMinerals.remove(m.code);
              }
            });
            _scheduleSave();
          },
          selectedColor: GfColors.accent.withValues(alpha: 0.25),
          backgroundColor: GfColors.surface,
          side: BorderSide(
              color: selected ? GfColors.accent : GfColors.outline),
          labelStyle: GfText.body.copyWith(
              fontSize: 14,
              color:
                  selected ? GfColors.textPrimary : GfColors.textSecondary),
        );
      }).toList(),
    );
  }

  Widget _dictAutocomplete(TextEditingController mainCtrl, FocusNode focus,
      List<DictEntry> options, String hint) {
    return RawAutocomplete<String>(
      textEditingController: mainCtrl,
      focusNode: focus,
      optionsBuilder: (t) {
        final q = t.text.trim().toLowerCase();
        if (q.isEmpty) return const Iterable<String>.empty();
        return options
            .map((r) => r.label)
            .where((l) => l.toLowerCase().contains(q));
      },
      onSelected: (_) => _scheduleSave(),
      fieldViewBuilder: (context, ctrl, focus, onSubmit) => TextField(
        controller: ctrl,
        focusNode: focus,
        style: GfText.body,
        onChanged: (_) => _scheduleSave(),
        decoration: _dec(hint),
      ),
      optionsViewBuilder: (context, onSelected, options) => Align(
        alignment: Alignment.topLeft,
        child: Material(
          color: GfColors.surfaceHi,
          borderRadius: BorderRadius.circular(GfRadius.r12),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 220, maxWidth: 320),
            child: ListView(
              padding: EdgeInsets.zero,
              shrinkWrap: true,
              children: options
                  .map((o) => ListTile(
                        title: Text(o, style: GfText.body),
                        onTap: () => onSelected(o),
                      ))
                  .toList(),
            ),
          ),
        ),
      ),
    );
  }

  Widget _structureBlock() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final m in _measurements)
          Padding(
            padding: const EdgeInsets.only(bottom: GfSpace.x8),
            child: Row(children: [
              const Icon(Icons.architecture,
                  size: 18, color: GfColors.textSecondary),
              const SizedBox(width: GfSpace.x8),
              Expanded(
                child: Text(
                  '${measureTypes[m.measureType] ?? m.measureType ?? '—'}: '
                  'аз. пад. ${_fmtNum(m.dipAzimuth)}° / угол ${_fmtNum(m.dipAngle)}°',
                  style: GfText.number.copyWith(fontSize: 16),
                ),
              ),
            ]),
          ),
        Row(children: [
          Expanded(
              child: _outlined('＋ Замер', Icons.add, _onAddMeasurement)),
          const SizedBox(width: GfSpace.x12),
          Expanded(
              child: _outlined('С датчика', Icons.explore, _onSensor)),
        ]),
      ],
    );
  }

  Widget _samplesBlock() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final s in _boundSamples)
          Padding(
            padding: const EdgeInsets.only(bottom: GfSpace.x8),
            child: Row(children: [
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                    color: SampleType.fromCode(s.sampleType).color,
                    shape: BoxShape.circle),
              ),
              const SizedBox(width: GfSpace.x8),
              Text(s.sampleNumber, style: GfText.number.copyWith(fontSize: 16)),
              const SizedBox(width: GfSpace.x8),
              Text(SampleType.fromCode(s.sampleType).label, style: GfText.hint),
            ]),
          ),
        _outlined('＋ Проба', Icons.add, _onAddSample),
      ],
    );
  }

  Widget _outlined(String text, IconData icon, VoidCallback onTap) {
    return SizedBox(
      height: GfTouch.min,
      child: OutlinedButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 20),
        label: Text(text, overflow: TextOverflow.ellipsis),
        style: OutlinedButton.styleFrom(
          foregroundColor: GfColors.textPrimary,
          side: const BorderSide(color: GfColors.outline),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(GfRadius.r12)),
        ),
      ),
    );
  }

  Widget _saveIndicator() {
    return Row(children: [
      Icon(_saveIsError ? Icons.error_outline : Icons.cloud_off,
          size: 16,
          color: _saveIsError ? GfColors.error : GfColors.textSecondary),
      const SizedBox(width: GfSpace.x8),
      Expanded(
        child: Text(_saveState,
            style: GfText.hint.copyWith(
                color: _saveIsError ? GfColors.error : GfColors.textSecondary)),
      ),
    ]);
  }

  Widget _deleteButton() {
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        onPressed: _onDelete,
        icon: const Icon(Icons.delete_outline, size: 18),
        label: const Text('Удалить точку'),
        style: TextButton.styleFrom(foregroundColor: GfColors.error),
      ),
    );
  }

  Widget _doneBar() {
    return SafeArea(
      minimum: const EdgeInsets.all(GfSpace.x16),
      child: SizedBox(
        height: GfTouch.min,
        width: double.infinity,
        child: FilledButton(
          onPressed: () async {
            final r = await _saveNow();
            // Черновик — тоже валидное состояние: «Готово» сворачивает форму
            // (ТЗ §6.3 — запись уже сохранена). Блокируем только invalid/failed.
            if (r == SaveResult.saved && mounted) {
              Navigator.of(context).pop(_id);
            }
          },
          style: FilledButton.styleFrom(
            backgroundColor: GfColors.accent,
            foregroundColor: GfColors.onAccent,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(GfRadius.r12)),
          ),
          child: const Text('Готово',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        ),
      ),
    );
  }

  // --- действия -----------------------------------------------------------------

  void _onGps() {
    // Флаг выключен: честное сообщение, ручной ввод — основной путь.
    if (!AppFeatures.gpsCapture) {
      _snack('GPS-приёмник не подключён в этой сборке — введите вручную');
      return;
    }
  }

  void _onSensor() {
    if (!AppFeatures.sensorCompass) {
      _snack('Датчики не подключены в этой сборке — введите вручную');
      return;
    }
  }

  Future<void> _onAddMeasurement() async {
    final result = await showDialog<({String type, String az, String ang})>(
      context: context,
      builder: (_) => const _MeasurementDialog(),
    );
    if (result == null) return;
    final az = _parse(result.az);
    final ang = _parse(result.ang);
    final measureType = result.type;
    // Противоречие ловим при вводе (ТЗ §0, пр.3) — до CHECK в базе.
    if (az == null || ang == null || az < 0 || az >= 360 || ang < 0 || ang > 90) {
      _snack('Азимут 0–359, угол 0–90 — проверьте значения');
      return;
    }
    // Родитель должен существовать до ребёнка.
    final r = await _saveNow();
    if (r != SaveResult.saved) {
      _snack('Сначала сохраните точку (см. подпись у индикатора)');
      return;
    }
    try {
      final now = _nowIso();
      await widget.points.addMeasurement(StructuralMeasurement(
        id: const Uuid().v4(),
        parentType: 'point',
        parentId: _id,
        measureType: measureType,
        dipAzimuth: az,
        dipAngle: ang,
        source: 'manual',
        authorId: widget.authorId,
        createdAt: now,
        modifiedAt: now,
      ));
    } catch (e) {
      _snack('Не удалось сохранить замер — проверьте память устройства');
      return;
    }
    await _reloadChildren();
  }

  Future<void> _onAddSample() async {
    // Проба привязывается к существующей точке — сначала дожать сохранение.
    final r = await _saveNow();
    if (r != SaveResult.saved) {
      _snack('Сначала сохраните точку (см. подпись у индикатора)');
      return;
    }
    final seq = await widget.samples.nextSeq(widget.projectId);
    final number = SampleNumberTemplate(widget.sampleNumbering).format(seq);
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<String>(
      builder: (_) => SampleCaptureScreen(
        repository: widget.samples,
        projectId: widget.projectId,
        authorId: widget.authorId,
        initialNumber: number,
        binding: ParentBinding(
          type: 'point',
          id: _id,
          label: 'Точка № ${_numberCtrl.text.trim()}',
        ),
      ),
    ));
    await _reloadChildren();
  }

  Future<void> _onDelete() async {
    // Свежий запрос, не кэш _boundSamples: кэш мог не успеть загрузиться
    // (гонка с _reloadChildren) — сироты недопустимы.
    final List<Sample> bound;
    try {
      bound = await widget.samples.listByParent('point', _id);
    } catch (e) {
      _snack('Не удалось проверить пробы точки — попробуйте ещё раз');
      return;
    }
    if (bound.isNotEmpty) {
      // Не оставляем проб-сирот: осознанное правило вместо каскада-сюрприза.
      _snack('Сначала удалите или отвяжите пробы точки (${bound.length})');
      return;
    }
    if (!mounted) return; // выше был await — экран могли закрыть
    final navigator = Navigator.of(context); // до следующего async-разрыва
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: GfColors.surfaceHi,
        title: const Text('Удалить точку?'),
        content:
            const Text('Точку можно восстановить в камералке до синхронизации.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Отмена')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              style: TextButton.styleFrom(foregroundColor: GfColors.error),
              child: const Text('Удалить')),
        ],
      ),
    );
    if (confirmed != true) return;
    if (_persistedOnce) {
      try {
        final ex = await widget.points.byId(_id);
        if (ex != null) await widget.points.softDelete(ex);
      } catch (e) {
        _setSave('не удалось удалить — проверьте память устройства',
            error: true);
        _snack('Не удалось удалить — проверьте память устройства');
        return;
      }
    }
    if (mounted) navigator.pop();
  }

  // --- helpers ------------------------------------------------------------------

  Widget _numField(TextEditingController c, String hint) => TextField(
        controller: c,
        style: GfText.number,
        keyboardType:
            const TextInputType.numberWithOptions(decimal: true, signed: true),
        onChanged: (_) => _scheduleSave(),
        decoration: _dec(hint),
      );

  Widget _textField(TextEditingController c, String hint) => TextField(
        controller: c,
        style: GfText.body,
        onChanged: (_) => _scheduleSave(),
        decoration: _dec(hint),
      );

  InputDecoration _dec(String hint) {
    OutlineInputBorder b(Color c) => OutlineInputBorder(
          borderRadius: BorderRadius.circular(GfRadius.r12),
          borderSide: BorderSide(color: c),
        );
    return InputDecoration(
      hintText: hint,
      labelText: hint,
      labelStyle: GfText.hint,
      hintStyle: GfText.hint,
      filled: true,
      fillColor: GfColors.surface,
      contentPadding: const EdgeInsets.symmetric(
          horizontal: GfSpace.x16, vertical: GfSpace.x16),
      enabledBorder: b(GfColors.outline),
      focusedBorder: b(GfColors.accent),
    );
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  static double? _parse(String s) {
    final t = s.trim().replaceAll(',', '.');
    if (t.isEmpty) return null;
    return double.tryParse(t);
  }

  static String? _emptyNull(String s) {
    final t = s.trim();
    return t.isEmpty ? null : t;
  }

  static String _fmtNum(double? v) => v == null ? '—' : v.toStringAsFixed(0);

  static String _nowIso() => DateTime.now().toUtc().toIso8601String();
}

/// Диалог структурного замера. Отдельный StatefulWidget: контроллеры живут
/// со своим State и уничтожаются ПОСЛЕ анимации закрытия маршрута —
/// dispose сразу после showDialog ронял поля («used after being disposed»).
/// Тип замера обязателен: замер жилы, записанный «слоистостью», даёт ложную
/// структурную картину в камералке (ревизия geo-consultant).
class _MeasurementDialog extends StatefulWidget {
  const _MeasurementDialog();

  @override
  State<_MeasurementDialog> createState() => _MeasurementDialogState();
}

class _MeasurementDialogState extends State<_MeasurementDialog> {
  final _azCtrl = TextEditingController();
  final _angCtrl = TextEditingController();
  String _type = 'bedding';

  @override
  void dispose() {
    _azCtrl.dispose();
    _angCtrl.dispose();
    super.dispose();
  }

  InputDecoration _dec(String hint) {
    OutlineInputBorder b(Color c) => OutlineInputBorder(
          borderRadius: BorderRadius.circular(GfRadius.r12),
          borderSide: BorderSide(color: c),
        );
    return InputDecoration(
      hintText: hint,
      labelText: hint,
      labelStyle: GfText.hint,
      hintStyle: GfText.hint,
      filled: true,
      fillColor: GfColors.surface,
      contentPadding: const EdgeInsets.symmetric(
          horizontal: GfSpace.x16, vertical: GfSpace.x16),
      enabledBorder: b(GfColors.outline),
      focusedBorder: b(GfColors.accent),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: GfColors.surfaceHi,
      title: const Text('Структурный замер'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          DropdownButtonFormField<String>(
            initialValue: _type,
            items: measureTypes.entries
                .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
                .toList(),
            onChanged: (v) => setState(() => _type = v ?? 'bedding'),
            dropdownColor: GfColors.surfaceHi,
            style: GfText.body,
            decoration: _dec('Тип замера'),
          ),
          const SizedBox(height: GfSpace.x12),
          TextField(
            controller: _azCtrl,
            style: GfText.number,
            keyboardType: TextInputType.number,
            decoration: _dec('Азимут падения, 0–359'),
          ),
          const SizedBox(height: GfSpace.x12),
          TextField(
            controller: _angCtrl,
            style: GfText.number,
            keyboardType: TextInputType.number,
            decoration: _dec('Угол падения, 0–90'),
          ),
        ]),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена')),
        TextButton(
            onPressed: () => Navigator.pop(
                context, (type: _type, az: _azCtrl.text, ang: _angCtrl.text)),
            child: const Text('Добавить')),
      ],
    );
  }
}
