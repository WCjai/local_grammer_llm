import 'dart:async';
import 'package:flutter/material.dart';
import 'package:local_grammer_llm/services/platform_channel_service.dart';
import 'package:local_grammer_llm/services/preferences_service.dart';
import 'package:local_grammer_llm/providers/settings_provider.dart';
import 'package:local_grammer_llm/ui/widgets/engine_card.dart';
import 'package:local_grammer_llm/app.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen>
    with WidgetsBindingObserver {
  final _channel = LlmChannelService();
  final _prefs = PreferencesService();

  final _pageCtrl = PageController();
  int _currentPage = 0;

  // Page 1 – Engine
  String _engineMode = "local"; // "local" | "cloud"
  bool _engineReady = false;
  bool _pickingModel = false;
  bool _copying = false;
  double? _copyProgress;
  final _onboardApiKeyCtrl = TextEditingController();
  String _onboardApiModel = "gemini-2.5-flash";
  bool _onboardApiValidating = false;
  bool? _onboardApiValid;
  String? _onboardApiError;
  bool _onboardApiKeyVisible = false;
  StreamSubscription<dynamic>? _progressSub;

  // Page 2 – Accessibility
  bool _accessibilityGranted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkAccessibility();
    _progressSub = _channel.progressStream.listen((event) {
      if (event is Map) {
        final progress = event["progress"];
        final done = event["done"] == true;
        setState(() {
          _copying = !done;
          _copyProgress = (progress is num) ? progress.toDouble() : null;
        });
      }
    }, onError: (_) {
      setState(() {
        _copying = false;
        _copyProgress = null;
      });
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkAccessibility();
    }
  }

  Future<void> _checkAccessibility() async {
    try {
      final granted = await _channel.isAccessibilityGranted();
      if (!mounted) return;
      final wasGranted = _accessibilityGranted;
      setState(() => _accessibilityGranted = granted);
      if (!wasGranted && _accessibilityGranted && _currentPage == 2) {
        try {
          await _channel.setServiceEnabled(true);
        } catch (_) {}
        _goNext();
      }
    } catch (_) {}
  }

  void _goNext() {
    if (_currentPage < 3) {
      _pageCtrl.nextPage(
          duration: const Duration(milliseconds: 300), curve: Curves.easeInOut);
      setState(() => _currentPage++);
    }
  }

  Future<void> _finishOnboarding() async {
    await _prefs.setOnboardingCompleted(true);
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const App(showOnboarding: false)),
      (_) => false,
    );
  }

  void _skip() => _finishOnboarding();

  Future<void> _pickLocalModel() async {
    setState(() {
      _pickingModel = true;
      _copying = true;
      _copyProgress = null;
    });
    try {
      await _channel.setApiMode("local");
      final path = await _channel.pickModel();
      final ok = path != null && path.trim().isNotEmpty;
      if (!mounted) return;
      setState(() {
        _engineReady = ok;
        _pickingModel = false;
      });
      if (ok) {
        _channel.initFireAndForget();
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _pickingModel = false;
        _engineReady = false;
      });
    } finally {
      if (mounted) setState(() => _copying = false);
    }
  }

  Future<void> _onboardValidateCloud() async {
    final key = _onboardApiKeyCtrl.text.trim();
    if (key.isEmpty) return;
    setState(() {
      _onboardApiValidating = true;
      _onboardApiValid = null;
      _onboardApiError = null;
    });
    try {
      await _channel.setApiMode("online");
      await _channel.setApiKey(key);
      await _channel.setApiModel(_onboardApiModel);
      final ok = await _channel.validateApiKey(
        model: _onboardApiModel,
        key: key,
      );
      if (!mounted) return;
      setState(() {
        _onboardApiValid = ok;
        _onboardApiValidating = false;
        _engineReady = ok;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _onboardApiValid = false;
        _onboardApiError = "$e";
        _onboardApiValidating = false;
        _engineReady = false;
      });
    }
  }

  @override
  void dispose() {
    _progressSub?.cancel();
    _pageCtrl.dispose();
    _onboardApiKeyCtrl.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  ...List.generate(4, (i) {
                    return Container(
                      width: i == _currentPage ? 24 : 8,
                      height: 8,
                      margin: const EdgeInsets.only(right: 6),
                      decoration: BoxDecoration(
                        color: i <= _currentPage
                            ? cs.primary
                            : cs.outlineVariant,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    );
                  }),
                  const Spacer(),
                  TextButton(onPressed: _skip, child: const Text("Skip")),
                ],
              ),
            ),
            Expanded(
              child: PageView(
                controller: _pageCtrl,
                physics: const NeverScrollableScrollPhysics(),
                onPageChanged: (i) => setState(() => _currentPage = i),
                children: [
                  _buildWelcome(cs),
                  _buildEngine(cs),
                  _buildAccessibility(cs),
                  _buildProcessText(cs),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWelcome(ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.auto_fix_high, size: 72, color: cs.primary),
          const SizedBox(height: 24),
          Text(
            "Welcome to Local Scribe",
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.bold,
              color: cs.onSurface,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            "Your private, on-device AI writing assistant.\nFix grammar, rewrite text, and more — right from any app.",
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 16, color: cs.onSurface.withOpacity(0.7)),
          ),
          const SizedBox(height: 40),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _goNext,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
                textStyle: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w600),
              ),
              child: const Text("Let's Get Started"),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEngine(ColorScheme cs) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "Choose Your Engine",
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(
            "Local runs entirely on-device (private). Cloud uses the Gemini API (faster, needs internet).",
            style: TextStyle(color: cs.onSurface.withOpacity(0.7)),
          ),
          const SizedBox(height: 20),
          EngineCard(
            selected: _engineMode == "local",
            icon: Icons.phone_android,
            title: "Local (MediaPipe)",
            subtitle: "Private, offline, runs on your device",
            onTap: () => setState(() {
              _engineMode = "local";
              _engineReady = false;
            }),
          ),
          const SizedBox(height: 12),
          EngineCard(
            selected: _engineMode == "cloud",
            icon: Icons.cloud_outlined,
            title: "Cloud (Gemini API)",
            subtitle: "Faster, requires API key",
            onTap: () => setState(() {
              _engineMode = "cloud";
              _engineReady = false;
            }),
          ),
          const SizedBox(height: 20),
          if (_engineMode == "local") ...[
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _pickingModel ? null : _pickLocalModel,
                icon: _pickingModel
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.folder_open),
                label: Text(
                    _pickingModel ? "Copying model…" : "Select .tflite Model"),
              ),
            ),
            if (_copying && _copyProgress != null) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(value: _copyProgress),
            ],
            if (_engineReady)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  children: [
                    Icon(Icons.check_circle,
                        color: Colors.green.shade600, size: 20),
                    const SizedBox(width: 6),
                    const Text("Model loaded successfully"),
                  ],
                ),
              ),
          ],
          if (_engineMode == "cloud") ...[
            DropdownButtonFormField<String>(
              value: _onboardApiModel,
              decoration: const InputDecoration(labelText: "Model"),
              items: SettingsProvider.apiModels
                  .map((m) => DropdownMenuItem(value: m, child: Text(m)))
                  .toList(),
              onChanged: (v) {
                if (v != null) {
                  setState(() {
                    _onboardApiModel = v;
                    _onboardApiValid = null;
                    _engineReady = false;
                  });
                }
              },
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _onboardApiKeyCtrl,
              obscureText: !_onboardApiKeyVisible,
              decoration: InputDecoration(
                labelText: "Gemini API Key",
                suffixIcon: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: Icon(_onboardApiKeyVisible
                          ? Icons.visibility_off
                          : Icons.visibility),
                      onPressed: () => setState(
                          () => _onboardApiKeyVisible = !_onboardApiKeyVisible),
                    ),
                    IconButton(
                      icon: _onboardApiValidating
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.check),
                      onPressed:
                          _onboardApiValidating ? null : _onboardValidateCloud,
                    ),
                  ],
                ),
              ),
            ),
            if (_onboardApiValid == true)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  children: [
                    Icon(Icons.check_circle,
                        color: Colors.green.shade600, size: 20),
                    const SizedBox(width: 6),
                    const Text("API key validated"),
                  ],
                ),
              ),
            if (_onboardApiValid == false)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _onboardApiError ?? "Validation failed",
                  style: TextStyle(color: cs.error),
                ),
              ),
          ],
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _engineReady ? _goNext : null,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
                textStyle: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w600),
              ),
              child: const Text("Continue"),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAccessibility(ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            _accessibilityGranted
                ? Icons.check_circle
                : Icons.accessibility_new,
            size: 64,
            color:
                _accessibilityGranted ? Colors.green.shade600 : cs.primary,
          ),
          const SizedBox(height: 24),
          const Text(
            "Accessibility Permission",
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          Text(
            "Local Scribe needs the Accessibility Service to read and replace text in other apps.\n\n"
            "• We only read the focused text field.\n"
            "• Processing happens on-device (or via your chosen API).\n"
            "• No data is stored or sent elsewhere.",
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 14,
                color: cs.onSurface.withOpacity(0.7),
                height: 1.5),
          ),
          const SizedBox(height: 28),
          if (!_accessibilityGranted)
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () async {
                  try {
                    await _channel.openAccessibilitySettings();
                  } catch (_) {}
                },
                icon: const Icon(Icons.settings),
                label: const Text("Open Accessibility Settings"),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  textStyle: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w600),
                ),
              ),
            )
          else
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _goNext,
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  textStyle: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w600),
                ),
                child: const Text("Continue"),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildProcessText(ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.select_all, size: 64, color: cs.primary),
          const SizedBox(height: 24),
          const Text(
            "Highlight → Transform",
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          Text(
            "Besides the ?fix commands, you can also highlight text in any app and choose Local Scribe from the context menu to transform it.\n\n"
            "1. Select any text in any app.\n"
            "2. Tap the ⋯ menu or \"Local Scribe\".\n"
            "3. Choose a command from the popup sheet.",
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 14,
                color: cs.onSurface.withOpacity(0.7),
                height: 1.5),
          ),
          const SizedBox(height: 28),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _finishOnboarding,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
                textStyle: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w600),
              ),
              child: const Text("Finish Setup"),
            ),
          ),
        ],
      ),
    );
  }
}
