import 'package:flutter/material.dart';

/// Дизайн-токены GeoField (ТЗ 4.3). Своя тема, свои токены — не дефолт Material.
/// Цвет = семантика/значимость, а не декор. Тёмный фон по умолчанию (OLED, ночь).
abstract class GfColors {
  static const bg = Color(0xFF12140F); // тёплый near-black
  static const surface = Color(0xFF1D2018);
  static const surfaceHi = Color(0xFF272B20);
  static const outline = Color(0xFF3A3F30);

  static const textPrimary = Color(0xFFF2F0E9);
  static const textSecondary = Color(0xFF9DA08F);
  static const textFaint = Color(0xFF6C6F5F);

  /// Единственный акцент действия — только для главной кнопки экрана.
  static const accent = Color(0xFFF2A63B); // тёплый янтарный
  static const onAccent = Color(0xFF1A1204);

  /// Ошибка — отчётливо, но не «кровавый» красный (ТЗ 4.3).
  static const error = Color(0xFFE07A5F); // терракота

  /// Статус «черновик»: жёлтый маркер и его подложка (бейдж в шапке формы).
  static const draft = Color(0xFFE0C766);
  static const draftBg = Color(0xFF4A4222);

  /// Путь записи к серверу (точка-индикатор в журнале): в очереди → отправлена
  /// → подтверждена. pending — textFaint (ещё ничего не произошло).
  static const syncQueued = draft;
  static const syncSent = Color(0xFF6E8CA0);
  static const syncConfirmed = Color(0xFF4FB286);
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

  static const screenTitle = TextStyle(
    fontSize: 22,
    fontWeight: FontWeight.w700,
    color: GfColors.textPrimary,
    height: 1.15,
  );
  static const sectionLabel = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.8,
    color: GfColors.textSecondary,
  );
  static const body = TextStyle(fontSize: 16, color: GfColors.textPrimary);
  static const hint = TextStyle(fontSize: 14, color: GfColors.textFaint);

  static const number = TextStyle(
    fontFamily: _mono,
    fontSize: 20,
    fontWeight: FontWeight.w600,
    color: GfColors.textPrimary,
    fontFeatures: [FontFeature.tabularFigures()],
  );
  static const numberField = TextStyle(
    fontFamily: _mono,
    fontSize: 22,
    color: GfColors.textPrimary,
    fontFeatures: [FontFeature.tabularFigures()],
  );
  static const numberSmall = TextStyle(
    fontFamily: _mono,
    fontSize: 16,
    fontWeight: FontWeight.w600,
    color: GfColors.textPrimary,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  /// Подпись главной кнопки экрана («Готово», «Синхронизировать», FAB).
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
      side: const BorderSide(color: GfColors.outline),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(GfRadius.r12)),
    );

/// Карточка на поверхности: скругление + тонкая рамка.
BoxDecoration gfCard({Color borderColor = GfColors.outline}) => BoxDecoration(
      color: GfColors.surface,
      borderRadius: BorderRadius.circular(GfRadius.r12),
      border: Border.all(color: borderColor),
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

/// Тёмная тема приложения, собранная из токенов (не дефолтная Material-тема).
ThemeData buildGeoFieldTheme() {
  const scheme = ColorScheme.dark(
    surface: GfColors.surface,
    primary: GfColors.accent,
    onPrimary: GfColors.onAccent,
    error: GfColors.error,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: GfColors.bg,
    splashFactory: InkRipple.splashFactory,
    textSelectionTheme:
        const TextSelectionThemeData(cursorColor: GfColors.accent),
  );
}
