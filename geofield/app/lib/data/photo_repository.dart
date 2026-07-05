import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../models/photo.dart';
import '../sync/hlc.dart';
import '../util/format.dart';
import 'change_payload.dart';

/// Доступ к фото. Тот же инвариант, что у остальных сущностей: строка +
/// change_log + row_clock атомарно. Плюс владение файлами: снятый кадр
/// КОПИРУЕТСЯ в каталог приложения — исходник из камеры/галереи временный,
/// системе ничто не мешает его удалить (потеря фото недопустима, ТЗ §0).
class PhotoRepository {
  PhotoRepository(this._db,
      {required this.deviceId, required this.authorId, required this.clock});

  final Database _db;
  final String deviceId;
  final String authorId;
  final HlcClock clock;
  final Uuid _uuid = const Uuid();

  /// Каталог фото — рядом с базой (на iOS это Documents: виден в «Файлах»).
  Future<Directory> photosDir() async {
    final dir = Directory(
        p.join(await databaseFactory.getDatabasesPath(), 'geofield_photos'));
    dir.createSync(recursive: true);
    return dir;
  }

  /// Принять снятый/выбранный файл: копия в каталог приложения + строка +
  /// мутация. Возвращает сохранённое фото.
  Future<Photo> addFromFile(
    String sourcePath, {
    required String parentType,
    required String parentId,
    double? lat,
    double? lon,
  }) async {
    final id = _uuid.v4();
    final ext =
        p.extension(sourcePath).isEmpty ? '.jpg' : p.extension(sourcePath);
    final dir = await photosDir();
    final destPath = p.join(dir.path, '$id$ext');
    File(sourcePath).copySync(destPath);
    final now = nowIso();
    final photo = Photo(
      id: id,
      parentType: parentType,
      parentId: parentId,
      filePath: destPath,
      lat: lat,
      lon: lon,
      takenAt: now,
      authorId: authorId,
      createdAt: now,
      modifiedAt: now,
    );
    final map = photo.toMap();
    try {
      await _db.transaction((txn) async {
        await txn.insert('photos', map);
        await logChange(txn,
            clock: clock,
            table: 'photos',
            entityId: id,
            op: 'insert',
            payload: insertPayload(map),
            authorId: authorId,
            deviceId: deviceId);
      });
    } catch (e) {
      // Строка не записалась — копию не бросаем сиротой на диске.
      File(destPath).deleteSync();
      rethrow;
    }
    return photo;
  }

  Future<List<Photo>> listByParent(String parentType, String parentId) async {
    final rows = await _db.query(
      'photos',
      where: 'parent_type = ? AND parent_id = ? AND deleted = 0',
      whereArgs: [parentType, parentId],
      orderBy: 'created_at',
    );
    return rows.map(Photo.fromMap).toList();
  }

  /// Мягкое удаление строки. Файл НЕ трогаем: до синхронизации/камералки
  /// снимок восстановим, а место освободит компакция этапа 2.
  Future<void> softDelete(Photo photo) async {
    await _db.transaction((txn) async {
      await txn.update(
        'photos',
        {
          'deleted': 1,
          'version': photo.version + 1,
          'modified_at': nowIso(),
          'sync_status': 'pending',
        },
        where: 'id = ?',
        whereArgs: [photo.id],
      );
      await logChange(txn,
          clock: clock,
          table: 'photos',
          entityId: photo.id,
          op: 'delete',
          payload: const {},
          authorId: authorId,
          deviceId: deviceId);
    });
  }
}
