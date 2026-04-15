import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:local_grammer_llm/providers/theme_provider.dart';
import 'package:local_grammer_llm/ui/screens/dashboard_screen.dart';
import 'package:local_grammer_llm/ui/screens/onboarding_screen.dart';

class App extends StatelessWidget {
  const App({super.key, this.showOnboarding = false});

  final bool showOnboarding;

  @override
  Widget build(BuildContext context) {
    final themeProvider = context.watch<ThemeProvider>();

    final light = ColorScheme.light(
      primary: const Color(0xFF6C4AD5),
      onPrimary: Colors.white,
      secondary: const Color(0xFF8E7EE6),
      onSecondary: Colors.white,
      tertiary: const Color(0xFFC4B7FF),
      onTertiary: const Color(0xFF2A2155),
      surface: const Color(0xFFF7F5FF),
      onSurface: const Color(0xFF1A1633),
      surfaceContainerHighest: const Color(0xFFEEE9FF),
      outline: const Color(0xFFB8B0D9),
      outlineVariant: const Color(0xFFD8D2F0),
    );

    final dark = ColorScheme.dark(
      primary: const Color(0xFF9B80E8),
      onPrimary: const Color(0xFF1A1633),
      secondary: const Color(0xFFB0A0F0),
      onSecondary: const Color(0xFF1A1633),
      tertiary: const Color(0xFF6C4AD5),
      onTertiary: const Color(0xFFE8E4F4),
      surface: const Color(0xFF121020),
      onSurface: const Color(0xFFE8E4F4),
      surfaceContainerHighest: const Color(0xFF252240),
      outline: const Color(0xFF5A5080),
      outlineVariant: const Color(0xFF3D3565),
    );

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      themeMode: themeProvider.themeMode,
      theme: _buildTheme(light),
      darkTheme: _buildTheme(dark),
      home: showOnboarding
          ? const OnboardingScreen()
          : const DashboardScreen(),
    );
  }

  static ThemeData _buildTheme(ColorScheme scheme) {
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      appBarTheme: AppBarTheme(
          centerTitle: false,
          elevation: 0,
          backgroundColor: scheme.surface,
          foregroundColor: scheme.onSurface,
          surfaceTintColor: scheme.surfaceTint,
          titleTextStyle: TextStyle(
            color: scheme.onSurface,
            fontSize: 20,
            fontWeight: FontWeight.w600,
          ),
        ),
        cardTheme: CardThemeData(
          elevation: 0,
          surfaceTintColor: scheme.surfaceTint,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: scheme.outlineVariant),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: scheme.surfaceContainerHighest,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: scheme.outlineVariant),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: scheme.primary, width: 1.4),
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            elevation: 0,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
        switchTheme: SwitchThemeData(
          thumbColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? scheme.primary
                : scheme.outline,
          ),
          trackColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? scheme.primary.withOpacity(0.3)
                : scheme.surfaceContainerHighest,
          ),
        ),
        listTileTheme: ListTileThemeData(
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12)),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        ),
        snackBarTheme: SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        dividerTheme: DividerThemeData(
          color: scheme.outlineVariant,
          thickness: 1,
          space: 1,
        ),
      );
  }
}
