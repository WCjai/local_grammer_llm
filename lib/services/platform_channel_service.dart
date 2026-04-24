import 'dart:async';
import 'package:flutter/services.dart';

/// Wraps all MethodChannel('local_llm') + EventChannel('local_llm_progress') calls.
class LlmChannelService {
  static const _channel = MethodChannel('local_llm');
  static const _progressChannel = EventChannel('local_llm_progress');
  static const _generationChannel = EventChannel('local_llm_generation');

  // ── Model ──

  Future<bool> hasModel() async {
    final v = await _channel.invokeMethod<bool>("hasModel");
    return v == true;
  }

  Future<String> getModelName() async {
    final v = await _channel.invokeMethod<String>("getModelName");
    return v ?? "";
  }

  Future<bool> init() async {
    final v = await _channel.invokeMethod<bool>("init");
    return v == true;
  }

  void initFireAndForget() {
    _channel.invokeMethod<bool>("init");
  }

  Future<String?> pickModel() async {
    return _channel.invokeMethod<String>("pickModel");
  }

  /// Downloads the model file from [url], saves it to internal storage,
  /// and sets it as the active model. Progress is emitted via [progressStream].
  Future<String?> downloadModel(String url) async {
    return _channel.invokeMethod<String>("downloadModel", {"url": url});
  }

  /// Cancels an in-progress [downloadModel] call.
  Future<void> cancelDownload() async {
    await _channel.invokeMethod("cancelDownload");
  }

  // ── Accessibility / Service ──

  Future<bool> isAccessibilityGranted() async {
    final v = await _channel.invokeMethod<bool>("isAccessibilityGranted");
    return v == true;
  }

  Future<bool> getServiceEnabled() async {
    final v = await _channel.invokeMethod<bool>("getServiceEnabled");
    return v == true;
  }

  Future<void> setServiceEnabled(bool enabled) async {
    await _channel.invokeMethod<bool>("setServiceEnabled", {"enabled": enabled});
  }

  Future<void> openAccessibilitySettings() async {
    await _channel.invokeMethod<bool>("openAccessibilitySettings");
  }

  // ── Preview / Context ──

  Future<bool> getShowPreview() async {
    final v = await _channel.invokeMethod<bool>("getShowPreview");
    return v == true;
  }

  Future<void> setShowPreview(bool enabled) async {
    await _channel.invokeMethod<bool>("setShowPreview", {"enabled": enabled});
  }

  Future<bool> getShowContext() async {
    final v = await _channel.invokeMethod<bool>("getShowContext");
    return v == true;
  }

  Future<void> setShowContext(bool enabled) async {
    await _channel.invokeMethod<bool>("setShowContext", {"enabled": enabled});
  }

  // ── API Settings ──

  Future<String?> getApiMode() async {
    return _channel.invokeMethod<String>("getApiMode");
  }

  Future<void> setApiMode(String mode) async {
    await _channel.invokeMethod<bool>("setApiMode", {"mode": mode});
  }

  Future<String?> getApiModel() async {
    return _channel.invokeMethod<String>("getApiModel");
  }

  Future<void> setApiModel(String model) async {
    await _channel.invokeMethod<bool>("setApiModel", {"model": model});
  }

  Future<String?> getApiKey() async {
    return _channel.invokeMethod<String>("getApiKey");
  }

  Future<void> setApiKey(String key) async {
    await _channel.invokeMethod<bool>("setApiKey", {"key": key});
  }

  Future<bool> validateApiKey({required String model, required String key}) async {
    final v = await _channel.invokeMethod<bool>("validateApiKey", {
      "model": model,
      "key": key,
    });
    return v == true;
  }

  // ── Token Settings ──

  Future<int> getMaxTokens() async {
    final v = await _channel.invokeMethod<int>("getMaxTokens");
    return v ?? 512;
  }

  Future<void> setMaxTokens(int value) async {
    await _channel.invokeMethod<bool>("setMaxTokens", {"value": value});
  }

  Future<int> getOutputTokens() async {
    final v = await _channel.invokeMethod<int>("getOutputTokens");
    return v ?? 128;
  }

  Future<void> setOutputTokens(int value) async {
    await _channel.invokeMethod<bool>("setOutputTokens", {"value": value});
  }

  // ── Vision ──

  Future<bool> getModelSupportsVision() async {
    return await _channel.invokeMethod<bool>("getModelSupportsVision") ?? false;
  }

  Future<void> setModelSupportsVision(bool enabled) async {
    await _channel.invokeMethod<bool>("setModelSupportsVision", {"enabled": enabled});
  }

  Future<void> deleteModel() async {
    await _channel.invokeMethod<bool>("deleteModel");
  }

  Future<String> getProcessingMode() async {
    final v = await _channel.invokeMethod<String>("getProcessingMode");
    return v ?? "cpu";
  }

  /// Sets the processing mode and eagerly tries to (re)build the engine
  /// with the requested backend. Returns the backend that was actually used
  /// (e.g. "cpu" if "gpu" was requested but failed to initialise on the device).
  Future<String> setProcessingMode(String mode) async {
    final v = await _channel.invokeMethod<String>("setProcessingMode", {"mode": mode});
    return v ?? mode;
  }

  /// Requests POST_NOTIFICATIONS permission on Android 13+.
  /// Returns true if granted (or if not needed on older Android), false if denied.
  Future<bool> requestNotificationPermission() async {
    final v = await _channel.invokeMethod<bool>("requestNotificationPermission");
    return v == true;
  }

  // ── Generation ──

  Future<String?> generate(String prompt) async {
    return _channel.invokeMethod<String>("generate", {"prompt": prompt});
  }

  /// Starts a streaming generation on the native side and returns a stream
  /// that yields partial text chunks. The stream completes normally when the
  /// engine reports "done", or errors when native reports a failure.
  ///
  /// Callers should subscribe *before* the underlying native call is issued —
  /// [generateStream] wires the subscription first, then fires the start
  /// request, so the first token can't be dropped on fast models.
  Stream<String> generateStream(String prompt) {
    final controller = StreamController<String>();
    late StreamSubscription<dynamic> sub;
    sub = _generationChannel.receiveBroadcastStream().listen(
      (event) {
        if (event is! Map) return;
        if (event["token"] is String) {
          controller.add(event["token"] as String);
        } else if (event["done"] == true) {
          controller.close();
          sub.cancel();
        } else if (event["error"] is String) {
          controller.addError(event["error"] as String);
          controller.close();
          sub.cancel();
        }
      },
      onError: (err, st) {
        controller.addError(err, st);
        controller.close();
        sub.cancel();
      },
      cancelOnError: false,
    );
    // Kick off the native generation after the sink is wired. Ignore the
    // Future result — progress comes back via the event channel.
    _channel.invokeMethod<bool>("generateStream", {"prompt": prompt}).catchError((e) {
      if (!controller.isClosed) {
        controller.addError(e);
        controller.close();
      }
      sub.cancel();
      return null;
    });
    controller.onCancel = () async {
      // If the Dart consumer cancels (e.g. chat screen disposed mid-stream),
      // ask native to stop so we don't leak compute. cancelGenerate is a no-op
      // when nothing is running.
      try { await cancelGenerate(); } catch (_) {}
      await sub.cancel();
    };
    return controller.stream;
  }

  /// Cancels the in-progress streaming generation, if any. Returns true if a
  /// running generation was actually interrupted.
  Future<bool> cancelGenerate() async {
    final v = await _channel.invokeMethod<bool>("cancelGenerate");
    return v == true;
  }

  // ── Sampler (creativity / advanced) ──

  Future<double> getTemperature() async {
    final v = await _channel.invokeMethod<double>("getTemperature");
    return v ?? 0.3;
  }
  Future<void> setTemperature(double value) async {
    await _channel.invokeMethod<bool>("setTemperature", {"value": value});
  }
  Future<int> getTopK() async {
    final v = await _channel.invokeMethod<int>("getTopK");
    return v ?? 40;
  }
  Future<void> setTopK(int value) async {
    await _channel.invokeMethod<bool>("setTopK", {"value": value});
  }
  Future<double> getTopP() async {
    final v = await _channel.invokeMethod<double>("getTopP");
    return v ?? 0.9;
  }
  Future<void> setTopP(double value) async {
    await _channel.invokeMethod<bool>("setTopP", {"value": value});
  }
  Future<bool> getAdvancedMode() async {
    final v = await _channel.invokeMethod<bool>("getAdvancedMode");
    return v == true;
  }
  Future<void> setAdvancedMode(bool enabled) async {
    await _channel.invokeMethod<bool>("setAdvancedMode", {"enabled": enabled});
  }

  // ── Prompts ──

  Future<List<Map<String, dynamic>>> getPrompts() async {
    final raw = await _channel.invokeMethod<List<dynamic>>("getPrompts") ?? [];
    return raw
        .whereType<Map>()
        .map((e) => e.map((k, v) => MapEntry(k.toString(), v)))
        .map((e) => e.cast<String, dynamic>())
        .toList();
  }

  Future<void> addPrompt({required String keyword, required String prompt}) async {
    await _channel.invokeMethod<bool>("addPrompt", {
      "keyword": keyword,
      "prompt": prompt,
    });
  }

  Future<void> updatePrompt({
    required String keyword,
    required String prompt,
    required String oldKeyword,
  }) async {
    await _channel.invokeMethod<bool>("updatePrompt", {
      "keyword": keyword,
      "prompt": prompt,
      "oldKeyword": oldKeyword,
    });
  }

  Future<void> deletePrompt(String keyword) async {
    await _channel.invokeMethod<bool>("deletePrompt", {"keyword": keyword});
  }

  // ── Progress Stream ──

  // We own a single broadcast controller and subscribe to the EventChannel
  // exactly once. Every consumer (ModelProvider, ModelDownloadCard,
  // onboarding, …) receives events through this controller so there's no
  // chance of a second receiveBroadcastStream() call replacing the channel's
  // message handler and starving earlier listeners.
  static final StreamController<dynamic> _progressController =
      StreamController<dynamic>.broadcast();
  static bool _progressWired = false;

  /// Last progress event received from native; replayed to new subscribers
  /// so widgets that mount mid-download (e.g. user navigates back into AI
  /// Settings) immediately see the in-flight progress instead of an empty
  /// idle state.
  static Map<dynamic, dynamic>? _lastProgress;
  static Map<dynamic, dynamic>? get lastProgress => _lastProgress;

  static void _wireProgress() {
    if (_progressWired) return;
    _progressWired = true;
    _progressChannel.receiveBroadcastStream().listen(
      (event) {
        if (event is Map) {
          final done = event["done"] == true;
          // Cache the latest event while a download is in flight; clear it
          // once the stream signals done so a stale "in-progress" snapshot
          // doesn't resurrect after completion.
          _lastProgress = done ? null : event;
        }
        if (!_progressController.isClosed) _progressController.add(event);
      },
      onError: (err, st) {
        _lastProgress = null;
        if (!_progressController.isClosed) {
          _progressController.addError(err, st);
        }
      },
      cancelOnError: false,
    );
  }

  Stream<dynamic> get progressStream {
    _wireProgress();
    return _progressController.stream;
  }

  /// Whether a download is currently running on the native side. Used by
  /// widgets that mount mid-download to restore their UI.
  Future<bool> isDownloadActive() async {
    try {
      final v = await _channel.invokeMethod<bool>("isDownloadActive");
      return v == true;
    } catch (_) {
      return false;
    }
  }
}
