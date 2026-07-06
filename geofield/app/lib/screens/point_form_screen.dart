import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../config/features.dart';
import '../data/dictionary_repository.dart';
import '../data/photo_repository.dart';
import '../data/point_repository.dart';
import '../data/sample_repository.dart';
import '../models/observation_point.dart';
import '../models/sample.dart';
import '../theme/tokens.dart';
import '../util/crs.dart';
import '../util/format.dart';
import '../util/gps.dart';
import '../util/sample_number.dart';
import '../util/save_queue.dart';
import '../widgets/confirm_dialog.dart';
import '../widgets/field_picker.dart';
import '../widgets/photo_strip.dart';
import '../widgets/sample_row.dart';
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
    required this.photos,
    required this.projectId,
    required this.routeId,
    required this.authorId,
    required this.sampleNumbering,
    this.initialNumber,
    this.existing,
    this.gps = acquireGpsFix,
    this.photoPicker,
  }) : assert(existing != null || initialNumber != null,
            'нужен либо existing, либо initialNumber');

  final PointRepository points;
  final SampleRepository samples;
  final DictionaryRepository dictionaries;
  final PhotoRepository photos;
  final String projectId;
  final String routeId;
  final String authorId;
  final String sampleNumbering;
  final String? initialNumber;
  final ObservationPoint? existing;

  /// Источник координат — подменяется в тестах (без платформенных каналов).
  final GpsProvider gps;

  /// Источник снимков — подменяется в тестах; null — камера/галерея.
  final PhotoPicker? photoPicker;

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
  String? _coordSource; // 'gps' | 'manual' — как сняты текущие координаты
  double? _gpsAccuracy;
  bool _gpsBusy = false;
  // Система координат ВВОДА/ПОКАЗА. Хранение всегда каноническое (WGS-84);
  // СК-42 — вид поверх (ТЗ §6.2). false — WGS-84, true — СК-42 ГК зона 25.
  bool _sk42 = false;
  final Set<String> _selectedMinerals = {};
  List<DictEntry> _objectTypes = const [];
  List<DictEntry> _rocks = const [];
  List<DictEntry> _alterations = const [];
  List<DictEntry> _mineralDict = const [];
  List<StructuralMeasurement> _measurements = const [];
  List<Sample> _boundSamples = const [];

  final _queue = SaveQueue();
  // Защита от двойного pop: «Готово» и системный back могут сработать почти
  // одновременно, оба дождутся _saveNow и вызовут pop() — второй pop снял бы
  // лишний экран под формой. Кто первым выставил флаг, тот и закрывает.
  bool _exiting = false;
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
      _coordSource = ex.coordSource;
      _gpsAccuracy = ex.gpsAccuracyM;
      _objectType = ex.objectType;
      _colorCtrl.text = ex.colorCode ?? '';
      _grainCtrl.text = ex.grain ?? '';
      _noteCtrl.text = ex.note ?? '';
      _isDraft = ex.isDraft;
      _saveState = 'сохранено · не отправлено';
      _selectedMinerals.addAll(decodeMineralCodes(ex.minerals));
    } else {
      _id = const Uuid().v4();
      _createdAt = nowIso();
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
    // на каждый тап «+ Точка» (perf-audit: отзывчивость главного жеста).
    final d = widget.dictionaries;
    final typesF = d.list(widget.projectId, 'object_type');
    final rocksF = d.list(widget.projectId, 'rock');
    final alterationsF = d.list(widget.projectId, 'alteration');
    final mineralsF = d.list(widget.projectId, 'mineral');
    final rockLabelF = rockCode == null
        ? Future<String?>.value()
        : d.labelForCode(widget.projectId, 'rock', rockCode);
    final alterationLabelF = alterationCode == null
        ? Future<String?>.value()
        : d.labelForCode(widget.projectId, 'alteration', alterationCode);
    await Future.wait<Object?>([
      typesF,
      rocksF,
      alterationsF,
      mineralsF,
      rockLabelF,
      alterationLabelF
    ]);
    final types = await typesF;
    final rocks = await rocksF;
    final alterations = await alterationsF;
    final minerals = await mineralsF;
    final rockLabel = rockCode == null ? '' : (await rockLabelF ?? rockCode);
    final alterationLabel = alterationCode == null
        ? ''
        : (await alterationLabelF ?? alterationCode);
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
    final elev = parseDouble(_elevCtrl.text);

    // Противоречия — invalid, не пишем (ТЗ §0, правило 3).
    if (number.isEmpty) {
      _setSave('Номер точки обязателен', error: true);
      return SaveResult.invalid;
    }
    // Координаты интерпретируются по текущей СК и приводятся к WGS-84 (канон).
    final coords = _coordsAsWgs();
    if (coords.error != null) {
      _setSave(coords.error!, error: true);
      return SaveResult.invalid;
    }
    final lat = coords.lat;
    final lon = coords.lon;

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
        coordSource: lat == null ? null : (_coordSource ?? 'manual'),
        gpsAccuracyM:
            lat == null || _coordSource != 'gps' ? null : _gpsAccuracy,
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
        modifiedAt: nowIso(),
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
        if (!mounted || _exiting) return;
        _exiting = true;
        navigator.pop();
      },
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: GfColors.bg,
          title: Text('Точка наблюдения', style: GfText.screenTitle),
          actions: [
            if (_isDraft)
              Padding(
                padding: const EdgeInsets.only(right: GfSpace.x16),
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: GfSpace.x8, vertical: GfSpace.x4),
                    decoration: BoxDecoration(
                      color: GfColors.draftBg,
                      borderRadius: BorderRadius.circular(GfRadius.r8),
                    ),
                    child: Text('черновик',
                        style: TextStyle(fontSize: 12, color: GfColors.draft)),
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
              _section(
                'ФОТО',
                PhotoStrip(
                  photos: widget.photos,
                  parentType: 'point',
                  parentId: _id,
                  ensureParent: () async =>
                      (await _saveNow()) == SaveResult.saved,
                  picker: widget.photoPicker,
                ),
              ),
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
        Text('НОМЕР ТОЧКИ', style: GfText.sectionLabel),
        const SizedBox(height: GfSpace.x8),
        TextField(
          controller: _numberCtrl,
          style: GfText.numberField,
          onChanged: (_) => _scheduleSave(),
          decoration: _dec('Т-001'),
        ),
        const SizedBox(height: GfSpace.x16),
        Text(_sk42 ? 'КООРДИНАТЫ (СК-42 · ГК)' : 'КООРДИНАТЫ (WGS-84)',
            style: GfText.sectionLabel),
        const SizedBox(height: GfSpace.x8),
        FieldPicker(
          label: 'Система координат',
          options: const [
            ('wgs84', 'WGS-84 · широта/долгота, °'),
            // Зона НЕ фиксирована: партия работает по всей Магаданской обл. и
            // Якутии (зоны ГК 18–28) — зона берётся из долготы/префикса Y.
            ('sk42', 'СК-42 · Гаусса-Крюгера (метры)'),
          ],
          selected: _sk42 ? 'sk42' : 'wgs84',
          onSelected: (code) => _onCrsChanged(code == 'sk42'),
        ),
        const SizedBox(height: GfSpace.x8),
        Row(children: [
          // Русская геодезическая конвенция: X — северная (сверху), Y —
          // восточная (снизу). Подписи словами, чтобы камералка/Micromine не
          // получили перевёрнутые точки (ревизия geo-consultant).
          Expanded(
              child: _numField(_latCtrl, _sk42 ? 'Север (X), м' : 'Широта',
                  onEdited: _onCoordsEdited)),
          const SizedBox(width: GfSpace.x12),
          Expanded(
              child: _numField(_lonCtrl, _sk42 ? 'Восток (Y), м' : 'Долгота',
                  onEdited: _onCoordsEdited)),
        ]),
        if (_sk42) _zoneReadout(),
        if (!_sk42) _gmsReadout(),
        const SizedBox(height: GfSpace.x12),
        Row(children: [
          Expanded(child: _numField(_elevCtrl, 'Высота, м')),
          const SizedBox(width: GfSpace.x12),
          Expanded(
            child: _outlined(
              _gpsBusy ? 'Приём…' : 'С приёмника',
              Icons.gps_fixed,
              _onGps,
            ),
          ),
        ]),
        if (_coordSource == 'gps') ...[
          const SizedBox(height: GfSpace.x8),
          Text(
            _gpsAccuracy == null
                ? 'Источник: GPS-приёмник'
                : 'Источник: GPS-приёмник · точность ±${_gpsAccuracy!.toStringAsFixed(0)} м',
            style: GfText.hint,
          ),
        ],
      ],
    );
  }

  /// Ручная правка широты/долготы: координата больше не «с приёмника».
  void _onCoordsEdited() {
    if (_coordSource != 'manual') {
      setState(() {
        _coordSource = 'manual';
        _gpsAccuracy = null;
      });
    }
  }

  /// Два поля координат → WGS-84 (lat/lon) по текущей СК. error != null —
  /// показать пользователю и не писать; оба null без error — координат нет.
  ({double? lat, double? lon, String? error}) _coordsAsWgs() {
    final aText = _latCtrl.text.trim();
    final bText = _lonCtrl.text.trim();
    if (aText.isEmpty && bText.isEmpty) {
      return (lat: null, lon: null, error: null);
    }
    if (aText.isEmpty != bText.isEmpty) {
      return (
        lat: null,
        lon: null,
        error: _sk42
            ? 'Укажите оба значения (X и Y) или ни одного'
            : 'Укажите обе координаты или ни одной'
      );
    }
    final a = parseDouble(aText);
    final b = parseDouble(bText);
    if (a == null || b == null) {
      return (
        lat: null,
        lon: null,
        error: _sk42 ? 'X и Y — числа' : 'Координаты — числа'
      );
    }
    if (!_sk42) {
      if (a < -90 || a > 90) {
        return (lat: null, lon: null, error: 'Широта вне диапазона ±90');
      }
      if (b < -180 || b > 180) {
        return (lat: null, lon: null, error: 'Долгота вне диапазона ±180');
      }
      return (lat: a, lon: b, error: null);
    }
    // СК-42: a = X (север), b = Y (восток, с префиксом зоны). Зона — из Y.
    final w = sk42GkToWgs84(a, b);
    if (w.lat < -90 || w.lat > 90 || w.lon < -180 || w.lon > 180) {
      return (
        lat: null,
        lon: null,
        error: 'X/Y вне разумных пределов зоны — проверьте значения'
      );
    }
    return (lat: w.lat, lon: w.lon, error: null);
  }

  /// Записать WGS-84 координату в поля ввода в текущей СК (без дрейфа: канон —
  /// переданные lat/lon, а не то, что уже в полях).
  void _writeCoordFields(double lat, double lon) {
    if (!_sk42) {
      _latCtrl.text = lat.toStringAsFixed(6);
      _lonCtrl.text = lon.toStringAsFixed(6);
    } else {
      final gk = wgs84ToSk42Gk(lat, lon);
      _latCtrl.text = gk.x.toStringAsFixed(0); // Север (X)
      _lonCtrl.text = gk.y.toStringAsFixed(0); // Восток (Y) с префиксом зоны
    }
  }

  /// Актуальная зона ГК по введённым координатам — подтверждает геологу, что
  /// точка легла в ту зону (Тенькинский р-н у границы 150° может уйти в 26).
  Widget _zoneReadout() {
    final w = _coordsAsWgs();
    String text;
    if (w.lat != null && w.lon != null) {
      final gk = wgs84ToSk42Gk(w.lat!, w.lon!);
      text = 'Зона ${gk.zone} · осевой меридиан '
          '${gkCentralMeridian(gk.zone).toStringAsFixed(0)}°';
    } else {
      text = 'Зона определится по долготе (18–28: Магадан, Якутия)';
    }
    return Padding(
      padding: const EdgeInsets.only(top: GfSpace.x8),
      child: Text(text, style: GfText.hint),
    );
  }

  /// ГМС-показ введённых WGS-84 координат (ТЗ §6.2): десятичные — для ввода,
  /// градусы-минуты-секунды — для сверки с рамкой топокарты. Только показ,
  /// ввод остаётся десятичным (в поле не набирают °′″ вручную).
  Widget _gmsReadout() {
    final w = _coordsAsWgs();
    final text = (w.lat != null && w.lon != null)
        ? '${formatGms(w.lat!, isLat: true)} · ${formatGms(w.lon!, isLat: false)}'
        : 'ГМС покажется по координатам';
    return Padding(
      padding: const EdgeInsets.only(top: GfSpace.x8),
      child: Text(text, style: GfText.hint),
    );
  }

  /// Переключение СК: пересчитать уже введённые координаты в новую систему,
  /// чтобы точка не «переехала». Пустые/невалидные поля оставляем как есть.
  void _onCrsChanged(bool sk42) {
    if (sk42 == _sk42) return;
    final w = _coordsAsWgs(); // в СТАРОЙ системе
    setState(() {
      _sk42 = sk42;
      if (w.lat != null && w.lon != null) {
        _writeCoordFields(w.lat!, w.lon!);
      }
    });
  }

  Widget _descriptionBlock() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Полевой пикер вместо дропдауна: крупные строки шторкой (ТЗ §4.5 —
        // без мелких жестов), длинные подписи не переполняют строку.
        FieldPicker(
          label: 'Тип объекта',
          options: [for (final e in _objectTypes) (e.code, e.label)],
          selected: _objectType,
          onSelected: (code) {
            setState(() => _objectType = code);
            _scheduleSave();
          },
        ),
        const SizedBox(height: GfSpace.x12),
        _dictAutocomplete(_rockCtrl, _rockFocus, _rocks,
            'Порода (справочник; новое — «на проверку»)'),
        const SizedBox(height: GfSpace.x12),
        _dictAutocomplete(_alterationCtrl, _alterationFocus, _alterations,
            'Вторичные изменения (окварцевание, серицитизация…)'),
        const SizedBox(height: GfSpace.x12),
        Text('МИНЕРАЛИЗАЦИЯ', style: GfText.sectionLabel),
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
      return Text('Справочник минералов пуст — обновите с сервера',
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
          selectedColor: gfChipSelectedColor(),
          backgroundColor: GfColors.surface,
          side: gfChipSide(selected),
          labelStyle: gfChipLabel(selected),
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
              Icon(Icons.architecture,
                  size: 18, color: GfColors.textSecondary),
              const SizedBox(width: GfSpace.x8),
              Expanded(
                child: Text(
                  '${measureTypes[m.measureType] ?? m.measureType ?? '—'}: '
                  'аз. пад. ${_fmtNum(m.dipAzimuth)}° / угол ${_fmtNum(m.dipAngle)}° '
                  '· ${m.isTrueAngle ? 'ист.' : 'магн.'}',
                  style: GfText.numberSmall,
                ),
              ),
            ]),
          ),
        Row(children: [
          Expanded(child: _outlined('+ Замер', Icons.add, _onAddMeasurement)),
          const SizedBox(width: GfSpace.x12),
          Expanded(child: _outlined('С датчика', Icons.explore, _onSensor)),
        ]),
      ],
    );
  }

  Widget _samplesBlock() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final s in _boundSamples) SampleRow(s),
        _outlined('+ Проба', Icons.add, _onAddSample),
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
        style: gfOutlinedStyle(),
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
            if (r == SaveResult.saved && mounted && !_exiting) {
              _exiting = true;
              Navigator.of(context).pop(_id);
            }
          },
          style: gfFilledStyle(),
          child: const Text('Готово', style: GfText.button),
        ),
      ),
    );
  }

  // --- действия -----------------------------------------------------------------

  Future<void> _onGps() async {
    if (!AppFeatures.gpsCapture) {
      _snack('GPS-приёмник не подключён в этой сборке — введите вручную');
      return;
    }
    if (_gpsBusy) return;
    setState(() => _gpsBusy = true);
    try {
      final fix = await widget.gps();
      if (!mounted) return;
      // Приёмник даёт WGS-84; в поля кладём в текущей СК (СК-42 при показе).
      _writeCoordFields(fix.lat, fix.lon);
      if (fix.elevation != null) {
        _elevCtrl.text = fix.elevation!.toStringAsFixed(0);
      }
      setState(() {
        _coordSource = 'gps';
        _gpsAccuracy = fix.accuracy;
      });
      _scheduleSave();
    } on Exception catch (e) {
      // GpsException несёт понятную причину (службы/разрешение/таймаут).
      _snack('$e');
    } finally {
      if (mounted) setState(() => _gpsBusy = false);
    }
  }

  void _onSensor() {
    if (!AppFeatures.sensorCompass) {
      _snack('Датчики не подключены в этой сборке — введите вручную');
      return;
    }
  }

  Future<void> _onAddMeasurement() async {
    final result =
        await showDialog<({String type, String az, String ang, bool trueAz})>(
      context: context,
      builder: (_) => const _MeasurementDialog(),
    );
    if (result == null) return;
    final az = parseDouble(result.az);
    final ang = parseDouble(result.ang);
    final measureType = result.type;
    // Противоречие ловим при вводе (ТЗ §0, пр.3) — до CHECK в базе.
    if (az == null ||
        ang == null ||
        az < 0 ||
        az >= 360 ||
        ang < 0 ||
        ang > 90) {
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
      final now = nowIso();
      await widget.points.addMeasurement(StructuralMeasurement(
        id: const Uuid().v4(),
        parentType: 'point',
        parentId: _id,
        measureType: measureType,
        dipAzimuth: az,
        dipAngle: ang,
        source: 'manual',
        isTrueAngle: result.trueAz,
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
        photos: widget.photos,
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
    final confirmed = await confirmDelete(
      context,
      title: 'Удалить точку?',
      message: 'Точку можно восстановить в камералке до синхронизации.',
    );
    if (!confirmed) return;
    if (_persistedOnce) {
      try {
        // Фото точки — её аннотации: каскадно, чтобы не осталось сирот.
        await widget.photos.softDeleteForParent('point', _id);
        final ex = await widget.points.byId(_id);
        if (ex != null) await widget.points.softDelete(ex);
      } catch (e) {
        _setSave('не удалось удалить — проверьте память устройства',
            error: true);
        _snack('Не удалось удалить — проверьте память устройства');
        return;
      }
    }
    if (!mounted || _exiting) return;
    _exiting = true;
    navigator.pop();
  }

  // --- helpers ------------------------------------------------------------------

  Widget _numField(TextEditingController c, String hint,
          {VoidCallback? onEdited}) =>
      TextField(
        controller: c,
        style: GfText.number,
        keyboardType:
            const TextInputType.numberWithOptions(decimal: true, signed: true),
        onChanged: (_) {
          onEdited?.call();
          _scheduleSave();
        },
        decoration: _dec(hint),
      );

  Widget _textField(TextEditingController c, String hint) => TextField(
        controller: c,
        style: GfText.body,
        onChanged: (_) => _scheduleSave(),
        decoration: _dec(hint),
      );

  InputDecoration _dec(String hint) =>
      gfInputDecoration(hint: hint, label: hint);

  void _snack(String m) {
    if (!mounted) return;
    context.snack(m);
  }

  static String? _emptyNull(String s) {
    final t = s.trim();
    return t.isEmpty ? null : t;
  }

  static String _fmtNum(double? v) => v == null ? '—' : v.toStringAsFixed(0);
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
  // По умолчанию МАГНИТНЫЙ: буссоль так и даёт. Истинный — только если геолог
  // уже поправил на склонение в поле.
  bool _trueAz = false;

  @override
  void dispose() {
    _azCtrl.dispose();
    _angCtrl.dispose();
    super.dispose();
  }

  InputDecoration _dec(String hint) =>
      gfInputDecoration(hint: hint, label: hint);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: GfColors.surfaceHi,
      title: const Text('Структурный замер'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          FieldPicker(
            label: 'Тип замера',
            options: [for (final e in measureTypes.entries) (e.key, e.value)],
            selected: _type,
            onSelected: (v) => setState(() => _type = v),
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
          const SizedBox(height: GfSpace.x12),
          FieldPicker(
            label: 'Азимут',
            options: const [
              ('magnetic', 'Магнитный (с буссоли)'),
              ('true', 'Истинный (правлен на склонение)'),
            ],
            selected: _trueAz ? 'true' : 'magnetic',
            onSelected: (v) => setState(() => _trueAz = v == 'true'),
          ),
        ]),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена')),
        TextButton(
            onPressed: () => Navigator.pop(context, (
                  type: _type,
                  az: _azCtrl.text,
                  ang: _angCtrl.text,
                  trueAz: _trueAz
                )),
            child: const Text('Добавить')),
      ],
    );
  }
}
