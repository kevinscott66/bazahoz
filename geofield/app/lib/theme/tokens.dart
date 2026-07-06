import 'package:flutter/material.dart';

/// Полный набор цветовых слотов одной темы. Значения — семантика/значимость,
/// а не декор (ТЗ 4.3). Две готовых палитры ниже: тёмная (ночь/OLED) и «день
/// на снегу» (светлая высококонтрастная, ТЗ §4.5).
@immutable
class GfPalette {
  const GfPalette({
    required this.brightness,
    required this.bg,
    required this.surface,
    required this.surfaceHi,
    required this.outline,
    required this.textPrimary,
    required this.textSecondary,
    required this.textFaint,
    required this.accent,
    required this.onAccent,
    required this.error,
    required this.draft,
    required this.draftBg,
    required this.syncSent,
    required this.syncConfirmed,
  });

  final Brightness brightness;
  final Color bg;
  final Color surface;
  final Color surfaceHi;
  final Color outline;
  final Color textPrimary;
  final Color textSecondary;
  final Color textFaint;
  final Color accent;
  final Color onAccent;
  final Color error;
  final Color draft;
  final Color draftBg;
  final Color syncSent;
  final Color syncConfirmed;

  /// syncQueued совпадает с «черновиком» по смыслу (жёлтый — ждёт).
  Color get syncQueued => draft;

  /// Тёмная тема по умолчанию (тёплый near-black, OLED, ночь).
  static const dark = GfPalette(
    brightness: Brightness.dark,
    bg: Color(0xFF12140F),
    surface: Color(0xFF1D2018),
    surfaceHi: Color(0xFF272B20),
    outline: Color(0xFF3A3F30),
    textPrimary: Color(0xFFF2F0E9),
    textSecondary: Color(0xFF9DA08F),
    textFaint: Color(0xFF6C6F5F),
    accent: Color(0xFFF2A63B), // тёплый янтарный
    onAccent: Color(0xFF1A1204),
    error: Color(0xFFE07A5F), // терракота
    draft: Color(0xFFE0C766),
    draftBg: Color(0xFF4A4222),
    syncSent: Color(0xFF6E8CA0),
    syncConfirmed: Color(0xFF4FB286),
  );

  /// «День на снегу» (ТЗ §4.5): светлая, высококонтрастная — тёмный текст на
  /// тёплой бумаге, насыщенные статусы читаются на солнце. Не инверсия тёмной:
  /// вторичный текст/акцент/ошибка ЗАТЕМНЕНЫ, чтобы держать контраст на белом.
  static const daylight = GfPalette(
    brightness: Brightness.light,
    bg: Color(0xFFF4F2EA), // тёплая бумага, чуть глуше чистого белого от бликов
    surface: Color(0xFFFFFFFF),
    surfaceHi: Color(0xFFEAE7DC),
    outline: Color(0xFFB6B2A2),
    textPrimary: Color(0xFF17190F),
    textSecondary: Color(0xFF4C4F40), // затемнён: серый оригинала слеп на белом
    textFaint: Color(0xFF6C6F5F),
    accent: Color(0xFFB35E00), // глубокий янтарь — читаем на белом и как фон
    onAccent: Color(0xFFFFFFFF),
    error: Color(0xFFB23A22), // терракота потемнее для контраста
    draft: Color(0xFF8A6D00), // тёмное золото поверх белого
    draftBg: Color(0xFFF1E4A6),
    syncSent: Color(0xFF3F6178),
    syncConfirmed: Color(0xFF1F7A50),
  );
}

/// Дизайн-токены GeoField (ТЗ 4.3). Своя тема, свои токены — не дефолт Material.
/// Цвет = семантика/значимость, а не декор. Активная палитра сменяема на лету
/// («день на снегу», ТЗ §4.5): экраны читают `GfColors.x` без изменений, под
/// капотом — геттер к [active]. Тема в приложении одна на всех, поэтому
/// глобальная активная палитра корректна (весь экран перестраивается при смене).
abstract class GfColors {
  static GfPalette _active = GfPalette.dark;

  /// Текущая палитра. Меняется через [use]; UI перестраивается вызывающим.
  static GfPalette get active => _active;

  /// Переключить активную палитру (тёмная ↔ «день на снегу»). Вызывающий
  /// обязан перестроить дерево (в приложении — ListenableBuilder над MaterialApp).
  static void use(GfPalette palette) => _active = palette;

  static Color get bg => _active.bg;
  static Color get surface => _active.surface;
  static Color get surfaceHi => _active.surfaceHi;
  static Color get outline => _active.outline;

  static Color get textPrimary => _active.textPrimary;
  static Color get textSecondary => _active.textSecondary;
  static Color get textFaint => _active.textFaint;

  /// Единственный акцент действия — только для главной кнопки экрана.
  static Color get accent => _active.accent;
  static Color get onAccent => _active.onAccent;

  /// Ошибка — отчётливо, но не «кровавый» красный (ТЗ 4.3).
  static Color get error => _active.error;

  /// Статус «черновик»: маркер и его подложка (бейдж в шапке формы).
  static Color get draft => _active.draft;
  static Color get draftBg => _active.draftBg;

  /// Путь записи к серверу (точка-индикатор в журнале): в очереди → отправлена
  /// → подтверждена. pending — textFaint (ещё ничего не произошло).
  static Color get syncQueued => _active.syncQueued;
  static Color get syncSent => _active.syncSent;
  static Color get syncConfirmed => _active.syncConfirmed;
}

/// Единая шкала отступов 4–8–12–16–24 (ТЗ 4.3).
abstract class GfSpace {
  static const x4 = 4.0;
  static const x8 = 8.0;
  static const x12 = 12.0;
  static const x16 = 16.0;
  static const x24 = 24.0;
}

/// Своя система радиусов.
abstract class GfRadius {
  static const r8 = 8.0;
  static const r12 = 12.0;
  static const r16 = 16.0;
}

/// Цели нажатия. В поле кнопки крупные; режим перчаток — ещё крупнее (ТЗ 4.5).
abstract class GfTouch {
  static const min = 56.0;
  static const glove = 72.0;
}

/// Типографика. Числа/таблицы (глубины, координаты, номера) — моноширинным
/// с табличными цифрами: ошибки видно сразу, цифры столбиком (ТЗ 4.3).
abstract class GfText {
  static const _mono = 'monospace';

  // Стили — геттеры, а не const: цвет берётся из активной палитры (для «дня на
  // снегу»). Геометрия (размер/вес/фичи) неизменна между темами.
  static TextStyle get screenTitle => TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.w700,
        color: GfColors.textPrimary,
        height: 1.15,
      );
  static TextStyle get sectionLabel => TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.8,
        color: GfColors.textSecondary,
      );
  static TextStyle get body =>
      TextStyle(fontSize: 16, color: GfColors.textPrimary);
  static TextStyle get hint =>
      TextStyle(fontSize: 14, color: GfColors.textFaint);

  static TextStyle get number => TextStyle(
        fontFamily: _mono,
        fontSize: 20,
        fontWeight: FontWeight.w600,
        color: GfColors.textPrimary,
        fontFeatures: const [FontFeature.tabularFigures()],
      );
  static TextStyle get numberField => TextStyle(
        fontFamily: _mono,
        fontSize: 22,
        color: GfColors.textPrimary,
        fontFeatures: const [FontFeature.tabularFigures()],
      );
  static TextStyle get numberSmall => TextStyle(
        fontFamily: _mono,
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: GfColors.textPrimary,
        fontFeatures: const [FontFeature.tabularFigures()],
      );

  /// Подпись главной кнопки экрана («Готово», «Синхронизировать», FAB).
  /// Цвет не задаёт — берётся у кнопки (foreground); безопасна как const.
  static const button = TextStyle(fontSize: 18, fontWeight: FontWeight.w700);
}

/// Оформление текстового поля из токенов — одно на все экраны.
/// [hint] — подсказка в пустом поле; [label] — плавающая подпись поверх
/// рамки (формы точки/пробы задают обе, пикеры — только label).
InputDecoration gfInputDecoration({String? hint, String? label}) {
  OutlineInputBorder b(Color c) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(GfRadius.r12),
        borderSide: BorderSide(color: c),
      );
  return InputDecoration(
    hintText: hint,
    labelText: label,
    labelStyle: GfText.hint,
    hintStyle: GfText.hint,
    filled: true,
    fillColor: GfColors.surface,
    contentPadding: const EdgeInsets.symmetric(
        horizontal: GfSpace.x16, vertical: GfSpace.x16),
    enabledBorder: b(GfColors.outline),
    focusedBorder: b(GfColors.accent),
  );
}

/// Главная (акцентная) кнопка экрана.
ButtonStyle gfFilledStyle() => FilledButton.styleFrom(
      backgroundColor: GfColors.accent,
      foregroundColor: GfColors.onAccent,
      disabledBackgroundColor: GfColors.surfaceHi,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(GfRadius.r12)),
    );

/// Второстепенная кнопка (контурная).
ButtonStyle gfOutlinedStyle() => OutlinedButton.styleFrom(
      foregroundColor: GfColors.textPrimary,
      side: BorderSide(color: GfColors.outline),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(GfRadius.r12)),
    );

/// Карточка на поверхности: скругление + тонкая рамка. Цвет рамки по умолчанию
/// — outline активной палитры (null → берётся в теле, т.к. значение не const).
BoxDecoration gfCard({Color? borderColor}) => BoxDecoration(
      color: GfColors.surface,
      borderRadius: BorderRadius.circular(GfRadius.r12),
      border: Border.all(color: borderColor ?? GfColors.outline),
    );

/// Общий вид полевых чипов (фильтры журнала, минерализация).
Color gfChipSelectedColor() => GfColors.accent.withValues(alpha: 0.25);
BorderSide gfChipSide(bool selected) =>
    BorderSide(color: selected ? GfColors.accent : GfColors.outline);
TextStyle gfChipLabel(bool selected) => GfText.body.copyWith(
    fontSize: 14,
    color: selected ? GfColors.textPrimary : GfColors.textSecondary);

/// Снекбар без обвязки ScaffoldMessenger на каждом экране.
/// Вызывающий State сам проверяет mounted до обращения к context.
extension GfSnack on BuildContext {
  void snack(String message, {Duration? duration}) {
    ScaffoldMessenger.of(this).showSnackBar(SnackBar(
      content: Text(message),
      duration: duration ?? const Duration(seconds: 4),
    ));
  }
}

/// Тема приложения, собранная из активной палитры (не дефолтная Material-тема).
/// [palette] по умолчанию — текущая активная (для «дня на снегу» вызывающий
/// сперва делает `GfColors.use(...)`, затем строит тему).
ThemeData buildGeoFieldTheme([GfPalette? palette]) {
  final p = palette ?? GfColors.active;
  // Тот же набор оверрайдов, что и раньше (без fromSeed) — тёмная схема
  // остаётся байт-в-байт прежней, светлая получает аналогичную из .light.
  final scheme = (p.brightness == Brightness.dark
      ? ColorScheme.dark(
          surface: p.surface,
          primary: p.accent,
          onPrimary: p.onAccent,
          error: p.error,
        )
      : ColorScheme.light(
          surface: p.surface,
          primary: p.accent,
          onPrimary: p.onAccent,
          error: p.error,
        ));
  return ThemeData(
    useMaterial3: true,
    brightness: p.brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: p.bg,
    splashFactory: InkRipple.splashFactory,
    textSelectionTheme: TextSelectionThemeData(cursorColor: p.accent),
  );
}
