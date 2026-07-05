import 'package:sqflite/sqflite.dart';

import '../sync/hlc.dart';

const demoProjectId = 'demo-suzun';
const demoRouteId = 'demo-route-1';
const demoNumbering = 'SUZ-{seq:05}';
const demoAuthorId = 'demo-geologist';
const demoDeviceId = 'demo-device';

/// Демо-проект, маршрут и стартовые справочники — чтобы прототип открывался
/// сразу на журнале и форма точки имела реальные подсказки.
/// Состав справочников — черновой, на ревизию geo-consultant и живому
/// консультанту (раздел 14 мастер-плана).
Future<void> seedDemo(Database db) async {
  final existing = await db.query('projects',
      where: 'id = ?', whereArgs: [demoProjectId], limit: 1);
  if (existing.isNotEmpty) return;

  final now = DateTime.now().toUtc().toIso8601String();
  // Сид — бутстрап «как будто пришло с сервера», НЕ пользовательская мутация:
  // в change_log не пишется (иначе каждое устройство отправит одинаковые
  // сиды и создаст дубли), sync_status='confirmed' (отправлять нечего),
  // row_clock — нулевая метка: любой реальный update детерминированно
  // выигрывает LWW, проходя обычный путь с историей.
  final seedClock = const Hlc(0, 0, 'seed').encode();
  final batch = db.batch();

  void seedRowClock(String table, String id) {
    batch.insert('row_clocks',
        {'entity_table': table, 'entity_id': id, 'hlc_ts': seedClock});
  }

  batch.insert('projects', {
    'id': demoProjectId,
    'name': 'Демо — Сусуман',
    'area': 'Участок 1',
    'default_crs': 'SK-42 / GK-7',
    'sample_numbering': demoNumbering,
    'author_id': demoAuthorId,
    'created_at': now,
    'modified_at': now,
    'sync_status': 'confirmed',
  });
  seedRowClock('projects', demoProjectId);
  batch.insert('routes', {
    'id': demoRouteId,
    'route_date': now.substring(0, 10),
    'title': 'Маршрут 1',
    'geologist_id': demoAuthorId,
    'author_id': demoAuthorId,
    'created_at': now,
    'modified_at': now,
    'sync_status': 'confirmed',
  });
  seedRowClock('routes', demoRouteId);

  // Состав — по ревизии geo-consultant (Магаданская область, россыпное +
  // рудное золото); итоговые перечни утверждает живой консультант
  // (geofield/domain-review.md).
  const dicts = <String, List<(String, String)>>{
    'object_type': [
      ('outcrop', 'Обнажение'),
      ('bedrock', 'Коренной выход'),
      ('shurf', 'Шурф'),
      ('trench', 'Канава'),
      ('clearing', 'Расчистка'),
      ('pit', 'Закопушка'),
      ('float', 'Свалы/высыпки'),
      ('deluvium', 'Делювиальные высыпки'),
      ('alluvium', 'Русловой аллювий'),
      ('terrace', 'Терраса'),
    ],
    'rock': [
      ('sandstone', 'Песчаник'),
      ('siltstone', 'Алевролит'),
      ('mudstone', 'Аргиллит'),
      ('clay_shale', 'Глинистый сланец'),
      ('carbon_shale', 'Углисто-глинистый сланец'),
      ('granite', 'Гранит'),
      ('granodiorite', 'Гранодиорит'),
      ('diorite', 'Диорит'),
      ('dike', 'Дайковая порода'),
      ('vein_quartz', 'Жильный кварц'),
      ('beresite', 'Березит'),
      ('silicified', 'Окварцованная порода'),
    ],
    'alteration': [
      ('silicification', 'Окварцевание'),
      ('sericitization', 'Серицитизация'),
      ('sulfidization', 'Сульфидизация'),
      ('beresitization', 'Березитизация'),
      ('argillization', 'Аргиллизация'),
    ],
    'mineral': [
      ('pyrite', 'Пирит'),
      ('arsenopyrite', 'Арсенопирит'),
      ('galena', 'Галенит'),
      ('sphalerite', 'Сфалерит'),
      ('native_gold', 'Видимое золото'),
    ],
  };
  for (final entry in dicts.entries) {
    var order = 0;
    for (final (code, label) in entry.value) {
      final id = 'dict-${entry.key}-$code';
      batch.insert('dictionaries', {
        'id': id,
        'project_id': demoProjectId,
        'dict_type': entry.key,
        'code': code,
        'label': label,
        'sort_order': order++,
        'author_id': demoAuthorId,
        'created_at': now,
        'modified_at': now,
        'sync_status': 'confirmed',
      });
      seedRowClock('dictionaries', id);
    }
  }
  await batch.commit(noResult: true);
}
