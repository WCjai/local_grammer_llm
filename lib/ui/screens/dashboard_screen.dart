import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:local_grammer_llm/providers/model_provider.dart';
import 'package:local_grammer_llm/providers/service_provider.dart';
import 'package:local_grammer_llm/providers/settings_provider.dart';
import 'package:local_grammer_llm/providers/commands_provider.dart';
import 'package:local_grammer_llm/providers/theme_provider.dart';
import 'package:local_grammer_llm/ui/screens/ai_settings_screen.dart';
import 'package:local_grammer_llm/ui/screens/chat_screen.dart';
import 'package:local_grammer_llm/ui/screens/manage_prompts_screen.dart';
import 'package:local_grammer_llm/ui/screens/demo_screen.dart';
import 'package:local_grammer_llm/ui/widgets/no_glow_scroll.dart';
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
    final type = message.contains('âœ“') || message.contains('ready')
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
                        .withValues(alpha: 0.6),
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
        leading: IconButton(
          icon: const Icon(Icons.settings),
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const AiSettingsScreen()),
          ),
          tooltip: "AI settings",
        ),
      ),
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
      color: (service.serviceEnabled ? green : red).withValues(alpha: 0.20),
      child: SwitchTheme(
        data: SwitchThemeData(
          thumbColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? const Color(0xFF34A853)
                : const Color(0xFFEA4335),
          ),
          trackColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? const Color(0xFF34A853).withValues(alpha: 0.35)
                : const Color(0xFFEA4335).withValues(alpha: 0.35),
          ),
        ),
        child: SwitchListTile(
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          controlAffinity: ListTileControlAffinity.trailing,
          title: Text(
            service.serviceGranted
                ? (service.serviceEnabled ? "Service Active" : "Enable Service")
                : "Service Disabled",
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              service.serviceGranted
                  ? (service.serviceEnabled
                      ? "Scribe is ready to help"
                      : "Tap to activate Scribe assistant")
                  : "Android Accessibility permission required",
              style: TextStyle(
                fontSize: 14,
                color: Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: 0.7),
              ),
            ),
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
    // Larger hit targets that fill the empty horizontal space: the top row
    // of primary buttons is 88 dp tall with big icons + labels, and the
    // tertiary "How to use?" button matches at 64 dp so it reads as a
    // proper dashboard tile instead of a skinny pill.
    const double primaryHeight = 88;
    const double secondaryHeight = 64;

    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: SizedBox(
                height: primaryHeight,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: blue,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 12),
                    textStyle: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16)),
                  ),
                  onPressed: busy
                      ? null
                      : () async {
                          await Navigator.of(context).push(
                            MaterialPageRoute(
                                builder: (_) => const ChatScreen()),
                          );
                          commands.load();
                        },
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.auto_awesome, size: 28),
                      const SizedBox(height: 6),
                      const FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text("Prompt Generator"),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: SizedBox(
                height: primaryHeight,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: green,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 12),
                    textStyle: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16)),
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
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: const [
                      Icon(Icons.tune, size: 28),
                      SizedBox(height: 6),
                      FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text("Manage Prompts")),
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
          height: secondaryHeight,
          child: ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: service.serviceEnabled
                  ? yellow
                  : Theme.of(context).colorScheme.outline,
              foregroundColor: service.serviceEnabled
                  ? Colors.black
                  : Theme.of(context).colorScheme.onSurface,
              textStyle:
                  const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
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
            icon: const Icon(Icons.play_circle_outline, size: 24),
            label: const Text("How to use?"),
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
              "Behavior",
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              title: const Text("Show preview"),
              subtitle: Text(
                "Review output before applying changes",
                style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6)),
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
                style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6)),
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
                "Loading AI Provider...",
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
                      .withValues(alpha: 0.6),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

}
