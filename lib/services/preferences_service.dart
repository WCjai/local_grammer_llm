import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// Wraps SharedPreferences reads/writes used by the app.
class PreferencesService {
  SharedPreferences? _prefs;

  Future<SharedPreferences> _getPrefs() async {
    _prefs ??= await SharedPreferences.getInstance();
    return _prefs!;
  }

  // ── Onboarding ──

  Future<bool> hasCompletedOnboarding() async {
    final prefs = await _getPrefs();
    return prefs.getBool('has_completed_onboarding') ?? false;
  }

  Future<void> setOnboardingCompleted(bool value) async {
    final prefs = await _getPrefs();
    await prefs.setBool('has_completed_onboarding', value);
  }

  // ── Command Description Cache ──

  Future<Map<String, dynamic>> getCommandCache() async {
    final prefs = await _getPrefs();
    final raw = prefs.getString("command_desc_cache") ?? "{}";
    try {
      return (jsonDecode(raw) as Map<String, dynamic>?) ?? {};
    } catch (_) {
      return {};
    }
  }

  Future<void> setCommandCache(Map<String, dynamic> cache) async {
    final prefs = await _getPrefs();
    await prefs.setString("command_desc_cache", jsonEncode(cache));
  }
}
