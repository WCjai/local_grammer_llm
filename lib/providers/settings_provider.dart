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
    "gemma-4-31b-it",
    "gemma-4-26b-a4b-it",
  ];

  String _apiMode = "local";
  String _apiModel = "gemini-2.5-flash";
  bool _apiValidating = false;
  bool? _apiValid;
  String? _apiError;
  bool _apiKeyVisible = false;
  final apiKeyCtrl = TextEditingController();

  bool _showPreview = true;
  bool _showContext = true;
  bool _modelSupportsVision = false;
  String _processingMode = "cpu";

  int _maxTokens = 512;
  int _outputTokens = 128;

  // Sampler knobs. Defaults tuned for grammar / correction workloads; the
  // Creativity slider in AI Settings remaps [0..1] onto temperature [0.1..1.2]
  // so most users never touch the advanced fields directly.
  double _temperature = 0.3;
  int _topK = 40;
  double _topP = 0.9;
  bool _advancedMode = false;

  String get apiMode => _apiMode;
  String get apiModel => _apiModel;
  bool get apiValidating => _apiValidating;
  bool? get apiValid => _apiValid;
  String? get apiError => _apiError;
  bool get apiKeyVisible => _apiKeyVisible;
  bool get showPreview => _showPreview;
  bool get showContext => _showContext;
  bool get modelSupportsVision => _modelSupportsVision;
  String get processingMode => _processingMode;
  int get maxTokens => _maxTokens;
  int get outputTokens => _outputTokens;
  double get temperature => _temperature;
  int get topK => _topK;
  double get topP => _topP;
  bool get advancedMode => _advancedMode;

  /// Creativity slider value in [0.0, 1.0]. Derived from [temperature] using
  /// the inverse of the mapping in [setCreativity]. Zero = deterministic,
  /// one = exploratory.
  double get creativity {
    final t = _temperature.clamp(0.1, 1.2);
    return ((t - 0.1) / 1.1).clamp(0.0, 1.0);
  }

  Future<void> refreshAll() async {
    await Future.wait([
      _refreshApiSettings(),
      _refreshPreview(),
      _refreshContext(),
      _refreshTokens(),
      _refreshVision(),
      _refreshProcessingMode(),
      _refreshSampler(),
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
      _showPreview = true;
    }
    notifyListeners();
  }

  Future<void> _refreshContext() async {
    try {
      _showContext = await _channel.getShowContext();
    } catch (_) {
      _showContext = true;
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

  Future<void> _refreshVision() async {
    try {
      _modelSupportsVision = await _channel.getModelSupportsVision();
    } catch (_) {
      _modelSupportsVision = false;
    }
    notifyListeners();
  }

  Future<void> setModelSupportsVision(bool value) async {
    await _channel.setModelSupportsVision(value);
    _modelSupportsVision = value;
    notifyListeners();
  }

  Future<void> _refreshProcessingMode() async {
    try {
      _processingMode = await _channel.getProcessingMode();
    } catch (_) {
      _processingMode = "cpu";
    }
    notifyListeners();
  }

  Future<void> setProcessingMode(String mode) async {
    final actual = await _channel.setProcessingMode(mode);
    _processingMode = actual;
    notifyListeners();
    if (actual != mode) {
      // GPU was requested but the device fell back to CPU.
      throw Exception(
          "${mode.toUpperCase()} backend isn't available on this device — using CPU instead.");
    }
  }

  Future<void> _refreshSampler() async {
    try {
      _temperature = await _channel.getTemperature();
      _topK = await _channel.getTopK();
      _topP = await _channel.getTopP();
      _advancedMode = await _channel.getAdvancedMode();
    } catch (_) {
      // Keep defaults.
    }
    notifyListeners();
  }

  /// Drives the Creativity slider. Maps [0..1] onto temperature [0.1..1.2]
  /// so the default "balanced" midpoint (0.5) produces temperature ≈ 0.65,
  /// usable for both grammar correction (low) and brainstorming (high).
  Future<void> setCreativity(double value) async {
    final v = value.clamp(0.0, 1.0);
    final temp = 0.1 + v * 1.1;
    await setTemperature(temp);
  }

  Future<void> setTemperature(double value) async {
    final v = value.clamp(0.0, 2.0);
    await _channel.setTemperature(v);
    _temperature = v;
    notifyListeners();
  }

  Future<void> setTopK(int value) async {
    final v = value.clamp(1, 100);
    await _channel.setTopK(v);
    _topK = v;
    notifyListeners();
  }

  Future<void> setTopP(double value) async {
    final v = value.clamp(0.0, 1.0);
    await _channel.setTopP(v);
    _topP = v;
    notifyListeners();
  }

  Future<void> setAdvancedMode(bool enabled) async {
    await _channel.setAdvancedMode(enabled);
    _advancedMode = enabled;
    notifyListeners();
  }

  @override
  void dispose() {
    apiKeyCtrl.dispose();
    super.dispose();
  }
}
