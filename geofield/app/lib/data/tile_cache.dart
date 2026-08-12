import 'dart:io';
import 'dart:math' as math;

/// Тайловая математика и индекс офлайн-кэша (OSM slippy map, EPSG:3857) —
/// фундамент офлайн-подложки (за флагом `mapBasemap`). Чистые функции: какие
/// тайлы покрывают регион (для заготовки/скачивания) и какие уже есть в кэше
/// (быстрый `has` вместо синхронного `existsSync` на каждый тайл — долг аудита).

/// Тайл slippy-map: зум и целочисленные x/y. Путь в кэше — `{z}/{x}/{y}.png`.
class TileId {
  const TileId(this.z, this.x, this.y);

  final int z;
  final int x;
  final int y;

  String get key => '$z/$x/$y';

  @override
  bool operator ==(Object other) =>
      other is TileId && other.z == z && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(z, x, y);

  @override
  String toString() => 'TileId($key)';
}

/// lon/lat (град, WGS-84) → тайл на зуме [z] (OSM/Web-Mercator). x/y зажаты в
/// [0, 2^z − 1]: за пределами широты веб-меркатора (±85.051°) — крайний тайл.
TileId tileForLonLat(double lon, double lat, int z) {
  final n = 1 << z; // 2^z
  final latClamped = lat.clamp(-85.05112878, 85.05112878);
  final latRad = latClamped * math.pi / 180.0;
  var x = ((lon + 180.0) / 360.0 * n).floor();
  var y = ((1.0 -
              math.log(math.tan(latRad) + 1.0 / math.cos(latRad)) / math.pi) /
          2.0 *
          n)
      .floor();
  x = x.clamp(0, n - 1);
  y = y.clamp(0, n - 1);
  return TileId(z, x, y);
}

/// Число тайлов, покрывающих bbox на зумах [minZoom]..[maxZoom] — дёшево, без
/// материализации списка (для оценки веса заготовки до скачивания).
int countTilesForRegion({
  required double west,
  required double south,
  required double east,
  required double north,
  required int minZoom,
  required int maxZoom,
}) {
  var total = 0;
  for (var z = minZoom; z <= maxZoom; z++) {
    final tl = tileForLonLat(west, north, z); // северо-запад → мин x, мин y
    final br = tileForLonLat(east, south, z); // юго-восток → макс x, макс y
    final cols = (br.x - tl.x).abs() + 1;
    final rows = (br.y - tl.y).abs() + 1;
    total += cols * rows;
  }
  return total;
}

/// Тайлы, покрывающие bbox на зумах [minZoom]..[maxZoom]. Для защиты от
/// взрыва памяти при большом регионе/зуме бросает [ArgumentError], если тайлов
/// больше [maxTiles] — вызывающий сузит зум/регион (планируется по
/// [countTilesForRegion]).
List<TileId> tilesForRegion({
  required double west,
  required double south,
  required double east,
  required double north,
  required int minZoom,
  required int maxZoom,
  int maxTiles = 500000,
}) {
  final count = countTilesForRegion(
      west: west,
      south: south,
      east: east,
      north: north,
      minZoom: minZoom,
      maxZoom: maxZoom);
  if (count > maxTiles) {
    throw ArgumentError(
        'Регион требует $count тайлов (> $maxTiles) — сузьте зум или область');
  }
  final out = <TileId>[];
  for (var z = minZoom; z <= maxZoom; z++) {
    final tl = tileForLonLat(west, north, z);
    final br = tileForLonLat(east, south, z);
    final x0 = math.min(tl.x, br.x), x1 = math.max(tl.x, br.x);
    final y0 = math.min(tl.y, br.y), y1 = math.max(tl.y, br.y);
    for (var x = x0; x <= x1; x++) {
      for (var y = y0; y <= y1; y++) {
        out.add(TileId(z, x, y));
      }
    }
  }
  return out;
}

/// Индекс присутствующих в кэше тайлов: `has()` за O(1) (вместо синхронного
/// `existsSync` на каждый тайл в горячем пути рендера) и оценка покрытия
/// региона для честной метки «тайлы не загружены / частично».
class TileCacheIndex {
  TileCacheIndex(this.baseDir, this._present);

  /// Корень кэша (`{baseDir}/{z}/{x}/{y}.png`). null — тайлов нет вовсе.
  final Directory? baseDir;
  final Set<String> _present; // ключи '{z}/{x}/{y}'

  bool get isEmpty => _present.isEmpty;
  int get length => _present.length;

  bool has(int z, int x, int y) => _present.contains('$z/$x/$y');

  /// Доля тайлов [needed], присутствующих в кэше (0..1). Пустой список → 1.0
  /// (нечего покрывать), пустой индекс → 0.0.
  double coverage(Iterable<TileId> needed) {
    var total = 0, have = 0;
    for (final t in needed) {
      total++;
      if (_present.contains(t.key)) have++;
    }
    return total == 0 ? 1.0 : have / total;
  }

  static TileCacheIndex empty() => TileCacheIndex(null, const {});

  /// Построить индекс сканированием каталога `{z}/{x}/{y}.png`. Асинхронно и
  /// один раз при открытии карты (не в горячем пути кадра).
  static Future<TileCacheIndex> scan(Directory dir) async {
    final present = <String>{};
    if (!await dir.exists()) return TileCacheIndex(dir, present);
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.png')) continue;
      // Ключ '{z}/{x}/{y}' из хвоста пути.
      final parts = entity.path.split(Platform.pathSeparator);
      if (parts.length < 3) continue;
      final z = parts[parts.length - 3];
      final x = parts[parts.length - 2];
      final y = parts.last.replaceAll('.png', '');
      if (int.tryParse(z) == null ||
          int.tryParse(x) == null ||
          int.tryParse(y) == null) {
        continue;
      }
      present.add('$z/$x/$y');
    }
    return TileCacheIndex(dir, present);
  }
}
