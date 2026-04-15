import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  static final List<ChatMessage> _cachedMessages = [];
  static String _cachedDraft = "";

  final _promptCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();

  bool _busy = false;
  int _generationId = 0;

  final List<ChatMessage> _messages = [];

  void _showNotice(String message) {
    showAppSnackBar(context, message);
  }

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
                  final isUser = msg.role == ChatRole.user;

                  final bubbleColor = isUser
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.surfaceContainerHighest;
                  final textColor = isUser
                      ? Theme.of(context).colorScheme.onPrimary
                      : Theme.of(context).colorScheme.onSurface;

                  return Align(
                    alignment:
                        isUser ? Alignment.centerRight : Alignment.centerLeft,
                    child: GestureDetector(
                      onLongPress: msg.text.isEmpty
                          ? null
                          : () async {
                              await Clipboard.setData(
                                  ClipboardData(text: msg.text));
                            },
                      child: Container(
                        constraints: const BoxConstraints(maxWidth: 340),
                        margin: const EdgeInsets.symmetric(vertical: 6),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 10),
                        decoration: BoxDecoration(
                          color: bubbleColor,
                          borderRadius: BorderRadius.circular(14),
                          border: isUser
                              ? null
                              : Border.all(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .outlineVariant),
                        ),
                        child: msg.suggestions != null
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
