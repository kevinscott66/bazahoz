/// Жизненный цикл пробы (ТЗ 2, 6.5). Порядок переходов:
/// collected → packed → sent → resultReceived. Откат/прыжок мимо — нарушение
/// инварианта (ловит logic-auditor). Коды совпадают с samples.status в схеме.
enum SampleStatus {
  collected('collected', 'отобрана'),
  packed('packed', 'упакована'),
  sent('sent', 'отправлена'),
  resultReceived('result_received', 'результат получен');

  const SampleStatus(this.db, this.label);

  final String db;
  final String label;

  static SampleStatus fromDb(String v) =>
      values.firstWhere((s) => s.db == v, orElse: () => SampleStatus.collected);
}

/// Статус синхронизации записи (schema: sync_status).
enum SyncStatus {
  pending('pending', 'не отправлено'),
  queued('queued', 'в очереди'),
  sent('sent', 'отправлено'),
  confirmed('confirmed', 'подтверждено');

  const SyncStatus(this.db, this.label);

  final String db;
  final String label;
}

/// Проба — главная единица учёта. Поля соответствуют таблице `samples`.
class Sample {
  Sample({
    required this.id,
    required this.projectId,
    this.parentType,
    this.parentId,
    required this.sampleNumber,
    required this.sampleType,
    this.barcode,
    this.depthFrom,
    this.depthTo,
    this.mass,
    this.lengthM,
    this.status = SampleStatus.collected,
    this.note,
    required this.authorId,
    required this.createdAt,
    required this.modifiedAt,
    this.version = 1,
    this.syncStatus = SyncStatus.pending,
    this.deleted = false,
  });

  final String id;
  final String projectId;
  final String? parentType; // 'point' | 'interval'
  final String? parentId;
  final String sampleNumber;
  final String sampleType; // код SampleType
  final String? barcode;
  final double? depthFrom;
  final double? depthTo;
  final double? mass;
  final double? lengthM;
  final SampleStatus status;
  final String? note;
  final String authorId;
  final String createdAt;
  final String modifiedAt;
  final int version;
  final SyncStatus syncStatus;
  final bool deleted;

  Sample copyWith({
    String? sampleNumber,
    String? sampleType,
    String? barcode,
    double? depthFrom,
    double? depthTo,
    double? mass,
    double? lengthM,
    SampleStatus? status,
    String? note,
    String? modifiedAt,
    int? version,
    SyncStatus? syncStatus,
    bool? deleted,
  }) {
    return Sample(
      id: id,
      projectId: projectId,
      parentType: parentType,
      parentId: parentId,
      sampleNumber: sampleNumber ?? this.sampleNumber,
      sampleType: sampleType ?? this.sampleType,
      barcode: barcode ?? this.barcode,
      depthFrom: depthFrom ?? this.depthFrom,
      depthTo: depthTo ?? this.depthTo,
      mass: mass ?? this.mass,
      lengthM: lengthM ?? this.lengthM,
      status: status ?? this.status,
      note: note ?? this.note,
      authorId: authorId,
      createdAt: createdAt,
      modifiedAt: modifiedAt ?? this.modifiedAt,
      version: version ?? this.version,
      syncStatus: syncStatus ?? this.syncStatus,
      deleted: deleted ?? this.deleted,
    );
  }

  Map<String, Object?> toMap() => {
        'id': id,
        'project_id': projectId,
        'parent_type': parentType,
        'parent_id': parentId,
        'sample_number': sampleNumber,
        'sample_type': sampleType,
        'barcode': barcode,
        'depth_from': depthFrom,
        'depth_to': depthTo,
        'mass': mass,
        'length_m': lengthM,
        'status': status.db,
        'note': note,
        'author_id': authorId,
        'created_at': createdAt,
        'modified_at': modifiedAt,
        'version': version,
        'sync_status': syncStatus.db,
        'deleted': deleted ? 1 : 0,
      };
}
