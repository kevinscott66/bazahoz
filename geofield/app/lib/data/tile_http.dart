import 'dart:io';
import 'dart:typed_data';

import 'tile_cache.dart';
import 'tile_downloader.dart';

/// Прод-транспорт для [TileDownloader]: HTTP-загрузка тайлов с тайл-сервера,
/// URL которого настраивает оператор (как адрес relay). Источник и лицензия
/// тайлов — решение оператора; здесь только подстановка в шаблон и загрузка.
/// Используется ТОЛЬКО при заготовке региона в городе/по связи (не в поле).

/// Подстановка координат тайла в URL-шаблон. Поддерживает `{z}`/`{x}`/`{y}`
/// и опциональный `{s}` (поддомен tile-сервера, напр. a/b/c).
String tileUrl(String template, TileId t, {String? subdomain}) {
  var url = template
      .replaceAll('{z}', '${t.z}')
      .replaceAll('{x}', '${t.x}')
      .replaceAll('{y}', '${t.y}');
  if (subdomain != null) url = url.replaceAll('{s}', subdomain);
  return url;
}

/// HTTP-загрузчик тайлов. Ошибка/не-200/оверсайз → null (тайл просто не ляжет
/// в кэш; [TileDownloader] посчитает это failed) — заготовка не должна падать
/// из-за одного битого тайла. Клиент [HttpClient] инъектируется (тест — против
/// локального HttpServer, как e2e relay).
class HttpTileFetcher {
  HttpTileFetcher({
    required this.urlTemplate,
    this.subdomains = const [],
    HttpClient? client,
    this.timeout = const Duration(seconds: 20),
    this.maxTileBytes = 2 << 20, // 2 МБ — растровый тайл заведомо меньше
    this.userAgent = 'GeoField',
  }) : _client = client ?? HttpClient() {
    _client.connectionTimeout = timeout;
  }

  final String urlTemplate;
  final List<String> subdomains;
  final Duration timeout;
  final int maxTileBytes;
  final String userAgent;
  final HttpClient _client;

  /// [TileFetcher] для передачи в [TileDownloader].
  Future<Uint8List?> fetch(TileId t) async {
    // Поддомен по хешу тайла — равномернее раскладывает нагрузку/кэш CDN.
    final sub = subdomains.isEmpty
        ? null
        : subdomains[(t.x + t.y).abs() % subdomains.length];
    final uri = Uri.tryParse(tileUrl(urlTemplate, t, subdomain: sub));
    if (uri == null) return null;
    try {
      final req = await _client.getUrl(uri);
      req.headers.set(HttpHeaders.userAgentHeader, userAgent);
      final resp = await req.close().timeout(timeout);
      if (resp.statusCode != HttpStatus.ok) {
        await resp.drain<void>();
        return null;
      }
      final bytes = <int>[];
      await for (final chunk in resp) {
        bytes.addAll(chunk);
        if (bytes.length > maxTileBytes) {
          return null; // подозрительно большой ответ — не тайл
        }
      }
      return bytes.isEmpty ? null : Uint8List.fromList(bytes);
    } on Object {
      // Таймаут/обрыв/DNS — тайл не скачан, но заготовка продолжается.
      return null;
    }
  }

  void close() => _client.close(force: true);
}
