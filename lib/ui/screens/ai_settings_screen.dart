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
              _localModelCard(theme, cs, model, settings, busy, isLocal),
              const SizedBox(height: 16),

              // ── Token limits (only when local is active) ─────────────
              // AnimatedOpacity(
              //   opacity: isLocal ? 1.0 : 0.4,
              //   duration: const Duration(milliseconds: 200),
              //   child: IgnorePointer(
              //     ignoring: !isLocal,
              //     child: _settingsCard(
              //       theme: theme,
              //       icon: Icons.tune,
              //       title: "Token Limits",
              //       enabled: isLocal,
              //       child: Column(
              //         children: [
              //           _tokenSlider(
              //             label: "Max Tokens",
              //             value: settings.maxTokens,
              //             min: 256,
              //             max: 2048,
              //             divisions: 14,
              //             enabled: !busy && isLocal,
              //             onChanged: (v) => settings.setMaxTokens(v),
              //             theme: theme,
              //           ),
              //           const SizedBox(height: 4),
              //           _tokenSlider(
              //             label: "Output Tokens",
              //             value: settings.outputTokens,
              //             min: 64,
              //             max: (settings.maxTokens - 64).clamp(64, 512).toDouble(),
              //             divisions: ((settings.maxTokens - 64).clamp(64, 512) - 64) ~/ 32,
              //             enabled: !busy && isLocal,
              //             onChanged: (v) => settings.setOutputTokens(v),
              //             theme: theme,
              //           ),
              //         ],
              //       ),
              //     ),
              //   ),
              // ),
              // const SizedBox(height: 16),

              // ── Other local options ─────────────────────────────────
              AnimatedOpacity(
                opacity: isLocal ? 1.0 : 0.4,
                duration: const Duration(milliseconds: 200),
                child: IgnorePointer(
                  ignoring: !isLocal,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: theme.dividerColor.withValues(alpha: 0.4)),
                    ),
                    child: SwitchListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: const Text("Image input support"),
                      subtitle: Text(
                        "Enable only if your local model accepts image input.",
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: cs.onSurface.withValues(alpha: 0.5),
                        ),
                      ),
                      value: settings.modelSupportsVision,
                      onChanged: (busy || !isLocal)
                          ? null
                          : (v) => settings.setModelSupportsVision(v).catchError((e) {
                                _showNotice("Error: $e");
                              }),
                    ),
                  ),
                ),
              ),
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
                      onTap: busy
                          ? null
                          : () => settings
                              .setProcessingMode("cpu")
                              .catchError((e) { _showNotice("$e"); }),
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
                      onTap: busy
                          ? null
                          : () => settings
                              .setProcessingMode("gpu")
                              .catchError((e) { _showNotice("$e"); }),
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
    return GestureDetector(
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
}
