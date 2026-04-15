import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:local_grammer_llm/providers/model_provider.dart';
import 'package:local_grammer_llm/providers/service_provider.dart';
import 'package:local_grammer_llm/providers/settings_provider.dart';
import 'package:local_grammer_llm/providers/commands_provider.dart';
import 'package:local_grammer_llm/providers/theme_provider.dart';
import 'package:local_grammer_llm/ui/screens/chat_screen.dart';
import 'package:local_grammer_llm/ui/screens/manage_prompts_screen.dart';
import 'package:local_grammer_llm/ui/screens/demo_screen.dart';
import 'package:local_grammer_llm/ui/widgets/no_glow_scroll.dart';
import 'package:local_grammer_llm/ui/widgets/beta_tag.dart';
import 'package:local_grammer_llm/ui/widgets/command_item.dart';
import 'package:local_grammer_llm/ui/widgets/command_row.dart';
import 'package:local_grammer_llm/ui/widgets/app_snackbar.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<ServiceProvider>().refresh();
      context.read<ModelProvider>().refreshModelStatus();
      context.read<SettingsProvider>().refreshAll();
      context.read<CommandsProvider>().load();
      context.read<ModelProvider>().initModel().then((msg) {
        if (msg != null && mounted) _showNotice(msg);
      });
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      context.read<ServiceProvider>().refresh();
      context.read<CommandsProvider>().load();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _showNotice(String message) {
    if (!mounted) return;
    final type = message.contains('✓') || message.contains('ready')
        ? SnackType.success
        : message.toLowerCase().contains('error') ||
                message.toLowerCase().contains('failed') ||
                message.toLowerCase().contains('enable')
            ? SnackType.error
            : SnackType.info;
    showAppSnackBar(context, message, type: type);
  }

  @override
  Widget build(BuildContext context) {
    final model = context.watch<ModelProvider>();
    final service = context.watch<ServiceProvider>();
    final settings = context.watch<SettingsProvider>();
    final commands = context.watch<CommandsProvider>();
    final themeProvider = context.watch<ThemeProvider>();
    final busy = model.busy;

    const googleBlue = Color(0xFF1A73E8);
    const googleGreen = Color(0xFF34A853);
    const googleYellow = Color(0xFFF9AB00);
    const googleRed = Color(0xFFEA4335);

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            RichText(
              text: TextSpan(
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.2,
                    ),
                children: [
                  TextSpan(
                    text: "Local",
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurface),
                  ),
                  TextSpan(
                    text: "Scribe",
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.primary),
                  ),
                ],
              ),
            ),
            Text(
              "made for jAi ONLY",
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withOpacity(0.6),
                    letterSpacing: 0.4,
                  ),
            ),
          ],
        ),
        centerTitle: true,
        actions: [
          IconButton(
            icon: Icon(
              themeProvider.isDark
                  ? Icons.light_mode_rounded
                  : Icons.dark_mode_rounded,
            ),
            onPressed: themeProvider.toggle,
            tooltip: themeProvider.isDark ? 'Light mode' : 'Dark mode',
          ),
        ],
        leading: Builder(
          builder: (ctx) => IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => Scaffold.of(ctx).openDrawer(),
            tooltip: "AI settings",
          ),
        ),
      ),
      drawer: _buildDrawer(settings, model, busy),
      body: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: ScrollConfiguration(
              behavior: const NoGlowScrollBehavior(),
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    _buildServiceCard(service, busy, googleGreen, googleRed),
                    const SizedBox(height: 12),
                    _buildActionButtons(
                        busy, service, googleBlue, googleGreen, googleYellow, commands),
                    const SizedBox(height: 12),
                    _buildSettingsCard(settings, busy),
                    const SizedBox(height: 12),
                    _buildCommandsCard(commands),
                  ],
                ),
              ),
            ),
          ),
          if (model.initInProgress) _buildLoadingOverlay(),
        ],
      ),
    );
  }

  Widget _buildServiceCard(
      ServiceProvider service, bool busy, Color green, Color red) {
    return Card(
      color: (service.serviceEnabled ? green : red).withOpacity(0.20),
      child: SwitchTheme(
        data: SwitchThemeData(
          thumbColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? const Color(0xFF34A853)
                : const Color(0xFFEA4335),
          ),
          trackColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? const Color(0xFF34A853).withOpacity(0.35)
                : const Color(0xFFEA4335).withOpacity(0.35),
          ),
        ),
        child: SwitchListTile(
          title: Text(
            service.serviceGranted
                ? (service.serviceEnabled ? "Service Active" : "Enable Service")
                : "Service Disabled",
          ),
          subtitle: Text(
            service.serviceGranted
                ? (service.serviceEnabled
                    ? "Scribe is ready to help"
                    : "Tap to activate Scribe assistant")
                : "Android Accessibility permission required",
            style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6)),
          ),
          value: service.serviceEnabled,
          onChanged: busy
              ? null
              : (v) async {
                  final msg = await service.toggle(v);
                  if (msg != null) _showNotice(msg);
                },
        ),
      ),
    );
  }

  Widget _buildActionButtons(bool busy, ServiceProvider service, Color blue,
      Color green, Color yellow, CommandsProvider commands) {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: blue,
                  foregroundColor: Colors.white,
                ),
                onPressed: busy
                    ? null
                    : () async {
                        await Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => const ChatScreen()),
                        );
                        commands.load();
                      },
                child: const FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.auto_awesome),
                      SizedBox(width: 8),
                      Text("Prompt Generator"),
                      SizedBox(width: 8),
                      BetaTag(),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: green,
                  foregroundColor: Colors.white,
                ),
                onPressed: busy
                    ? null
                    : () async {
                        await Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) => const ManagePromptsScreen()),
                        );
                        commands.load();
                      },
                child: const FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.tune),
                      SizedBox(width: 8),
                      Text("Manage Prompts"),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor:
                  service.serviceEnabled ? yellow : Theme.of(context).colorScheme.outline,
              foregroundColor:
                  service.serviceEnabled ? Colors.black : Theme.of(context).colorScheme.onSurface,
            ),
            onPressed: busy
                ? null
                : () {
                    if (!service.serviceEnabled) {
                      _showNotice("Enable the service first.");
                      return;
                    }
                    Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const DemoScreen()),
                    );
                  },
            child: const Text("How to use?"),
          ),
        ),
      ],
    );
  }

  Widget _buildSettingsCard(SettingsProvider settings, bool busy) {
    return Card(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "Settings",
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              title: const Text("Show preview"),
              subtitle: Text(
                "Review output before applying changes",
                style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6)),
              ),
              value: settings.showPreview,
              onChanged: busy
                  ? null
                  : (v) => settings.togglePreview(v).catchError((e) {
                        _showNotice("Preview toggle error: $e");
                      }),
            ),
            SwitchListTile(
              title: const Text("Show add context window"),
              subtitle: Text(
                "Optionally add scenario before processing",
                style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6)),
              ),
              value: settings.showContext,
              onChanged: busy
                  ? null
                  : (v) => settings.toggleContext(v).catchError((e) {
                        _showNotice("Context toggle error: $e");
                      }),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCommandsCard(CommandsProvider commands) {
    return SizedBox(
      width: double.infinity,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                "Available commands",
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              commands.loading
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: const [
                          SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          SizedBox(height: 8),
                          Text("Loading commands..."),
                        ],
                      ),
                    )
                  : Column(
                      children: List.generate(
                        (commands.availableCommands.length / 2).ceil(),
                        (i) {
                          final left = commands.availableCommands[i * 2];
                          final rightIndex = i * 2 + 1;
                          final right =
                              rightIndex < commands.availableCommands.length
                                  ? commands.availableCommands[rightIndex]
                                  : null;
                          return commandRow(
                            CommandItem(
                              command: left.command,
                              desc: left.desc,
                              maxDescLines: 2,
                            ),
                            right == null
                                ? const SizedBox.shrink()
                                : CommandItem(
                                    command: right.command,
                                    desc: right.desc,
                                    maxDescLines: 2,
                                  ),
                          );
                        },
                      ),
                    ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLoadingOverlay() {
    return Positioned.fill(
      child: Container(
        color: Theme.of(context).colorScheme.surface,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 64,
                height: 64,
                child: CircularProgressIndicator(
                  strokeWidth: 4,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
              const SizedBox(height: 24),
              Text(
                "Loading AI Model…",
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                "This may take a moment on first launch",
                style: TextStyle(
                  fontSize: 14,
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withOpacity(0.6),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Drawer _buildDrawer(SettingsProvider settings, ModelProvider model,
      bool busy) {
    final theme = Theme.of(context);
    final isLocal = settings.apiMode != "online";
    final isOnline = settings.apiMode != "local";

    return Drawer(
      child: SafeArea(
        child: ScrollConfiguration(
          behavior: const NoGlowScrollBehavior(),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 24),
            children: [
              // ── Header ──
              Row(
                children: [
                  Icon(Icons.tune, color: theme.colorScheme.primary),
                  const SizedBox(width: 10),
                  Text(
                    "AI Settings",
                    style: theme.textTheme.titleLarge
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ],
              ),
              const SizedBox(height: 20),

              // ── Engine Mode (segmented button) ──
              Text("Engine", style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                fontWeight: FontWeight.w600,
              )),
              const SizedBox(height: 8),
              LayoutBuilder(
                builder: (context, constraints) {
                  final compact = constraints.maxWidth < 320;
                  return SegmentedButton<String>(
                    segments: [
                      ButtonSegment(
                        value: "local",
                        label: const Text("Local", softWrap: false),
                        icon: compact ? null : const Icon(Icons.smartphone),
                      ),
                      ButtonSegment(
                        value: "best",
                        label: const Text("Auto", softWrap: false),
                        icon: compact ? null : const Icon(Icons.auto_awesome),
                      ),
                      ButtonSegment(
                        value: "online",
                        label: const Text("Cloud", softWrap: false),
                        icon: compact ? null : const Icon(Icons.cloud),
                      ),
                    ],
                    selected: {settings.apiMode},
                    onSelectionChanged: busy
                        ? null
                        : (v) => settings.setApiMode(v.first).catchError((e) {
                              _showNotice("Mode error: $e");
                            }),
                    showSelectedIcon: false,
                    style: ButtonStyle(
                      visualDensity: compact
                          ? VisualDensity.compact
                          : VisualDensity.standard,
                    ),
                  );
                },
              ),
              const SizedBox(height: 20),

              // ── Cloud Mode ──
              _drawerSection(
                theme: theme,
                icon: Icons.cloud,
                title: "Cloud API",
                enabled: isOnline,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    DropdownButtonFormField<String>(
                      value: settings.apiModel,
                      decoration: const InputDecoration(
                        labelText: "Model",
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                      items: SettingsProvider.apiModels
                          .map((m) =>
                              DropdownMenuItem(value: m, child: Text(m)))
                          .toList(),
                      onChanged: (busy || !isOnline)
                          ? null
                          : (v) => settings
                              .setApiModel(v ?? settings.apiModel)
                              .catchError((e) {
                              _showNotice("Model error: $e");
                            }),
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
                          onPressed: () => settings.toggleApiKeyVisible(),
                          icon: Icon(
                            settings.apiKeyVisible
                                ? Icons.visibility_off
                                : Icons.visibility,
                            size: 20,
                          ),
                          tooltip: settings.apiKeyVisible
                              ? "Hide key"
                              : "Show key",
                        ),
                      ),
                      onChanged: (_) => settings.clearValidation(),
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: settings.apiValid == true
                              ? Colors.green
                              : (settings.apiValid == false
                                  ? Colors.red
                                  : theme.colorScheme.primary),
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
                                child:
                                    CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                              )
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
                    if (settings.apiError != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        settings.apiError!,
                        style: theme.textTheme.labelSmall
                            ?.copyWith(color: Colors.red),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 12),

              // ── Local Mode ──
              _drawerSection(
                theme: theme,
                icon: Icons.smartphone,
                title: "Local Model",
                enabled: isLocal,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            model.modelName.isEmpty
                                ? "No model loaded"
                                : model.modelName,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w500,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilledButton.tonalIcon(
                          onPressed: (busy || !isLocal)
                              ? null
                              : () async {
                                  final msg = await model.pickModel();
                                  if (msg != null) _showNotice(msg);
                                },
                          icon: Icon(
                            model.hasModel ? Icons.swap_horiz : Icons.download,
                            size: 18,
                          ),
                          label: Text(model.hasModel ? "Change" : "Pick"),
                        ),
                      ],
                    ),
                    if (model.hasModel)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Row(
                          children: [
                            Icon(Icons.check_circle, size: 14, color: Colors.green.shade600),
                            const SizedBox(width: 4),
                            Text("Ready", style: theme.textTheme.labelSmall?.copyWith(
                              color: Colors.green.shade600,
                            )),
                          ],
                        ),
                      ),
                    if (model.copying) ...[
                      const SizedBox(height: 12),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: (model.copyProgress == null ||
                                  model.copyProgress!.isNaN)
                              ? null
                              : model.copyProgress,
                          minHeight: 6,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        model.copyProgress == null
                            ? "Copying model…"
                            : "Copying… ${(model.copyProgress! * 100).toStringAsFixed(0)}%",
                        style: theme.textTheme.labelSmall,
                      ),
                    ],
                    const Divider(height: 24),
                    Text("Token Limits", style: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    )),
                    const SizedBox(height: 2),
                    Text(
                      "Controls how much text the on-device model processes",
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                      ),
                    ),
                    const SizedBox(height: 8),
                    _tokenSlider(
                      label: "Max Tokens",
                      value: settings.maxTokens,
                      min: 256,
                      max: 2048,
                      divisions: 14,
                      enabled: !busy && isLocal,
                      onChanged: (v) => settings.setMaxTokens(v),
                      theme: theme,
                    ),
                    const SizedBox(height: 4),
                    _tokenSlider(
                      label: "Output Tokens",
                      value: settings.outputTokens,
                      min: 64,
                      max: (settings.maxTokens - 64).clamp(64, 512).toDouble(),
                      divisions: ((settings.maxTokens - 64).clamp(64, 512) - 64) ~/ 32,
                      enabled: !busy && isLocal,
                      onChanged: (v) => settings.setOutputTokens(v),
                      theme: theme,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Drawer helpers ──

  Widget _drawerSection({
    required ThemeData theme,
    required IconData icon,
    required String title,
    required bool enabled,
    required Widget child,
  }) {
    return AnimatedOpacity(
      opacity: enabled ? 1.0 : 0.45,
      duration: const Duration(milliseconds: 200),
      child: IgnorePointer(
        ignoring: !enabled,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: theme.dividerColor.withValues(alpha: 0.4),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, size: 18, color: theme.colorScheme.primary),
                  const SizedBox(width: 8),
                  Text(title, style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  )),
                ],
              ),
              const SizedBox(height: 12),
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
                color: theme.colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                "$value",
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.onPrimaryContainer,
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
