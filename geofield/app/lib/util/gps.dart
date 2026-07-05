import 'package:geolocator/geolocator.dart';

/// Снятая с приёмника позиция (WGS-84).
typedef GpsFix = ({
  double lat,
  double lon,
  double? elevation,
  double? accuracy
});

/// Источник координат. Интерфейс-функция, а не прямой вызов плагина из
/// экрана: тесты подставляют фикс без платформенных каналов.
typedef GpsProvider = Future<GpsFix> Function();

/// Понятная пользователю причина, почему координаты не снялись.
class GpsException implements Exception {
  GpsException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Боевой провайдер: службы → разрешение → позиция с лучшей точностью.
/// 30 секунд на холодный старт приёмника — дальше честный отказ, не вечное
/// ожидание (в распадке спутники видны плохо, геолог должен понимать почему).
Future<GpsFix> acquireGpsFix() async {
  if (!await Geolocator.isLocationServiceEnabled()) {
    throw GpsException('Геолокация выключена — включите в настройках');
  }
  var perm = await Geolocator.checkPermission();
  if (perm == LocationPermission.denied) {
    perm = await Geolocator.requestPermission();
  }
  if (perm == LocationPermission.denied ||
      perm == LocationPermission.deniedForever) {
    throw GpsException(
        'Нет разрешения на геолокацию — разрешите в настройках телефона');
  }
  final Position pos;
  try {
    pos = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.best,
        timeLimit: Duration(seconds: 30),
      ),
    );
  } on Exception {
    throw GpsException('Спутники не поймались за 30 секунд — попробуйте '
        'на открытом месте или введите вручную');
  }
  return (
    lat: pos.latitude,
    lon: pos.longitude,
    elevation: pos.altitude == 0 ? null : pos.altitude,
    accuracy: pos.accuracy == 0 ? null : pos.accuracy,
  );
}
