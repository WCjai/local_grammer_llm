import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:local_grammer_llm/models/chat_message.dart';
import 'package:local_grammer_llm/services/platform_channel_service.dart';
import 'package:local_grammer_llm/ui/widgets/suggestions_list.dart';
import 'package:local_grammer_llm/ui/widgets/app_snackbar.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _channel = LlmChannelService();

  final _promptCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();

  bool _busy = false;
  bool _historyLoaded = false;
  int _generationId = 0;

  final List<ChatMessage> _messages = [];

  static const _historyKey = 'prompt_gen_history';

  void _showNotice(String message) => showAppSnackBar(context, message);

  static const Set<String> _reservedKeywords = {
    "fix", "rewrite", "scribe", "summ", "polite", "casual",
    "expand", "translate", "bullet", "improve", "rephrase", "formal",
  };

  String _sanitizeUserRequest(String s) {
    var out = s.replaceAll("\r", " ").replaceAll("\n", " ").trim();
    out = out.replaceAll("<", "").replaceAll(">", "");
    return out;
  }

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
- prompt: clear and detailed instruction string that includes {text}, does NOT mention JSON/tags/system/AI, ends with "Return only the result." without "\\n"

User request: $req

Output JSON only, format:
{"prompts":[{"keyword":"string","label":"string","prompt":"string"}]}
""";
  }

  String _cleanJson(String raw) {
    var text = raw.trim();
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
    final first = text.indexOf("{");
    if (first != -1) text = text.substring(first);
    text = _extractJsonObject(text);
    return text.trim();
  }

  String _extractJsonObject(String text) {
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
        if (depth == 0) return text.substring(0, i + 1);
      }
    }
    return text;
  }

  String _repairJson(String text) {
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

  List<PromptSuggestion> _parseSuggestions(String raw) {
    final cleaned = _cleanJson(raw);
    final extracted = _extractSuggestionPairs(cleaned);
    if (extracted.isNotEmpty) return extracted;

    try {
      final decoded = jsonDecode(cleaned);
      final list = decoded is Map ? decoded["prompts"] : null;
      if (list is! List) return [];
      return list
          .whereType<Map>()
          .map((e) => _normalizeSuggestion(e["keyword"], e["prompt"], e["label"]))
          .whereType<PromptSuggestion>()
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
            .whereType<PromptSuggestion>()
            .toList();
      } catch (_) {
        return [];
      }
    }
  }

  PromptSuggestion? _normalizeSuggestion(dynamic key, dynamic promptValue, dynamic labelValue) {
    var keyword = (key ?? "").toString().trim().toLowerCase();
    final prompt = (promptValue ?? "").toString().trim();
    final label = (labelValue ?? "").toString().trim();

    if (keyword.isEmpty || prompt.isEmpty) return null;
    if (_reservedKeywords.contains(keyword)) return null;

    keyword = keyword.replaceAll(RegExp(r"[^a-z0-9_]"), "_");
    keyword = keyword.replaceAll(RegExp(r"_+"), "_");
    keyword = keyword.replaceAll(RegExp(r"^_+|_+$"), "");
    if (keyword.length > 20) keyword = keyword.substring(0, 20);
    if (!RegExp(r"^[a-z0-9_]{3,20}$").hasMatch(keyword)) return null;
    if (!prompt.contains("{text}")) return null;

    final safeLabel = label.isEmpty ? null : label;
    return PromptSuggestion(keyword: keyword, prompt: prompt, label: safeLabel);
  }

  List<PromptSuggestion> _extractSuggestionPairs(String raw) {
    final regex = RegExp(
      r'"keyword"\s*:\s*"([^"]+)"\s*,\s*"label"\s*:\s*"([^"]*)"\s*,\s*"prompt"\s*:\s*"([^"]+)"',
    );
    final matches = regex.allMatches(raw).toList();
    if (matches.isEmpty) return [];
    return matches
        .map((m) => _normalizeSuggestion(m.group(1), m.group(3), m.group(2)))
        .whereType<PromptSuggestion>()
        .toList();
  }

  Future<void> _addSuggestion(PromptSuggestion suggestion) async {
    try {
      await _channel.addPrompt(
        keyword: suggestion.keyword,
        prompt: suggestion.prompt,
      );
      setState(() => suggestion.added = true);
    } catch (_) {
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

  String _friendlyError(Object e) {
    final msg = e.toString();
    if (msg.contains("API key")) {
      return "No API key set — open AI Settings and add your key.";
    }
    if (msg.contains("quota") || msg.contains("429")) {
      return "API quota exceeded — wait a moment or switch to local mode.";
    }
    if (msg.contains("internet") || msg.contains("SocketException")) {
      return "No internet connection — check your network or switch to local mode.";
    }
    if (msg.contains("400")) {
      return "Invalid API request — check your API key in AI Settings.";
    }
    return "Generation failed: ${msg.replaceAll(RegExp(r'PlatformException\(GEN_FAIL, '), '').replaceAll(RegExp(r', null, null\)$'), '')}";
  }

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
      _messages.add(ChatMessage(role: ChatRole.user, text: input));
      _messages.add(const ChatMessage(role: ChatRole.assistant, text: "Generating..."));
    });
    _scrollToBottom();

    try {
      final text = await _channel.generate(_buildPrompt(input));

      if (!mounted || myGenId != _generationId) return;

      final parsed = _parseSuggestions(text ?? "");
      setState(() {
        _messages.removeLast();
        if (parsed.isNotEmpty) {
          _messages.add(ChatMessage(role: ChatRole.assistant, suggestions: parsed));
        } else {
          _messages.add(
            ChatMessage(
              role: ChatRole.assistant,
              text: "Could not parse suggestions.\n\nRaw:\n${text ?? ""}",
            ),
          );
        }
      });
    } catch (e) {
      if (!mounted || myGenId != _generationId) return;
      setState(() {
        _messages.removeLast();
        _messages.add(
          ChatMessage(role: ChatRole.assistant, text: _friendlyError(e)),
        );
      });
    } finally {
      if (!mounted || myGenId != _generationId) return;
      setState(() => _busy = false);
      _scrollToBottom();
      _saveHistory().ignore();
    }
  }

  /// Aborts the in-flight generation. Bumps [_generationId] so the still-running
  /// `_generate` future gets ignored on completion, tells native to stop so we
  /// don't burn CPU, and swaps the placeholder bubble for a "Cancelled" note.
  Future<void> _cancelGenerate() async {
    if (!_busy) return;
    _generationId++;
    try {
      await _channel.cancelGenerate();
    } catch (_) {
      // best effort — if native has nothing in flight this is a no-op.
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (_messages.isNotEmpty &&
          _messages.last.role == ChatRole.assistant &&
          _messages.last.text == 'Generating...') {
        _messages.removeLast();
        _messages.add(const ChatMessage(
          role: ChatRole.assistant,
          text: 'Cancelled.',
        ));
      }
    });
    _saveHistory().ignore();
  }

  // ── Persistence ────────────────────────────────────────────────────────────

  Map<String, dynamic> _msgToJson(ChatMessage msg) => {
        'role': msg.role == ChatRole.user ? 'user' : 'assistant',
        'text': msg.text,
        'suggestions': msg.suggestions
            ?.map((s) => {
                  'keyword': s.keyword,
                  'label': s.label,
                  'prompt': s.prompt,
                })
            .toList(),
      };

  ChatMessage _msgFromJson(Map<String, dynamic> j) {
    final role = j['role'] == 'user' ? ChatRole.user : ChatRole.assistant;
    final text = (j['text'] ?? '') as String;
    final rawS = j['suggestions'];
    List<PromptSuggestion>? suggestions;
    if (rawS is List) {
      final list = rawS
          .whereType<Map>()
          .map((s) => PromptSuggestion(
                keyword: s['keyword'] as String? ?? '',
                prompt: s['prompt'] as String? ?? '',
                label: s['label'] as String?,
              ))
          .where((s) => s.keyword.isNotEmpty && s.prompt.isNotEmpty)
          .toList();
      if (list.isNotEmpty) suggestions = list;
    }
    return ChatMessage(role: role, text: text, suggestions: suggestions);
  }

  Future<void> _loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_historyKey);
    if (!mounted) return;
    setState(() {
      _historyLoaded = true;
      if (raw == null) return;
      try {
        final list = jsonDecode(raw) as List;
        _messages.addAll(
          list.whereType<Map<String, dynamic>>().map(_msgFromJson),
        );
      } catch (_) {}
    });
    if (_messages.isNotEmpty) _scrollToBottom();
  }

  Future<void> _saveHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _historyKey,
      jsonEncode(_messages.map(_msgToJson).toList()),
    );
  }

  Future<void> _clearHistory() async {
    setState(() => _messages.clear());
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_historyKey);
    _showNotice('History cleared');
  }

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  @override
  void dispose() {
    _generationId++;
    _promptCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasMessages = _messages.isNotEmpty;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Prompt Generator'),
        actions: [
          if (hasMessages && !_busy)
            IconButton(
              icon: const Icon(Icons.delete_sweep_outlined),
              tooltip: 'Clear history',
              onPressed: _clearHistory,
            ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: !_historyLoaded
                  ? const Center(child: CircularProgressIndicator())
                  : !hasMessages
                      ? _buildEmptyState(theme)
                      : ListView.builder(
                          controller: _scrollCtrl,
                          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                          itemCount: _messages.length,
                          itemBuilder: _buildMessageItem,
                        ),
            ),
            _buildInputBar(theme),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState(ThemeData theme) => Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.auto_awesome_outlined,
                size: 52,
                color: theme.colorScheme.outlineVariant,
              ),
              const SizedBox(height: 16),
              Text(
                'Describe the kind of prompts you need',
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                "I'll suggest keywords and prompts you can add to the app.",
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ],
          ),
        ),
      );

  Widget _buildMessageItem(BuildContext context, int index) {
    final msg = _messages[index];
    final isUser = msg.role == ChatRole.user;
    final theme = Theme.of(context);
    final isGenerating =
        !isUser && msg.text == 'Generating...' && msg.suggestions == null;

    final bubbleColor = isUser
        ? theme.colorScheme.primary
        : theme.colorScheme.surfaceContainerHighest;
    final textColor =
        isUser ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface;

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: msg.text.isEmpty || isGenerating
            ? null
            : () async {
                await Clipboard.setData(ClipboardData(text: msg.text));
                if (mounted) _showNotice('Copied to clipboard');
              },
        child: Container(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.sizeOf(context).width * 0.85,
          ),
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: bubbleColor,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(18),
              topRight: const Radius.circular(18),
              bottomLeft: Radius.circular(isUser ? 18 : 4),
              bottomRight: Radius.circular(isUser ? 4 : 18),
            ),
            border: isUser
                ? null
                : Border.all(color: theme.colorScheme.outlineVariant),
          ),
          child: isGenerating
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: textColor,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text('Generating\u2026', style: TextStyle(color: textColor)),
                  ],
                )
              : msg.suggestions != null
                  ? SuggestionsList(
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
  }

  Widget _buildInputBar(ThemeData theme) => Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          border: Border(
            top: BorderSide(color: theme.colorScheme.outlineVariant),
          ),
        ),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: _promptCtrl,
                minLines: 1,
                maxLines: 4,
                textCapitalization: TextCapitalization.sentences,
                onSubmitted: (_) {
                  if (!_busy) _generate();
                },
                decoration: InputDecoration(
                  hintText: 'Describe what you want to generate\u2026',
                  filled: true,
                  fillColor: theme.colorScheme.surfaceContainerHighest,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: _busy ? _cancelGenerate : _generate,
              style: FilledButton.styleFrom(
                minimumSize: const Size(48, 48),
                padding: EdgeInsets.zero,
                shape: const CircleBorder(),
                backgroundColor:
                    _busy ? theme.colorScheme.error : null,
              ),
              child: _busy
                  ? const Icon(Icons.stop_rounded, color: Colors.white)
                  : const Icon(Icons.arrow_upward_rounded),
            ),
          ],
        ),
      );
}
