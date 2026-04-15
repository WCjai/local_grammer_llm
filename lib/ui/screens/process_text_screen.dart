import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:local_grammer_llm/services/process_text_channel.dart';

/// Notifier that forces ProcessTextScreen rebuild when native pushes new text.
final _screenKey = ValueNotifier<Key>(UniqueKey());

/// Notifier for dark mode, re-read from prefs on each invocation.
final _isDarkNotifier = ValueNotifier<bool>(false);

const _kChannel = MethodChannel('process_text');

@pragma('vm:entry-point')
void processTextMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  _isDarkNotifier.value = prefs.getBool('is_dark_mode') ?? false;
  _kChannel.setMethodCallHandler((call) async {
    if (call.method == 'onNewText') {
      // Re-read theme pref each time the popup is triggered
      await prefs.reload();
      _isDarkNotifier.value = prefs.getBool('is_dark_mode') ?? false;
      _screenKey.value = UniqueKey();
    }
    return null;
  });
  runApp(const ProcessTextApp());
}

class ProcessTextApp extends StatelessWidget {
  const ProcessTextApp({super.key});

  static const _light = ColorScheme.light(
    primary: Color(0xFF6C4AD5),
    onPrimary: Colors.white,
    secondary: Color(0xFF8E7EE6),
    onSecondary: Colors.white,
    tertiary: Color(0xFFC4B7FF),
    onTertiary: Color(0xFF2A2155),
    surface: Color(0xFFF7F5FF),
    onSurface: Color(0xFF1A1633),
    surfaceContainerHighest: Color(0xFFEEE9FF),
    outline: Color(0xFFB8B0D9),
    outlineVariant: Color(0xFFD8D2F0),
  );

  static const _dark = ColorScheme.dark(
    primary: Color(0xFF9B80E8),
    onPrimary: Color(0xFF1A1633),
    secondary: Color(0xFFB0A0F0),
    onSecondary: Color(0xFF1A1633),
    tertiary: Color(0xFF6C4AD5),
    onTertiary: Color(0xFFE8E4F4),
    surface: Color(0xFF121020),
    onSurface: Color(0xFFE8E4F4),
    surfaceContainerHighest: Color(0xFF252240),
    outline: Color(0xFF5A5080),
    outlineVariant: Color(0xFF3D3565),
  );

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: _isDarkNotifier,
      builder: (_, isDark, __) {
        final scheme = isDark ? _dark : _light;
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            useMaterial3: true,
            colorScheme: scheme,
            scaffoldBackgroundColor: Colors.transparent,
          ),
          home: ValueListenableBuilder<Key>(
            valueListenable: _screenKey,
            builder: (_, key, __) => ProcessTextScreen(key: key),
          ),
        );
      },
    );
  }
}

class ProcessTextScreen extends StatefulWidget {
  const ProcessTextScreen({super.key});

  @override
  State<ProcessTextScreen> createState() => _ProcessTextScreenState();
}

class _ProcessTextScreenState extends State<ProcessTextScreen>
    with SingleTickerProviderStateMixin {
  final _channel = ProcessTextChannelService();
  late final AnimationController _anim;
  late final Animation<double> _scrimOpacity;
  late final Animation<Offset> _slideOffset;

  String _inputText = '';
  bool _isReadOnly = true;
  List<Map<String, dynamic>> _prompts = [];
  bool _loading = false;
  bool _dataLoaded = false;
  String? _result;
  String? _error;
  String? _activeCommand;
  final _contextCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );
    _scrimOpacity = CurvedAnimation(parent: _anim, curve: Curves.easeOut);
    _slideOffset = Tween<Offset>(
      begin: const Offset(0, 1),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _anim, curve: Curves.easeOutCubic));
    _anim.forward();
    _loadData();
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    try {
      final data = await _channel.getProcessTextData();
      final prompts = await _channel.getPrompts();
      if (!mounted) return;
      setState(() {
        _inputText = data?['text']?.toString() ?? '';
        _isReadOnly = data?['readOnly'] == true;
        _prompts = prompts;
        _dataLoaded = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _dataLoaded = true;
      });
    }
  }

  Future<void> _runCommand(String keyword, [String? arg]) async {
    setState(() {
      _loading = true;
      _result = null;
      _error = null;
      _activeCommand = keyword;
    });
    try {
      final ctx = _contextCtrl.text.trim();
      final result = await _channel.generate(
        text: _inputText,
        command: keyword,
        arg: arg,
        context: ctx.isNotEmpty ? ctx : null,
      );
      if (!mounted) return;
      setState(() {
        _loading = false;
        _result = result ?? '';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  void _apply() {
    if (_result != null) {
      _channel.finishWithResult(_result!);
    }
  }

  void _dismiss() async {
    await _anim.reverse();
    _channel.dismiss();
  }

  void _copyResult() {
    if (_result == null) return;
    Clipboard.setData(ClipboardData(text: _result!));
  }

  void _reset() {
    setState(() {
      _result = null;
      _error = null;
      _activeCommand = null;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Colors.transparent,
      resizeToAvoidBottomInset: true,
      body: GestureDetector(
        onTap: _dismiss,
        behavior: HitTestBehavior.opaque,
        child: FadeTransition(
          opacity: _scrimOpacity,
          child: Container(
            color: Colors.black54,
            alignment: Alignment.bottomCenter,
            child: GestureDetector(
              onTap: () {},
              child: SlideTransition(
                position: _slideOffset,
                child: _buildSheet(context, cs),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSheet(BuildContext context, ColorScheme cs) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final screenH = MediaQuery.of(context).size.height;
    final maxH = (screenH - bottomInset) * 0.65;
    return Container(
      constraints: BoxConstraints(maxHeight: maxH),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Center(
              child: Container(
                margin: const EdgeInsets.only(top: 12),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: cs.outline,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 8, 0),
              child: Row(
                children: [
                  Icon(Icons.edit_note, color: cs.primary, size: 24),
                  const SizedBox(width: 8),
                  Text(
                    'Local Scribe',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: Icon(Icons.close, color: cs.onSurface),
                    onPressed: _dismiss,
                  ),
                ],
              ),
            ),
            if (_inputText.isNotEmpty)
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    _inputText,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      color: cs.onSurface.withValues(alpha: 0.8),
                    ),
                  ),
                ),
              ),
            Divider(color: cs.outlineVariant, height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
              child: _buildContent(cs),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContent(ColorScheme cs) {
    if (!_dataLoaded) {
      return Padding(
        padding: const EdgeInsets.all(32),
        child: Center(child: CircularProgressIndicator(color: cs.primary)),
      );
    }

    if (_loading) {
      return Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          children: [
            CircularProgressIndicator(color: cs.primary),
            const SizedBox(height: 16),
            Text(
              'Processing with ?$_activeCommand ...',
              style: TextStyle(color: cs.onSurface.withValues(alpha: 0.7)),
            ),
          ],
        ),
      );
    }

    if (_result != null) return _buildResultView(cs);
    if (_error != null && _activeCommand != null) return _buildErrorView(cs);
    return _buildCommandGrid(cs);
  }

  Widget _buildCommandGrid(ColorScheme cs) {
    if (_prompts.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(20),
        child: Text(
          'No commands available',
          style: TextStyle(color: cs.onSurface.withValues(alpha: 0.6)),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _contextCtrl,
          maxLines: 2,
          minLines: 1,
          style: TextStyle(fontSize: 14, color: cs.onSurface),
          decoration: InputDecoration(
            hintText: 'Add context (optional)',
            hintStyle: TextStyle(color: cs.onSurface.withValues(alpha: 0.4)),
            prefixIcon: Icon(Icons.notes, color: cs.primary, size: 20),
            filled: true,
            fillColor: cs.surfaceContainerHighest,
            isDense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: cs.outlineVariant),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: cs.outlineVariant),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: cs.primary, width: 1.4),
            ),
          ),
        ),
        const SizedBox(height: 14),
        Text(
          'Choose a command',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: cs.onSurface.withValues(alpha: 0.7),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: _prompts.map((p) {
            final keyword = p['keyword']?.toString() ?? '';
            final builtIn = p['builtIn'] == true;
            return ActionChip(
              avatar: Icon(
                builtIn ? Icons.auto_fix_high : Icons.tag,
                size: 18,
                color: cs.primary,
              ),
              label: Text('?$keyword'),
              labelStyle: TextStyle(
                color: cs.onSurface,
                fontWeight: FontWeight.w500,
              ),
              backgroundColor: cs.surfaceContainerHighest,
              side: BorderSide(color: cs.outlineVariant),
              onPressed: () => _runCommand(keyword),
            );
          }).toList(),
        ),
      ],
    );
  }

  Widget _buildResultView(ColorScheme cs) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Result',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: cs.primary,
          ),
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: cs.outlineVariant),
          ),
          child: SelectableText(
            _result!,
            style:
                TextStyle(fontSize: 15, color: cs.onSurface, height: 1.5),
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            if (!_isReadOnly)
              Expanded(
                child: FilledButton.icon(
                  onPressed: _apply,
                  icon: const Icon(Icons.check, size: 18),
                  label: const Text('Apply'),
                  style: FilledButton.styleFrom(
                    backgroundColor: cs.primary,
                    foregroundColor: cs.onPrimary,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
            if (!_isReadOnly) const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _copyResult,
                icon: const Icon(Icons.copy, size: 18),
                label: const Text('Copy'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  side: BorderSide(color: cs.outline),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextButton.icon(
                onPressed: _reset,
                icon: const Icon(Icons.arrow_back, size: 18),
                label: const Text('Back'),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildErrorView(ColorScheme cs) {
    return Column(
      children: [
        Icon(Icons.error_outline, color: cs.error, size: 48),
        const SizedBox(height: 12),
        Text(
          _error!,
          textAlign: TextAlign.center,
          style: TextStyle(color: cs.error, fontSize: 14),
        ),
        const SizedBox(height: 16),
        OutlinedButton(
          onPressed: _reset,
          child: const Text('Try Again'),
        ),
      ],
    );
  }
}
