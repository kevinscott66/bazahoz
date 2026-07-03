import 'package:flutter/material.dart';

import 'data/database.dart';
import 'data/demo_seed.dart';
import 'data/dictionary_repository.dart';
import 'data/point_repository.dart';
import 'data/sample_repository.dart';
import 'screens/journal_screen.dart';
import 'sync/hlc.dart';
import 'theme/tokens.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final app = await AppDatabase.open();
  await seedDemo(app.db);
  final clock = await HlcClock.load(app.db, demoDeviceId);
  runApp(GeoFieldApp(database: app, clock: clock));
}

class GeoFieldApp extends StatelessWidget {
  const GeoFieldApp({super.key, required this.database, required this.clock});

  final AppDatabase database;
  final HlcClock clock;

  @override
  Widget build(BuildContext context) {
    final samples = SampleRepository(database.db,
        deviceId: demoDeviceId, authorId: demoAuthorId, clock: clock);
    final points = PointRepository(database.db,
        deviceId: demoDeviceId, authorId: demoAuthorId, clock: clock);
    final dictionaries = DictionaryRepository(database.db,
        deviceId: demoDeviceId, authorId: demoAuthorId, clock: clock);

    return MaterialApp(
      title: 'GeoField',
      debugShowCheckedModeBanner: false,
      theme: buildGeoFieldTheme(),
      home: JournalScreen(
        points: points,
        samples: samples,
        dictionaries: dictionaries,
        projectId: demoProjectId,
        routeId: demoRouteId,
        authorId: demoAuthorId,
        sampleNumbering: demoNumbering,
        deviceId: demoDeviceId,
        clock: clock,
      ),
    );
  }
}
