import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:local_grammer_llm/services/platform_channel_service.dart';
import 'package:local_grammer_llm/services/preferences_service.dart';
import 'package:local_grammer_llm/providers/settings_provider.dart';
import 'package:local_grammer_llm/ui/widgets/model_download_card.dart';
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

  // Page 1 – AI Provider choice
  String _provider = "gemini"; // "gemini" | "local"
  bool _pickingModel = false;
  bool _downloadingModel = false;
  bool _copying = false;
  double? _copyProgress;
  bool _localModelReady = false;
  final _onboardApiKeyCtrl = TextEditingController();
  String _onboardApiModel = "gemini-2.5-flash";
  bool _onboardApiValidating = false;
  bool? _onboardApiValid;
  String? _onboardApiError;
  bool _onboardApiKeyVisible = false;
  bool _geminiProceedAttempted = false;
  bool _localProceedAttempted = false;
  StreamSubscription<dynamic>? _progressSub;

  // Page 2 – Accessibility
  bool _accessibilityGranted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkAccessibility();
    _progressSub = _channel.progressStream.listen((event) {
      if (event is! Map) return;
      final progress = event["progress"];
      final done = event["done"] == true;
      final newProgress = (progress is num) ? progress.toDouble() : null;
      if (!mounted) return;
      setState(() {
        _copying = !done;
        _copyProgress = newProgress;
      });
    }, onError: (_) {
      if (!mounted) return;
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
      if (!wasGranted && _accessibilityGranted && _currentPage == _accessibilityPageIndex) {
        try {
          await _channel.setServiceEnabled(true);
        } catch (_) {}
        _goNext();
      }
    } catch (_) {}
  }

  int get _totalPages => _provider == "both" ? 6 : 5;
  int get _accessibilityPageIndex => 1;

  void _goNext() {
    if (_currentPage < _totalPages - 1) {
      _pageCtrl.nextPage(
          duration: const Duration(milliseconds: 300), curve: Curves.easeInOut);
      setState(() => _currentPage++);
    }
  }

  void _goPrev() {
    if (_currentPage > 0) {
      _pageCtrl.previousPage(
          duration: const Duration(milliseconds: 300), curve: Curves.easeInOut);
      setState(() => _currentPage--);
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
        _localModelReady = ok;
        _pickingModel = false;
      });
      if (ok) {
        _channel.initFireAndForget();
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _pickingModel = false;
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
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _onboardApiValid = false;
        _onboardApiError = "$e";
        _onboardApiValidating = false;
      });
    }
  }

  Future<void> _localSetupAdvance() async {
    if (_provider == "both") {
      try { await _channel.setApiMode("best"); } catch (_) {}
    }
    if (mounted) _goNext();
  }

  Future<void> _onboardSaveAndAdvance() async {
    if (_provider == "both") {
      // Gemini slide for "both" — validate key then advance to local slide
      final key = _onboardApiKeyCtrl.text.trim();
      if (key.isNotEmpty) {
        await _onboardValidateCloud();
        // Always advance even if validation fails — local model is the fallback
      }
      if (mounted) _goNext();
      return;
    }
    final key = _onboardApiKeyCtrl.text.trim();
    if (key.isEmpty) {
      try {
        await _channel.setApiMode("online");
      } catch (_) {}
      if (mounted) _goNext();
      return;
    }
    await _onboardValidateCloud();
    if (mounted && _onboardApiValid == true) {
      _goNext();
    }
  }

  void _tryGeminiAdvance() {
    if (_onboardApiValid == true) {
      _onboardSaveAndAdvance();
    } else {
      setState(() => _geminiProceedAttempted = true);
    }
  }

  void _tryLocalAdvance() {
    if (_localModelReady) {
      _localSetupAdvance();
    } else {
      setState(() => _localProceedAttempted = true);
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
                  ...List.generate(_totalPages, (i) {
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
                  _buildAccessibility(cs),
                  _buildProviderChoice(cs),
                  if (_provider == "both") ...[_buildGeminiSetup(cs), _buildLocalSetup(cs)] else _buildProviderSetup(cs),
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
                fontSize: 16, color: cs.onSurface.withValues(alpha: 0.7)),
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

  // ── Provider Choice (page 1) ──────────────────────────────────────────────

  Widget _buildProviderChoice(ColorScheme cs) {
    Widget providerRow({
      required bool selected,
      required IconData icon,
      required String title,
      required VoidCallback onTap,
    }) {
      return InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: selected
                ? cs.primary.withValues(alpha: 0.08)
                : cs.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? cs.primary : Colors.transparent,
              width: 2,
            ),
          ),
          child: Row(
            children: [
              Icon(icon,
                  color: selected ? cs.primary : cs.onSurface.withValues(alpha: 0.7)),
              const SizedBox(width: 14),
              Text(title,
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                      color: cs.onSurface)),
              const Spacer(),
              Icon(
                selected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_off,
                color: selected ? cs.primary : cs.outline,
              ),
            ],
          ),
        ),
      );
    }

    final pros = _provider == "gemini"
        ? [
            "Best performance and accuracy",
            "Fast processing",
            "Free tier available for most users",
            "Always up-to-date with latest improvements",
          ]
        : _provider == "local"
        ? [
            "Completely private — nothing leaves your device",
            "Works fully offline",
            "No API key required",
          ]
        : [
            "Best of both — cloud speed with offline fallback",
            "Automatic failover to on-device when offline",
            "Can switch modes anytime in settings",
          ];

    final cons = _provider == "gemini"
        ? [
            "Requires internet connection",
            "API key needed (free to obtain)",
            "Text sent to Google servers for processing",
          ]
        : _provider == "local"
        ? [
            "Requires a .litertlm model file (~1–4 GB)",
            "Slower on older devices compared to cloud",
          ]
        : [
            "Requires both an API key and a model file",
            "Higher initial setup effort",
          ];

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text("Choose Your AI Provider",
              style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: cs.onSurface)),
          const SizedBox(height: 8),
          Text(
            "Select how you want Local Scribe to process your text.",
            style: TextStyle(color: cs.onSurface.withValues(alpha: 0.7)),
          ),
          const SizedBox(height: 20),
          providerRow(
            selected: _provider == "gemini",
            icon: Icons.cloud_outlined,
            title: "Gemini (Cloud AI)",
            onTap: () => setState(() => _provider = "gemini"),
          ),
          const SizedBox(height: 12),
          providerRow(
            selected: _provider == "local",
            icon: Icons.phone_android,
            title: "On-Device AI (Gemma)",
            onTap: () => setState(() => _provider = "local"),
          ),
          const SizedBox(height: 12),
          providerRow(
            selected: _provider == "both",
            icon: Icons.auto_awesome_outlined,
            title: "Both (Cloud + On-Device)",
            onTap: () => setState(() => _provider = "both"),
          ),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ...pros.map((s) => Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text("• ",
                              style:
                                  TextStyle(color: cs.onSurface)),
                          Expanded(
                              child: Text(s,
                                  style: TextStyle(
                                      color: cs.onSurface))),
                        ],
                      ),
                    )),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Icon(Icons.info_outline,
                        size: 16, color: Colors.orange.shade700),
                    const SizedBox(width: 6),
                    Text("Considerations",
                        style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: Colors.orange.shade700)),
                  ],
                ),
                const SizedBox(height: 6),
                ...cons.map((s) => Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text("• ",
                              style:
                                  TextStyle(color: cs.onSurface)),
                          Expanded(
                              child: Text(s,
                                  style: TextStyle(
                                      color: cs.onSurface))),
                        ],
                      ),
                    )),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Icon(Icons.settings_outlined,
                  size: 14,
                  color: cs.onSurface.withValues(alpha: 0.45)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  "You can change this anytime in Settings → AI Settings",
                  style: TextStyle(
                      fontSize: 12,
                      fontStyle: FontStyle.italic,
                      color: cs.onSurface.withValues(alpha: 0.45)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          _buildNavRow(cs,
              onBack: _goPrev,
              onNext: _goNext,
              nextLabel: "Continue"),
        ],
      ),
    );
  }

  // ── Provider Setup dispatcher (page 2) ─────────────────────────────────────

  Widget _buildProviderSetup(ColorScheme cs) {
    if (_provider == "gemini") return _buildGeminiSetup(cs);
    return _buildLocalSetup(cs);
  }

  // ── Gemini Setup ───────────────────────────────────────────────────────────

  Widget _buildGeminiSetup(ColorScheme cs) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.cloud_outlined, size: 36, color: cs.primary),
              const SizedBox(width: 12),
              Text("Set Up Gemini",
                  style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: cs.onSurface)),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            "Enter your Google Gemini API key to enable cloud AI features.",
            style: TextStyle(color: cs.onSurface.withValues(alpha: 0.7)),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _onboardApiKeyCtrl,
            obscureText: !_onboardApiKeyVisible,
            onChanged: (_) => setState(() {
              _onboardApiValid = null;
              _onboardApiError = null;
              _geminiProceedAttempted = false;
            }),
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.key_outlined),
              hintText: "API Key",
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12)),
              errorText: (_geminiProceedAttempted && _onboardApiValid != true)
                  ? (_onboardApiKeyCtrl.text.trim().isEmpty
                      ? "Enter your API key"
                      : "Validate your API key to continue")
                  : null,
              errorBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: cs.error, width: 2)),
              focusedErrorBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: cs.error, width: 2)),
              suffixIcon: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: Icon(_onboardApiKeyVisible
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined),
                    onPressed: () => setState(
                        () => _onboardApiKeyVisible = !_onboardApiKeyVisible),
                    tooltip: "Toggle visibility",
                  ),
                  IconButton(
                    icon: const Icon(Icons.content_paste_outlined),
                    tooltip: "Paste",
                    onPressed: () async {
                      final data = await Clipboard.getData(
                          Clipboard.kTextPlain);
                      final text = data?.text ?? '';
                      if (text.isNotEmpty && mounted) {
                        _onboardApiKeyCtrl.text = text;
                        setState(() {
                          _onboardApiValid = null;
                          _onboardApiError = null;
                        });
                      }
                    },
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _onboardApiModel,
            decoration: InputDecoration(
              labelText: "Model",
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12)),
              contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14, vertical: 12),
            ),
            items: SettingsProvider.apiModels
                .map((m) => DropdownMenuItem(value: m, child: Text(m)))
                .toList(),
            onChanged: (v) {
              if (v != null) {
                setState(() {
                  _onboardApiModel = v;
                  _onboardApiValid = null;
                });
              }
            },
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.lightbulb_outline, color: cs.primary),
                    const SizedBox(width: 8),
                    Text("How to get an API key:",
                        style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: cs.onSurface)),
                  ],
                ),
                const SizedBox(height: 12),
                ...const [
                  "Go to Google AI Studio",
                  "Sign in with your Google account",
                  'Click "Get API Key"',
                  "Create a new API key",
                  "Copy and paste it here",
                ].asMap().entries.map((e) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: 24,
                            height: 24,
                            decoration: BoxDecoration(
                              color:
                                  cs.onSurface.withValues(alpha: 0.15),
                              shape: BoxShape.circle,
                            ),
                            alignment: Alignment.center,
                            child: Text("${e.key + 1}",
                                style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold)),
                          ),
                          const SizedBox(width: 10),
                          Expanded(child: Text(e.value)),
                        ],
                      ),
                    )),
                const Divider(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      final uri = Uri.parse(
                          'https://aistudio.google.com/apikey');
                      if (await canLaunchUrl(uri)) {
                        await launchUrl(uri,
                            mode: LaunchMode.externalApplication);
                      }
                    },
                    icon: const Icon(Icons.open_in_new, size: 18),
                    label: const Text("Open Google AI Studio"),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          if (_onboardApiValidating)
            const Row(children: [
              SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2)),
              SizedBox(width: 10),
              Text("Validating key…"),
            ]),
          if (_onboardApiValid == true)
            Row(children: [
              Icon(Icons.check_circle,
                  color: Colors.green.shade600, size: 20),
              const SizedBox(width: 6),
              const Text("API key validated ✓"),
            ]),
          if (_onboardApiValid == false)
            Row(children: [
              Icon(Icons.error_outline, color: cs.error, size: 20),
              const SizedBox(width: 6),
              Expanded(
                  child: Text(
                      _onboardApiError ?? "Validation failed",
                      style: TextStyle(color: cs.error))),
            ]),
          const SizedBox(height: 16),
          Row(
            children: [
              Icon(Icons.settings_outlined,
                  size: 14,
                  color: cs.onSurface.withValues(alpha: 0.45)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  "You can change all these options anytime in Settings → AI Settings",
                  style: TextStyle(
                      fontSize: 12,
                      fontStyle: FontStyle.italic,
                      color: cs.onSurface.withValues(alpha: 0.45)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          _buildNavRow(cs,
              onBack: _goPrev,
              onNext: (_onboardApiValidating || (_geminiProceedAttempted && _onboardApiValid != true)) ? null : _tryGeminiAdvance,
              nextLabel: "Next"),
        ],
      ),
    );
  }

  // ── On-Device Setup ────────────────────────────────────────────────────────

  Widget _buildLocalSetup(ColorScheme cs) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header ──────────────────────────────────────────────────
          // Text(
          //   "LOCAL GEMMA MODEL",
          //   style: TextStyle(
          //     fontSize: 13,
          //     fontWeight: FontWeight.w700,
          //     letterSpacing: 1.4,
          //     color: cs.primary,
          //   ),
          // ),
          // const SizedBox(height: 6),
          
          Row(
            children: [
              Icon(Icons.phone_android, size: 36, color: cs.primary),
              const SizedBox(width: 12),
              Text(
                "Set Up On-Device AI",
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.bold,
                  color: cs.onSurface,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            "Download or select a local Gemma model file (.litertlm) to process text entirely on your device — no internet needed.",
            style: TextStyle(color: cs.onSurface.withValues(alpha: 0.65), height: 1.4),
          ),

          const SizedBox(height: 28),

          // ── Download section card (shared widget) ─────────────────────
          ModelDownloadCard(
            enabled: !_pickingModel,
            onDownloadingChanged: (v) =>
                setState(() => _downloadingModel = v),
            onDownloadSuccess: (_) =>
                setState(() => _localModelReady = true),
            onDownloadError: (msg) {
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Download failed: $msg')),
              );
            },
          ),

          const SizedBox(height: 16),

          // ── Select from file card ────────────────────────────────────
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              border: Border.all(
                color: (_localProceedAttempted && !_localModelReady)
                    ? cs.error
                    : cs.outline.withValues(alpha: 0.5),
                width: (_localProceedAttempted && !_localModelReady) ? 2 : 1,
              ),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "Already have a model?",
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: cs.onSurface,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  "Pick a .litertlm file you downloaded manually.",
                  style: TextStyle(
                    fontSize: 13,
                    color: cs.onSurface.withValues(alpha: 0.6),
                  ),
                ),
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: (_downloadingModel || _pickingModel)
                        ? null
                        : _pickLocalModel,
                    icon: _pickingModel
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.folder_open_outlined),
                    label: Text(_pickingModel ? "Copying model…" : "Select Model File"),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ),
                if (!_downloadingModel && _copying && _copyProgress != null) ...[
                  const SizedBox(height: 10),
                  LinearProgressIndicator(
                    value: _copyProgress,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ],
                if (_localModelReady) ...[
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Icon(Icons.check_circle_outline,
                          color: Colors.green.shade600, size: 20),
                      const SizedBox(width: 8),
                      const Text("Model loaded successfully"),
                    ],
                  ),
                ],
              ],
            ),
          ),
          if (_localProceedAttempted && !_localModelReady) ...[  
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.error_outline, color: cs.error, size: 16),
                const SizedBox(width: 6),
                Text(
                  "Download or select a model file to continue",
                  style: TextStyle(color: cs.error, fontSize: 13),
                ),
              ],
            ),
          ],

          const SizedBox(height: 12),
          Row(
            children: [
              Icon(Icons.settings_outlined,
                  size: 13,
                  color: cs.onSurface.withValues(alpha: 0.4)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  "You can change the model later in Settings → AI Settings.",
                  style: TextStyle(
                    fontSize: 12,
                    fontStyle: FontStyle.italic,
                    color: cs.onSurface.withValues(alpha: 0.4),
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 24),
          if (_downloadingModel) ...[            
            Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                        strokeWidth: 1.5,
                        color: cs.onSurface.withValues(alpha: 0.4)),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    "Please wait for the download to complete",
                    style: TextStyle(
                      fontSize: 12,
                      color: cs.onSurface.withValues(alpha: 0.5),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
          _buildNavRow(cs,
              onBack: _goPrev,
              onNext: (_downloadingModel || (_localProceedAttempted && !_localModelReady)) ? null : _tryLocalAdvance,
              nextLabel: "Next"),
        ],
      ),
    );
  }

  // ── Shared nav row ─────────────────────────────────────────────────────────

  Widget _buildNavRow(
    ColorScheme cs, {
    required VoidCallback? onBack,
    required VoidCallback? onNext,
    required String nextLabel,
  }) {
    return Row(
      children: [
        Expanded(
          child: OutlinedButton(
            onPressed: onBack,
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24)),
            ),
            child: const Text("Back",
                style: TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w600)),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          flex: 2,
          child: FilledButton(
            onPressed: onNext,
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24)),
              textStyle: const TextStyle(
                  fontSize: 16, fontWeight: FontWeight.w600),
            ),
            child: Text(nextLabel),
          ),
        ),
      ],
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
                color: cs.onSurface.withValues(alpha: 0.7),
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
          Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              color: cs.primary.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.check_circle_outline, size: 56, color: cs.primary),
          ),
          const SizedBox(height: 28),
          Text(
            "You're All Set!",
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 30,
              fontWeight: FontWeight.bold,
              color: cs.onSurface,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            "Local Scribe is ready to go.\nStart writing in any app and let AI do the heavy lifting.",
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 16,
              color: cs.onSurface.withValues(alpha: 0.65),
              height: 1.5,
            ),
          ),
          const SizedBox(height: 32),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              children: [
                _allSetTip(cs, Icons.auto_fix_high, "Type ?fix in any text field to correct grammar instantly."),
                const SizedBox(height: 12),
                _allSetTip(cs, Icons.text_fields, "Highlight text in any app and tap Local Scribe from the menu."),
                const SizedBox(height: 12),
                _allSetTip(cs, Icons.settings_outlined, "Customise commands and AI settings anytime."),
              ],
            ),
          ),
          const SizedBox(height: 36),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _finishOnboarding,
              icon: const Icon(Icons.rocket_launch_outlined),
              label: const Text("Finish Setup"),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
                textStyle: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _allSetTip(ColorScheme cs, IconData icon, String text) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: cs.primary),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 14,
              color: cs.onSurface.withValues(alpha: 0.75),
              height: 1.4,
            ),
          ),
        ),
      ],
    );
  }
}
