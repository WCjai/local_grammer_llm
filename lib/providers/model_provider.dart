import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:local_grammer_llm/services/platform_channel_service.dart';

class ModelProvider extends ChangeNotifier {
  ModelProvider(this._channel) {
    _listenProgress();
  }

  final LlmChannelService _channel;

  bool _busy = false;
  bool _ready = false;
  bool _copying = false;
  double? _copyProgress;
  bool _hasModel = false;
  String _modelName = "";
  bool _initInProgress = false;
  bool _initFlash = false;

  bool get busy => _busy;
  bool get ready => _ready;
  bool get copying => _copying;
  double? get copyProgress => _copyProgress;
  bool get hasModel => _hasModel;
  String get modelName => _modelName;
  bool get initInProgress => _initInProgress;
  bool get initFlash => _initFlash;

  StreamSubscription<dynamic>? _progressSub;

  void _listenProgress() {
    _progressSub = _channel.progressStream.listen((event) {
      if (event is Map) {
        final progress = event["progress"];
        final done = event["done"] == true;
        _copying = !done;
        _copyProgress = (progress is num) ? progress.toDouble() : null;
        notifyListeners();
      }
    }, onError: (_) {
      _copying = false;
      _copyProgress = null;
      notifyListeners();
    });
  }

  Future<void> refreshModelStatus() async {
    try {
      _hasModel = await _channel.hasModel();
      _modelName = await _channel.getModelName();
    } catch (_) {
      _hasModel = false;
      _modelName = "";
    }
    notifyListeners();
  }

  Future<String?> initModel() async {
    if (_initInProgress) return null;
    _busy = true;
    _initInProgress = true;
    _initFlash = false;
    notifyListeners();

    String? message;
    try {
      final ok = await _channel.init();
      _ready = ok;
      message = ok ? "Model ready ✓" : "Init returned false";
      if (ok) {
        _initFlash = true;
        notifyListeners();
        await Future.delayed(const Duration(milliseconds: 700));
        _initFlash = false;
      }
    } catch (e) {
      message = "Init error: $e";
    } finally {
      _busy = false;
      _initInProgress = false;
      notifyListeners();
    }
    return message;
  }

  Future<String?> pickModel() async {
    _busy = true;
    _copying = true;
    _copyProgress = null;
    // Clear any stale name (e.g. "model.task" placeholder) up front so the
    // UI doesn't briefly show the wrong filename while the new file copies.
    _modelName = "";
    notifyListeners();

    // Delete the existing model file before picking a new one so storage
    // isn't wasted holding both files simultaneously.
    if (_hasModel) {
      try {
        await _channel.deleteModel();
      } catch (_) {
        // Deletion failure is non-fatal — proceed with pick.
      }
      _hasModel = false;
      notifyListeners();
    }

    String? message;
    try {
      final path = await _channel.pickModel();
      final hasPath = path != null && path.trim().isNotEmpty;
      _ready = false;
      _hasModel = hasPath;
      if (hasPath) {
        _modelName = path.split(RegExp(r'[/\\]')).last;
      }
      message = hasPath ? "Model copied. Initializing..." : "No model selected.";
      notifyListeners();

      if (hasPath && !_initInProgress) {
        await initModel();
      }
    } catch (e) {
      message = "Pick model error: $e";
    } finally {
      _busy = false;
      notifyListeners();
      await refreshModelStatus();
    }
    return message;
  }

  Future<String?> deleteModel() async {
    _busy = true;
    notifyListeners();
    String? message;
    try {
      await _channel.deleteModel();
      _ready = false;
      _hasModel = false;
      _modelName = "";
      message = "Model deleted.";
    } catch (e) {
      message = "Delete error: $e";
    } finally {
      _busy = false;
      notifyListeners();
    }
    return message;
  }

  @override
  void dispose() {
    _progressSub?.cancel();
    super.dispose();
  }
}
