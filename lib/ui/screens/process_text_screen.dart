import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_grammer_llm/services/process_text_channel.dart';

@pragma('vm:entry-point')
void processTextMain() => runApp(const ProcessTextApp());

class ProcessTextApp extends StatelessWidget {
  const ProcessTextApp({super.key});

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
        scaffoldBackgroundColor: Colors.transparent,
      ),
      home: const ProcessTextScreen(),
    );
  }
}

class ProcessTextScreen extends StatefulWidget {
  const ProcessTextScreen({super.key});

  @override
  State<ProcessTextScreen> createState() => _ProcessTextScreenState();
}

class _ProcessTextScreenState extends State<ProcessTextScreen> {
  final _channel = ProcessTextChannelService();

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
    _loadData();
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

  void _dismiss() {
    _channel.dismiss();
  }

  void _copyResult() {
    if (_result == null) return;
    Clipboard.setData(ClipboardData(text: _result!));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Copied to clipboard')),
    );
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
        child: Container(
          color: Colors.black54,
          alignment: Alignment.bottomCenter,
          child: GestureDetector(
            onTap: () {},
            child: _buildSheet(context, cs),
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
