import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:local_grammer_llm/providers/theme_provider.dart';
import 'package:local_grammer_llm/ui/screens/dashboard_screen.dart';
import 'package:local_grammer_llm/ui/screens/onboarding_screen.dart';

/// Root widget of the LocalScribe Flutter app.
///
/// Picks between the onboarding flow and the main dashboard based on
/// [showOnboarding] (set by `main.dart` after reading the
/// `has_completed_onboarding` pref). Rebuilds on [ThemeProvider] changes so
/// the light/dark toggle takes effect immediately.
class App extends StatelessWidget {
  const App({super.key, required this.showOnboarding});

  final bool showOnboarding;

  // Brand palette — kept in sync with `ProcessTextApp` in
  // `process_text_screen.dart` so the share-popup and the main app share the
  // same violet/indigo tone.
  static const _lightScheme = ColorScheme.light(
    primary: Color(0xFF6C4AD5),
    onPrimary: Colors.white,
    secondary: Color(0xFF8E7EE6),
    onSecondary: Colors.white,
    tertiary: Color(0xFFC4B7FF),
    onTertiary: Color(0xFF2A2155),
    surface: Color(0xFFF7F5FF),
    onSurface: Color(0xFF1A1633),
    surfaceContainerHighest: Color(0xFFEEE9FF),
    outline: Color(0xFFB8B0D9),
    outlineVariant: Color(0xFFD8D2F0),
  );

  static const _darkScheme = ColorScheme.dark(
    primary: Color(0xFF9B80E8),
    onPrimary: Color(0xFF1A1633),
    secondary: Color(0xFFB0A0F0),
    onSecondary: Color(0xFF1A1633),
    tertiary: Color(0xFF6C4AD5),
    onTertiary: Color(0xFFE8E4F4),
    surface: Color(0xFF121020),
    onSurface: Color(0xFFE8E4F4),
    surfaceContainerHighest: Color(0xFF252240),
    outline: Color(0xFF5A5080),
    outlineVariant: Color(0xFF3D3565),
  );

  @override
  Widget build(BuildContext context) {
    // Listen, not read: when the theme toggle fires we need MaterialApp to
    // rebuild with the new themeMode.
    final theme = context.watch<ThemeProvider>();

    return MaterialApp(
      title: 'LocalScribe',
      debugShowCheckedModeBanner: false,
      themeMode: theme.themeMode,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: _lightScheme,
        scaffoldBackgroundColor: _lightScheme.surface,
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: _darkScheme,
        scaffoldBackgroundColor: _darkScheme.surface,
      ),
      home: showOnboarding
          ? const OnboardingScreen()
          : const DashboardScreen(),
    );
  }
}
