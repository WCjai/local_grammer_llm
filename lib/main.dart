import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:local_grammer_llm/app.dart';
import 'package:local_grammer_llm/providers/model_provider.dart';
import 'package:local_grammer_llm/providers/service_provider.dart';
import 'package:local_grammer_llm/providers/settings_provider.dart';
import 'package:local_grammer_llm/providers/commands_provider.dart';
import 'package:local_grammer_llm/providers/theme_provider.dart';
import 'package:local_grammer_llm/services/platform_channel_service.dart';
import 'package:local_grammer_llm/services/preferences_service.dart';

export 'package:local_grammer_llm/ui/screens/process_text_screen.dart'
    show processTextMain;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  final showOnboarding = !(prefs.getBool('has_completed_onboarding') ?? false);

  final channel = LlmChannelService();
  final prefsService = PreferencesService();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ThemeProvider(prefs)),
        ChangeNotifierProvider(create: (_) => ModelProvider(channel)),
        ChangeNotifierProvider(create: (_) => ServiceProvider(channel)),
        ChangeNotifierProvider(create: (_) => SettingsProvider(channel)),
        ChangeNotifierProvider(create: (_) => CommandsProvider(channel, prefsService)),
      ],
      child: App(showOnboarding: showOnboarding),
    ),
  );
}
