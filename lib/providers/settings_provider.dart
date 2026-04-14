import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:local_grammer_llm/services/platform_channel_service.dart';

class SettingsProvider extends ChangeNotifier {
  SettingsProvider(this._channel);

  final LlmChannelService _channel;

  static const apiModels = [
    "gemini-2.5-flash-lite",
    "gemini-2.5-flash",
    "gemini-2.5-pro",
    "gemma-3n-e2b-it",
    "gemma-3n-e4b-it",
  ];

  String _apiMode = "local";
  String _apiModel = "gemini-2.5-flash";
  bool _apiValidating = false;
  bool? _apiValid;
  String? _apiError;
  bool _apiKeyVisible = false;
  final apiKeyCtrl = TextEditingController();

  bool _showPreview = false;
  bool _showContext = false;

  int _maxTokens = 512;
  int _outputTokens = 128;

  String get apiMode => _apiMode;
  String get apiModel => _apiModel;
  bool get apiValidating => _apiValidating;
  bool? get apiValid => _apiValid;
  String? get apiError => _apiError;
  bool get apiKeyVisible => _apiKeyVisible;
  bool get showPreview => _showPreview;
  bool get showContext => _showContext;
  int get maxTokens => _maxTokens;
  int get outputTokens => _outputTokens;

  Future<void> refreshAll() async {
    await Future.wait([
      _refreshApiSettings(),
      _refreshPreview(),
      _refreshContext(),
      _refreshTokens(),
    ]);
  }

  Future<void> _refreshApiSettings() async {
    try {
      final mode = await _channel.getApiMode();
      final model = await _channel.getApiModel();
      final key = await _channel.getApiKey();
      const validModes = {"local", "online", "best"};
      _apiMode = (mode != null && validModes.contains(mode)) ? mode : "local";
      _apiModel = (model != null && apiModels.contains(model)) ? model : "gemini-2.5-flash";
      apiKeyCtrl.text = key ?? "";
      _apiValid = null;
      _apiError = null;
      notifyListeners();
      _maybeValidateApiKey();
    } catch (_) {
      _apiMode = "local";
      _apiModel = "gemini-2.5-flash";
      _apiValid = null;
      _apiError = null;
      notifyListeners();
    }
  }

  Future<void> _refreshPreview() async {
    try {
      _showPreview = await _channel.getShowPreview();
    } catch (_) {
      _showPreview = false;
    }
    notifyListeners();
  }

  Future<void> _refreshContext() async {
    try {
      _showContext = await _channel.getShowContext();
    } catch (_) {
      _showContext = false;
    }
    notifyListeners();
  }

  Future<void> _refreshTokens() async {
    try {
      _maxTokens = await _channel.getMaxTokens();
      _outputTokens = await _channel.getOutputTokens();
    } catch (_) {
      // keep defaults
    }
    notifyListeners();
  }

  Future<void> setApiMode(String value) async {
    await _channel.setApiMode(value);
    _apiMode = value;
    _apiValid = null;
    _apiError = null;
    notifyListeners();
    _maybeValidateApiKey();
  }

  Future<void> setApiModel(String value) async {
    await _channel.setApiModel(value);
    _apiModel = value;
    _apiValid = null;
    _apiError = null;
    notifyListeners();
  }

  Future<void> validateApiKey() async {
    _apiValidating = true;
    _apiValid = null;
    _apiError = null;
    notifyListeners();
    try {
      final key = apiKeyCtrl.text.trim();
      await _channel.setApiKey(key);
      final ok = await _channel.validateApiKey(model: _apiModel, key: key);
      _apiValid = ok;
      _apiValidating = false;
    } catch (e) {
      _apiValid = false;
      _apiError = "$e";
      _apiValidating = false;
    }
    notifyListeners();
  }

  void clearValidation() {
    if (_apiValid != null || _apiError != null) {
      _apiValid = null;
      _apiError = null;
      notifyListeners();
    }
  }

  void toggleApiKeyVisible() {
    _apiKeyVisible = !_apiKeyVisible;
    notifyListeners();
  }

  Future<void> _maybeValidateApiKey() async {
    if (_apiValidating) return;
    if (_apiMode == "local") return;
    final key = apiKeyCtrl.text.trim();
    if (key.isEmpty) return;
    await validateApiKey();
  }

  Future<void> togglePreview(bool value) async {
    await _channel.setShowPreview(value);
    _showPreview = value;
    notifyListeners();
  }

  Future<void> toggleContext(bool value) async {
    await _channel.setShowContext(value);
    _showContext = value;
    notifyListeners();
  }

  Future<void> setMaxTokens(int value) async {
    await _channel.setMaxTokens(value);
    _maxTokens = value;
    if (_outputTokens >= value) {
      _outputTokens = (value ~/ 4).clamp(64, 512);
      await _channel.setOutputTokens(_outputTokens);
    }
    notifyListeners();
  }

  Future<void> setOutputTokens(int value) async {
    await _channel.setOutputTokens(value);
    _outputTokens = value;
    notifyListeners();
  }

  @override
  void dispose() {
    apiKeyCtrl.dispose();
    super.dispose();
  }
}
