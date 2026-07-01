import 'package:flutter/material.dart';

import 'data/database.dart';
import 'data/dictionary_repository.dart';
import 'data/point_repository.dart';
import 'data/sample_repository.dart';
import 'screens/journal_screen.dart';
import 'theme/tokens.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final app = await AppDatabase.open();
  await _seedDemo(app);
  runApp(GeoFieldApp(database: app));
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
  final batch = app.db.batch();
  batch.insert('projects', {
    'id': _demoProjectId,
    'name': 'Демо — Сусуман',
    'area': 'Участок 1',
    'default_crs': 'SK-42 / GK-7',
    'sample_numbering': _demoNumbering,
    'author_id': _demoAuthorId,
    'created_at': now,
    'modified_at': now,
  });
  batch.insert('routes', {
    'id': _demoRouteId,
    'route_date': now.substring(0, 10),
    'title': 'Маршрут 1',
    'geologist_id': _demoAuthorId,
    'author_id': _demoAuthorId,
    'created_at': now,
    'modified_at': now,
  });

  const objectTypes = [
    ('outcrop', 'Обнажение'),
    ('pit', 'Закопушка'),
    ('deluvium', 'Делювий'),
    ('bedrock', 'Коренной выход'),
  ];
  const rocks = [
    ('granite', 'Гранит'),
    ('diorite', 'Диорит'),
    ('basalt', 'Базальт'),
    ('sandstone', 'Песчаник'),
    ('siltstone', 'Алевролит'),
    ('shale', 'Сланец'),
    ('quartz_vein', 'Кварцевая жила'),
  ];
  var order = 0;
  for (final (code, label) in objectTypes) {
    batch.insert('dictionaries', {
      'id': 'dict-ot-$code',
      'project_id': _demoProjectId,
      'dict_type': 'object_type',
      'code': code,
      'label': label,
      'sort_order': order++,
      'author_id': _demoAuthorId,
      'created_at': now,
      'modified_at': now,
    });
  }
  order = 0;
  for (final (code, label) in rocks) {
    batch.insert('dictionaries', {
      'id': 'dict-rock-$code',
      'project_id': _demoProjectId,
      'dict_type': 'rock',
      'code': code,
      'label': label,
      'sort_order': order++,
      'author_id': _demoAuthorId,
      'created_at': now,
      'modified_at': now,
    });
  }
  await batch.commit(noResult: true);
}

class GeoFieldApp extends StatelessWidget {
  const GeoFieldApp({super.key, required this.database});

  final AppDatabase database;

  @override
  Widget build(BuildContext context) {
    final samples = SampleRepository(database.db,
        deviceId: _demoDeviceId, authorId: _demoAuthorId);
    final points = PointRepository(database.db,
        deviceId: _demoDeviceId, authorId: _demoAuthorId);
    final dictionaries = DictionaryRepository(database.db,
        deviceId: _demoDeviceId, authorId: _demoAuthorId);

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
      ),
    );
  }
}
