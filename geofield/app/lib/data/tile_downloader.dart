import 'dart:io';
import 'dart:typed_data';

import 'tile_cache.dart';

/// Скачивание офлайн-региона тайлов (за флагом `mapBasemap`). Оркестрация —
/// чистая и тестируемая без сети: сам транспорт (откуда берутся байты тайла)
/// инъектируется как [TileFetcher]. Прод подставит HTTP-загрузку с тайл-сервера,
/// URL которого настраивает оператор (как адрес relay); тесты — фейк без сети.
/// Скачивание делается В ГОРОДЕ/ПРИ СВЯЗИ заранее; в поле — только чтение кэша.

/// Загрузка одного тайла: байты PNG или null (нет тайла/ошибка сети).
typedef TileFetcher = Future<Uint8List?> Function(TileId tile);

/// Токен отмены долгой загрузки (геолог может прервать).
class CancelToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}

/// Итог скачивания региона.
class TileDownloadResult {
  const TileDownloadResult({
    required this.downloaded,
    required this.skipped,
    required this.failed,
    required this.cancelled,
  });

  /// Реально скачано и записано в кэш.
  final int downloaded;

  /// Пропущено (уже были в кэше).
  final int skipped;

  /// Не удалось скачать (fetcher вернул null).
  final int failed;

  /// Прервано пользователем до конца.
  final bool cancelled;
}

class TileDownloader {
  TileDownloader({
    required this.cacheDir,
    required this.fetcher,
    this.maxBytes = 500 * 1024 * 1024, // лимит кэша по умолчанию — 500 МБ
  });

  final Directory cacheDir;
  final TileFetcher fetcher;
  final int maxBytes;

  /// Тайлы из [needed], которых ещё нет в [index] — только их и качаем.
  List<TileId> missing(List<TileId> needed, TileCacheIndex index) =>
      [for (final t in needed) if (!index.has(t.z, t.x, t.y)) t];

  /// Скачать недостающие тайлы региона: пропустить уже скачанные, записать
  /// новые в `{cache}/{z}/{x}/{y}.png`, держать кэш под [maxBytes] (вытеснить
  /// самые старые), уважать отмену. [onProgress] — (сделано, всего к загрузке).
  Future<TileDownloadResult> downloadRegion({
    required List<TileId> needed,
    required TileCacheIndex index,
    void Function(int done, int total)? onProgress,
    CancelToken? cancel,
  }) async {
    final todo = missing(needed, index);
    final skipped = needed.length - todo.length;
    var downloaded = 0, failed = 0;
    for (var i = 0; i < todo.length; i++) {
      if (cancel?.isCancelled ?? false) {
        return TileDownloadResult(
            downloaded: downloaded,
            skipped: skipped,
            failed: failed,
            cancelled: true);
      }
      final t = todo[i];
      final bytes = await fetcher(t);
      if (bytes == null) {
        failed++;
      } else {
        final f = File('${cacheDir.path}/${t.z}/${t.x}/${t.y}.png');
        await f.parent.create(recursive: true);
        await f.writeAsBytes(bytes, flush: true);
        downloaded++;
      }
      onProgress?.call(i + 1, todo.length);
    }
    await enforceLimit();
    return TileDownloadResult(
        downloaded: downloaded,
        skipped: skipped,
        failed: failed,
        cancelled: false);
  }

  /// Держать кэш под [maxBytes]: вытеснять самые старые тайлы (по времени
  /// записи) до тех пор, пока суммарный размер не уложится в лимит. Оценка
  /// размера — реальная (сумма длин файлов кэша).
  Future<void> enforceLimit() async {
    if (!await cacheDir.exists()) return;
    final files = <File>[];
    var total = 0;
    await for (final e in cacheDir.list(recursive: true, followLinks: false)) {
      if (e is File && e.path.endsWith('.png')) {
        files.add(e);
        total += await e.length();
      }
    }
    if (total <= maxBytes) return;
    files.sort((a, b) =>
        a.statSync().modified.compareTo(b.statSync().modified)); // старые первыми
    for (final f in files) {
      if (total <= maxBytes) break;
      total -= await f.length();
      await f.delete();
    }
  }
}
