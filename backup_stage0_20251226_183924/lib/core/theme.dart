// lib/core/theme.dart
import 'package:flutter/material.dart';

/// اللون الأساسي للتطبيق (أزرار/هايلايت) مع نص أبيض عليها.
const Color kPrimaryColor = Color(0xFF0059A5);

/// خلفية التطبيق الافتراضية (نيومورفيزم يعمل أفضل على خلفيات فاتحة).
const Color kScaffoldBg = Colors.white;

/// نصف القطر الافتراضي للحواف في الواجهات الناعمة.
const double kRadius = 18.0;

/// مسافات عامة
const EdgeInsets kScreenPadding =
    EdgeInsets.symmetric(horizontal: 16, vertical: 12);

class AppTheme {
  AppTheme._();

  /// مخطط ألوان موحّد يعتمد على الأبيض كأساس
  static ColorScheme _scheme(Brightness b) {
    final isDark = b == Brightness.dark;
    return ColorScheme(
      brightness: b,
      primary: kPrimaryColor,
      onPrimary: Colors.white,
      secondary: const Color(0xFF1565C0),
      onSecondary: Colors.white,
      surface: isDark ? const Color(0xFF111315) : Colors.white,
      onSurface: isDark ? const Color(0xFFE0E3E7) : const Color(0xFF1E2430),
      error: Colors.red.shade700,
      onError: Colors.white,
      tertiary: const Color(0xFF00BFA6),
      onTertiary: Colors.white,
      primaryContainer: kPrimaryColor.withValues(alpha: .08),
      onPrimaryContainer: kPrimaryColor,
      secondaryContainer: const Color(0xFFE3F2FD),
      onSecondaryContainer: const Color(0xFF0D47A1),
      surfaceContainerHighest:
          isDark ? const Color(0xFF161A1E) : const Color(0xFFF6F7FB),
      surfaceContainerHigh:
          isDark ? const Color(0xFF14181C) : const Color(0xFFF9FAFD),
      surfaceContainer:
          isDark ? const Color(0xFF1A1F24) : const Color(0xFFF3F5F7),
      surfaceContainerLow:
          isDark ? const Color(0xFF1F2429) : const Color(0xFFF0F2F5),
      surfaceContainerLowest:
          isDark ? const Color(0xFF23292E) : const Color(0xFFEFF1F4),
      outline: isDark ? Colors.white24 : Colors.black12,
      outlineVariant: isDark ? Colors.white10 : Colors.black12,
      scrim: Colors.black54,
      inversePrimary: Colors.white,
      inverseSurface: isDark ? Colors.white : Colors.black,
      errorContainer: Colors.red.shade50,
      onErrorContainer: Colors.red.shade900,
      tertiaryContainer: const Color(0xFFE0FFF8),
      onTertiaryContainer: const Color(0xFF004D43),
      surfaceTint: kPrimaryColor,
    );
  }

  static ThemeData _base(Brightness brightness) {
    final scheme = _scheme(brightness);
    final isDark = brightness == Brightness.dark;

    final textTheme = Typography.blackCupertino.apply(
      fontFamily: 'Cairo',
      bodyColor: scheme.onSurface,
      displayColor: scheme.onSurface,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      fontFamily: 'Cairo',
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      visualDensity: VisualDensity.adaptivePlatformDensity,

      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        centerTitle: true,
        titleTextStyle: textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w700,
          color: scheme.onSurface,
        ),
        iconTheme: IconThemeData(color: scheme.onSurface),
      ),

      iconTheme: IconThemeData(
        color: scheme.onSurface.withValues(alpha: .8),
        size: 22,
      ),

      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          elevation: 0,
        ),
      ),

      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          elevation: 0,
        ),
      ),

      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          side: BorderSide(color: scheme.outlineVariant),
          foregroundColor: isDark ? Colors.white : kPrimaryColor,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
      ),

      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),

      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHigh,
        hintStyle: TextStyle(color: scheme.onSurface.withValues(alpha: .45)),
        labelStyle: TextStyle(color: scheme.onSurface.withValues(alpha: .75)),
        suffixIconColor: scheme.onSurface.withValues(alpha: .7),
        prefixIconColor: scheme.onSurface.withValues(alpha: .7),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(kRadius),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(kRadius),
          borderSide: BorderSide(color: kPrimaryColor, width: 1.4),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(kRadius),
          borderSide: BorderSide(color: scheme.error),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(kRadius),
          borderSide: BorderSide(color: scheme.error, width: 1.4),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      ),

      // 👇 التعديل هنا: استخدام CardThemeData بدل CardTheme
      cardTheme: CardThemeData(
        color: scheme.surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(kRadius),
        ),
      ),

      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        thickness: 1,
        space: 24,
      ),

      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor:
            isDark ? const Color(0xFF1F2429) : const Color(0xFF102A43),
        contentTextStyle: const TextStyle(color: Colors.white),
        elevation: 6,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),

      dropdownMenuTheme: DropdownMenuThemeData(
        menuStyle: MenuStyle(
          // إن كانت نسختك أقدم ولا تعرف WidgetStatePropertyAll، بدّلها بـ MaterialStatePropertyAll
          backgroundColor: WidgetStatePropertyAll(scheme.surface),
          elevation: const WidgetStatePropertyAll(2),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          ),
        ),
      ),

      textTheme: textTheme,
    );
  }

  static ThemeData get light => _base(Brightness.light);
  static ThemeData get dark => _base(Brightness.dark);
}
