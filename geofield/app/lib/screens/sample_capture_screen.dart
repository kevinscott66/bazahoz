import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:uuid/uuid.dart';

import '../config/features.dart';
import '../data/photo_repository.dart';
import '../data/sample_repository.dart';
import '../models/sample.dart';
import '../theme/sample_type.dart';
import '../theme/tokens.dart';
import '../util/format.dart';
import '../util/save_queue.dart';
import '../widgets/confirm_dialog.dart';
import '../widgets/photo_strip.dart';

/// Привязка пробы к родителю (точка наблюдения или интервал керна).
class ParentBinding {
  const ParentBinding({
    required this.type, // 'point' | 'interval'
    required this.id,
    required this.label, // напр. «Точка № 12»
    this.depthFrom,
    this.depthTo,
  });

  final String type;
  final String id;
  final String label;
  final double? depthFrom;
  final double? depthTo;
}

/// Экран регистрации пробы и печати бирки (ТЗ 6.5).
/// Автосохранение после каждого действия: проба пишется в базу сразу при
/// открытии (черновик не теряется) и при каждом изменении — с дебаунсом.
class SampleCaptureScreen extends StatefulWidget {
  const SampleCaptureScreen({
    super.key,
    required this.repository,
    required this.photos,
    required this.projectId,
    required this.authorId,
    required this.initialNumber,
    required this.binding,
    this.existing,
    this.photoPicker,
  });

  final SampleRepository repository;
  final PhotoRepository photos;
  final String projectId;
  final String authorId;
  final String initialNumber;
  final ParentBinding binding;

  /// Источник снимков — подменяется в тестах; null — камера/галерея.
  final PhotoPicker? photoPicker;

  /// Существующая проба — режим редактирования (открытие из журнала, ТЗ §6.7).
  final Sample? existing;

  @override
  State<SampleCaptureScreen> createState() => _SampleCaptureScreenState();
}

class _SampleCaptureScreenState extends State<SampleCaptureScreen> {
  late final String _id;
  late final String _createdAt;

  final _numberCtrl = TextEditingController();
  final _fromCtrl = TextEditingController();
  final _toCtrl = TextEditingController();
  final _lengthCtrl = TextEditingController();
  final _massCtrl = TextEditingController();
  final _noteCtrl = TextEditingController();

  SampleType _type = SampleType.core;
  int _version = 1;
  // Защита от двойного pop: «Готово» и системный back могут сработать почти
  // одновременно, оба дождутся _saveNow и вызовут pop() — второй pop снял бы
  // лишний экран под формой. Кто первым выставил флаг, тот и закрывает.
  bool _exiting = false;
  bool _persistedOnce = false;
  bool _gloveMode = false;
  // Дебаунс + сериализация сохранений (SaveQueue): конкурентные вызовы
  // (автосейв при открытии + «Готово»/«назад») выполняются по очереди,
  // чтобы isNew не прочитался дважды и не случилось двух INSERT одной записи.
  final _queue = SaveQueue();
  String _saveState = 'сохранение…';
  bool _saveIsError = false;

  @override
  void initState() {
    super.initState();
    final ex = widget.existing;
    if (ex != null) {
      // Режим редактирования: запись уже в базе, версия продолжается.
      _id = ex.id;
      _createdAt = ex.createdAt;
      _persistedOnce = true;
      _version = ex.version;
      _numberCtrl.text = ex.sampleNumber;
      _type = SampleType.fromCode(ex.sampleType);
      if (ex.depthFrom != null) _fromCtrl.text = _fmt(ex.depthFrom!);
      if (ex.depthTo != null) _toCtrl.text = _fmt(ex.depthTo!);
      if (ex.lengthM != null) _lengthCtrl.text = ex.lengthM.toString();
      if (ex.mass != null) _massCtrl.text = ex.mass.toString();
      _noteCtrl.text = ex.note ?? '';
      _saveState = 'сохранено · не отправлено';
      return;
    }
    // id пробы создаётся один раз при входе на экран (UUID, офлайн).
    _id = const Uuid().v4();
    _createdAt = nowIso();
    _numberCtrl.text = widget.initialNumber;
    // Для керна интервал отбора подтягивается из родительского интервала.
    if (widget.binding.depthFrom != null) {
      _fromCtrl.text = _fmt(widget.binding.depthFrom!);
    }
    if (widget.binding.depthTo != null) {
      _toCtrl.text = _fmt(widget.binding.depthTo!);
    }
    // Немедленно сохранить черновик — один тап «+ Проба» уже создал запись.
    WidgetsBinding.instance.addPostFrameCallback((_) => _saveNow());
  }

  @override
  void dispose() {
    _queue.dispose();
    _numberCtrl.dispose();
    _fromCtrl.dispose();
    _toCtrl.dispose();
    _lengthCtrl.dispose();
    _massCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  // --- модель из текущего состояния экрана ------------------------------------

  Sample _current({required int version}) {
    final number = _numberCtrl.text.trim();
    // У существующей пробы привязка сохраняется как есть (в т.ч. NULL у
    // свободной): смена привязки — отдельное явное действие, не автосейв.
    final ex = widget.existing;
    return Sample(
      id: _id,
      projectId: widget.projectId,
      parentType: ex != null ? ex.parentType : widget.binding.type,
      parentId: ex != null ? ex.parentId : widget.binding.id,
      sampleNumber: number,
      sampleType: _type.code,
      barcode: number.isEmpty ? null : number, // штрихкод из номера
      // Поля, не осмысленные для типа, не персистятся, даже если контроллер
      // хранит старый ввод после переключения типа.
      depthFrom: _type.hasDepthInterval ? parseDouble(_fromCtrl.text) : null,
      depthTo: _type.hasDepthInterval ? parseDouble(_toCtrl.text) : null,
      lengthM: _type.hasLength ? parseDouble(_lengthCtrl.text) : null,
      mass: parseDouble(_massCtrl.text),
      // Правка полей не откатывает жизненный цикл: статус существующей пробы
      // сохраняется (переходы статуса — отдельное действие, не этот экран).
      status: widget.existing?.status ?? SampleStatus.collected,
      note: _noteCtrl.text.trim().isEmpty ? null : _noteCtrl.text.trim(),
      authorId: widget.authorId,
      createdAt: _createdAt,
      modifiedAt: nowIso(),
      version: version,
      syncStatus: SyncStatus.pending,
    );
  }

  void _scheduleSave() {
    _setSave('сохранение…');
    _queue.schedule(_doSave);
  }

  Future<SaveResult> _saveNow() => _queue.flush(_doSave);

  /// Одно сохранение. Никогда не бросает: невалидность/ошибка — это видимое
  /// состояние, а не необработанное исключение в фоновом таймере.
  Future<SaveResult> _doSave() async {
    final number = _numberCtrl.text.trim();
    final from = parseDouble(_fromCtrl.text);
    final to = parseDouble(_toCtrl.text);
    // Обязательные поля и противоречия ловим при вводе (ТЗ §0, правило 3),
    // не доводя до CHECK-исключения СУБД.
    if (number.isEmpty) {
      _setSave('Номер пробы обязателен', error: true);
      return SaveResult.invalid;
    }
    // Валидируем интервал только когда поля видимы для типа: после смены
    // типа старый ввод в скрытых полях не должен блокировать сохранение
    // (он и не персистится — см. _current).
    if (_type.hasDepthInterval && from != null && to != null && to < from) {
      _setSave('«До» не может быть меньше «От»', error: true);
      return SaveResult.invalid;
    }
    final isNew = !_persistedOnce;
    final nextVersion = isNew ? 1 : _version + 1;
    try {
      await widget.repository
          .save(_current(version: nextVersion), isNew: isNew);
      _persistedOnce = true;
      _version = nextVersion;
      _setSave('сохранено · не отправлено');
      return SaveResult.saved;
    } catch (e) {
      // Реальный сбой записи (диск/блокировка WAL). Ошибка видима (не проглочена);
      // вызывающий не должен молча закрывать экран.
      _setSave('ошибка сохранения', error: true);
      return SaveResult.failed;
    }
  }

  void _setSave(String s, {bool error = false}) {
    _saveState = s;
    _saveIsError = error;
    if (mounted) setState(() {});
  }

  // --- UI ---------------------------------------------------------------------

  double get _target => _gloveMode ? GfTouch.glove : GfTouch.min;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        // Системная «назад»/жест: дожать отложенную правку. Выходим, если
        // сохранено или ввод невалиден (сохранять нечего — последняя валидная
        // версия уже в базе). Но если РЕАЛЬНАЯ запись валидных данных провалилась,
        // не закрываем молча — показываем ошибку (ТЗ §0, правило 2).
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
          title: const Text('Регистрация пробы', style: GfText.screenTitle),
          actions: [
            IconButton(
              tooltip: _gloveMode ? 'Перчатки: вкл' : 'Перчатки: выкл',
              icon: Icon(
                  _gloveMode ? Icons.back_hand : Icons.back_hand_outlined,
                  color: _gloveMode ? GfColors.accent : GfColors.textSecondary),
              onPressed: () => setState(() => _gloveMode = !_gloveMode),
            ),
          ],
        ),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(GfSpace.x16),
            children: [
              _binding(),
              const SizedBox(height: GfSpace.x24),
              _label('ТИП ПРОБЫ'),
              const SizedBox(height: GfSpace.x12),
              _typeTiles(),
              const SizedBox(height: GfSpace.x24),
              _label('НОМЕР'),
              const SizedBox(height: GfSpace.x8),
              _numberField(),
              const SizedBox(height: GfSpace.x24),
              // Атрибуты зависят от типа пробы: «От/До» у штуфа или шлиха
              // бессмысленны и путают (ревизия geo-consultant).
              if (_type.hasDepthInterval) ...[
                _label('ИНТЕРВАЛ ОТБОРА (м)'),
                const SizedBox(height: GfSpace.x8),
                _depthFields(),
                const SizedBox(height: GfSpace.x16),
              ],
              if (_type.hasLength) ...[
                _numTextField(_lengthCtrl, 'Длина, м'),
                const SizedBox(height: GfSpace.x16),
              ],
              _massField(),
              const SizedBox(height: GfSpace.x24),
              _label('БИРКА'),
              const SizedBox(height: GfSpace.x12),
              _barcodeRow(),
              const SizedBox(height: GfSpace.x24),
              _label('ПРИМЕЧАНИЕ'),
              const SizedBox(height: GfSpace.x8),
              _noteField(),
              const SizedBox(height: GfSpace.x24),
              _label('ФОТО'),
              const SizedBox(height: GfSpace.x12),
              PhotoStrip(
                photos: widget.photos,
                parentType: 'sample',
                parentId: _id,
                ensureParent: () async =>
                    (await _saveNow()) == SaveResult.saved,
                picker: widget.photoPicker,
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

  Widget _label(String t) => Text(t, style: GfText.sectionLabel);

  Widget _binding() {
    return Container(
      padding: const EdgeInsets.all(GfSpace.x12),
      decoration: BoxDecoration(
        color: GfColors.surface,
        borderRadius: BorderRadius.circular(GfRadius.r12),
        border: Border.all(color: GfColors.outline),
      ),
      child: Row(
        children: [
          const Icon(Icons.link, size: 20, color: GfColors.textSecondary),
          const SizedBox(width: GfSpace.x8),
          Expanded(
            child: Text('Привязано к: ${widget.binding.label}',
                style: GfText.body),
          ),
        ],
      ),
    );
  }

  Widget _typeTiles() {
    return Wrap(
      spacing: GfSpace.x8,
      runSpacing: GfSpace.x8,
      children: SampleType.values.map((t) {
        final selected = t == _type;
        return InkWell(
          borderRadius: BorderRadius.circular(GfRadius.r12),
          onTap: () {
            setState(() => _type = t);
            _scheduleSave();
          },
          child: Container(
            constraints: BoxConstraints(minHeight: _target, minWidth: 104),
            padding: const EdgeInsets.symmetric(
                horizontal: GfSpace.x16, vertical: GfSpace.x12),
            decoration: BoxDecoration(
              color:
                  selected ? t.color.withValues(alpha: 0.20) : GfColors.surface,
              borderRadius: BorderRadius.circular(GfRadius.r12),
              border: Border.all(
                color: selected ? t.color : GfColors.outline,
                width: selected ? 2 : 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 14,
                  height: 14,
                  decoration:
                      BoxDecoration(color: t.color, shape: BoxShape.circle),
                ),
                const SizedBox(width: GfSpace.x8),
                Text(t.label,
                    style: GfText.body.copyWith(
                        fontWeight:
                            selected ? FontWeight.w700 : FontWeight.w400)),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _numberField() {
    return TextField(
      controller: _numberCtrl,
      style: GfText.numberField,
      onChanged: (_) => _scheduleSave(),
      decoration: _fieldDecoration(hint: 'SUZ-00001'),
    );
  }

  Widget _depthFields() {
    return Row(
      children: [
        Expanded(child: _numTextField(_fromCtrl, 'От')),
        const SizedBox(width: GfSpace.x12),
        Expanded(child: _numTextField(_toCtrl, 'До')),
      ],
    );
  }

  Widget _massField() => _numTextField(_massCtrl, 'Масса, кг');

  Widget _numTextField(TextEditingController c, String hint) {
    return TextField(
      controller: c,
      style: GfText.number,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      onChanged: (_) => _scheduleSave(),
      decoration: _fieldDecoration(hint: hint),
    );
  }

  Widget _noteField() {
    return TextField(
      controller: _noteCtrl,
      style: GfText.body,
      minLines: 2,
      maxLines: 4,
      onChanged: (_) => _scheduleSave(),
      decoration: _fieldDecoration(hint: 'свободный текст'),
    );
  }

  InputDecoration _fieldDecoration({required String hint}) =>
      gfInputDecoration(hint: hint);

  Widget _barcodeRow() {
    return Row(
      children: [
        Expanded(
            child: _secondaryButton('Печать бирки', Icons.print, _onPrint)),
        const SizedBox(width: GfSpace.x12),
        Expanded(
            child:
                _secondaryButton('Показать код', Icons.qr_code_2, _onShowCode)),
      ],
    );
  }

  Widget _secondaryButton(String text, IconData icon, VoidCallback onTap) {
    return SizedBox(
      height: _target,
      child: OutlinedButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 20),
        label: Text(text, overflow: TextOverflow.ellipsis),
        style: gfOutlinedStyle(),
      ),
    );
  }

  Widget _saveIndicator() {
    final err = _saveIsError;
    return Row(
      children: [
        Icon(err ? Icons.error_outline : Icons.cloud_off,
            size: 16, color: err ? GfColors.error : GfColors.textSecondary),
        const SizedBox(width: GfSpace.x8),
        Text(_saveState,
            style: GfText.hint.copyWith(
                color: err ? GfColors.error : GfColors.textSecondary)),
      ],
    );
  }

  Widget _deleteButton() {
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        onPressed: _onDelete,
        icon: const Icon(Icons.delete_outline, size: 18),
        label: const Text('Удалить пробу'),
        style: TextButton.styleFrom(foregroundColor: GfColors.error),
      ),
    );
  }

  Widget _doneBar() {
    return SafeArea(
      minimum: const EdgeInsets.all(GfSpace.x16),
      child: SizedBox(
        height: _target,
        width: double.infinity,
        child: FilledButton(
          onPressed: () async {
            final r = await _saveNow();
            // Закрываем только при успешном сохранении. Невалидный ввод (пустой
            // номер / «До < От») и сбой записи — остаёмся, даём исправить/повторить.
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

  // --- действия ---------------------------------------------------------------

  void _onShowCode() {
    final number = _numberCtrl.text.trim();
    if (number.isEmpty) {
      _snack('Сначала задайте номер пробы');
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: GfColors.surface,
      builder: (_) => Padding(
        padding: const EdgeInsets.all(GfSpace.x24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _tagPreview(number),
            const SizedBox(height: GfSpace.x12),
            const Text('Нет принтера — сфотографировать/наклеить код от руки',
                style: GfText.hint, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }

  void _onPrint() {
    // Барьер заглушек: транспорт печати за выключенным флагом (UNFINISHED.md).
    // Не имитируем успех — честно сообщаем, что принтера в этой сборке нет.
    if (!AppFeatures.bluetoothLabelPrinter) {
      _snack('Принтер этикеток не подключён в этой сборке');
      _onShowCode();
      return;
    }
    // Реальная передача на принтер появится вместе с SDK принтера.
    _snack('Отправка на принтер…');
  }

  /// Настоящий рендер бирки (QR + номер + цвет типа). То, что уйдёт на принтер.
  Widget _tagPreview(String number) {
    return Container(
      width: 260,
      padding: const EdgeInsets.all(GfSpace.x16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(GfRadius.r8),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                      color: _type.color, shape: BoxShape.circle)),
              const SizedBox(width: GfSpace.x8),
              Text(_type.label,
                  style: const TextStyle(
                      color: Colors.black87, fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: GfSpace.x12),
          QrImageView(
            data: number,
            version: QrVersions.auto,
            size: 180,
            backgroundColor: Colors.white,
          ),
          const SizedBox(height: GfSpace.x8),
          Text(number,
              style: const TextStyle(
                  fontFamily: 'monospace',
                  color: Colors.black,
                  fontSize: 18,
                  fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }

  Future<void> _onDelete() async {
    final confirmed = await confirmDelete(
      context,
      title: 'Удалить пробу?',
      message: _gloveMode
          ? 'Подтвердите удаление (режим перчаток).'
          : 'Пробу можно будет восстановить в камералке до синхронизации.',
    );
    if (!confirmed) return;
    if (_persistedOnce) {
      try {
        await widget.repository.softDelete(_current(version: _version));
      } catch (e) {
        // Симметрично _doSave: реальный сбой хранилища не проглатываем и не
        // закрываем экран молча — сообщаем, оставляем возможность повторить.
        _setSave('не удалось удалить — проверьте память устройства',
            error: true);
        _snack('Не удалось удалить — проверьте память устройства');
        return;
      }
    }
    if (!mounted || _exiting) return;
    _exiting = true;
    Navigator.of(context).pop();
  }

  void _snack(String m) {
    if (!mounted) return;
    context.snack(m);
  }

  // --- helpers ----------------------------------------------------------------

  static String _fmt(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(1) : v.toString();
}
