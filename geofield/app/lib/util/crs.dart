import 'dart:math' as math;

/// Пересчёт систем координат (ТЗ §6.2). Канон хранения — WGS-84 (широта/
/// долгота): его отдаёт GPS, в нём же приходят чужие мутации. Для показа и
/// ручного ввода геолог выбирает систему; здесь — только преобразования,
/// без состояния.
///
/// СК-42 (Пулково-1942): эллипсоид Красовского 1940, проекция Гаусса-Крюгера,
/// 6-градусные зоны, масштаб на осевом меридиане 1.0 (НЕ 0.9996 как UTM).
/// Смена датума WGS-84 ↔ СК-42 — 7-параметрическим преобразованием Гельмерта
/// через геоцентрические XYZ.
///
/// ВНИМАНИЕ по параметрам датума: набор ниже — общеупотребимый
/// (ГОСТ-совместимый) СК-42→WGS-84, даёт метровую точность. Точные параметры
/// (и тем более местную МСК) обязан подтвердить геодезист/консультант — см.
/// UNFINISHED.md. Алгоритм от набора не зависит: параметры — сменяемые
/// константы в одном месте.

/// Эллипсоид вращения.
class Ellipsoid {
  const Ellipsoid(this.a, this.invF);

  final double a; // большая полуось, м
  final double invF; // обратное сжатие 1/f

  double get f => 1 / invF;
  double get b => a * (1 - f);
  double get e2 => f * (2 - f); // первый эксцентриситет²
  double get ep2 => e2 / (1 - e2); // второй эксцентриситет²

  static const wgs84 = Ellipsoid(6378137.0, 298.257223563);
  static const krassovsky = Ellipsoid(6378245.0, 298.3);
}

/// 7 параметров Гельмерта (позиционного вектора): сдвиги dX/dY/dZ в метрах,
/// вращения rx/ry/rz в угловых секундах, масштаб m в ppm. Направление — из
/// СК-42 в WGS-84.
class HelmertParams {
  const HelmertParams({
    required this.dx,
    required this.dy,
    required this.dz,
    required this.rx,
    required this.ry,
    required this.rz,
    required this.m,
  });

  final double dx, dy, dz; // м
  final double rx, ry, rz; // угловые секунды
  final double m; // ppm

  /// Обратный набор (WGS-84 → СК-42) — при малых параметрах это смена знака.
  HelmertParams get inverse => HelmertParams(
      dx: -dx, dy: -dy, dz: -dz, rx: -rx, ry: -ry, rz: -rz, m: -m);
}

/// Общеупотребимый набор СК-42 → WGS-84 (метровая точность; точные значения —
/// за геодезистом, см. заголовок файла).
const sk42ToWgs84Helmert = HelmertParams(
  dx: 23.57,
  dy: -140.95,
  dz: -79.8,
  rx: 0.0,
  ry: 0.35,
  rz: 0.79,
  m: -0.22,
);

/// Плоские прямоугольные координаты Гаусса-Крюгера: X — северный (от экватора),
/// Y — восточный (с префиксом зоны и ложным сдвигом 500 км). Метры.
class GkPoint {
  const GkPoint(this.x, this.y, this.zone);

  final double x; // северный, м
  final double y; // восточный (zone*1e6 + 500000 + …), м
  final int zone; // номер 6-градусной зоны
}

/// Географические координаты (градусы).
class LatLon {
  const LatLon(this.lat, this.lon);
  final double lat;
  final double lon;
}

double _rad(double d) => d * math.pi / 180.0;
double _deg(double r) => r * 180.0 / math.pi;
double _arcsecToRad(double s) => s * math.pi / 180.0 / 3600.0;

/// Номер 6-градусной зоны Гаусса-Крюгера по долготе (в.д.), и осевой меридиан.
int gkZone(double lonDeg) => (lonDeg / 6).floor() + 1;
double gkCentralMeridian(int zone) => zone * 6.0 - 3.0;

// --- геодезические ↔ геоцентрические ------------------------------------------

List<double> _geodeticToGeocentric(
    double latDeg, double lonDeg, double h, Ellipsoid el) {
  final lat = _rad(latDeg), lon = _rad(lonDeg);
  final sinLat = math.sin(lat), cosLat = math.cos(lat);
  final n = el.a / math.sqrt(1 - el.e2 * sinLat * sinLat);
  final x = (n + h) * cosLat * math.cos(lon);
  final y = (n + h) * cosLat * math.sin(lon);
  final z = (n * (1 - el.e2) + h) * sinLat;
  return [x, y, z];
}

LatLon _geocentricToGeodetic(double x, double y, double z, Ellipsoid el) {
  final lon = math.atan2(y, x);
  final p = math.sqrt(x * x + y * y);
  // Bowring, замкнутая форма — одной итерации хватает на метровую точность.
  final theta = math.atan2(z * el.a, p * el.b);
  final sinT = math.sin(theta), cosT = math.cos(theta);
  final lat = math.atan2(
    z + el.ep2 * el.b * sinT * sinT * sinT,
    p - el.e2 * el.a * cosT * cosT * cosT,
  );
  return LatLon(_deg(lat), _deg(lon));
}

List<double> _applyHelmert(List<double> xyz, HelmertParams h) {
  final rx = _arcsecToRad(h.rx),
      ry = _arcsecToRad(h.ry),
      rz = _arcsecToRad(h.rz);
  final s = 1 + h.m * 1e-6;
  final x = xyz[0], y = xyz[1], z = xyz[2];
  // Позиционный вектор (Bursa-Wolf).
  return [
    h.dx + s * (x - rz * y + ry * z),
    h.dy + s * (rz * x + y - rx * z),
    h.dz + s * (-ry * x + rx * y + z),
  ];
}

// --- Gauss-Krüger (Transverse Mercator, k0 = 1.0, ряды Снайдера) --------------

/// Длина дуги меридиана от экватора до широты lat (рад) на эллипсоиде el.
double _meridianArc(double lat, Ellipsoid el) {
  final e2 = el.e2, e4 = e2 * e2, e6 = e4 * e2;
  return el.a *
      ((1 - e2 / 4 - 3 * e4 / 64 - 5 * e6 / 256) * lat -
          (3 * e2 / 8 + 3 * e4 / 32 + 45 * e6 / 1024) * math.sin(2 * lat) +
          (15 * e4 / 256 + 45 * e6 / 1024) * math.sin(4 * lat) -
          (35 * e6 / 3072) * math.sin(6 * lat));
}

/// Прямая ГК: широта/долгота (на эллипсоиде el) → (северный, восточный от
/// осевого меридиана без ложного сдвига).
List<double> _gkForward(
    double latDeg, double lonDeg, double cmDeg, Ellipsoid el) {
  final lat = _rad(latDeg);
  final sinLat = math.sin(lat), cosLat = math.cos(lat), tanLat = math.tan(lat);
  final n = el.a / math.sqrt(1 - el.e2 * sinLat * sinLat);
  final t = tanLat * tanLat;
  final c = el.ep2 * cosLat * cosLat;
  final aa = _rad(lonDeg - cmDeg) * cosLat;
  final m = _meridianArc(lat, el);
  final northing = m +
      n *
          tanLat *
          (aa * aa / 2 +
              (5 - t + 9 * c + 4 * c * c) * math.pow(aa, 4) / 24 +
              (61 - 58 * t + t * t + 600 * c - 330 * el.ep2) *
                  math.pow(aa, 6) /
                  720);
  final easting = n *
      (aa +
          (1 - t + c) * math.pow(aa, 3) / 6 +
          (5 - 18 * t + t * t + 72 * c - 58 * el.ep2) * math.pow(aa, 5) / 120);
  return [northing, easting];
}

/// Обратная ГК: (северный, восточный от осевого меридиана) → широта/долгота.
LatLon _gkInverse(double northing, double easting, double cmDeg, Ellipsoid el) {
  final e1 = (1 - math.sqrt(1 - el.e2)) / (1 + math.sqrt(1 - el.e2));
  final mu = northing /
      (el.a *
          (1 -
              el.e2 / 4 -
              3 * el.e2 * el.e2 / 64 -
              5 * math.pow(el.e2, 3) / 256));
  final phi1 = mu +
      (3 * e1 / 2 - 27 * math.pow(e1, 3) / 32) * math.sin(2 * mu) +
      (21 * e1 * e1 / 16 - 55 * math.pow(e1, 4) / 32) * math.sin(4 * mu) +
      (151 * math.pow(e1, 3) / 96) * math.sin(6 * mu) +
      (1097 * math.pow(e1, 4) / 512) * math.sin(8 * mu);
  final sinP = math.sin(phi1), cosP = math.cos(phi1), tanP = math.tan(phi1);
  final c1 = el.ep2 * cosP * cosP;
  final t1 = tanP * tanP;
  final n1 = el.a / math.sqrt(1 - el.e2 * sinP * sinP);
  final r1 = el.a * (1 - el.e2) / math.pow(1 - el.e2 * sinP * sinP, 1.5);
  final d = easting / n1;
  final lat = phi1 -
      (n1 * tanP / r1) *
          (d * d / 2 -
              (5 + 3 * t1 + 10 * c1 - 4 * c1 * c1 - 9 * el.ep2) *
                  math.pow(d, 4) /
                  24 +
              (61 +
                      90 * t1 +
                      298 * c1 +
                      45 * t1 * t1 -
                      252 * el.ep2 -
                      3 * c1 * c1) *
                  math.pow(d, 6) /
                  720);
  final lon = _rad(cmDeg) +
      (d -
              (1 + 2 * t1 + c1) * math.pow(d, 3) / 6 +
              (5 - 2 * c1 + 28 * t1 - 3 * c1 * c1 + 8 * el.ep2 + 24 * t1 * t1) *
                  math.pow(d, 5) /
                  120) /
          cosP;
  return LatLon(_deg(lat), _deg(lon));
}

// --- публичный API ------------------------------------------------------------

/// WGS-84 (град.) → СК-42 Гаусса-Крюгера (метры, с префиксом зоны).
GkPoint wgs84ToSk42Gk(double lat, double lon,
    {HelmertParams datum = sk42ToWgs84Helmert}) {
  // 1. WGS-84 → геоцентрик → датум СК-42 (обратный Гельмерт) → широта/долгота
  //    на Красовском.
  final xyzW = _geodeticToGeocentric(lat, lon, 0, Ellipsoid.wgs84);
  final xyzK = _applyHelmert(xyzW, datum.inverse);
  final geoK =
      _geocentricToGeodetic(xyzK[0], xyzK[1], xyzK[2], Ellipsoid.krassovsky);
  // 2. Гаусс-Крюгер на Красовском.
  final zone = gkZone(geoK.lon);
  final cm = gkCentralMeridian(zone);
  final ne = _gkForward(geoK.lat, geoK.lon, cm, Ellipsoid.krassovsky);
  final y = zone * 1e6 + 500000 + ne[1];
  return GkPoint(ne[0], y, zone);
}

/// СК-42 Гаусса-Крюгера (метры) → WGS-84 (град.). Зона берётся из префикса Y,
/// если не задана явно.
LatLon sk42GkToWgs84(double x, double y,
    {int? zone, HelmertParams datum = sk42ToWgs84Helmert}) {
  final z = zone ?? (y / 1e6).floor();
  final cm = gkCentralMeridian(z);
  final easting = y - z * 1e6 - 500000;
  // 1. Обратная ГК на Красовском → геоцентрик → датум WGS-84 (прямой Гельмерт).
  final geoK = _gkInverse(x, easting, cm, Ellipsoid.krassovsky);
  final xyzK =
      _geodeticToGeocentric(geoK.lat, geoK.lon, 0, Ellipsoid.krassovsky);
  final xyzW = _applyHelmert(xyzK, datum);
  return _geocentricToGeodetic(xyzW[0], xyzW[1], xyzW[2], Ellipsoid.wgs84);
}
