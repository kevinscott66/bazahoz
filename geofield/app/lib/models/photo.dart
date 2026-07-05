import 'sample.dart' show SyncStatus;

/// Фото, привязанное к точке/пробе (таблица `photos`, ТЗ §6.6).
/// Файл лежит локально (file_path); по спутнику уходят только метаданные —
/// defer_until_office=1 по умолчанию, выгрузка файлов — камералка/этап 2.
class Photo {
  Photo({
    required this.id,
    required this.parentType, // point | interval | sample | borehole
    required this.parentId,
    required this.filePath,
    this.lat,
    this.lon,
    this.takenAt,
    required this.authorId,
    required this.createdAt,
    required this.modifiedAt,
    this.version = 1,
    this.syncStatus = SyncStatus.pending,
    this.deleted = false,
  });

  final String id;
  final String parentType;
  final String parentId;
  final String filePath;
  final double? lat;
  final double? lon;
  final String? takenAt;
  final String authorId;
  final String createdAt;
  final String modifiedAt;
  final int version;
  final SyncStatus syncStatus;
  final bool deleted;

  Map<String, Object?> toMap() => {
        'id': id,
        'parent_type': parentType,
        'parent_id': parentId,
        'file_path': filePath,
        'lat': lat,
        'lon': lon,
        'taken_at': takenAt,
        'author_id': authorId,
        'created_at': createdAt,
        'modified_at': modifiedAt,
        'version': version,
        'sync_status': syncStatus.db,
        'deleted': deleted ? 1 : 0,
      };

  static Photo fromMap(Map<String, Object?> m) => Photo(
        id: m['id'] as String,
        parentType: m['parent_type'] as String,
        parentId: m['parent_id'] as String,
        filePath: m['file_path'] as String,
        lat: m['lat'] as double?,
        lon: m['lon'] as double?,
        takenAt: m['taken_at'] as String?,
        authorId: (m['author_id'] as String?) ?? '',
        createdAt: m['created_at'] as String,
        modifiedAt: m['modified_at'] as String,
        version: (m['version'] as int?) ?? 1,
        syncStatus: SyncStatus.values.firstWhere(
          (s) => s.db == m['sync_status'],
          orElse: () => SyncStatus.pending,
        ),
        deleted: (m['deleted'] as int? ?? 0) != 0,
      );
}
