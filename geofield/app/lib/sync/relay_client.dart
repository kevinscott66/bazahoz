import 'dart:convert';
import 'dart:io';

/// Ответ relay на пакет (см. relay/README.md).
class PushAck {
  const PushAck({
    required this.batchId,
    required this.accepted,
    required this.duplicates,
    required this.lastSeq,
  });

  final String batchId;
  final List<String> accepted;
  final List<String> duplicates;
  final int lastSeq;
}

/// Страница PULL.
class PullPage {
  const PullPage({
    required this.changes,
    required this.nextCursor,
    required this.hasMore,
  });

  final List<Map<String, Object?>> changes;
  final int nextCursor;
  final bool hasMore;
}

/// Ошибка обмена с relay: код и текст сервера — для лога сеанса и решения
/// о повторе (5xx — повторяемо, 4xx — нет, чинить пакет/настройки).
class RelayException implements Exception {
  RelayException(this.statusCode, this.message);

  final int statusCode;
  final String message;

  bool get retryable => statusCode >= 500;

  @override
  String toString() => 'relay $statusCode: $message';
}

/// HTTP-клиент relay. Пакеты уходят gzip'ом (протокол §3.1; zstd — позже).
class RelayClient {
  RelayClient({required this.baseUrl, required this.token, HttpClient? http})
      : _http = http ?? HttpClient() {
    _http.connectionTimeout = const Duration(seconds: 30);
  }

  final String baseUrl;
  final String token;
  final HttpClient _http;

  Future<PushAck> push(
      String deviceId, List<Map<String, Object?>> changes) async {
    final body = gzip.encode(utf8.encode(jsonEncode({
      'device_id': deviceId,
      'changes': changes,
    })));
    final req = await _http.postUrl(Uri.parse('$baseUrl/v1/push'));
    req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
    req.headers.set('Content-Encoding', 'gzip');
    req.add(body);
    final resp = await req.close();
    final text = await resp.transform(utf8.decoder).join();
    if (resp.statusCode != HttpStatus.ok) {
      throw RelayException(resp.statusCode, text);
    }
    final m = _decodeObject(text);
    // Оборонительный разбор: кривой ответ сервера — это RelayException
    // (управляемый обрыв сеанса), а не TypeError мимо всей обработки.
    final batchId = m['batch_id'];
    final lastSeq = m['last_seq'];
    if (batchId is! String || lastSeq is! num) {
      throw RelayException(0, 'некорректный ответ push: $text');
    }
    return PushAck(
      batchId: batchId,
      accepted: _stringList(m['accepted']),
      duplicates: _stringList(m['duplicates']),
      lastSeq: lastSeq.toInt(),
    );
  }

  Future<PullPage> pull(String deviceId, int cursor, {int limit = 500}) async {
    final uri = Uri.parse(
        '$baseUrl/v1/pull?device_id=$deviceId&cursor=$cursor&limit=$limit');
    final req = await _http.getUrl(uri);
    req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    final resp = await req.close();
    final text = await resp.transform(utf8.decoder).join();
    if (resp.statusCode != HttpStatus.ok) {
      throw RelayException(resp.statusCode, text);
    }
    final m = _decodeObject(text);
    final nextCursor = m['next_cursor'];
    if (nextCursor is! num) {
      throw RelayException(0, 'некорректный ответ pull: $text');
    }
    final rawChanges = m['changes'];
    final changes = <Map<String, Object?>>[];
    if (rawChanges is List) {
      for (final e in rawChanges) {
        if (e is! Map) {
          throw RelayException(0, 'некорректная мутация в pull: $e');
        }
        changes.add(e.map((k, v) => MapEntry('$k', v as Object?)));
      }
    }
    return PullPage(
      changes: changes,
      nextCursor: nextCursor.toInt(),
      hasMore: m['has_more'] == true,
    );
  }

  void close() => _http.close(force: true);

  static Map<String, Object?> _decodeObject(String text) {
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException catch (e) {
      throw RelayException(0, 'ответ relay не JSON: $e');
    }
    if (decoded is! Map) {
      throw RelayException(0, 'ответ relay не объект: $text');
    }
    return decoded.map((k, v) => MapEntry('$k', v as Object?));
  }

  static List<String> _stringList(Object? v) {
    if (v is! List) return const [];
    return [for (final e in v) '$e'];
  }
}
