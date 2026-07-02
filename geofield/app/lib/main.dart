import 'package:flutter/material.dart';

import 'data/database.dart';
import 'data/dictionary_repository.dart';
import 'data/point_repository.dart';
import 'data/sample_repository.dart';
import 'screens/journal_screen.dart';
import 'sync/hlc.dart';
import 'theme/tokens.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final app = await AppDatabase.open();
  await _seedDemo(app);
  final clock = await HlcClock.load(app.db, _demoDeviceId);
  runApp(GeoFieldApp(database: app, clock: clock));
}

const _demoProjectId = 'demo-suzun';
const _demoRouteId = 'demo-route-1';
const _demoNumbering = 'SUZ-{seq:05}';
const _demoAuthorId = 'demo-geologist';
const _demoDeviceId = 'demo-device';

/// Демо-проект, маршрут и стартовые справочники — чтобы прототип открывался
/// сразу на журнале и форма точки имела реальные подсказки.
/// Состав справочников — черновой, на ревизию geo-consultant и живому
/// консультанту (раздел 14 мастер-плана).
Future<void> _seedDemo(AppDatabase app) async {
  final existing = await app.db.query('projects',
      where: 'id = ?', whereArgs: [_demoProjectId], limit: 1);
  if (existing.isNotEmpty) return;

  final now = DateTime.now().toUtc().toIso8601String();
  // Сид — бутстрап «как будто пришло с сервера», НЕ пользовательская мутация:
  // в change_log не пишется (иначе каждое устройство отправит одинаковые
  // сиды и создаст дубли), sync_status='confirmed' (отправлять нечего),
  // row_clock — нулевая метка: любой реальный update детерминированно
  // выигрывает LWW, проходя обычный путь с историей.
  final seedClock = const Hlc(0, 0, 'seed').encode();
  final batch = app.db.batch();

  void seedRowClock(String table, String id) {
    batch.insert('row_clocks',
        {'entity_table': table, 'entity_id': id, 'hlc_ts': seedClock});
  }

  batch.insert('projects', {
    'id': _demoProjectId,
    'name': 'Демо — Сусуман',
    'area': 'Участок 1',
    'default_crs': 'SK-42 / GK-7',
    'sample_numbering': _demoNumbering,
    'author_id': _demoAuthorId,
    'created_at': now,
    'modified_at': now,
    'sync_status': 'confirmed',
  });
  seedRowClock('projects', _demoProjectId);
  batch.insert('routes', {
    'id': _demoRouteId,
    'route_date': now.substring(0, 10),
    'title': 'Маршрут 1',
    'geologist_id': _demoAuthorId,
    'author_id': _demoAuthorId,
    'created_at': now,
    'modified_at': now,
    'sync_status': 'confirmed',
  });
  seedRowClock('routes', _demoRouteId);

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
        'project_id': _demoProjectId,
        'dict_type': entry.key,
        'code': code,
        'label': label,
        'sort_order': order++,
        'author_id': _demoAuthorId,
        'created_at': now,
        'modified_at': now,
        'sync_status': 'confirmed',
      });
      seedRowClock('dictionaries', id);
    }
  }
  await batch.commit(noResult: true);
}

class GeoFieldApp extends StatelessWidget {
  const GeoFieldApp({super.key, required this.database, required this.clock});

  final AppDatabase database;
  final HlcClock clock;

  @override
  Widget build(BuildContext context) {
    final samples = SampleRepository(database.db,
        deviceId: _demoDeviceId, authorId: _demoAuthorId, clock: clock);
    final points = PointRepository(database.db,
        deviceId: _demoDeviceId, authorId: _demoAuthorId, clock: clock);
    final dictionaries = DictionaryRepository(database.db,
        deviceId: _demoDeviceId, authorId: _demoAuthorId, clock: clock);

    return MaterialApp(
      title: 'GeoField',
      debugShowCheckedModeBanner: false,
      theme: buildGeoFieldTheme(),
      home: JournalScreen(
        points: points,
        samples: samples,
        dictionaries: dictionaries,
        projectId: _demoProjectId,
        routeId: _demoRouteId,
        authorId: _demoAuthorId,
        sampleNumbering: _demoNumbering,
        deviceId: _demoDeviceId,
        clock: clock,
      ),
    );
  }
}
