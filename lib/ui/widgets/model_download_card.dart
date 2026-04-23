import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:local_grammer_llm/services/platform_channel_service.dart';

/// Shared UI + logic for downloading the recommended Gemma local model.
///
/// Renders:
///   • "Download Model" header + size hint
///   • A filled button that morphs into a spinner / green "Downloaded" state
///   • A linear progress bar with percentage and Cancel button while running
///   • A "download manually from HuggingFace" link when idle
///
/// Owns all download-related state internally. Parents are notified via
/// callbacks so they can disable navigation or refresh providers.
class ModelDownloadCard extends StatefulWidget {
  /// Set to false when the parent wants to disable the download (e.g. when
  /// another operation is in progress or the local engine mode is not active).
  final bool enabled;

  /// Called whenever the download starts or ends. `true` means a download is
  /// in flight right now — parents should block navigation while true.
  final ValueChanged<bool>? onDownloadingChanged;

  /// Called once when a download finishes successfully with the saved path.
  final ValueChanged<String>? onDownloadSuccess;

  /// Called when a download fails (not for user-initiated cancels).
  final ValueChanged<String>? onDownloadError;

  /// If true (default) the widget shows a persistent green "Model Downloaded"
  /// confirmation after a successful download. Callers that manage their own
  /// "model loaded" UI (e.g. the AI settings screen which re-renders based on
  /// a provider) can set this to false.
  final bool showSuccessState;

  const ModelDownloadCard({
    super.key,
    this.enabled = true,
    this.onDownloadingChanged,
    this.onDownloadSuccess,
    this.onDownloadError,
    this.showSuccessState = true,
  });

  @override
  State<ModelDownloadCard> createState() => _ModelDownloadCardState();
}

class _ModelDownloadCardState extends State<ModelDownloadCard> {
  static const _downloadUrl =
      'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm';
  static const _huggingFaceUrl =
      'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/blob/main/gemma-4-E2B-it.litertlm';
  static const _sizeLabel = '~2.58 GB';

  final _channel = LlmChannelService();
  StreamSubscription<dynamic>? _progressSub;

  bool _downloading = false;
  bool _retrying = false;
  bool _cancelled = false;
  bool _ready = false;
  double? _progress;
  // Guards onDownloadSuccess against double-firing (the stream's `done` event
  // and the method-channel future can both signal completion).
  bool _successFired = false;

  @override
  void initState() {
    super.initState();
    _progressSub = _channel.progressStream.listen(_onProgress, onError: (_) {
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _retrying = false;
        _progress = null;
      });
      widget.onDownloadingChanged?.call(false);
    });
    _restoreActiveDownload();
  }

  /// If a download is already running on the native side (started before this
  /// widget was mounted, e.g. user navigated away and came back), reflect
  /// that in the UI so the button shows progress instead of the idle state.
  Future<void> _restoreActiveDownload() async {
    final active = await _channel.isDownloadActive();
    if (!mounted || !active) return;
    final cached = LlmChannelService.lastProgress;
    final rawProgress = cached?["progress"];
    final cachedProgress =
        (rawProgress is num) ? rawProgress.toDouble() : null;
    setState(() {
      _downloading = true;
      _ready = false;
      _retrying = false;
      _progress = cachedProgress;
      _successFired = false;
    });
    widget.onDownloadingChanged?.call(true);
  }

  void _onProgress(dynamic event) {
    if (event is! Map) return;
    // The progress stream is shared with file-copy progress (model picker).
    // Ignore events when this card isn't actively downloading so unrelated
    // copy progress can't corrupt _progress or spuriously flip _ready=true.
    if (!_downloading) return;
    final rawProgress = event["progress"];
    final done = event["done"] == true;
    final newProgress =
        (rawProgress is num) ? rawProgress.toDouble() : null;

    if (!mounted) return;
    setState(() {
      if (newProgress != null &&
          _progress != null &&
          newProgress < _progress! - 0.02 &&
          !done) {
        // Progress regressed — native side is resuming after a retry.
        _retrying = true;
      } else if (done || (newProgress != null && newProgress > 0.01)) {
        _retrying = false;
      }
      _progress = newProgress;
      if (done) {
        _downloading = false;
        _ready = true;
      }
    });
    if (done) {
      widget.onDownloadingChanged?.call(false);
      // Fire success from the stream too, in case the method-channel future
      // is slow to resolve. _successFired prevents double-notify.
      _fireSuccess('');
    }
  }

  void _fireSuccess(String path) {
    if (_successFired) return;
    _successFired = true;
    // Trigger a (re)load of the model into memory and notify the parent so
    // it can refresh provider state and rebuild into the loaded UI.
    _channel.initFireAndForget();
    widget.onDownloadSuccess?.call(path);
  }

  Future<void> _startDownload() async {
    // Request notification permission up front so the Android foreground
    // download service can post its progress notification.
    try {
      await _channel.requestNotificationPermission();
    } catch (_) {}
    if (!mounted) return;

    setState(() {
      _downloading = true;
      _cancelled = false;
      _retrying = false;
      _progress = null; // "Connecting…" until first real progress tick
      _ready = false;
      _successFired = false;
    });
    widget.onDownloadingChanged?.call(true);

    try {
      await _channel.setApiMode("local");
      final path = await _channel.downloadModel(_downloadUrl);
      final ok = path != null && path.trim().isNotEmpty;
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _ready = ok;
      });
      widget.onDownloadingChanged?.call(false);
      if (ok) {
        _fireSuccess(path);
      }
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _retrying = false;
      });
      widget.onDownloadingChanged?.call(false);
      if (e.code != 'CANCELLED' && !_cancelled) {
        widget.onDownloadError?.call(e.message ?? 'Download failed');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _retrying = false;
      });
      widget.onDownloadingChanged?.call(false);
      if (!_cancelled) widget.onDownloadError?.call('$e');
    } finally {
      if (mounted) {
        setState(() {
          _cancelled = false;
          _retrying = false;
        });
      }
    }
  }

  Future<void> _cancelDownload() async {
    setState(() {
      _cancelled = true;
      _downloading = false;
      _retrying = false;
      _progress = null;
    });
    widget.onDownloadingChanged?.call(false);
    try {
      await _channel.cancelDownload();
    } catch (_) {}
  }

  @override
  void dispose() {
    _progressSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final showSuccess = widget.showSuccessState && _ready && !_downloading;
    final buttonDisabled =
        !widget.enabled || _downloading || showSuccess;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.download_outlined,
                size: 16, color: cs.onSurface),
            const SizedBox(width: 6),
            Text(
              "Download Model",
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          "Recommended: Gemma 4 E2B IT  ($_sizeLabel)",
          style: theme.textTheme.bodySmall
              ?.copyWith(color: cs.onSurface.withValues(alpha: 0.6)),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: buttonDisabled ? null : _startDownload,
            icon: showSuccess
                ? const Icon(Icons.check_circle, color: Colors.white)
                : _downloading
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.cloud_download_outlined),
            label: Text(
              showSuccess
                  ? "Model Downloaded"
                  : _downloading
                      ? "Downloading… (see notification)"
                      : "Download Gemma Model",
            ),
            style: FilledButton.styleFrom(
              backgroundColor: showSuccess ? Colors.green.shade600 : null,
              padding: const EdgeInsets.symmetric(vertical: 13),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ),
        if (showSuccess) ...[
          const SizedBox(height: 10),
          Row(
            children: [
              Icon(Icons.check_circle,
                  color: Colors.green.shade600, size: 18),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  "Download complete — model is ready!",
                  style: TextStyle(
                    color: Colors.green.shade700,
                    fontWeight: FontWeight.w500,
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ),
        ],
        if (_downloading) ...[
          const SizedBox(height: 10),
          LinearProgressIndicator(
            value: _retrying ? null : _progress,
            borderRadius: BorderRadius.circular(4),
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  _retrying
                      ? "Reconnecting… resuming from where it left off"
                      : _progress != null
                          ? "${(_progress! * 100).toStringAsFixed(0)}% of $_sizeLabel"
                          : "Connecting…",
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: cs.onSurface.withValues(alpha: 0.55),
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: _cancelDownload,
                icon: const Icon(Icons.cancel_outlined, size: 15),
                label: const Text("Cancel"),
                style: TextButton.styleFrom(
                  foregroundColor: cs.error,
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ],
        if (!_downloading && !showSuccess) ...[
          const SizedBox(height: 10),
          Center(
            child: GestureDetector(
              onTap: () => launchUrl(
                Uri.parse(_huggingFaceUrl),
                mode: LaunchMode.externalApplication,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.link, size: 14, color: cs.primary),
                  const SizedBox(width: 4),
                  Text(
                    "Or download manually from HuggingFace",
                    style: TextStyle(
                      fontSize: 13,
                      color: cs.primary,
                      decoration: TextDecoration.underline,
                      decorationColor: cs.primary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}
