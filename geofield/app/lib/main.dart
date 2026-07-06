import 'package:flutter/material.dart';

import 'config/display_settings.dart';
import 'data/database.dart';
import 'data/demo_seed.dart';
import 'data/dictionary_repository.dart';
import 'data/photo_repository.dart';
import 'data/point_repository.dart';
import 'data/sample_repository.dart';
import 'lab/lab_service.dart';
import 'screens/journal_screen.dart';
import 'sync/hlc.dart';
import 'theme/tokens.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Первый кадр — сразу, до открытия базы: иначе сбой/задержка инициализации
  // выглядит как вечный белый экран без единого слова (ТЗ §0 — ошибки видимы).
  runApp(const _Booting());
  try {
    final app = await AppDatabase.open();
    await seedDemo(app.db);
    final clock = await HlcClock.load(app.db, demoDeviceId);
    final display = await DisplaySettings.load(app.db);
    runApp(GeoFieldApp(database: app, clock: clock, display: display));
  } catch (e, st) {
    runApp(_BootError(error: e, stack: st));
  }
}

/// Кадр запуска, пока открывается база (доли секунды).
class _Booting extends StatelessWidget {
  const _Booting();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildGeoFieldTheme(),
      home: Scaffold(
        body: Center(child: CircularProgressIndicator(color: GfColors.accent)),
      ),
    );
  }
}

/// Хранилище не поднялось — честная диагностика на экране вместо белого
/// экрана: в поле нет консоли, текст ошибки — единственный след.
class _BootError extends StatelessWidget {
  const _BootError({required this.error, required this.stack});

  final Object error;
  final StackTrace stack;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildGeoFieldTheme(),
      home: Scaffold(
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(GfSpace.x24),
            children: [
              Icon(Icons.error_outline, size: 48, color: GfColors.error),
              const SizedBox(height: GfSpace.x16),
              Text('Хранилище не открылось', style: GfText.screenTitle),
              const SizedBox(height: GfSpace.x8),
              Text(
                'Данные не тронуты. Сфотографируйте этот экран и передайте '
                'разработчику.',
                style: GfText.body,
              ),
              const SizedBox(height: GfSpace.x16),
              Text('$error', style: GfText.hint),
              const SizedBox(height: GfSpace.x8),
              Text('$stack', style: GfText.hint),
            ],
          ),
        ),
      ),
    );
  }
}

class GeoFieldApp extends StatelessWidget {
  const GeoFieldApp({
    super.key,
    required this.database,
    required this.clock,
    required this.display,
  });

  final AppDatabase database;
  final HlcClock clock;
  final DisplaySettings display;

  @override
  Widget build(BuildContext context) {
    final samples = SampleRepository(database.db,
        deviceId: demoDeviceId, authorId: demoAuthorId, clock: clock);
    final points = PointRepository(database.db,
        deviceId: demoDeviceId, authorId: demoAuthorId, clock: clock);
    final dictionaries = DictionaryRepository(database.db,
        deviceId: demoDeviceId, authorId: demoAuthorId, clock: clock);
    final photos = PhotoRepository(database.db,
        deviceId: demoDeviceId, authorId: demoAuthorId, clock: clock);
    final lab = LabService(database.db, samples,
        deviceId: demoDeviceId, authorId: demoAuthorId, clock: clock);

    // Тема И масштаб шрифта живут в display: смена «дня на снегу» меняет
    // тему целиком, поэтому весь MaterialApp пересобирается под слушателем
    // (навигатор и его стек при этом сохраняются — обычный приём смены темы).
    return ListenableBuilder(
      listenable: display,
      builder: (context, _) => MaterialApp(
        title: 'GeoField',
        debugShowCheckedModeBanner: false,
        theme: buildGeoFieldTheme(display.palette),
        // Масштаб шрифта применяется НАД навигатором — на все экраны и шторки.
        builder: (context, child) => MediaQuery.withClampedTextScaling(
          minScaleFactor: display.textScale,
          maxScaleFactor: display.textScale,
          child: child!,
        ),
        home: JournalScreen(
          points: points,
          samples: samples,
          dictionaries: dictionaries,
          photos: photos,
          display: display,
          projectId: demoProjectId,
          routeId: demoRouteId,
          authorId: demoAuthorId,
          sampleNumbering: demoNumbering,
          deviceId: demoDeviceId,
          clock: clock,
          lab: lab,
        ),
      ),
    );
  }
}
