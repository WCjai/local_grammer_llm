import 'package:flutter/foundation.dart';
import 'package:local_grammer_llm/services/platform_channel_service.dart';

class ServiceProvider extends ChangeNotifier {
  ServiceProvider(this._channel);

  final LlmChannelService _channel;

  bool _serviceEnabled = false;
  bool _serviceGranted = false;

  bool get serviceEnabled => _serviceEnabled;
  bool get serviceGranted => _serviceGranted;

  Future<void> refresh() async {
    try {
      _serviceGranted = await _channel.isAccessibilityGranted();
      final enabled = await _channel.getServiceEnabled();
      _serviceEnabled = _serviceGranted && enabled;
    } catch (_) {
      _serviceGranted = false;
      _serviceEnabled = false;
    }
    notifyListeners();
  }

  /// Returns a message to show, or null.
  Future<String?> toggle(bool value) async {
    if (value && !_serviceGranted) {
      try {
        await _channel.openAccessibilitySettings();
        _serviceEnabled = false;
        notifyListeners();
        return "Enable the accessibility service, then return.";
      } catch (e) {
        return "Open settings error: $e";
      }
    }

    try {
      await _channel.setServiceEnabled(value);
      _serviceEnabled = value;
      notifyListeners();
      return value ? null : "Grammar correction disabled.";
    } catch (e) {
      return "Service toggle error: $e";
    }
  }
}
