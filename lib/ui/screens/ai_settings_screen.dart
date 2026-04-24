import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:local_grammer_llm/providers/model_provider.dart';
import 'package:local_grammer_llm/providers/settings_provider.dart';
import 'package:local_grammer_llm/services/platform_channel_service.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:local_grammer_llm/ui/widgets/app_snackbar.dart';
import 'package:local_grammer_llm/ui/widgets/model_download_card.dart';
import 'package:local_grammer_llm/ui/widgets/no_glow_scroll.dart';

class AiSettingsScreen extends StatefulWidget {
  const AiSettingsScreen({super.key});

  @override
  State<AiSettingsScreen> createState() => _AiSettingsScreenState();
}

class _AiSettingsScreenState extends State<AiSettingsScreen> {
  final _channel = LlmChannelService();
  bool _downloadingModel = false;
  bool _switchingMode = false;
  bool _togglingVision = false;

  // Pending sampler edits. Writing to the MethodChannel on every slider
  // frame stalls the drag on mid-range devices, so we hold edits locally
  // and commit them through an explicit Apply button. Native reads the
  // sampler at generate time (see MainActivity.invalidateEngineIfSamplerChanged),
  // so committed values automatically apply to the next LLM call.
  double? _pendingCreativity;
  double? _pendingTemp;
  int? _pendingTopK;
  double? _pendingTopP;
  bool _advancedExpanded = false;
  bool _applyingSampler = false;

  Future<void> _changeProcessingMode(SettingsProvider settings, String mode) async {
    if (_switchingMode) return;
    if (settings.processingMode == mode) return;
    setState(() => _switchingMode = true);
    try {
      await settings.setProcessingMode(mode);
    } catch (e) {
      _showNotice("$e");
    } finally {
      if (mounted) setState(() => _switchingMode = false);
    }
  }

  Future<void> _toggleVisionSupport(SettingsProvider settings, bool v) async {
    if (_togglingVision) return;
    setState(() => _togglingVision = true);
    try {
      await settings.setModelSupportsVision(v);
    } catch (e) {
      _showNotice("Error: $e");
    } finally {
      if (mounted) setState(() => _togglingVision = false);
    }
  }

  void _showNotice(String message) {
    if (!mounted) return;
    final type = message.contains('✓') || message.contains('deleted') || message.contains('ready')
        ? SnackType.success
        : message.toLowerCase().contains('error') || message.toLowerCase().contains('fail')
            ? SnackType.error
            : SnackType.info;
    showAppSnackBar(context, message, type: type);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final model = context.watch<ModelProvider>();
    final settings = context.watch<SettingsProvider>();
    final busy = model.busy;
    final isLocal = settings.apiMode != "online";
    final isOnline = settings.apiMode != "local";

    return Scaffold(
      appBar: AppBar(
        title: const Text("AI Settings"),
        leading: const BackButton(),
        centerTitle: false,
      ),
      body: SafeArea(
        child: ScrollConfiguration(
          behavior: const NoGlowScrollBehavior(),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            children: [

              // ── Engine Mode ─────────────────────────────────────────
              _sectionLabel("AI provider", theme),
              const SizedBox(height: 8),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(
                    value: "local",
                    label: Text("Local", softWrap: false),
                    icon: Icon(Icons.smartphone),
                  ),
                  ButtonSegment(
                    value: "best",
                    label: Text("Auto", softWrap: false),
                    icon: Icon(Icons.auto_awesome),
                  ),
                  ButtonSegment(
                    value: "online",
                    label: Text("Cloud", softWrap: false),
                    icon: Icon(Icons.cloud),
                  ),
                ],
                selected: {settings.apiMode},
                onSelectionChanged: busy
                    ? null
                    : (v) => settings.setApiMode(v.first).catchError((e) {
                          _showNotice("Mode error: $e");
                        }),
                showSelectedIcon: false,
              ),
              const SizedBox(height: 24),

              // ── Cloud API ────────────────────────────────────────────
              _settingsCard(
                theme: theme,
                icon: Icons.cloud_outlined,
                title: "Cloud API",
                enabled: isOnline,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    DropdownButtonFormField<String>(
                      initialValue: settings.apiModel,
                      decoration: const InputDecoration(
                        labelText: "Model",
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                      items: SettingsProvider.apiModels
                          .map((m) => DropdownMenuItem(value: m, child: Text(m)))
                          .toList(),
                      onChanged: (busy || !isOnline)
                          ? null
                          : (v) => settings
                              .setApiModel(v ?? settings.apiModel)
                              .catchError((e) { _showNotice("Model error: $e"); }),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: settings.apiKeyCtrl,
                      obscureText: !settings.apiKeyVisible,
                      decoration: InputDecoration(
                        labelText: "API Key",
                        isDense: true,
                        border: const OutlineInputBorder(),
                        suffixIcon: IconButton(
                          onPressed: settings.toggleApiKeyVisible,
                          icon: Icon(
                            settings.apiKeyVisible ? Icons.visibility_off : Icons.visibility,
                            size: 20,
                          ),
                        ),
                      ),
                      onChanged: (_) => settings.clearValidation(),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            style: FilledButton.styleFrom(
                              backgroundColor: settings.apiValid == true
                                  ? Colors.green
                                  : (settings.apiValid == false
                                      ? Colors.red
                                      : cs.primary),
                            ),
                            onPressed: (settings.apiValidating || !isOnline)
                                ? null
                                : () => settings.validateApiKey().catchError((e) {
                                      _showNotice("Validation error: $e");
                                    }),
                            icon: settings.apiValidating
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2, color: Colors.white))
                                : Icon(
                                    settings.apiValid == true
                                        ? Icons.check
                                        : (settings.apiValid == false
                                            ? Icons.close
                                            : Icons.vpn_key),
                                    size: 18,
                                  ),
                            label: Text(
                              settings.apiValid == true
                                  ? "Verified"
                                  : (settings.apiValid == false
                                      ? "Invalid"
                                      : "Validate Key"),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        OutlinedButton.icon(
                          onPressed: () => launchUrl(
                            Uri.parse('https://aistudio.google.com/app/apikey'),
                            mode: LaunchMode.externalApplication,
                          ),
                          icon: const Icon(Icons.open_in_new, size: 15),
                          label: const Text("Get API Key"),
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                                vertical: 12, horizontal: 10),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8)),
                          ),
                        ),
                      ],
                    ),
                    if (settings.apiError != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        settings.apiError!,
                        style: theme.textTheme.labelSmall?.copyWith(color: Colors.red),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    if (isOnline && settings.apiValid != true) ...[
                      const SizedBox(height: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 10),
                        decoration: BoxDecoration(
                          color: cs.primaryContainer.withValues(alpha: 0.45),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                              color: cs.primary.withValues(alpha: 0.22)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(Icons.tips_and_updates_outlined,
                                    size: 14, color: cs.primary),
                                const SizedBox(width: 6),
                                Text(
                                  "Quick Setup",
                                  style: theme.textTheme.labelMedium?.copyWith(
                                    fontWeight: FontWeight.w700,
                                    color: cs.primary,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            ...[
                              '1. Tap "Get API Key" above',
                              '2. Sign in to Google AI Studio',
                              '3. Create a key and paste it here',
                            ].map(
                              (step) => Padding(
                                padding: const EdgeInsets.only(top: 3),
                                child: Text(
                                  step,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: cs.onSurface.withValues(alpha: 0.75),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // ── LOCAL MODELS ─────────────────────────────────────────
              //_sectionLabel("LOCAL MODELS", theme),
              //const SizedBox(height: 8),
              // The creativity sliders + image-input toggle used to sit as
              // separate cards beneath this one. They are now rendered inside
              // the local-model card so all Gemma-specific controls live in
              // a single section.
              _localModelCard(theme, cs, model, settings, busy, isLocal),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  Widget _localModelCard(
    ThemeData theme,
    ColorScheme cs,
    ModelProvider model,
    SettingsProvider settings,
    bool busy,
    bool isLocal,
  ) {
    final hasModel = model.hasModel;
    final modelName = model.modelName;

    return AnimatedOpacity(
      opacity: isLocal ? 1.0 : 0.45,
      duration: const Duration(milliseconds: 200),
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: theme.dividerColor.withValues(alpha: 0.4)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Header ─────────────────────────────────────────────
            Row(
              children: [
                Icon(Icons.phone_android, size: 18, color: cs.primary),
                const SizedBox(width: 8),
                Text(
                  "LOCAL GEMMA MODEL",
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                    color: cs.primary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              "Download or select a local Gemma model file (.litertlm or .task) to use for on-device AI processing. Downloaded models are saved to the app's private storage.",
              style: theme.textTheme.bodySmall?.copyWith(
                color: cs.onSurface.withValues(alpha: 0.65),
                height: 1.4,
              ),
            ),
            const SizedBox(height: 18),

            // ── Download section (shown only when no model) ─────────
            if (!hasModel) ...[
              ModelDownloadCard(
                enabled: isLocal && !busy,
                showSuccessState: false, // hasModel flips immediately after refresh
                onDownloadingChanged: (v) {
                  if (!mounted) return;
                  setState(() => _downloadingModel = v);
                  // When a download finishes (v == false), refresh status so
                  // the card collapses and the loaded-model UI appears, even
                  // if the success callback raced with the stream event.
                  if (!v) {
                    context.read<ModelProvider>().refreshModelStatus();
                  }
                },
                onDownloadSuccess: (_) {
                  if (!mounted) return;
                  context.read<ModelProvider>().refreshModelStatus();
                },
                onDownloadError: (msg) => _showNotice('Download failed: $msg'),
              ),
              const SizedBox(height: 16),
              const Divider(height: 1),
              const SizedBox(height: 16),
              // ── Select file ───────────────────────────────────────
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: (busy || !isLocal || _downloadingModel || model.copying)
                      ? null
                      : () async {
                          final msg = await model.pickModel();
                          if (msg != null) _showNotice(msg);
                        },
                  icon: model.copying
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.folder_open_outlined),
                  label: Text(model.copying ? "Copying model…" : "Select Model File"),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
              if (model.copying && model.copyProgress != null) ...[
                const SizedBox(height: 8),
                LinearProgressIndicator(
                  value: model.copyProgress,
                  borderRadius: BorderRadius.circular(4),
                ),
              ],
            ],

            // ── Model loaded state ──────────────────────────────────
            if (hasModel) ...[
              // Selected model display
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: cs.surface,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: cs.outline.withValues(alpha: 0.3)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      "Selected Model:",
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: cs.onSurface.withValues(alpha: 0.55),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Icon(Icons.check_circle_outline,
                            size: 16, color: Colors.green.shade500),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            modelName.isEmpty ? "Model ready" : modelName,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),

              // ── Processing mode ─────────────────────────────────
              Text(
                "Processing Mode",
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                "Choose the processing mode for the local model:",
                style: theme.textTheme.bodySmall?.copyWith(
                  color: cs.onSurface.withValues(alpha: 0.55),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _processorModeCard(
                      theme: theme,
                      cs: cs,
                      icon: Icons.memory_outlined,
                      label: "CPU",
                      description: "Optimized for lower resource usage.",
                      selected: settings.processingMode == "cpu",
                      onTap: (busy || _switchingMode || settings.processingMode == "cpu")
                          ? null
                          : () => _changeProcessingMode(settings, "cpu"),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _processorModeCard(
                      theme: theme,
                      cs: cs,
                      icon: Icons.developer_board_outlined,
                      label: "GPU",
                      description: "Designed for higher performance tasks.",
                      selected: settings.processingMode == "gpu",
                      onTap: (busy || _switchingMode || settings.processingMode == "gpu")
                          ? null
                          : () => _changeProcessingMode(settings, "gpu"),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.amber.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                      color: Colors.amber.withValues(alpha: 0.45)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.warning_amber_rounded,
                        size: 16, color: Colors.amber.shade800),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        "If the app crashes when GPU is selected, your device's hardware can't handle GPU inference for this model. Switch back to CPU for stable performance.",
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: cs.onSurface.withValues(alpha: 0.75),
                          height: 1.35,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),

              // ── Image input support (moved inside the local-model card so
              //     every Gemma-specific control lives in one section) ──
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                decoration: BoxDecoration(
                  color: cs.surface,
                  borderRadius: BorderRadius.circular(12),
                  border:
                      Border.all(color: cs.outline.withValues(alpha: 0.3)),
                ),
                child: SwitchListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: const Text("Image input support"),
                  subtitle: Text(
                    _togglingVision
                        ? "Rebuilding engine…"
                        : "Enable only if your local model accepts image input.",
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: cs.onSurface.withValues(alpha: 0.5),
                    ),
                  ),
                  value: settings.modelSupportsVision,
                  onChanged: (busy || !isLocal || _togglingVision)
                      ? null
                      : (v) => _toggleVisionSupport(settings, v),
                ),
              ),
              const SizedBox(height: 14),

              // ── Creativity + advanced sampler (also moved inside) ──
              _creativityCard(theme, cs, settings, !busy && isLocal),
              const SizedBox(height: 20),

              // ── Bottom actions: Change + Delete ─────────────────
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: (busy || !isLocal)
                          ? null
                          : () async {
                              final msg = await model.pickModel();
                              if (msg != null) _showNotice(msg);
                            },
                      icon: const Icon(Icons.folder_open_outlined, size: 18),
                      label: const Text("Change Model"),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: (busy || !isLocal)
                          ? null
                          : () async {
                              final confirmed = await _confirmDelete(context);
                              if (!confirmed || !mounted) return;
                              final msg = await model.deleteModel();
                              if (msg != null) _showNotice(msg);
                            },
                      icon: Icon(Icons.delete_outline, size: 18, color: cs.error),
                      label: Text(
                        "Delete All",
                        style: TextStyle(color: cs.error),
                      ),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        side: BorderSide(color: cs.error.withValues(alpha: 0.6)),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _processorModeCard({
    required ThemeData theme,
    required ColorScheme cs,
    required IconData icon,
    required String label,
    required String description,
    required bool selected,
    required VoidCallback? onTap,
  }) {
    final disabled = onTap == null && !selected;
    return Opacity(
      opacity: disabled ? 0.45 : 1.0,
      child: GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: selected
              ? cs.primary.withValues(alpha: 0.12)
              : cs.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? cs.primary : theme.dividerColor.withValues(alpha: 0.4),
            width: selected ? 2 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 22, color: selected ? cs.primary : cs.onSurface),
            const SizedBox(height: 8),
            Text(
              label,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
                color: selected ? cs.primary : cs.onSurface,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              description,
              style: theme.textTheme.labelSmall?.copyWith(
                color: cs.onSurface.withValues(alpha: 0.6),
                height: 1.3,
              ),
            ),
          ],
        ),
      ),
    ),
    );
  }

  Future<bool> _confirmDelete(BuildContext ctx) async {
    final result = await showDialog<bool>(
      context: ctx,
      builder: (ctx) => AlertDialog(
        title: const Text("Delete model?"),
        content: const Text(
            "This will permanently delete the downloaded model file. You will need to download or import it again."),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text("Cancel"),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(
                foregroundColor: Theme.of(ctx).colorScheme.error),
            child: const Text("Delete"),
          ),
        ],
      ),
    );
    return result == true;
  }

  Widget _sectionLabel(String label, ThemeData theme) {
    return Text(
      label,
      style: theme.textTheme.labelMedium?.copyWith(
        color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
        fontWeight: FontWeight.w600,
        letterSpacing: 0.6,
      ),
    );
  }

  Widget _settingsCard({
    required ThemeData theme,
    required IconData icon,
    required String title,
    required bool enabled,
    required Widget child,
  }) {
    final cs = theme.colorScheme;
    return AnimatedOpacity(
      opacity: enabled ? 1.0 : 0.45,
      duration: const Duration(milliseconds: 200),
      child: IgnorePointer(
        ignoring: !enabled,
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: theme.dividerColor.withValues(alpha: 0.4)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, size: 18, color: cs.primary),
                  const SizedBox(width: 8),
                  Text(
                    title,
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              child,
            ],
          ),
        ),
      ),
    );
  }

  Widget _tokenSlider({
    required String label,
    required int value,
    required double min,
    required double max,
    required int divisions,
    required bool enabled,
    required ValueChanged<int> onChanged,
    required ThemeData theme,
  }) {
    final cs = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: theme.textTheme.bodySmall),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: cs.primaryContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                "$value",
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: cs.onPrimaryContainer,
                ),
              ),
            ),
          ],
        ),
        SliderTheme(
          data: SliderThemeData(
            trackHeight: 4,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
          ),
          child: Slider(
            value: value.toDouble().clamp(min, max),
            min: min,
            max: max,
            divisions: divisions > 0 ? divisions : 1,
            onChanged: enabled ? (v) => onChanged(v.round()) : null,
          ),
        ),
      ],
    );
  }

  /// Card that hosts the Creativity slider plus a collapsible advanced
  /// panel (temperature / top-K / top-P). Edits are buffered in local
  /// `_pending*` fields so slider drags are silky on low-end devices —
  /// the MethodChannel writes (which can rebuild the native engine) only
  /// happen when the user taps **Apply**. Native re-reads sampler params
  /// on every generate, so committed values always hit the next LLM call.
  Widget _creativityCard(
    ThemeData theme,
    ColorScheme cs,
    SettingsProvider settings,
    bool enabled,
  ) {
    final creativity = _pendingCreativity ?? settings.creativity;
    final temp = _pendingTemp ?? settings.temperature;
    final topK = _pendingTopK ?? settings.topK;
    final topP = _pendingTopP ?? settings.topP;

    final dirty = _pendingCreativity != null ||
        _pendingTemp != null ||
        _pendingTopK != null ||
        _pendingTopP != null;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.dividerColor.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.auto_awesome_outlined, size: 18, color: cs.primary),
              const SizedBox(width: 8),
              Text(
                "Creativity",
                style: theme.textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                decoration: BoxDecoration(
                  color: cs.primaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _creativityLabel(creativity),
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: cs.onPrimaryContainer,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            "Lower = strict / deterministic. Higher = exploratory.",
            style: theme.textTheme.labelSmall?.copyWith(
              color: cs.onSurface.withValues(alpha: 0.6),
            ),
          ),
          SliderTheme(
            data: SliderThemeData(
              trackHeight: 4,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
            ),
            child: Slider(
              value: creativity.clamp(0.0, 1.0),
              onChanged: enabled
                  ? (v) => setState(() => _pendingCreativity = v)
                  : null,
            ),
          ),

          // ── Advanced sampler (collapsible) ──────────────────────────
          Theme(
            // Strip the default ExpansionTile divider.
            data: theme.copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              initiallyExpanded: _advancedExpanded || settings.advancedMode,
              onExpansionChanged: (v) {
                setState(() => _advancedExpanded = v);
                // Remember the preference across screen visits. Fire-and-forget;
                // a failure here shouldn't block the UI.
                settings.setAdvancedMode(v);
              },
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(top: 4, bottom: 8),
              dense: true,
              expandedCrossAxisAlignment: CrossAxisAlignment.start,
              title: Text(
                "Advanced sampler",
                style: theme.textTheme.bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              subtitle: Text(
                "Tune temperature / top-K / top-P directly.",
                style: theme.textTheme.labelSmall?.copyWith(
                  color: cs.onSurface.withValues(alpha: 0.55),
                ),
              ),
              children: [
                _advSlider(
                  theme: theme,
                  label: "Temperature",
                  value: temp,
                  min: 0.0,
                  max: 2.0,
                  divisions: 40,
                  display: temp.toStringAsFixed(2),
                  enabled: enabled,
                  onChanged: (v) => setState(() => _pendingTemp = v),
                ),
                const SizedBox(height: 8),
                _advSlider(
                  theme: theme,
                  label: "Top-K",
                  value: topK.toDouble(),
                  min: 1,
                  max: 100,
                  divisions: 99,
                  display: "$topK",
                  enabled: enabled,
                  onChanged: (v) =>
                      setState(() => _pendingTopK = v.round()),
                ),
                const SizedBox(height: 8),
                _advSlider(
                  theme: theme,
                  label: "Top-P",
                  value: topP,
                  min: 0.0,
                  max: 1.0,
                  divisions: 20,
                  display: topP.toStringAsFixed(2),
                  enabled: enabled,
                  onChanged: (v) => setState(() => _pendingTopP = v),
                ),
              ],
            ),
          ),

          // ── Apply / Reset actions ───────────────────────────────────
          const SizedBox(height: 4),
          Row(
            children: [
              // Reset-to-model-defaults lives on the leading edge as an
              // icon-only button. Model defaults match `SamplerParams()`
              // on the Kotlin side: temperature 0.3, top-K 40, top-P 0.9.
              IconButton(
                onPressed: (enabled && !_applyingSampler)
                    ? () => _resetSamplerToDefaults(settings)
                    : null,
                icon: const Icon(Icons.restart_alt),
                tooltip: "Reset to model defaults",
                visualDensity: VisualDensity.compact,
              ),
              Expanded(
                child: Text(
                  dirty
                      ? "Unsaved changes — tap Apply to use on next request."
                      : "Changes apply to the next LLM request.",
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: dirty
                        ? cs.tertiary
                        : cs.onSurface.withValues(alpha: 0.55),
                    fontWeight: dirty ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              FilledButton.icon(
                onPressed: (enabled && dirty && !_applyingSampler)
                    ? () => _applySampler(settings)
                    : null,
                icon: _applyingSampler
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.check, size: 16),
                label: Text(_applyingSampler ? "Applying…" : "Apply"),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Word-label mapping for the Creativity slider. Buckets escalate through
  /// "Strict" → "Precise" → "Balanced" → "Playful" → "Imaginative" →
  /// "Extraordinary" at the top of the slider.
  String _creativityLabel(double c) {
    if (c < 0.15) return "Strict";
    if (c < 0.35) return "Precise";
    if (c < 0.55) return "Balanced";
    if (c < 0.75) return "Playful";
    if (c < 0.92) return "Imaginative";
    return "Extraordinary";
  }

  /// Reset sampler knobs back to the model's default values. Defaults mirror
  /// the Kotlin-side `SamplerParams()` (temperature 0.3, top-K 40, top-P 0.9).
  /// Applies immediately and clears any pending edits so the UI reflects the
  /// defaults right away.
  Future<void> _resetSamplerToDefaults(SettingsProvider settings) async {
    if (_applyingSampler) return;
    setState(() => _applyingSampler = true);
    try {
      await settings.setTemperature(0.3);
      await settings.setTopK(40);
      await settings.setTopP(0.9);
      if (!mounted) return;
      setState(() {
        _pendingCreativity = null;
        _pendingTemp = null;
        _pendingTopK = null;
        _pendingTopP = null;
      });
      _showNotice("Sampler reset to model defaults ✓");
    } catch (e) {
      _showNotice("Error resetting sampler: $e");
    } finally {
      if (mounted) setState(() => _applyingSampler = false);
    }
  }

  Future<void> _applySampler(SettingsProvider settings) async {
    if (_applyingSampler) return;
    setState(() => _applyingSampler = true);
    try {
      // Commit creativity first (it folds into temperature), then any
      // explicit temperature override so the user's advanced edit wins.
      if (_pendingCreativity != null) {
        await settings.setCreativity(_pendingCreativity!);
      }
      if (_pendingTemp != null) {
        await settings.setTemperature(_pendingTemp!);
      }
      if (_pendingTopK != null) {
        await settings.setTopK(_pendingTopK!);
      }
      if (_pendingTopP != null) {
        await settings.setTopP(_pendingTopP!);
      }
      if (!mounted) return;
      setState(() {
        _pendingCreativity = null;
        _pendingTemp = null;
        _pendingTopK = null;
        _pendingTopP = null;
      });
      _showNotice("Sampler updated ✓");
    } catch (e) {
      _showNotice("Error applying sampler: $e");
    } finally {
      if (mounted) setState(() => _applyingSampler = false);
    }
  }

  Widget _advSlider({
    required ThemeData theme,
    required String label,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String display,
    required bool enabled,
    required ValueChanged<double> onChanged,
  }) {
    final cs = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: theme.textTheme.bodySmall),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: cs.primaryContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                display,
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: cs.onPrimaryContainer,
                ),
              ),
            ),
          ],
        ),
        SliderTheme(
          data: SliderThemeData(
            trackHeight: 4,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
          ),
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions > 0 ? divisions : 1,
            onChanged: enabled ? onChanged : null,
          ),
        ),
      ],
    );
  }
}
