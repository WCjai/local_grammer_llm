import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() => runApp(const App());

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.light(
      primary: const Color(0xFF6C4AD5),
      onPrimary: Colors.white,
      secondary: const Color(0xFF8E7EE6),
      onSecondary: Colors.white,
      tertiary: const Color(0xFFC4B7FF),
      onTertiary: const Color(0xFF2A2155),
      surface: const Color(0xFFF7F5FF),
      onSurface: const Color(0xFF1A1633),
      surfaceContainerHighest: const Color(0xFFEEE9FF),
      outline: const Color(0xFFB8B0D9),
      outlineVariant: const Color(0xFFD8D2F0),
    );
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: scheme,
        scaffoldBackgroundColor: scheme.surface,
        appBarTheme: AppBarTheme(
          centerTitle: false,
          elevation: 0,
          backgroundColor: scheme.surface,
          foregroundColor: scheme.onSurface,
          surfaceTintColor: scheme.surfaceTint,
          titleTextStyle: TextStyle(
            color: scheme.onSurface,
            fontSize: 20,
            fontWeight: FontWeight.w600,
          ),
        ),
        cardTheme: CardThemeData(
          elevation: 0,
          surfaceTintColor: scheme.surfaceTint,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: scheme.outlineVariant),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: scheme.surfaceContainerHighest,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: scheme.outlineVariant),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: scheme.primary, width: 1.4),
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            elevation: 0,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
        switchTheme: SwitchThemeData(
          thumbColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? scheme.primary
                : scheme.outline,
          ),
          trackColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? scheme.primary.withOpacity(0.3)
                : scheme.surfaceContainerHighest,
          ),
        ),
        listTileTheme: ListTileThemeData(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        ),
        snackBarTheme: SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        dividerTheme: DividerThemeData(
          color: scheme.outlineVariant,
          thickness: 1,
          space: 1,
        ),
      ),
      home: const LlmDemoPage(),
    );
  }
}

class NoGlowScrollBehavior extends ScrollBehavior {
  const NoGlowScrollBehavior();

  @override
  Widget buildOverscrollIndicator(BuildContext context, Widget child, ScrollableDetails details) {
    return child;
  }
}

class LlmDemoPage extends StatefulWidget {
  const LlmDemoPage({super.key});

  @override
  State<LlmDemoPage> createState() => _LlmDemoPageState();
}

class _LlmDemoPageState extends State<LlmDemoPage> with WidgetsBindingObserver {
  static const _channel = MethodChannel('local_llm');
  static const _progressChannel = EventChannel('local_llm_progress');
  static const _apiModels = [
    "gemini-2.5-flash-lite",
    "gemini-2.5-flash",
    "gemini-2.5-pro",
    "gemma-3n-e2b-it",
    "gemma-3n-e4b-it",
  ];

  bool _busy = false;
  bool _ready = false;
  bool _copying = false;
  double? _copyProgress;
  bool _hasModel = false;
  String _modelName = "";
  bool _serviceEnabled = false;
  bool _serviceGranted = false;
  bool _initInProgress = false;
  bool _initFlash = false;
  bool _showPreview = false;
  bool _showContext = false;
  String _apiMode = "local";
  String _apiModel = "gemini-2.5-flash";
  bool _apiValidating = false;
  bool? _apiValid;
  String? _apiError;
  bool _apiKeyVisible = false;
  final _apiKeyCtrl = TextEditingController();

  List<_CommandInfo> _availableCommands = [];
  bool _commandsLoading = false;
  int _commandsGenId = 0;

  StreamSubscription<dynamic>? _progressSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshAccessibilityStatus();
    _refreshModelStatus();
    _refreshPreviewSetting();
    _refreshContextSetting();
    _refreshApiSettings();
    _loadAvailableCommands();
    Future.microtask(() => _initModel());
    _progressSub = _progressChannel.receiveBroadcastStream().listen((event) {
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
      _refreshAccessibilityStatus();
      _loadAvailableCommands();
    }
  }

  Future<void> _refreshModelStatus() async {
    try {
      final hasModel = await _channel.invokeMethod<bool>("hasModel");
      final name = await _channel.invokeMethod<String>("getModelName");
      if (!mounted) return;
      setState(() {
        _hasModel = hasModel == true;
        _modelName = name ?? "";
      });
    } on PlatformException {
      if (!mounted) return;
      setState(() {
        _hasModel = false;
        _modelName = "";
      });
    }
  }

  void _showNotice(String message) {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _refreshAccessibilityStatus() async {
    try {
      final granted = await _channel.invokeMethod<bool>("isAccessibilityGranted");
      final enabled = await _channel.invokeMethod<bool>("getServiceEnabled");
      if (!mounted) return;
      setState(() {
        _serviceGranted = granted == true;
        _serviceEnabled = (granted == true) && (enabled == true);
      });
    } on PlatformException {
      if (!mounted) return;
      setState(() {
        _serviceGranted = false;
        _serviceEnabled = false;
      });
    }
  }

  Future<void> _refreshPreviewSetting() async {
    try {
      final enabled = await _channel.invokeMethod<bool>("getShowPreview");
      if (!mounted) return;
      setState(() {
        _showPreview = enabled == true;
      });
    } on PlatformException {
      if (!mounted) return;
      setState(() {
        _showPreview = false;
      });
    }
  }

  Future<void> _refreshContextSetting() async {
    try {
      final enabled = await _channel.invokeMethod<bool>("getShowContext");
      if (!mounted) return;
      setState(() {
        _showContext = enabled == true;
      });
    } on PlatformException {
      if (!mounted) return;
      setState(() {
        _showContext = false;
      });
    }
  }

  Future<void> _refreshApiSettings() async {
    try {
      final mode = await _channel.invokeMethod<String>("getApiMode");
      final model = await _channel.invokeMethod<String>("getApiModel");
      final key = await _channel.invokeMethod<String>("getApiKey");
      if (!mounted) return;
      setState(() {
        _apiMode = (mode == null || mode.isEmpty) ? "local" : mode;
        _apiModel = (model == null || model.isEmpty) ? "gemini-2.5-flash" : model;
        _apiKeyCtrl.text = key ?? "";
        _apiValid = null;
        _apiError = null;
      });
      if (mounted) {
        Future.microtask(_maybeValidateApiKey);
      }
    } on PlatformException {
      if (!mounted) return;
      setState(() {
        _apiMode = "local";
        _apiModel = "gemini-2.5-flash";
        _apiValid = null;
        _apiError = null;
      });
    }
  }

  Future<void> _loadAvailableCommands() async {
    if (_commandsLoading) return;
    final myGenId = ++_commandsGenId;
    setState(() => _commandsLoading = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      final cacheRaw = prefs.getString("command_desc_cache") ?? "{}";
      Map<String, dynamic> cache;
      try {
        cache = (jsonDecode(cacheRaw) as Map<String, dynamic>?) ?? {};
      } catch (_) {
        cache = {};
      }

      final raw = await _channel.invokeMethod<List<dynamic>>("getPrompts") ?? [];
      if (!mounted || myGenId != _commandsGenId) return;
      final list = raw
          .whereType<Map>()
          .map((e) => e.map((k, v) => MapEntry(k.toString(), v)))
          .map((e) => e.cast<String, dynamic>())
          .toList();

      final builtInDesc = <String, String>{
        "fix": "Grammar/spelling/punctuation",
        "rewrite": "Rewrite with optional style",
        "scribe": "Direct answer only",
        "summ": "Short summary",
        "polite": "Polite/professional rewrite",
        "casual": "Casual/friendly rewrite",
        "expand": "Add more detail",
        "translate": "Translate to English",
        "bullet": "Bullet points",
        "improve": "Improve clarity",
        "rephrase": "Rephrase fully",
        "formal": "Formal/professional rewrite",
      };

      final entries = <_PromptEntry>[];
      for (final item in list) {
        final keyword = (item["keyword"] ?? "").toString().trim().toLowerCase();
        final prompt = (item["prompt"] ?? "").toString();
        final builtIn = item["builtIn"] == true;
        if (keyword.isEmpty) continue;
        entries.add(_PromptEntry(keyword: keyword, prompt: prompt, builtIn: builtIn));
      }
      final custom = entries.where((e) => !e.builtIn).toList().reversed;
      final orderedEntries = [
        ...custom,
        ...entries.where((e) => e.builtIn),
      ];

      final pending = <_PromptSpec>[];
      final descMap = <String, String>{};
      for (final e in orderedEntries) {
        if (e.builtIn) {
          descMap[e.keyword] = builtInDesc[e.keyword] ?? "Built-in prompt";
          continue;
        }
        final promptHash = e.prompt.hashCode.toString();
        final cached = cache[e.keyword];
        if (cached is Map && cached["hash"] == promptHash && cached["desc"] is String) {
          descMap[e.keyword] = cached["desc"] as String;
        } else {
          pending.add(_PromptSpec(keyword: e.keyword, prompt: e.prompt, hash: promptHash));
        }
      }

      if (pending.isNotEmpty) {
        final batch = await _generateBatchShortDesc(pending, myGenId);
        if (!mounted || myGenId != _commandsGenId) return;
        for (final item in pending) {
          if (!mounted || myGenId != _commandsGenId) return;
          final desc = batch[item.keyword] ?? await _generateShortDesc(item.prompt, myGenId);
          cache[item.keyword] = {"hash": item.hash, "desc": desc};
          descMap[item.keyword] = desc;
        }
      }

      final commands = <_CommandInfo>[];
      for (final e in orderedEntries) {
        final desc = descMap[e.keyword];
        if (desc != null) {
          commands.add(_CommandInfo(command: "?${e.keyword}", desc: desc));
        }
      }

      if (!mounted || myGenId != _commandsGenId) return;
      await prefs.setString("command_desc_cache", jsonEncode(cache));
      if (!mounted) return;
      setState(() => _availableCommands = commands);
    } on PlatformException {
      if (!mounted) return;
      setState(() => _availableCommands = []);
    } finally {
      if (mounted) setState(() => _commandsLoading = false);
    }
  }

  Future<String> _generateShortDesc(String prompt, int genId) async {
    if (!mounted || genId != _commandsGenId) return "Custom prompt";
    if (prompt.trim().isEmpty) return "Custom prompt";
    try {
      final text = await _channel.invokeMethod<String>("generate", {
        "prompt":
            "Summarize this instruction in 3-6 words. No punctuation, no quotes. Instruction: $prompt",
      });
      if (!mounted || genId != _commandsGenId) return "Custom prompt";
      final cleaned = (text ?? "").trim();
      if (cleaned.isEmpty) return "Custom prompt";
      return cleaned.split("\n").first.trim();
    } catch (_) {
      return "Custom prompt";
    }
  }

  Future<Map<String, String>> _generateBatchShortDesc(
      List<_PromptSpec> items, int genId) async {
    if (!mounted || genId != _commandsGenId) return {};
    try {
      final payload = items
          .map((e) => {"keyword": e.keyword, "prompt": e.prompt})
          .toList(growable: false);
      final prompt = """
You are summarizing custom prompts for a UI list.
Return ONLY valid JSON in this exact schema:
{"items":[{"keyword":"...","desc":"..."}]}
Rules:
- desc must be 3-6 words, no punctuation
- preserve keyword exactly as given
- no extra text or markdown
Input:
${jsonEncode({"items": payload})}
""";
      final text = await _channel.invokeMethod<String>("generate", {"prompt": prompt});
      if (!mounted || genId != _commandsGenId) return {};
      final cleaned = _cleanJsonLite(text ?? "");
      final decoded = jsonDecode(cleaned);
      final list = decoded is Map ? decoded["items"] : null;
      if (list is! List) return {};
      final out = <String, String>{};
      for (final e in list) {
        if (e is! Map) continue;
        final key = (e["keyword"] ?? "").toString().trim().toLowerCase();
        final desc = (e["desc"] ?? "").toString().trim();
        if (key.isEmpty || desc.isEmpty) continue;
        out[key] = desc.split("\n").first.trim();
      }
      return out;
    } catch (_) {
      return {};
    }
  }

  String _cleanJsonLite(String raw) {
    var text = raw.trim();
    // Strip common wrappers
    if (text.startsWith("'''") && text.endsWith("'''")) {
      text = text.substring(3, text.length - 3).trim();
    }
    if (text.startsWith("\"\"\"") && text.endsWith("\"\"\"")) {
      text = text.substring(3, text.length - 3).trim();
    }
    if (text.startsWith("```")) {
      text = text.replaceAll(RegExp(r"^```[a-zA-Z]*\s*"), "");
      text = text.replaceAll(RegExp(r"```$"), "");
    }
    text = text.replaceAll(
      RegExp(r"^json\s*", caseSensitive: false, multiLine: true),
      "",
    );
    final start = text.indexOf("{");
    final end = text.lastIndexOf("}");
    if (start != -1 && end != -1 && end > start) {
      text = text.substring(start, end + 1);
    }
    return text.trim();
  }

  Future<void> _setApiMode(String value) async {
    try {
      await _channel.invokeMethod<bool>("setApiMode", {"mode": value});
      if (!mounted) return;
      setState(() {
        _apiMode = value;
        _apiValid = null;
        _apiError = null;
      });
      _maybeValidateApiKey();
    } on PlatformException catch (e) {
      _showNotice("API mode error: ${e.code}: ${e.message}");
    }
  }

  Future<void> _setApiModel(String value) async {
    try {
      await _channel.invokeMethod<bool>("setApiModel", {"model": value});
      if (!mounted) return;
      setState(() {
        _apiModel = value;
        _apiValid = null;
        _apiError = null;
      });
    } on PlatformException catch (e) {
      _showNotice("API model error: ${e.code}: ${e.message}");
    }
  }

  Future<void> _validateApiKey() async {
    setState(() {
      _apiValidating = true;
      _apiValid = null;
      _apiError = null;
    });
    try {
      final key = _apiKeyCtrl.text.trim();
      await _channel.invokeMethod<bool>("setApiKey", {"key": key});
      final ok = await _channel.invokeMethod<bool>("validateApiKey", {
        "model": _apiModel,
        "key": key,
      });
      if (!mounted) return;
      setState(() {
        _apiValid = ok == true;
        _apiValidating = false;
      });
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() {
        _apiValid = false;
        _apiError = "${e.code}: ${e.message}";
        _apiValidating = false;
      });
    }
  }

  Future<void> _maybeValidateApiKey() async {
    if (_apiValidating) return;
    if (!mounted) return;
    if (_apiMode == "local") return;
    final key = _apiKeyCtrl.text.trim();
    if (key.isEmpty) return;
    await _validateApiKey();
  }

  Future<void> _togglePreview(bool value) async {
    try {
      await _channel.invokeMethod<bool>("setShowPreview", {"enabled": value});
      if (!mounted) return;
      setState(() => _showPreview = value);
    } on PlatformException catch (e) {
      _showNotice("Preview toggle error: ${e.code}: ${e.message}");
    }
  }

  Future<void> _toggleContext(bool value) async {
    try {
      await _channel.invokeMethod<bool>("setShowContext", {"enabled": value});
      if (!mounted) return;
      setState(() => _showContext = value);
    } on PlatformException catch (e) {
      _showNotice("Context toggle error: ${e.code}: ${e.message}");
    }
  }

  Future<void> _toggleService(bool value) async {
    if (value) {
      if (!_serviceGranted) {
        try {
          await _channel.invokeMethod<bool>("openAccessibilitySettings");
          _showNotice("Enable the accessibility service, then return.");
          setState(() => _serviceEnabled = false);
        } on PlatformException catch (e) {
          _showNotice("Open settings error: ${e.code}: ${e.message}");
        }
        return;
      }
    }
    try {
      await _channel.invokeMethod<bool>("setServiceEnabled", {"enabled": value});
      setState(() => _serviceEnabled = value);
      if (!value) {
        _showNotice("Grammar correction disabled.");
      }
    } on PlatformException catch (e) {
      _showNotice("Service toggle error: ${e.code}: ${e.message}");
    }
  }

  Future<void> _initModel() async {
    if (_initInProgress) return;
    setState(() {
      _busy = true;
      _initInProgress = true;
      _initFlash = false;
    });
    try {
      final ok = await _channel.invokeMethod<bool>("init");
      setState(() {
        _ready = (ok == true);
      });
      _showNotice(_ready ? "Model ready ✓" : "Init returned false");
      if (ok == true && mounted) {
        setState(() => _initFlash = true);
        await Future.delayed(const Duration(milliseconds: 700));
        if (mounted) {
          setState(() => _initFlash = false);
        }
      }
    } on PlatformException catch (e) {
      _showNotice("Init error: ${e.code}: ${e.message}");
    } finally {
      setState(() {
        _busy = false;
        _initInProgress = false;
      });
    }
  }


  Future<void> _pickModel() async {
    setState(() {
      _busy = true;
      _copying = true;
      _copyProgress = null;
    });
    try {
      final path = await _channel.invokeMethod<String>("pickModel");
      final hasPath = path != null && path.trim().isNotEmpty;
      setState(() {
        _ready = false;
        _hasModel = hasPath;
      });
      _showNotice(
        (path == null || path.trim().isEmpty)
            ? "No model selected."
            : "Model copied. Initializing...",
      );
      if (hasPath && !_initInProgress) {
        await _initModel();
      }
    } on PlatformException catch (e) {
      _showNotice("Pick model error: ${e.code}: ${e.message}");
    } finally {
      setState(() => _busy = false);
      _refreshModelStatus();
    }
  }

  @override
  void dispose() {
    _commandsGenId++;
    _progressSub?.cancel();
    _apiKeyCtrl.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const googleBlue = Color(0xFF1A73E8);
    const googleGreen = Color(0xFF34A853);
    const googleYellow = Color(0xFFF9AB00);
    const googleRed = Color(0xFFEA4335);

    Widget settingsSection({
      required String title,
      required Widget child,
      bool bordered = true,
      EdgeInsetsGeometry? padding,
      EdgeInsetsGeometry? margin,
    }) {
      final theme = Theme.of(context);
      return Container(
        margin: margin ?? const EdgeInsets.only(bottom: 12),
        padding: padding ?? const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: bordered ? Border.all(color: theme.dividerColor) : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            child,
          ],
        ),
      );
    }

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
                    style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
                  ),
                  TextSpan(
                    text: "Scribe",
                    style: TextStyle(color: Theme.of(context).colorScheme.primary),
                  ),
                ],
              ),
            ),
            Text(
              "made for jAi ONLY",
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
                    letterSpacing: 0.4,
                  ),
            ),
          ],
        ),
        centerTitle: true,
        actions: [
          if (_initInProgress)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
        ],
        leading: Builder(
          builder: (context) => IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => Scaffold.of(context).openDrawer(),
            tooltip: "AI settings",
          ),
        ),
      ),
      drawer: Drawer(
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Text(
                "AI Settings",
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
              settingsSection(
                title: "Mode",
                bordered: true,
                child: DropdownButtonFormField<String>(
                  value: _apiMode,
                  decoration: const InputDecoration(
                    filled: false,
                    fillColor: Colors.transparent,
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    DropdownMenuItem(value: "local", child: Text("Local only")),
                    DropdownMenuItem(value: "online", child: Text("Online only")),
                    DropdownMenuItem(value: "best", child: Text("Use the Best")),
                  ],
                  onChanged: _busy ? null : (v) => _setApiMode(v ?? "local"),
                ),
              ),
              settingsSection(
                title: "Local Mode",
                child: IgnorePointer(
                  ignoring: _apiMode == "online",
                  child: Opacity(
                    opacity: _apiMode == "online" ? 0.5 : 1.0,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: _hasModel
                                  ? Theme.of(context).colorScheme.primary
                                  : Theme.of(context).colorScheme.secondary,
                              foregroundColor: Colors.white,
                            ),
                            onPressed: _busy ? null : _pickModel,
                            child: const Text("Pick Model"),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _modelName.isEmpty ? "No model selected" : "Model: $_modelName",
                        ),
                        if (_copying) ...[
                          const SizedBox(height: 12),
                          LinearProgressIndicator(
                            value: (_copyProgress == null || _copyProgress!.isNaN)
                                ? null
                                : _copyProgress,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            _copyProgress == null
                                ? "Copying model..."
                                : "Copying model... ${(_copyProgress! * 100).toStringAsFixed(0)}%",
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
              settingsSection(
                title: "Online Mode",
                child: IgnorePointer(
                  ignoring: _apiMode == "local",
                  child: Opacity(
                    opacity: _apiMode == "local" ? 0.5 : 1.0,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        DropdownButtonFormField<String>(
                          value: _apiModel,
                          decoration: const InputDecoration(
                            labelText: "Model",
                            filled: false,
                            fillColor: Colors.transparent,
                            border: OutlineInputBorder(),
                          ),
                          items: _apiModels
                              .map((m) => DropdownMenuItem(value: m, child: Text(m)))
                              .toList(),
                          onChanged: _busy ? null : (v) => _setApiModel(v ?? _apiModel),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _apiKeyCtrl,
                          obscureText: !_apiKeyVisible,
                          decoration: InputDecoration(
                            labelText: "API Key",
                            filled: false,
                            fillColor: Colors.transparent,
                            border: OutlineInputBorder(),
                            suffixIcon: IconButton(
                              onPressed: () {
                                setState(() => _apiKeyVisible = !_apiKeyVisible);
                              },
                              icon: Icon(
                                _apiKeyVisible ? Icons.visibility_off : Icons.visibility,
                              ),
                              tooltip: _apiKeyVisible ? "Hide API key" : "Show API key",
                            ),
                          ),
                          onChanged: (_) {
                            if (_apiValid != null || _apiError != null) {
                              setState(() {
                                _apiValid = null;
                                _apiError = null;
                              });
                            }
                          },
                        ),
                        const SizedBox(height: 8),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom( 
                              backgroundColor: _apiValid == true
                                  ? Colors.green
                                  : (_apiValid == false ? Colors.red : const Color.fromARGB(255, 75, 92, 188)),
                              foregroundColor: Colors.white,
                            ),
                            onPressed: _apiValidating ? null : _validateApiKey,
                            child: _apiValidating
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(strokeWidth: 2),
                                  )
                                : const Text("Validate API"),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Card(
              color: (_serviceEnabled ? googleGreen : googleRed).withOpacity(0.20),
              child: SwitchTheme(
                data: SwitchThemeData(
                  thumbColor: WidgetStateProperty.resolveWith(
                    (states) => states.contains(WidgetState.selected)
                        ? const Color(0xFF34A853) // Google green
                        : const Color(0xFFEA4335), // Google red
                  ),
                  trackColor: WidgetStateProperty.resolveWith(
                    (states) => states.contains(WidgetState.selected)
                        ? const Color(0xFF34A853).withOpacity(0.35)
                        : const Color(0xFFEA4335).withOpacity(0.35),
                  ),
                ),
                child: SwitchListTile(
                  //title: const Text("Accessibility service"),
                  title: Text(
                    _serviceGranted
                        ? (_serviceEnabled ? "Service Active" : "Enable Service")
                        : "Service Disabled",
                  ),
                  subtitle: Text(
                    _serviceGranted
                        ? (_serviceEnabled ? "Scribe is ready to help" : "Tap to activate Scribe assistant")
                        : "Android Accessibility permission required",
                    style: TextStyle(color: Colors.grey.shade700),
                  ),
                  value: _serviceEnabled,
                  onChanged: _busy ? null : _toggleService,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: googleBlue,
                      foregroundColor: Colors.white,
                    ),
                    onPressed: _busy
                        ? null
                        : () async {
                            await Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => const ChatPage(),
                              ),
                            );
                            _loadAvailableCommands();
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
                          _BetaTag(),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: googleGreen,
                      foregroundColor: Colors.white,
                    ),
                    onPressed: _busy
                        ? null
                        : () async {
                            await Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => const ManagePromptsPage(),
                              ),
                            );
                            _loadAvailableCommands();
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
                  backgroundColor: _serviceEnabled ? googleYellow : Colors.grey.shade400,
                  foregroundColor: _serviceEnabled ? Colors.black : Colors.white,
                ),
                onPressed: _busy
                    ? null
                    : () {
                        if (!_serviceEnabled) {
                          _showNotice("Enable the service first.");
                          return;
                        }
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const DemoPage(),
                          ),
                        );
                      },
                child: const Text("How to use?"),
              ),
            ),
            const SizedBox(height: 12),
            Card(
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
                        style: TextStyle(color: Colors.grey.shade700),
                      ),
                      value: _showPreview,
                      onChanged: _busy ? null : _togglePreview,
                    ),
                    SwitchListTile(
                      title: const Text("Show add context window"),
                      subtitle: Text(
                        "Optionally add scenario before processing",
                        style: TextStyle(color: Colors.grey.shade700),
                      ),
                      value: _showContext,
                      onChanged: _busy ? null : _toggleContext,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: SizedBox(
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
                        Expanded(
                          child: ScrollConfiguration(
                            behavior: const NoGlowScrollBehavior(),
                            child: _commandsLoading
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
                                : SingleChildScrollView(
                                    child: Column(
                                      children: List.generate(
                                        (_availableCommands.length / 2).ceil(),
                                        (i) {
                                          final left = _availableCommands[i * 2];
                                          final rightIndex = i * 2 + 1;
                                          final right = rightIndex < _availableCommands.length
                                              ? _availableCommands[rightIndex]
                                              : null;
                                          return _commandRow(
                                            _CommandItem(
                                              command: left.command,
                                              desc: left.desc,
                                              maxDescLines: 2,
                                            ),
                                            right == null
                                                ? const SizedBox.shrink()
                                                : _CommandItem(
                                                    command: right.command,
                                                    desc: right.desc,
                                                    maxDescLines: 2,
                                                  ),
                                          );
                                        },
                                      ),
                                    ),
                                  ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

enum _ChatRole { user, assistant }
class _ChatMessage {
  const _ChatMessage({
    required this.role,
    this.text = "",
    this.suggestions,
  });

  final _ChatRole role;
  final String text;
  final List<_PromptSuggestion>? suggestions;
}
class _PromptSuggestion {
  _PromptSuggestion({
    required this.keyword,
    required this.prompt,
    this.label,
  });

  final String keyword;
  final String prompt;
  final String? label;

  bool added = false;
  String? error;
}

class _SuggestionsList extends StatelessWidget {
  const _SuggestionsList({
    required this.suggestions,
    required this.onAdd,
  });

  final List<_PromptSuggestion> suggestions;
  final Future<void> Function(_PromptSuggestion) onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          "Suggestions",
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        ...suggestions.map((s) {
          final title = s.label?.trim().isNotEmpty == true ? s.label!.trim() : "?${s.keyword}";
          return Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: theme.colorScheme.outlineVariant),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "?${s.keyword}",
                  style: TextStyle(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 6),
                Text(s.prompt),
                const SizedBox(height: 10),
                Row(
                  children: [
                    ElevatedButton(
                      onPressed: s.added ? null : () => onAdd(s),
                      child: Text(s.added ? "Added" : "Add"),
                    ),
                    if (s.error != null) ...[
                      const SizedBox(width: 10),
                      Text(
                        s.error!,
                        style: const TextStyle(color: Colors.red),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          );
        }),
      ],
    );
  }
}


class _CommandItem extends StatelessWidget {
  const _CommandItem({
    required this.command,
    required this.desc,
    this.maxDescLines,
  });

  final String command;
  final String desc;
  final int? maxDescLines;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            command,
            style: TextStyle(color: color, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 2),
          Text(
            desc,
            maxLines: maxDescLines,
            overflow: maxDescLines == null ? TextOverflow.visible : TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

class _CommandInfo {
  const _CommandInfo({required this.command, required this.desc});

  final String command;
  final String desc;
}

class _PromptSpec {
  const _PromptSpec({
    required this.keyword,
    required this.prompt,
    required this.hash,
  });

  final String keyword;
  final String prompt;
  final String hash;
}

class _PromptEntry {
  const _PromptEntry({
    required this.keyword,
    required this.prompt,
    required this.builtIn,
  });

  final String keyword;
  final String prompt;
  final bool builtIn;
}

class _BetaTag extends StatelessWidget {
  const _BetaTag();

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onPrimary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFFEA4335),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        "BETA",
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

Widget _commandRow(Widget left, Widget right) {
  return Padding(
    padding: EdgeInsets.zero,
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 72),
            child: left,
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 72),
            child: right,
          ),
        ),
      ],
    ),
  );
}

class _ChatPageState extends State<ChatPage> {
  static const _channel = MethodChannel('local_llm');

  // Keep cached messages if you want persistence across navigation.
  static final List<_ChatMessage> _cachedMessages = [];
  static String _cachedDraft = "";

  final _promptCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();

  bool _busy = false;
  int _generationId = 0;

  final List<_ChatMessage> _messages = [];

  void _showNotice(String message) {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  static const Set<String> _reservedKeywords = {
    "fix",
    "rewrite",
    "scribe",
    "summ",
    "polite",
    "casual",
    "expand",
    "translate",
    "bullet",
    "improve",
    "rephrase",
    "formal",
  };

  // ---------------------------
  // PATCH 1: safer user text
  // ---------------------------
  String _sanitizeUserRequest(String s) {
    var out = s.replaceAll("\r", " ").replaceAll("\n", " ").trim();
    // Prevent user input from accidentally looking like our tags
    out = out.replaceAll("<", "").replaceAll(">", "");
    return out;
  }

  // ---------------------------
  // PATCH 2: Prompt (Option A + C combined)
  // ---------------------------
  String _buildPrompt(String userInput) {
    final req = _sanitizeUserRequest(userInput);
    final reserved = _reservedKeywords.join(", ");
    return """
You generate custom commands (keywords) and prompts for a local writing assistant app.
Return ONLY valid JSON. No markdown, no code fences, no extra text.

Reserved keywords (must NOT use): $reserved

Generate 3 to 5 suggestions. Each suggestion MUST follow:
- keyword: 3-20 chars, lowercase, only letters/numbers/underscore (regex: ^[a-z0-9_]{3,20}\$), unique, not reserved
- label: 2-5 words, UI friendly, no punctuation
- prompt: clear and detailed instruction string that includes {text}, does NOT mention JSON/tags/system/AI, ends with "Return only the result." without "\n"

User request: $req

Output JSON only, format:
{"prompts":[{"keyword":"string","label":"string","prompt":"string"}]}
""";
  }

  // ---------------------------
  // JSON cleaning helpers
  // ---------------------------
  String _cleanJson(String raw) {
    var text = raw.trim();
    // Strip common wrappers
    if (text.startsWith("'''") && text.endsWith("'''")) {
      text = text.substring(3, text.length - 3).trim();
    }
    if (text.startsWith("\"\"\"") && text.endsWith("\"\"\"")) {
      text = text.substring(3, text.length - 3).trim();
    }

    // Remove markdown fences if model ignored rules
    if (text.startsWith("```")) {
      text = text.replaceAll(RegExp(r"^```[a-zA-Z]*\s*"), "");
      text = text.replaceAll(RegExp(r"```$"), "");
    }

    // Trim leading junk before first "{"
    final first = text.indexOf("{");
    if (first != -1) text = text.substring(first);

    // Keep only the main JSON object
    text = _extractJsonObject(text);

    return text.trim();
  }

  String _extractJsonObject(String text) {
    // Prefer starting where schema begins
    final start = text.indexOf('{"prompts"');
    if (start != -1) text = text.substring(start);

    var depth = 0;
    var inString = false;

    for (var i = 0; i < text.length; i++) {
      final ch = text[i];

      if (ch == '"' && (i == 0 || text[i - 1] != '\\')) {
        inString = !inString;
      }
      if (inString) continue;

      if (ch == "{") depth++;
      if (ch == "}") {
        depth--;
        if (depth == 0) {
          return text.substring(0, i + 1);
        }
      }
    }
    return text; // fallback
  }

  String _repairJson(String text) {
    // Basic bracket balance repair
    var openCurly = 0, closeCurly = 0, openSquare = 0, closeSquare = 0;
    var inString = false;

    for (var i = 0; i < text.length; i++) {
      final ch = text[i];
      if (ch == '"' && (i == 0 || text[i - 1] != '\\')) {
        inString = !inString;
      }
      if (inString) continue;

      if (ch == "{") openCurly++;
      if (ch == "}") closeCurly++;
      if (ch == "[") openSquare++;
      if (ch == "]") closeSquare++;
    }

    final buf = StringBuffer(text);
    for (var i = 0; i < (openSquare - closeSquare); i++) buf.write(']');
    for (var i = 0; i < (openCurly - closeCurly); i++) buf.write('}');
    return buf.toString();
  }

  // ---------------------------
  // Parse suggestions
  // ---------------------------
  List<_PromptSuggestion> _parseSuggestions(String raw) {
    final cleaned = _cleanJson(raw);

    // Fast fallback extraction (if JSON decode fails)
    final extracted = _extractSuggestionPairs(cleaned);
    if (extracted.isNotEmpty) return extracted;

    try {
      final decoded = jsonDecode(cleaned);
      final list = decoded is Map ? decoded["prompts"] : null;
      if (list is! List) return [];

      return list
          .whereType<Map>()
          .map((e) => _normalizeSuggestion(e["keyword"], e["prompt"], e["label"]))
          .whereType<_PromptSuggestion>()
          .toList();
    } catch (_) {
      try {
        final repaired = _repairJson(cleaned);
        final decoded = jsonDecode(repaired);
        final list = decoded is Map ? decoded["prompts"] : null;
        if (list is! List) return [];

        return list
            .whereType<Map>()
            .map((e) => _normalizeSuggestion(e["keyword"], e["prompt"], e["label"]))
            .whereType<_PromptSuggestion>()
            .toList();
      } catch (_) {
        return [];
      }
    }
  }

  _PromptSuggestion? _normalizeSuggestion(dynamic key, dynamic promptValue, dynamic labelValue) {
    var keyword = (key ?? "").toString().trim().toLowerCase();
    final prompt = (promptValue ?? "").toString().trim();
    final label = (labelValue ?? "").toString().trim();

    if (keyword.isEmpty || prompt.isEmpty) return null;
    if (_reservedKeywords.contains(keyword)) return null;

    // sanitize keyword
    keyword = keyword.replaceAll(RegExp(r"[^a-z0-9_]"), "_");
    keyword = keyword.replaceAll(RegExp(r"_+"), "_");
    keyword = keyword.replaceAll(RegExp(r"^_+|_+$"), "");
    if (keyword.length > 20) keyword = keyword.substring(0, 20);

    if (!RegExp(r"^[a-z0-9_]{3,20}$").hasMatch(keyword)) return null;

    // IMPORTANT: enforce {text} placeholder
    if (!prompt.contains("{text}")) return null;

    // label optional (but if provided, keep it short-ish)
    final safeLabel = label.isEmpty ? null : label;

    return _PromptSuggestion(keyword: keyword, prompt: prompt, label: safeLabel);
  }

  List<_PromptSuggestion> _extractSuggestionPairs(String raw) {
    // If JSON is broken, try regex extraction
    final regex = RegExp(
      r'"keyword"\s*:\s*"([^"]+)"\s*,\s*"label"\s*:\s*"([^"]*)"\s*,\s*"prompt"\s*:\s*"([^"]+)"',
    );
    final matches = regex.allMatches(raw).toList();
    if (matches.isEmpty) return [];

    return matches
        .map((m) => _normalizeSuggestion(m.group(1), m.group(3), m.group(2)))
        .whereType<_PromptSuggestion>()
        .toList();
  }

  // ---------------------------
  // Add suggestion -> native side
  // ---------------------------
  Future<void> _addSuggestion(_PromptSuggestion suggestion) async {
    try {
      await _channel.invokeMethod<bool>("addPrompt", {
        "keyword": suggestion.keyword,
        "prompt": suggestion.prompt,
      });
      setState(() => suggestion.added = true);
    } on PlatformException {
      setState(() => suggestion.error = "Failed to add");
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollCtrl.hasClients) return;
      _scrollCtrl.animateTo(
        _scrollCtrl.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  // ---------------------------
  // Generate flow
  // ---------------------------
  Future<void> _generate() async {
    final input = _promptCtrl.text.trim();
    if (input.isEmpty) {
      _showNotice("Enter some text first.");
      return;
    }

    final myGenId = ++_generationId;
    _promptCtrl.clear();

    setState(() {
      _busy = true;
      _messages.add(_ChatMessage(role: _ChatRole.user, text: input));
      _messages.add(const _ChatMessage(role: _ChatRole.assistant, text: "Generating..."));
    });
    _scrollToBottom();

    try {
      final text = await _channel.invokeMethod<String>("generate", {
        "prompt": _buildPrompt(input),
      });

      if (!mounted || myGenId != _generationId) return;

      final parsed = _parseSuggestions(text ?? "");
      setState(() {
        _messages.removeLast();
        if (parsed.isNotEmpty) {
          _messages.add(_ChatMessage(role: _ChatRole.assistant, suggestions: parsed));
        } else {
          _messages.add(
            _ChatMessage(
              role: _ChatRole.assistant,
              text: "Could not parse suggestions.\n\nRaw:\n${text ?? ""}",
            ),
          );
        }
      });
    } on PlatformException catch (e) {
      if (!mounted || myGenId != _generationId) return;
      setState(() {
        _messages.removeLast();
        _messages.add(
          _ChatMessage(
            role: _ChatRole.assistant,
            text: "Generate error: ${e.code}: ${e.message}",
          ),
        );
      });
    } finally {
      if (!mounted || myGenId != _generationId) return;
      setState(() => _busy = false);
      _scrollToBottom();
    }
  }

  @override
  void initState() {
    super.initState();
    if (_cachedMessages.isNotEmpty) {
      _messages.addAll(_cachedMessages);
    }
    if (_cachedDraft.isNotEmpty) {
      _promptCtrl.text = _cachedDraft;
    }
  }

  @override
  void dispose() {
    _generationId++;
    _cachedMessages
      ..clear()
      ..addAll(_messages);
    _cachedDraft = _promptCtrl.text;

    _promptCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  // ---------------------------
  // UI
  // ---------------------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Prompt Generator")),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView.builder(
                controller: _scrollCtrl,
                padding: const EdgeInsets.all(12),
                itemCount: _messages.length,
                itemBuilder: (context, index) {
                  final msg = _messages[index];
                  final isUser = msg.role == _ChatRole.user;

                  final bubbleColor = isUser
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.surfaceContainerHighest;
                  final textColor = isUser
                      ? Theme.of(context).colorScheme.onPrimary
                      : Theme.of(context).colorScheme.onSurface;

                  return Align(
                    alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
                    child: GestureDetector(
                      onLongPress: msg.text.isEmpty
                          ? null
                          : () async {
                              await Clipboard.setData(ClipboardData(text: msg.text));
                            },
                      child: Container(
                        constraints: const BoxConstraints(maxWidth: 340),
                        margin: const EdgeInsets.symmetric(vertical: 6),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        decoration: BoxDecoration(
                          color: bubbleColor,
                          borderRadius: BorderRadius.circular(14),
                          border: isUser
                              ? null
                              : Border.all(color: Theme.of(context).colorScheme.outlineVariant),
                        ),
                        child: msg.suggestions != null
                            ? _SuggestionsList(
                                suggestions: msg.suggestions!,
                                onAdd: _addSuggestion,
                              )
                            : Text(
                                msg.text,
                                style: TextStyle(color: textColor),
                              ),
                      ),
                    ),
                  );
                },
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _promptCtrl,
                      minLines: 1,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        hintText: "Describe the kind of prompts you want",
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  ElevatedButton(
                    onPressed: _busy ? null : _generate,
                    child: _busy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text("Generate"),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ManagePromptsPage extends StatefulWidget {
  const ManagePromptsPage({super.key});

  @override
  State<ManagePromptsPage> createState() => _ManagePromptsPageState();
}

class DemoPage extends StatefulWidget {
  const DemoPage({super.key});

  @override
  State<DemoPage> createState() => _DemoPageState();
}

class _DemoPageState extends State<DemoPage> {
  final _demoCtrl = TextEditingController();
  String _detected = "";
  static const _demoCommands = [
    "?fix",
    "?rewrite",
    "?summ",
    "?polite",
    "?casual",
  ];

  void _updateDetected(String text) {
    final match = RegExp(r"\?(fix|rewrite|summ|polite|casual|expand|translate|bullet|improve|rephrase|formal|scribe)\b",
        caseSensitive: false)
        .firstMatch(text);
    setState(() => _detected = match?.group(0)?.toLowerCase() ?? "");
  }

  void _appendCommand(String cmd) {
    final current = _demoCtrl.text.trimRight();
    if (current.isEmpty) return;
    final next = "$current $cmd";
    _demoCtrl.text = next;
    _demoCtrl.selection = TextSelection.fromPosition(TextPosition(offset: next.length));
    _updateDetected(next);
  }

  @override
  void dispose() {
    _demoCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Accessibility Demo")),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                "Quick Tutorial",
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              const Text(
                "1. Type or paste any text.",
              ),
              const Text(
                "2. Add a command like ?fix to the end.",
              ),
              const Text(
                "3. The service replaces your text automatically.",
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _demoCommands
                    .map(
                      (cmd) => OutlinedButton(
                        onPressed: _demoCtrl.text.trim().isEmpty ? null : () => _appendCommand(cmd),
                        child: Text(cmd),
                      ),
                    )
                    .toList(),
              ),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
                ),
                child: Row(
                  children: [
                    const Text("Detected: "),
                    Text(
                      _detected.isEmpty ? "None" : _detected,
                      style: TextStyle(
                        color: _detected.isEmpty
                            ? Theme.of(context).colorScheme.onSurface.withOpacity(0.6)
                            : Theme.of(context).colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: TextField(
                  controller: _demoCtrl,
                  maxLines: null,
                  expands: true,
                  onChanged: _updateDetected,
                  decoration: const InputDecoration(
                    hintText: "Try: This is a tset ?fix",
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ManagePromptsPageState extends State<ManagePromptsPage> {
  static const _channel = MethodChannel('local_llm');

  bool _loading = true;
  List<Map<String, dynamic>> _prompts = [];

  @override
  void initState() {
    super.initState();
    _loadPrompts();
  }

  Future<void> _loadPrompts() async {
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>("getPrompts") ?? [];
      final list = raw
          .whereType<Map>()
          .map((e) => e.map((k, v) => MapEntry(k.toString(), v)))
          .map((e) => e.cast<String, dynamic>())
          .toList();
      if (!mounted) return;
      final custom = list.where((e) => e["builtIn"] != true).toList().reversed;
      final ordered = [
        ...custom,
        ...list.where((e) => e["builtIn"] == true),
      ];
      setState(() {
        _prompts = ordered;
        _loading = false;
      });
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() {
        _prompts = [];
        _loading = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Load prompts error: ${e.code}: ${e.message}")),
      );
    }
  }

  Future<void> _addPrompt() async {
    final result = await _showPromptDialog();
    if (result == null) return;
    try {
      await _channel.invokeMethod<bool>("addPrompt", result);
      await _loadPrompts();
    } on PlatformException catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Add prompt error: ${e.code}: ${e.message}")),
      );
    }
  }

  Future<void> _editPrompt(Map<String, dynamic> prompt) async {
    final oldKeyword = (prompt["keyword"] as String? ?? "").trim().toLowerCase();
    final result = await _showPromptDialog(
      initialKeyword: prompt["keyword"] as String? ?? "",
      initialPrompt: prompt["prompt"] as String? ?? "",
      allowKeywordEdit: true,
    );
    if (result == null) return;
    try {
      await _channel.invokeMethod<bool>("updatePrompt", {
        ...result,
        "oldKeyword": oldKeyword,
      });
      await _loadPrompts();
    } on PlatformException catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Update prompt error: ${e.code}: ${e.message}")),
      );
    }
  }

  Future<void> _deletePrompt(Map<String, dynamic> prompt) async {
    final keyword = prompt["keyword"] as String? ?? "";
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Delete prompt"),
        content: RichText(
          text: TextSpan(
            style: Theme.of(context).textTheme.bodyMedium,
            children: [
              const TextSpan(text: "Are you sure to remove "),
              TextSpan(
                text: keyword,
                style: TextStyle(color: Theme.of(context).colorScheme.primary),
              ),
              const TextSpan(text: "?"),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text("Cancel"),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text("Delete"),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _channel.invokeMethod<bool>("deletePrompt", {"keyword": keyword});
      await _loadPrompts();
    } on PlatformException catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Delete prompt error: ${e.code}: ${e.message}")),
      );
    }
  }

  Future<Map<String, String>?> _showPromptDialog({
    String initialKeyword = "",
    String initialPrompt = "",
    bool allowKeywordEdit = true,
  }) async {
    final keywordCtrl = TextEditingController(text: initialKeyword);
    final promptCtrl = TextEditingController(text: initialPrompt);
    return showDialog<Map<String, String>>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(allowKeywordEdit ? "Add prompt" : "Edit prompt"),
        content: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 280, maxWidth: 360),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: keywordCtrl,
                enabled: allowKeywordEdit,
                minLines: 1,
                maxLines: 1,
                decoration: const InputDecoration(
                  labelText: "Keyword (without ?)",
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 140,
                child: TextField(
                  controller: promptCtrl,
                  minLines: null,
                  maxLines: null,
                  expands: true,
                  decoration: const InputDecoration(
                    labelText: "Prompt",
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.secondary,
            ),
            child: const Text("Cancel"),
          ),
          ElevatedButton(
            onPressed: () {
              final keyword = keywordCtrl.text.trim().replaceFirst("?", "");
              final prompt = promptCtrl.text.trim();
              if (keyword.isEmpty || prompt.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text("Keyword and prompt are required.")),
                );
                return;
              }
              if (allowKeywordEdit && _isBuiltInKeyword(keyword)) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text("That is a default keyword.")),
                );
                return;
              }
              Navigator.of(context).pop({
                "keyword": keyword.toLowerCase(),
                "prompt": prompt,
              });
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.primary,
              foregroundColor: Colors.white,
            ),
            child: const Text("Save"),
          ),
        ],
      ),
    );
  }

  bool _isBuiltInKeyword(String keyword) {
    const builtIns = {
      "fix",
      "rewrite",
      "scribe",
      "summ",
      "polite",
      "casual",
      "expand",
      "translate",
      "bullet",
      "improve",
      "rephrase",
      "formal",
    };
    return builtIns.contains(keyword.toLowerCase());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Manage Prompts")),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: _prompts.length + 1,
              itemBuilder: (context, index) {
                if (index == _prompts.length) {
                  return const SizedBox(height: 80);
                }
                final item = _prompts[index];
                final keyword = item["keyword"] as String? ?? "";
                final prompt = item["prompt"] as String? ?? "";
                final builtIn = item["builtIn"] == true;
                return Card(
                  margin: const EdgeInsets.only(bottom: 12),
                  child: ListTile(
                    title: Text("?$keyword"),
                    subtitle: Text(prompt),
                    trailing: builtIn
                        ? const Text("Default")
                        : Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.edit),
                                onPressed: () => _editPrompt(item),
                              ),
                              IconButton(
                                icon: const Icon(Icons.delete),
                                onPressed: () => _deletePrompt(item),
                              ),
                            ],
                          ),
                  ),
                );
              },
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: _addPrompt,
        child: const Icon(Icons.add),
      ),
    );
  }
}
