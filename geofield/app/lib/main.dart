import 'package:flutter/material.dart';

import 'data/database.dart';
import 'data/sample_repository.dart';
import 'screens/sample_capture_screen.dart';
import 'theme/tokens.dart';
import 'util/sample_number.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final app = await AppDatabase.open();
  await _seedDemoProject(app);
  runApp(GeoFieldApp(database: app));
}

const _demoProjectId = 'demo-suzun';
const _demoNumbering = 'SUZ-{seq:05}';
const _demoAuthorId = 'demo-geologist';
const _demoDeviceId = 'demo-device';

/// Демо-проект, чтобы прототип открывался сразу на экране сбора пробы.
Future<void> _seedDemoProject(AppDatabase app) async {
  final existing = await app.db.query('projects',
      where: 'id = ?', whereArgs: [_demoProjectId], limit: 1);
  if (existing.isNotEmpty) return;
  final now = DateTime.now().toUtc().toIso8601String();
  await app.db.insert('projects', {
    'id': _demoProjectId,
    'name': 'Демо — Сусуман',
    'area': 'Участок 1',
    'default_crs': 'SK-42 / GK-7',
    'sample_numbering': _demoNumbering,
    'author_id': _demoAuthorId,
    'created_at': now,
    'modified_at': now,
  });
}

class GeoFieldApp extends StatelessWidget {
  const GeoFieldApp({super.key, required this.database});

  final AppDatabase database;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GeoField',
      debugShowCheckedModeBanner: false,
      theme: buildGeoFieldTheme(),
      home: SampleCaptureLauncher(database: database),
    );
  }
}

/// Готовит номер пробы (следующий seq по схеме проекта) и открывает экран 6.5.
class SampleCaptureLauncher extends StatefulWidget {
  const SampleCaptureLauncher({super.key, required this.database});

  final AppDatabase database;

  @override
  State<SampleCaptureLauncher> createState() => _SampleCaptureLauncherState();
}

class _SampleCaptureLauncherState extends State<SampleCaptureLauncher> {
  late final SampleRepository _repo;
  Future<String>? _numberFuture;

  @override
  void initState() {
    super.initState();
    _repo = SampleRepository(widget.database.db,
        deviceId: _demoDeviceId, authorId: _demoAuthorId);
    _numberFuture = _nextNumber();
  }

  Future<String> _nextNumber() async {
    final seq = await _repo.nextSeq(_demoProjectId);
    return const SampleNumberTemplate(_demoNumbering).format(seq);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      future: _numberFuture,
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Scaffold(
            backgroundColor: GfColors.bg,
            body: Center(child: CircularProgressIndicator()),
          );
        }
        return SampleCaptureScreen(
          repository: _repo,
          projectId: _demoProjectId,
          authorId: _demoAuthorId,
          initialNumber: snap.data!,
          // Демо-привязка к точке наблюдения; для керна был бы интервал с глубинами.
          binding: const ParentBinding(
            type: 'point',
            id: 'demo-point-12',
            label: 'Точка № 12',
          ),
        );
      },
    );
  }
}
