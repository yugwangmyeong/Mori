import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'app_colors.dart';

class AppTheme {
  // 색상은 app_colors.dart에서 관리
  static const Color primaryColor = AppColors.primary;
  static const Color secondaryColor = AppColors.secondary;
  static const Color backgroundColor = AppColors.background;
  static const Color surfaceColor = AppColors.surface;
  static const Color textPrimary = AppColors.textPrimary;
  static const Color textSecondary = AppColors.textSecondary;
  
  // 라이트 테마
  static ThemeData lightTheme = ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.light(
      primary: AppColors.primary,
      secondary: AppColors.secondary,
      tertiary: AppColors.accent,
      surface: AppColors.surface,
      background: AppColors.background,
      onPrimary: Colors.white,
      onSecondary: Colors.white,
      onSurface: AppColors.textPrimary,
      onBackground: AppColors.textPrimary,
    ),
    // 고양이 캐릭터에 어울리는 폰트 적용
    textTheme: GoogleFonts.quicksandTextTheme().copyWith(
      // 한글 폰트를 위한 fallback 설정
      displayLarge: GoogleFonts.quicksand(),
      displayMedium: GoogleFonts.quicksand(),
      displaySmall: GoogleFonts.quicksand(),
      headlineLarge: GoogleFonts.quicksand(),
      headlineMedium: GoogleFonts.quicksand(),
      headlineSmall: GoogleFonts.quicksand(),
      titleLarge: GoogleFonts.quicksand(fontWeight: FontWeight.bold),
      titleMedium: GoogleFonts.quicksand(),
      titleSmall: GoogleFonts.quicksand(),
      bodyLarge: GoogleFonts.nunito(),
      bodyMedium: GoogleFonts.nunito(),
      bodySmall: GoogleFonts.nunito(),
      labelLarge: GoogleFonts.comfortaa(fontWeight: FontWeight.w600),
      labelMedium: GoogleFonts.comfortaa(),
      labelSmall: GoogleFonts.comfortaa(),
    ),
    scaffoldBackgroundColor: backgroundColor,
    appBarTheme: AppBarTheme(
      centerTitle: true,
      elevation: 0,
      backgroundColor: surfaceColor,
      foregroundColor: textPrimary,
      titleTextStyle: GoogleFonts.quicksand(
        fontSize: 22,
        fontWeight: FontWeight.bold,
        color: textPrimary,
      ),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        elevation: 2,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(28),
        ),
      ),
    ),
  );
  
  // 다크 테마 (추후 확장 가능)
  static ThemeData darkTheme = ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: primaryColor,
      brightness: Brightness.dark,
    ),
    scaffoldBackgroundColor: const Color(0xFF111827),
    appBarTheme: const AppBarTheme(
      centerTitle: true,
      elevation: 0,
    ),
  );
}

