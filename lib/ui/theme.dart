import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 全局主题模式（设置页/页头按钮切换，持久化）
class ThemeController {
  ThemeController._();
  static final ThemeController instance = ThemeController._();

  static const _kMode = 'ui.themeMode';

  final ValueNotifier<ThemeMode> mode = ValueNotifier(ThemeMode.dark);

  Future<void> load() async {
    final sp = await SharedPreferences.getInstance();
    mode.value = ThemeMode.values[sp.getInt(_kMode) ?? ThemeMode.dark.index];
  }

  Future<void> set(ThemeMode m) async {
    mode.value = m;
    final sp = await SharedPreferences.getInstance();
    await sp.setInt(_kMode, m.index);
  }

  void toggle() =>
      set(mode.value == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark);
}

/// iOS 风格设计令牌：深色默认 + 浅色完整切换（对照 demo CSS 变量）
class AppTheme {
  AppTheme._();

  // ---------- 深色 ----------
  static const _dPrimary = Color(0xFF0A84FF);
  static const _dBg = Color(0xFF000000);
  static const _dSurface = Color(0xFF1C1C1E);
  static const _dSurfaceVar = Color(0xFF2C2C2E);
  static const _dText = Color(0xFFFFFFFF);
  static const _dText2 = Color(0xFF98989D);
  static const _dText3 = Color(0xFF636366);
  static const _dText4 = Color(0xFF48484A);
  static const _dBorder = Color(0xA8545458); // rgba(84,84,88,0.65)
  static const _dSuccess = Color(0xFF30D158);
  static const _dWarning = Color(0xFFFF9F0A);
  static const _dDanger = Color(0xFFFF453A);

  // ---------- 浅色 ----------
  static const _lPrimary = Color(0xFF007AFF);
  static const _lBg = Color(0xFFF2F2F7);
  static const _lSurface = Color(0xFFFFFFFF);
  static const _lSurfaceVar = Color(0xFFF8F8FC);
  static const _lText = Color(0xFF1C1C1E);
  static const _lText2 = Color(0xFF636366);
  static const _lText3 = Color(0xFF8E8E93);
  static const _lText4 = Color(0xFFAEAEB2);
  static const _lBorder = Color(0x143C3C43); // rgba(60,60,67,0.08)
  static const _lSuccess = Color(0xFF34C759);
  static const _lWarning = Color(0xFFFF9500);
  static const _lDanger = Color(0xFFFF3B30);

  static const radiusSm = 10.0;
  static const radiusMd = 14.0;
  static const radiusLg = 18.0;

  static ThemeData dark() => _build(
    primary: _dPrimary,
    bg: _dBg,
    surface: _dSurface,
    surfaceVar: _dSurfaceVar,
    text: _dText,
    text2: _dText2,
    text3: _dText3,
    text4: _dText4,
    border: _dBorder,
    success: _dSuccess,
    warning: _dWarning,
    danger: _dDanger,
  );

  static ThemeData light() => _build(
    primary: _lPrimary,
    bg: _lBg,
    surface: _lSurface,
    surfaceVar: _lSurfaceVar,
    text: _lText,
    text2: _lText2,
    text3: _lText3,
    text4: _lText4,
    border: _lBorder,
    success: _lSuccess,
    warning: _lWarning,
    danger: _lDanger,
  );

  static ThemeData _build({
    required Color primary,
    required Color bg,
    required Color surface,
    required Color surfaceVar,
    required Color text,
    required Color text2,
    required Color text3,
    required Color text4,
    required Color border,
    required Color success,
    required Color warning,
    required Color danger,
  }) {
    final scheme = ColorScheme(
      brightness: bg.computeLuminance() > 0.5
          ? Brightness.light
          : Brightness.dark,
      primary: primary,
      onPrimary: Colors.white,
      secondary: primary,
      onSecondary: Colors.white,
      surface: bg,
      onSurface: text,
      surfaceContainerLowest: bg,
      surfaceContainerLow: surface,
      surfaceContainer: surface,
      surfaceContainerHigh: surfaceVar,
      surfaceContainerHighest: surfaceVar,
      onSurfaceVariant: text2,
      outline: border,
      outlineVariant: border,
      error: danger,
      onError: Colors.white,
    );
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: bg,
      splashFactory: InkSparkle.splashFactory,
      fontFamily: null,
    );
    return base.copyWith(
      textTheme: base.textTheme.apply(bodyColor: text, displayColor: text),
      appBarTheme: AppBarTheme(
        backgroundColor: bg,
        foregroundColor: text,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleSpacing: 20,
        titleTextStyle: TextStyle(
          fontSize: 23,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.4,
          color: text,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: surface,
        indicatorColor: primary.withValues(alpha: 0.15),
        surfaceTintColor: Colors.transparent,
        height: 64,
        iconTheme: WidgetStateProperty.resolveWith(
          (s) => IconThemeData(
            color: s.contains(WidgetState.selected) ? primary : text3,
          ),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (s) => TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w500,
            color: s.contains(WidgetState.selected) ? primary : text3,
          ),
        ),
      ),
      dividerTheme: DividerThemeData(color: border, thickness: 1, space: 1),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? Colors.white : text3,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? success
              : (bg == _dBg
                    ? const Color(0xFF39393D)
                    : const Color(0xFFE9E9EA)),
        ),
        trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? primary : text4,
        ),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (s) =>
              s.contains(WidgetState.selected) ? primary : Colors.transparent,
        ),
        side: BorderSide(color: text4, width: 2),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: primary,
        linearTrackColor: surfaceVar,
        circularTrackColor: surfaceVar,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusLg),
        ),
        titleTextStyle: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: text,
        ),
        contentTextStyle: TextStyle(fontSize: 14, color: text2, height: 1.5),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface,
        hintStyle: TextStyle(color: text3),
        labelStyle: TextStyle(color: text2),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusSm),
          borderSide: BorderSide(color: border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusSm),
          borderSide: BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusSm),
          borderSide: BorderSide(color: primary, width: 1.6),
        ),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: text2,
        titleTextStyle: TextStyle(fontSize: 15, color: text),
        subtitleTextStyle: TextStyle(fontSize: 12.5, color: text3),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: primary),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusSm),
          ),
          minimumSize: const Size(0, 46),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: primary,
          side: BorderSide(color: border),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusSm),
          ),
          minimumSize: const Size(0, 46),
        ),
      ),
    );
  }
}
