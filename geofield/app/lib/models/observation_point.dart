import 'sample.dart' show SyncStatus;

/// Точка наблюдения (ТЗ §6.3). Поля соответствуют таблице `observation_points`
/// (geofield/core/schema/001_initial.sql). Координаты канонически в WGS-84.
class ObservationPoint {
  ObservationPoint({
    required this.id,
    required this.routeId,
    required this.number,
    this.lat,
    this.lon,
    this.elevation,
    this.coordSource,
    this.gpsAccuracyM,
    this.observedAt,
    this.objectType,
    this.rockCode,
    this.colorCode,
    this.grain,
    this.alterationCode,
    this.minerals,
    this.note,
    this.isDraft = true,
    required this.authorId,
    required this.createdAt,
    required this.modifiedAt,
    this.version = 1,
    this.syncStatus = SyncStatus.pending,
    this.deleted = false,
  });

  final String id;
  final String routeId;
  final String number;
  final double? lat;
  final double? lon;
  final double? elevation;
  final String? coordSource; // 'gps' | 'manual'
  final double? gpsAccuracyM;
  final String? observedAt;
  final String? objectType; // код dictionaries(dict_type='object_type')
  final String? rockCode; // код dictionaries(dict_type='rock')
  final String? colorCode;
  final String? grain;
  final String? alterationCode;
  final String? minerals; // JSON [{code, intensity}]
  final String? note;
  final bool isDraft;
  final String authorId;
  final String createdAt;
  final String modifiedAt;
  final int version;
  final SyncStatus syncStatus;
  final bool deleted;

  Map<String, Object?> toMap() => {
        'id': id,
        'route_id': routeId,
        'number': number,
        'lat': lat,
        'lon': lon,
        'elevation': elevation,
        'coord_source': coordSource,
        'gps_accuracy_m': gpsAccuracyM,
        'observed_at': observedAt,
        'object_type': objectType,
        'rock_code': rockCode,
        'color_code': colorCode,
        'grain': grain,
        'alteration_code': alterationCode,
        'minerals': minerals,
        'note': note,
        'is_draft': isDraft ? 1 : 0,
        'author_id': authorId,
        'created_at': createdAt,
        'modified_at': modifiedAt,
        'version': version,
        'sync_status': syncStatus.db,
        'deleted': deleted ? 1 : 0,
      };

  static ObservationPoint fromMap(Map<String, Object?> m) => ObservationPoint(
        id: m['id'] as String,
        routeId: m['route_id'] as String,
        number: m['number'] as String,
        lat: m['lat'] as double?,
        lon: m['lon'] as double?,
        elevation: m['elevation'] as double?,
        coordSource: m['coord_source'] as String?,
        gpsAccuracyM: m['gps_accuracy_m'] as double?,
        observedAt: m['observed_at'] as String?,
        objectType: m['object_type'] as String?,
        rockCode: m['rock_code'] as String?,
        colorCode: m['color_code'] as String?,
        grain: m['grain'] as String?,
        alterationCode: m['alteration_code'] as String?,
        minerals: m['minerals'] as String?,
        note: m['note'] as String?,
        isDraft: (m['is_draft'] as int? ?? 1) != 0,
        authorId: (m['author_id'] as String?) ?? '',
        createdAt: m['created_at'] as String,
        modifiedAt: m['modified_at'] as String,
        version: (m['version'] as int?) ?? 1,
        syncStatus: _sync(m['sync_status'] as String?),
        deleted: (m['deleted'] as int? ?? 0) != 0,
      );

  static SyncStatus _sync(String? v) => SyncStatus.values.firstWhere(
        (s) => s.db == v,
        orElse: () => SyncStatus.pending,
      );
}

/// Типы структурных замеров (structural_measurements.measure_type).
/// Состав — по ревизии geo-consultant (рудное золото: жилы, трещиноватость,
/// контакты — главные замеры, не только слоистость).
const Map<String, String> measureTypes = {
  'bedding': 'Слоистость',
  'foliation': 'Сланцеватость',
  'joint': 'Трещина',
  'vein': 'Жила',
  'contact': 'Контакт',
  'fault_zone': 'Зона разлома',
};

/// Структурный замер (таблица `structural_measurements`, родитель — точка).
class StructuralMeasurement {
  StructuralMeasurement({
    required this.id,
    required this.parentType,
    required this.parentId,
    this.measureType,
    this.dipAzimuth,
    this.dipAngle,
    this.source, // 'manual' | 'sensor'
    this.note,
    required this.authorId,
    required this.createdAt,
    required this.modifiedAt,
  });

  final String id;
  final String parentType; // 'point' | 'interval'
  final String parentId;
  final String? measureType;
  final double? dipAzimuth;
  final double? dipAngle;
  final String? source;
  final String? note;
  final String authorId;
  final String createdAt;
  final String modifiedAt;

  Map<String, Object?> toMap() => {
        'id': id,
        'parent_type': parentType,
        'parent_id': parentId,
        'measure_type': measureType,
        'dip_azimuth': dipAzimuth,
        'dip_angle': dipAngle,
        'source': source,
        'note': note,
        'author_id': authorId,
        'created_at': createdAt,
        'modified_at': modifiedAt,
      };

  static StructuralMeasurement fromMap(Map<String, Object?> m) =>
      StructuralMeasurement(
        id: m['id'] as String,
        parentType: m['parent_type'] as String,
        parentId: m['parent_id'] as String,
        measureType: m['measure_type'] as String?,
        dipAzimuth: m['dip_azimuth'] as double?,
        dipAngle: m['dip_angle'] as double?,
        source: m['source'] as String?,
        note: m['note'] as String?,
        authorId: (m['author_id'] as String?) ?? '',
        createdAt: m['created_at'] as String,
        modifiedAt: m['modified_at'] as String,
      );
}
