import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:geofield/data/database.dart';
import 'package:geofield/data/photo_repository.dart';
import 'package:geofield/sync/hlc.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  test('миграция v1→v2: photos докатывается на живую базу устройства',
      () async {
    final dir = Directory.systemTemp.createTempSync('geofield_mig');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = p.join(dir.path, 'geofield.db');

    // База, как её оставила сборка v1 (без photos).
    final v1 = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
          version: 1, onCreate: (d, _) => AppDatabase.migrate001(d)),
    );
    await v1.insert('projects', {
      'id': 'p1',
      'name': 'Тест',
      'created_at': 't',
      'modified_at': 't',
    });
    await v1.close();

    // Обновление приложения: open() должен докатить v2, не тронув данные.
    final app = await AppDatabase.open(path: path);
    addTearDown(() => app.db.close());
    final projects = await app.db.query('projects');
    expect(projects, hasLength(1), reason: 'данные v1 не тронуты');
    await app.db.insert('photos', {
      'id': 'ph1',
      'parent_type': 'point',
      'parent_id': 'pt1',
      'file_path': '/tmp/x.jpg',
      'created_at': 't',
      'modified_at': 't',
    });
    expect(await app.db.query('photos'), hasLength(1));
  });

  test(
      'addFromFile: копия файла + строка + change_log атомарно; '
      'softDelete пишет мутацию', () async {
    final db = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 2,
        onCreate: (d, _) async {
          await AppDatabase.migrate001(d);
          await AppDatabase.migrate002(d);
        },
      ),
    );
    addTearDown(() => db.close());
    final clock = await HlcClock.load(db, 'dev-t');
    final repo =
        PhotoRepository(db, deviceId: 'dev-t', authorId: 'geo-t', clock: clock);

    final src = File(p.join(
        Directory.systemTemp.createTempSync('geofield_photo').path, 'shot.jpg'))
      ..writeAsBytesSync([1, 2, 3]);

    final photo =
        await repo.addFromFile(src.path, parentType: 'point', parentId: 'pt-1');
    expect(File(photo.filePath).existsSync(), isTrue,
        reason: 'файл скопирован во владение приложения');
    expect(photo.filePath, isNot(src.path));

    final listed = await repo.listByParent('point', 'pt-1');
    expect(listed.map((x) => x.id), [photo.id]);

    final log = await db
        .query('change_log', where: 'entity_table = ?', whereArgs: ['photos']);
    expect(log, hasLength(1));
    expect(log.single['op'], 'insert');

    await repo.softDelete(photo);
    expect(await repo.listByParent('point', 'pt-1'), isEmpty);
    // Фото родилось и умерло неотправленным — insert+tombstone схлопнулись.
    final log2 = await db
        .query('change_log', where: 'entity_table = ?', whereArgs: ['photos']);
    expect(log2, isEmpty);
    expect(File(photo.filePath).existsSync(), isTrue,
        reason: 'файл не удаляется до синхронизации — восстановимо');
  });
}
