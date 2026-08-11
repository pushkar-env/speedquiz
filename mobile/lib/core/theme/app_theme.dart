import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// SpeedQuiz design tokens — premium game feel without neon clutter.
///
/// Colour roles are resolved through [SqPalette] (see [SqPaletteX.sq]) so
/// screens never branch on `brightness` by hand.
abstract final class AppColors {
  // Brand
  static const Color accent = Color(0xFF2EE6A6);
  static const Color accentDim = Color(0xFF12B886);
  static const Color accentDeep = Color(0xFF0B7C5C);
  static const Color cyan = Color(0xFF35C8F2);
  static const Color violet = Color(0xFF7C6BFF);
  static const Color magenta = Color(0xFFE86BC8);

  // Semantic
  static const Color warning = Color(0xFFFFB020);
  static const Color gold = Color(0xFFFFC94A);
  static const Color danger = Color(0xFFFF5C5C);
  static const Color success = Color(0xFF2EE6A6);

  // Dark surfaces
  static const Color backgroundDarkTop = Color(0xFF0D1420);
  static const Color backgroundDarkBottom = Color(0xFF070A11);
  static const Color surfaceDark = Color(0xFF141B27);
  static const Color surfaceDarkElevated = Color(0xFF1B2432);
  static const Color borderDark = Color(0xFF243041);
  static const Color textPrimaryDark = Color(0xFFF4F7FA);
  static const Color textSecondaryDark = Color(0xFF97A5B5);

  // Light surfaces
  static const Color backgroundLight = Color(0xFFF4F7FA);
  static const Color surfaceLight = Color(0xFFFFFFFF);
  static const Color surfaceLightElevated = Color(0xFFFBFCFE);
  static const Color borderLight = Color(0xFFDCE4EC);
  static const Color textPrimaryLight = Color(0xFF0F1720);
  static const Color textSecondaryLight = Color(0xFF5A6875);

  /// Signature brand sweep, used on primary actions and hero surfaces.
  static const LinearGradient brandGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [accent, cyan],
  );

  /// Streak / heat sweep.
  static const LinearGradient heatGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [gold, Color(0xFFFF7A45)],
  );

  /// Premium sweep.
  static const LinearGradient premiumGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFFFFD770), Color(0xFFFF9F43)],
  );

  /// Rank-tier accents for leaderboard podium positions (1st, 2nd, 3rd).
  static const List<Color> podium = [
    Color(0xFFFFC94A),
    Color(0xFFC9D6E4),
    Color(0xFFE0925C),
  ];
}

/// Brightness-resolved colours. Read via `context.sq` / `theme.sq`.
class SqPalette {
  const SqPalette._({
    required this.isDark,
    required this.background,
    required this.backgroundGradient,
    required this.surface,
    required this.surfaceElevated,
    required this.border,
    required this.borderStrong,
    required this.textPrimary,
    required this.textSecondary,
    required this.textFaint,
    required this.scrim,
    required this.shadow,
  });

  factory SqPalette.of(Brightness brightness) =>
      brightness == Brightness.dark ? _dark : _light;

  final bool isDark;
  final Color background;
  final LinearGradient backgroundGradient;
  final Color surface;
  final Color surfaceElevated;
  final Color border;
  final Color borderStrong;
  final Color textPrimary;
  final Color textSecondary;
  final Color textFaint;
  final Color scrim;
  final Color shadow;

  /// Accent that stays legible on the current background.
  ///
  /// Light mode uses the deep emerald, not the brand mint: mint on white is
  /// ~2.6:1, which fails WCAG AA for the small labels this colour carries.
  /// The deep variant lands at ~5.2:1. The bright mint is still used for
  /// gradient *fills*, which always pair with near-black ink.
  Color get accent => isDark ? AppColors.accent : AppColors.accentDeep;

  /// Tint helper: accent wash at [alpha], for chips and highlights.
  Color accentWash([double alpha = 0.12]) => accent.withValues(alpha: alpha);

  static final _dark = SqPalette._(
    isDark: true,
    background: AppColors.backgroundDarkBottom,
    backgroundGradient: const LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [
        AppColors.backgroundDarkTop,
        AppColors.backgroundDarkBottom,
      ],
    ),
    surface: AppColors.surfaceDark,
    surfaceElevated: AppColors.surfaceDarkElevated,
    border: AppColors.borderDark,
    borderStrong: const Color(0xFF33425A),
    textPrimary: AppColors.textPrimaryDark,
    textSecondary: AppColors.textSecondaryDark,
    textFaint: const Color(0xFF64748B),
    scrim: const Color(0xCC05080D),
    shadow: const Color(0x66000000),
  );

  static final _light = SqPalette._(
    isDark: false,
    background: AppColors.backgroundLight,
    backgroundGradient: const LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [Color(0xFFFFFFFF), AppColors.backgroundLight],
    ),
    surface: AppColors.surfaceLight,
    surfaceElevated: AppColors.surfaceLightElevated,
    border: AppColors.borderLight,
    borderStrong: const Color(0xFFBECBD8),
    textPrimary: AppColors.textPrimaryLight,
    textSecondary: AppColors.textSecondaryLight,
    textFaint: const Color(0xFF8B98A5),
    scrim: const Color(0x99101820),
    shadow: const Color(0x1A0F1720),
  );
}

extension SqPaletteX on BuildContext {
  /// Brightness-resolved SpeedQuiz palette for this subtree.
  SqPalette get sq => SqPalette.of(Theme.of(this).brightness);
}

extension SqThemePaletteX on ThemeData {
  SqPalette get sq => SqPalette.of(brightness);
}

abstract final class AppSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 32;
  static const double xxl = 48;
}

abstract final class AppRadii {
  static const double sm = 10;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 30;
  static const double pill = 999;
}

/// Layered shadows tuned per brightness — flat cards read as cheap.
abstract final class AppShadows {
  static List<BoxShadow> soft(SqPalette p) => [
        BoxShadow(
          color: p.shadow,
          blurRadius: 18,
          offset: const Offset(0, 6),
        ),
      ];

  static List<BoxShadow> lifted(SqPalette p) => [
        BoxShadow(
          color: p.shadow,
          blurRadius: 32,
          offset: const Offset(0, 14),
        ),
      ];

  static List<BoxShadow> glow(Color color, {double strength = 0.35}) => [
        BoxShadow(
          color: color.withValues(alpha: strength),
          blurRadius: 26,
          spreadRadius: -4,
          offset: const Offset(0, 10),
        ),
      ];
}

abstract final class AppTheme {
  static const _displayFamily = 'SpaceGrotesk';
  static const _bodyFamily = 'DMSans';

  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData light() => _build(Brightness.light);

  /// Status/navigation bar styling that matches the active brightness.
  static SystemUiOverlayStyle overlayStyle(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    return SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
      statusBarBrightness: dark ? Brightness.dark : Brightness.light,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarDividerColor: Colors.transparent,
      systemNavigationBarIconBrightness:
          dark ? Brightness.light : Brightness.dark,
    );
  }

  static ThemeData _build(Brightness brightness) {
    final p = SqPalette.of(brightness);
    final dark = p.isDark;
    final onAccent = dark ? const Color(0xFF04110C) : Colors.white;

    final colorScheme = ColorScheme(
      brightness: brightness,
      primary: p.accent,
      onPrimary: onAccent,
      primaryContainer: p.accent.withValues(alpha: dark ? 0.18 : 0.14),
      onPrimaryContainer: dark ? AppColors.accent : AppColors.accentDeep,
      secondary: AppColors.violet,
      onSecondary: Colors.white,
      tertiary: AppColors.gold,
      onTertiary: const Color(0xFF1A1200),
      surface: p.surface,
      onSurface: p.textPrimary,
      surfaceContainerHighest: p.surfaceElevated,
      onSurfaceVariant: p.textSecondary,
      error: AppColors.danger,
      onError: Colors.white,
      outline: p.border,
      outlineVariant: p.border.withValues(alpha: 0.5),
      shadow: p.shadow,
      scrim: p.scrim,
      inverseSurface: dark ? AppColors.surfaceLight : AppColors.surfaceDark,
      onInverseSurface:
          dark ? AppColors.textPrimaryLight : AppColors.textPrimaryDark,
    );

    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: p.background,
      fontFamily: _bodyFamily,
      splashFactory: InkSparkle.splashFactory,
      visualDensity: VisualDensity.standard,
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        },
      ),
    );

    final text = _textTheme(base.textTheme, p);

    return base.copyWith(
      textTheme: text,
      primaryTextTheme: text,
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        systemOverlayStyle: overlayStyle(brightness),
        iconTheme: IconThemeData(color: p.textPrimary),
        titleTextStyle: text.titleLarge?.copyWith(
          fontFamily: _displayFamily,
          fontWeight: FontWeight.w700,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        height: 68,
        indicatorColor: p.accentWash(0.18),
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => text.labelSmall?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: 0.2,
            color: states.contains(WidgetState.selected)
                ? p.accent
                : p.textSecondary,
          ),
        ),
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            size: 24,
            color: states.contains(WidgetState.selected)
                ? p.accent
                : p.textSecondary,
          ),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: p.accent,
          foregroundColor: onAccent,
          disabledBackgroundColor: p.accent.withValues(alpha: 0.35),
          disabledForegroundColor: onAccent.withValues(alpha: 0.6),
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.md),
          ),
          textStyle: text.labelLarge,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: p.textPrimary,
          side: BorderSide(color: p.border),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.md),
          ),
          textStyle: text.labelLarge,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: p.accent,
          textStyle: text.labelLarge,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.sm),
          ),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(foregroundColor: p.textSecondary),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: p.surface,
        selectedColor: p.accentWash(0.18),
        disabledColor: p.surface.withValues(alpha: 0.5),
        side: BorderSide(color: p.border),
        labelStyle: text.bodyMedium?.copyWith(
          color: p.textPrimary,
          fontWeight: FontWeight.w600,
        ),
        secondaryLabelStyle: text.bodyMedium?.copyWith(color: p.accent),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.pill),
        ),
        showCheckmark: false,
      ),
      cardTheme: CardThemeData(
        color: p.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.md),
          side: BorderSide(color: p.border),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: p.border,
        thickness: 1,
        space: 1,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: p.surfaceElevated,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.lg),
          side: BorderSide(color: p.border),
        ),
        titleTextStyle: text.titleLarge,
        contentTextStyle: text.bodyMedium,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: p.surfaceElevated,
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: p.surfaceElevated,
        elevation: 0,
        showDragHandle: false,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppRadii.lg),
          ),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: p.surfaceElevated,
        contentTextStyle: text.bodyMedium?.copyWith(color: p.textPrimary),
        actionTextColor: p.accent,
        behavior: SnackBarBehavior.floating,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.md),
          side: BorderSide(color: p.border),
        ),
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: p.accent,
        unselectedLabelColor: p.textSecondary,
        indicatorColor: p.accent,
        indicatorSize: TabBarIndicatorSize.label,
        dividerColor: Colors.transparent,
        labelStyle: text.titleSmall?.copyWith(fontWeight: FontWeight.w700),
        unselectedLabelStyle: text.titleSmall,
        overlayColor: WidgetStatePropertyAll(p.accentWash(0.08)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: p.surface,
        hintStyle: text.bodyMedium?.copyWith(color: p.textFaint),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.md,
        ),
        border: _inputBorder(p.border),
        enabledBorder: _inputBorder(p.border),
        focusedBorder: _inputBorder(p.accent, width: 1.6),
        errorBorder: _inputBorder(AppColors.danger),
        focusedErrorBorder: _inputBorder(AppColors.danger, width: 1.6),
        counterStyle: text.bodySmall?.copyWith(color: p.textFaint),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: p.accent,
        linearTrackColor: p.border.withValues(alpha: 0.55),
        circularTrackColor: Colors.transparent,
        linearMinHeight: 6,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? p.accent
              : p.textSecondary,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? p.accentWash(0.35)
              : p.border,
        ),
        trackOutlineColor: WidgetStatePropertyAll(p.border),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? p.accentWash(0.18)
                : Colors.transparent,
          ),
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? p.accent
                : p.textSecondary,
          ),
          side: WidgetStatePropertyAll(BorderSide(color: p.border)),
          textStyle: WidgetStatePropertyAll(
            text.labelLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadii.sm),
            ),
          ),
        ),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: p.textSecondary,
        textColor: p.textPrimary,
        titleTextStyle: text.titleSmall,
        subtitleTextStyle: text.bodyMedium,
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: p.surfaceElevated,
          borderRadius: BorderRadius.circular(AppRadii.sm),
          border: Border.all(color: p.border),
        ),
        textStyle: text.bodySmall?.copyWith(color: p.textPrimary),
      ),
    );
  }

  static OutlineInputBorder _inputBorder(Color color, {double width = 1}) {
    return OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppRadii.md),
      borderSide: BorderSide(color: color, width: width),
    );
  }

  static TextTheme _textTheme(TextTheme base, SqPalette p) {
    TextStyle display(TextStyle? s, double size, FontWeight w, double ls) {
      return (s ?? const TextStyle()).copyWith(
        fontFamily: _displayFamily,
        fontSize: size,
        fontWeight: w,
        letterSpacing: ls,
        color: p.textPrimary,
        height: 1.1,
      );
    }

    TextStyle body(
      TextStyle? s,
      double size,
      FontWeight w, {
      Color? color,
      double height = 1.4,
      double ls = 0,
    }) {
      return (s ?? const TextStyle()).copyWith(
        fontFamily: _bodyFamily,
        fontSize: size,
        fontWeight: w,
        letterSpacing: ls,
        height: height,
        color: color ?? p.textPrimary,
      );
    }

    return base.copyWith(
      displayLarge: display(base.displayLarge, 52, FontWeight.w700, -1.6),
      displayMedium: display(base.displayMedium, 42, FontWeight.w700, -1.2),
      displaySmall: display(base.displaySmall, 34, FontWeight.w700, -1),
      headlineLarge: display(base.headlineLarge, 30, FontWeight.w700, -0.6),
      headlineMedium: display(base.headlineMedium, 26, FontWeight.w700, -0.4),
      headlineSmall: display(base.headlineSmall, 22, FontWeight.w700, -0.2),
      titleLarge: display(base.titleLarge, 20, FontWeight.w700, -0.2),
      titleMedium: body(base.titleMedium, 16, FontWeight.w600, height: 1.3),
      titleSmall: body(base.titleSmall, 14, FontWeight.w600, height: 1.3),
      bodyLarge: body(base.bodyLarge, 16, FontWeight.w400, height: 1.45),
      bodyMedium: body(
        base.bodyMedium,
        14,
        FontWeight.w400,
        color: p.textSecondary,
        height: 1.45,
      ),
      bodySmall: body(
        base.bodySmall,
        12,
        FontWeight.w400,
        color: p.textSecondary,
        height: 1.4,
      ),
      labelLarge: body(base.labelLarge, 14, FontWeight.w700, ls: 0.3),
      labelMedium: body(base.labelMedium, 12, FontWeight.w600, ls: 0.3),
      labelSmall: body(
        base.labelSmall,
        11,
        FontWeight.w600,
        color: p.textSecondary,
        ls: 0.4,
      ),
    );
  }
}
