import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';

import '../sync/hlc.dart';
import '../sync/relay_client.dart';
import '../sync/sync_engine.dart';
import '../theme/tokens.dart';
import '../util/format.dart';

/// Синхронизация — отдельный осознанный экран (ТЗ §6.8): связь — событие.
/// Большая кнопка, «что уйдёт», прогресс по пакетам с паузой, лог сеанса,
/// настройки relay. Фото-очереди пока нет (фото не реализованы — UNFINISHED).
class SyncScreen extends StatefulWidget {
  const SyncScreen(
      {super.key,
      required this.db,
      required this.deviceId,
      required this.clock});

  final Database db;
  final String deviceId;
  final HlcClock clock;

  @override
  State<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends State<SyncScreen> {
  final _urlCtrl = TextEditingController();
  final _tokenCtrl = TextEditingController();

  int _pendingCount = 0;
  int _pendingBytes = 0;
  Map<String, Object?>? _lastSession;
  SyncProgress? _progress;
  SyncEngine? _running;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _tokenCtrl.dispose();
    super.dispose();
  }

  Future<String?> _kv(String key) async {
    final rows = await widget.db
        .query('sync_state', where: 'key = ?', whereArgs: [key], limit: 1);
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  Future<void> _setKv(String key, String value) => widget.db.insert(
        'sync_state',
        {'key': key, 'value': value},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

  Future<void> _load() async {
    _urlCtrl.text = await _kv('relay_url') ?? '';
    _tokenCtrl.text = await _kv('relay_token') ?? '';
    final sessionJson = await _kv('last_session');
    if (sessionJson != null) {
      try {
        _lastSession = (jsonDecode(sessionJson) as Map).cast<String, Object?>();
      } catch (_) {
        _lastSession = null; // битый лог сеанса не роняет экран
      }
    }
    await _refreshPending();
  }

  Future<void> _refreshPending() async {
    // Та же метрика, которой пакетайзер режет пакеты (wire-байты UTF-8),
    // а не длина payload в символах — иначе оценка расходится с трафиком.
    final p = await pendingWireSize(widget.db);
    if (!mounted) return;
    setState(() {
      _pendingCount = p.count;
      _pendingBytes = p.bytes;
    });
  }

  bool get _configured =>
      _urlCtrl.text.trim().isNotEmpty && _tokenCtrl.text.trim().isNotEmpty;

  Future<void> _onSync() async {
    if (!_configured || _busy) return;
    final url = _urlCtrl.text.trim();
    final uri = Uri.tryParse(url);
    final isLocal =
        uri != null && (uri.host == 'localhost' || uri.host.startsWith('127.'));
    if (uri == null || (uri.scheme != 'https' && !isLocal)) {
      // Bearer-токен по открытому каналу — перехват на спутнике/Wi-Fi;
      // http допустим только для localhost-тестов.
      context.snack('Нужен https (http допустим только для localhost)');
      return;
    }
    await _setKv('relay_url', _urlCtrl.text.trim());
    await _setKv('relay_token', _tokenCtrl.text.trim());

    final client = RelayClient(
        baseUrl: _urlCtrl.text.trim(), token: _tokenCtrl.text.trim());
    final engine = SyncEngine(widget.db, client,
        deviceId: widget.deviceId, clock: widget.clock);
    setState(() {
      _busy = true;
      _running = engine;
      _progress = null;
    });
    try {
      final result = await engine.run(onProgress: (p) {
        if (mounted) setState(() => _progress = p);
      });
      if (!mounted) return;
      setState(() {
        _lastSession = {
          ...result.toMap(),
          'at': DateTime.now().toUtc().toIso8601String(),
        };
      });
      final msg = result.completed
          ? 'Сеанс завершён: отправлено ${result.pushedChanges}, '
              'принято ${result.pulledApplied}'
              '${result.conflicts > 0 ? ', конфликтов: ${result.conflicts}' : ''}'
          : result.error == null
              ? 'Пауза — продолжится с места остановки'
              : 'Обрыв: ${result.error} — возобновится со следующего сеанса';
      context.snack(msg);
    } catch (e) {
      // Последний рубеж (включая Error-типы — баги): пользователь видит сбой,
      // состояние синхрона согласовано (ack по пакетам, курсор в транзакции).
      if (mounted) context.snack('Сбой сеанса: $e');
    } finally {
      client.close();
      if (mounted) {
        setState(() {
          _busy = false;
          _running = null;
        });
        await _refreshPending();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: GfColors.bg,
        title: Text('Синхронизация', style: GfText.screenTitle),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(GfSpace.x16),
          children: [
            _pendingCard(),
            const SizedBox(height: GfSpace.x24),
            if (_progress != null) ...[
              _progressCard(_progress!),
              const SizedBox(height: GfSpace.x24),
            ],
            Text('RELAY', style: GfText.sectionLabel),
            const SizedBox(height: GfSpace.x8),
            TextField(
              controller: _urlCtrl,
              style: GfText.body,
              onChanged: (_) => setState(() {}),
              decoration: _dec('https://relay.example.com'),
            ),
            const SizedBox(height: GfSpace.x12),
            TextField(
              controller: _tokenCtrl,
              style: GfText.body,
              obscureText: true,
              onChanged: (_) => setState(() {}),
              decoration: _dec('Токен'),
            ),
            const SizedBox(height: GfSpace.x24),
            if (_lastSession != null) _sessionCard(_lastSession!),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.all(GfSpace.x16),
        child: SizedBox(
          height: GfTouch.min,
          width: double.infinity,
          child: _busy
              ? OutlinedButton(
                  onPressed: () => _running?.pause(),
                  style: gfOutlinedStyle(),
                  child: const Text('Пауза (после текущего пакета)'),
                )
              : FilledButton(
                  onPressed: _configured ? _onSync : null,
                  style: gfFilledStyle(),
                  child: Text(
                    _configured ? 'Синхронизировать' : 'Relay не настроен',
                    style: GfText.button,
                  ),
                ),
        ),
      ),
    );
  }

  Widget _pendingCard() {
    final kb = (_pendingBytes / 1024).ceil();
    return Container(
      padding: const EdgeInsets.all(GfSpace.x16),
      decoration: gfCard(),
      child: Row(children: [
        Icon(Icons.cloud_upload_outlined, color: GfColors.textSecondary),
        const SizedBox(width: GfSpace.x12),
        Expanded(
          child: Text(
            _pendingCount == 0
                ? 'Всё отправлено'
                : 'Уйдёт: ${plural(_pendingCount, 'запись', 'записи', 'записей')}'
                    ' · ~$kb КБ (до сжатия)',
            style: GfText.body,
          ),
        ),
      ]),
    );
  }

  Widget _progressCard(SyncProgress p) {
    final label = switch (p.phase) {
      'push' => 'Отправка: пакет ${p.packetsDone}/${p.packetsTotal} · '
          '${(p.bytesSent / 1024).ceil()} КБ',
      'pull' => 'Приём: применено ${p.pulledApplied}',
      _ => 'Готово',
    };
    return Container(
      padding: const EdgeInsets.all(GfSpace.x16),
      decoration: gfCard(borderColor: GfColors.accent),
      child: Column(children: [
        LinearProgressIndicator(
          value: p.phase == 'push' && p.packetsTotal > 0
              ? p.packetsDone / p.packetsTotal
              : null,
          backgroundColor: GfColors.surfaceHi,
          color: GfColors.accent,
        ),
        const SizedBox(height: GfSpace.x8),
        Text(label, style: GfText.hint),
      ]),
    );
  }

  Widget _sessionCard(Map<String, Object?> s) {
    final completed = s['completed'] == true;
    final packets = (s['pushed_packets'] as num?)?.toInt() ?? 0;
    return Container(
      padding: const EdgeInsets.all(GfSpace.x16),
      decoration: gfCard(),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('ПОСЛЕДНИЙ СЕАНС', style: GfText.sectionLabel),
        const SizedBox(height: GfSpace.x8),
        Text(
          '${s['at'] ?? '—'}\n'
          'отправлено: ${s['pushed_changes'] ?? 0} '
          '(${plural(packets, 'пакет', 'пакета', 'пакетов')}, '
          '${(((s['bytes_sent'] as num?) ?? 0) / 1024).ceil()} КБ) · '
          'принято: ${s['pulled_applied'] ?? 0} · '
          'конфликтов: ${s['conflicts'] ?? 0}\n'
          '${completed ? 'завершён' : 'обрыв/пауза: ${s['error'] ?? 'возобновляемо'}'}',
          style: GfText.hint,
        ),
      ]),
    );
  }

  InputDecoration _dec(String hint) => gfInputDecoration(hint: hint);
}
