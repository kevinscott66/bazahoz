import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart' show getDatabasesPath;

import '../data/dictionary_repository.dart';
import '../data/sample_repository.dart';
import '../lab/lab_service.dart';
import '../models/sample.dart';
import '../theme/sample_type.dart';
import '../theme/tokens.dart';
import '../widgets/sample_row.dart';

/// Лаборатория (этап 3, ТЗ §6.5/§6.9): ведомость отправки проб и приём
/// результатов с автопривязкой по штрихкоду. Пробы группируются по статусу
/// жизненного цикла; ведомость переводит отобранные/упакованные в «отправлена».
class LabScreen extends StatefulWidget {
  const LabScreen({
    super.key,
    required this.samples,
    required this.dictionaries,
    required this.lab,
    required this.projectId,
  });

  final SampleRepository samples;
  final DictionaryRepository dictionaries;
  final LabService lab;
  final String projectId;

  @override
  State<LabScreen> createState() => _LabScreenState();
}

class _LabScreenState extends State<LabScreen> {
  List<Sample> _pending =
      const []; // отобрана/упакована — кандидаты в ведомость
  List<Sample> _sent = const [];
  List<Sample> _done = const [];
  bool _loading = true;
  bool _busy = false; // двойной тап «Сформировать» не запускает второй проход

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final pending = await widget.samples.listByStatus(
        widget.projectId, [SampleStatus.collected, SampleStatus.packed]);
    final sent = await widget.samples
        .listByStatus(widget.projectId, [SampleStatus.sent]);
    final done = await widget.samples
        .listByStatus(widget.projectId, [SampleStatus.resultReceived]);
    if (!mounted) return;
    setState(() {
      _pending = pending;
      _sent = sent;
      _done = done;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: GfColors.bg,
        title: Text('Лаборатория', style: GfText.screenTitle),
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(GfSpace.x16),
                children: [
                  _section('К ОТПРАВКЕ (${_pending.length})', _pending),
                  const SizedBox(height: GfSpace.x24),
                  _section('ОТПРАВЛЕНЫ (${_sent.length})', _sent),
                  const SizedBox(height: GfSpace.x24),
                  _section('РЕЗУЛЬТАТ ПОЛУЧЕН (${_done.length})', _done),
                ],
              ),
      ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.all(GfSpace.x16),
        child: Row(children: [
          Expanded(
            child: SizedBox(
              height: GfTouch.min,
              child: FilledButton(
                onPressed: ((_pending.isEmpty && _sent.isEmpty) || _busy)
                    ? null
                    : _onDispatch,
                style: gfFilledStyle(),
                child: Text(
                  _pending.isNotEmpty
                      ? 'Ведомость (${_pending.length})'
                      : _sent.isNotEmpty
                          ? 'Ведомость повторно (${_sent.length})'
                          : 'Нечего отправлять',
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w700),
                ),
              ),
            ),
          ),
          const SizedBox(width: GfSpace.x12),
          Expanded(
            child: SizedBox(
              height: GfTouch.min,
              child: OutlinedButton(
                onPressed: _busy ? null : _onImport,
                style: gfOutlinedStyle(),
                child: const Text('Импорт результатов'),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _section(String title, List<Sample> items) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: GfText.sectionLabel),
        const SizedBox(height: GfSpace.x8),
        if (items.isEmpty)
          Text('—', style: GfText.hint)
        else
          for (final s in items) SampleRow(s),
      ],
    );
  }

  Future<void> _onDispatch() async {
    // Очередь пуста, но есть отправленные — повторная печать ведомости
    // (после сбоя записи файла документ иначе не получить, §6.9).
    final reprint = _pending.isEmpty;
    final batch = reprint ? _sent : _pending;
    final count = batch.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: GfColors.surfaceHi,
        title:
            Text(reprint ? 'Повторная ведомость?' : 'Сформировать ведомость?'),
        content: Text(reprint
            ? 'Ведомость по уже отправленным пробам ($count) сохранится '
                'CSV-файлом; статусы не изменятся.'
            : 'Пробы из очереди ($count) будут помечены отправленными в '
                'лабораторию; ведомость сохранится CSV-файлом.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Отмена')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Сформировать')),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _busy = true);
    var advanced = 0;
    try {
      // Сначала статусы (источник правды), затем файл: иначе сбой переводов
      // оставлял бы на диске ведомость «отправлено всё», противореча базе.
      advanced = await widget.lab.markDispatched(batch);
      final typeLabels = {
        for (final t in SampleType.values) t.code: t.label,
      };
      final csv = widget.lab.buildDispatchCsv(batch,
          typeLabel: (code) => typeLabels[code] ?? code);
      final dir = await getDatabasesPath();
      Directory(dir).createSync(recursive: true);
      final file = File(p.join(dir,
          'geofield_dispatch_${DateTime.now().toUtc().millisecondsSinceEpoch}.csv'))
        ..writeAsStringSync(csv);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Ведомость: ${file.path} · отправлено проб: $advanced'),
        duration: const Duration(seconds: 6),
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(advanced > 0
              ? 'Статусы переведены ($advanced), но ведомость не записана: $e'
              : 'Ведомость не сформирована: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    await _reload();
  }

  Future<void> _onImport() async {
    final pathCtrl = TextEditingController();
    final path = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: GfColors.surfaceHi,
        title: const Text('Импорт результатов'),
        content: TextField(
          controller: pathCtrl,
          style: GfText.body,
          decoration: InputDecoration(
              hintText: 'Путь к CSV-файлу лаборатории', hintStyle: GfText.hint),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Отмена')),
          TextButton(
              onPressed: () => Navigator.pop(context, pathCtrl.text.trim()),
              child: const Text('Импортировать')),
        ],
      ),
    );
    // Контроллер диалога нельзя освобождать до конца анимации закрытия.
    WidgetsBinding.instance.addPostFrameCallback((_) => pathCtrl.dispose());
    if (path == null || path.isEmpty) return;
    if (_busy) return; // ведомость/другой импорт ещё идёт — не пересекаем
    setState(() => _busy = true);
    try {
      final text = File(path).readAsStringSync();
      final outcome = await widget.lab.importResults(widget.projectId, text);
      if (!mounted) return;
      final msg = 'Принято результатов: ${outcome.applied} · '
          'проб закрыто: ${outcome.samplesUpdated}'
          '${outcome.issues.isEmpty ? '' : ' · нестыковок: ${outcome.issues.length}'}';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(outcome.issues.isEmpty
            ? msg
            : '$msg\n${outcome.issues.take(3).join('\n')}'),
        duration: const Duration(seconds: 8),
      ));
    } on FileSystemException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Файл не прочитан: ${e.message}')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    await _reload();
  }
}
