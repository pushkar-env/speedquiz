import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// SpeedQuiz design tokens — premium game feel without neon clutter.
abstract final class AppColors {
  static const CosmicInk backgroundDark = CosmicInk();
  static const Color backgroundLight = Color(0xFFF3F6F8);
  static const Color surfaceDark = Color(0xFF151B24);
  static const Color surfaceLight = Color(0xFFFFFFFF);
  static const Color accent = Color(0xFF2EE6A6);
  static const Color accentDim = Color(0xFF1AAF7A);
  static const Color warning = Color(0xFFFFB020);
  static const Color danger = Color(0xFFFF5C5C);
  static const Color success = Color(0xFF2EE6A6);
  static const Color textPrimaryDark = Color(0xFFF4F7FA);
  static const Color textSecondaryDark = Color(0xFF9AA6B2);
  static const Color textPrimaryLight = Color(0xFF121820);
  static const Color textSecondaryLight = Color(0xFF5C6B7A);
  static const Color borderDark = Color(0xFF243041);
  static const Color borderLight = Color(0xFFD7E0E8);
}

class CosmicInk {
  const CosmicInk();
  Color get primary => const Color(0xFF0B0F14);
  Color get secondary => const Color(0xFF101822);
  LinearGradient get wash => const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xFF121A24), Color(0xFF0B0F14)],
      );
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
  static const double pill = 999;
}

abstract final class AppTheme {
  static ThemeData dark() {
    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: AppColors.backgroundDark.primary,
      colorScheme: const ColorScheme.dark(
        primary: AppColors.accent,
        secondary: AppColors.warning,
        surface: AppColors.surfaceDark,
        error: AppColors.danger,
        onPrimary: Color(0xFF04110C),
        onSecondary: Color(0xFF1A1200),
        onSurface: AppColors.textPrimaryDark,
        onError: Colors.white,
      ),
    );
    return _withTypography(base, dark: true);
  }

  static ThemeData light() {
    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      scaffoldBackgroundColor: AppColors.backgroundLight,
      colorScheme: const ColorScheme.light(
        primary: AppColors.accentDim,
        secondary: AppColors.warning,
        surface: AppColors.surfaceLight,
        error: AppColors.danger,
        onPrimary: Colors.white,
        onSecondary: Color(0xFF1A1200),
        onSurface: AppColors.textPrimaryLight,
        onError: Colors.white,
      ),
    );
    return _withTypography(base, dark: false);
  }

  static ThemeData _withTypography(ThemeData base, {required bool dark}) {
    final display = GoogleFonts.spaceGroteskTextTheme(base.textTheme);
    final body = GoogleFonts.dmSansTextTheme(base.textTheme);
    final primary = dark ? AppColors.textPrimaryDark : AppColors.textPrimaryLight;
    final secondary =
        dark ? AppColors.textSecondaryDark : AppColors.textSecondaryLight;

    return base.copyWith(
      textTheme: display.copyWith(
        displayLarge: display.displayLarge?.copyWith(
          color: primary,
          fontWeight: FontWeight.w700,
          letterSpacing: -1.2,
        ),
        displayMedium: display.displayMedium?.copyWith(
          color: primary,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.8,
        ),
        headlineLarge: display.headlineLarge?.copyWith(
          color: primary,
          fontWeight: FontWeight.w700,
        ),
        headlineMedium: display.headlineMedium?.copyWith(
          color: primary,
          fontWeight: FontWeight.w600,
        ),
        titleLarge: display.titleLarge?.copyWith(
          color: primary,
          fontWeight: FontWeight.w600,
        ),
        titleMedium: body.titleMedium?.copyWith(
          color: primary,
          fontWeight: FontWeight.w600,
        ),
        bodyLarge: body.bodyLarge?.copyWith(color: primary, height: 1.35),
        bodyMedium: body.bodyMedium?.copyWith(color: secondary, height: 1.4),
        bodySmall: body.bodySmall?.copyWith(color: secondary),
        labelLarge: body.labelLarge?.copyWith(
          color: primary,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.2,
        ),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: display.titleLarge?.copyWith(
          color: primary,
          fontWeight: FontWeight.w700,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: dark ? AppColors.surfaceDark : AppColors.surfaceLight,
        indicatorColor: AppColors.accent.withValues(alpha: 0.18),
        labelTextStyle: WidgetStatePropertyAll(
          body.labelMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.accent,
          foregroundColor: const Color(0xFF04110C),
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.md),
          ),
          textStyle: body.labelLarge?.copyWith(fontWeight: FontWeight.w700),
        ),
      ),
    );
  }
}
