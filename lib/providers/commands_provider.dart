import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:local_grammer_llm/models/prompt_models.dart';
import 'package:local_grammer_llm/services/platform_channel_service.dart';
import 'package:local_grammer_llm/services/preferences_service.dart';

class CommandsProvider extends ChangeNotifier {
  CommandsProvider(this._channel, this._prefs);

  final LlmChannelService _channel;
  final PreferencesService _prefs;

  List<CommandInfo> _availableCommands = [];
  bool _loading = false;
  int _genId = 0;

  List<CommandInfo> get availableCommands => _availableCommands;
  bool get loading => _loading;

  Future<void> load() async {
    if (_loading) return;
    final myGenId = ++_genId;
    _loading = true;
    notifyListeners();

    try {
      var cache = await _prefs.getCommandCache();

      final list = await _channel.getPrompts();

      const builtInDesc = <String, String>{
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

      final entries = <PromptEntry>[];
      for (final item in list) {
        final keyword = (item["keyword"] ?? "").toString().trim().toLowerCase();
        final prompt = (item["prompt"] ?? "").toString();
        final builtIn = item["builtIn"] == true;
        if (keyword.isEmpty) continue;
        entries.add(PromptEntry(keyword: keyword, prompt: prompt, builtIn: builtIn));
      }
      final custom = entries.where((e) => !e.builtIn).toList().reversed;
      final orderedEntries = [...custom, ...entries.where((e) => e.builtIn)];

      final pending = <PromptSpec>[];
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
          pending.add(PromptSpec(keyword: e.keyword, prompt: e.prompt, hash: promptHash));
        }
      }

      if (pending.isNotEmpty) {
        final batch = await _generateBatchShortDesc(pending, myGenId);
        if (myGenId != _genId) return;
        for (final item in pending) {
          if (myGenId != _genId) return;
          final desc = batch[item.keyword] ?? await _generateShortDesc(item.prompt, myGenId);
          cache[item.keyword] = {"hash": item.hash, "desc": desc};
          descMap[item.keyword] = desc;
        }
      }

      final commands = <CommandInfo>[];
      for (final e in orderedEntries) {
        final desc = descMap[e.keyword];
        if (desc != null) {
          commands.add(CommandInfo(command: "?${e.keyword}", desc: desc));
        }
      }

      if (myGenId != _genId) return;
      await _prefs.setCommandCache(cache);
      _availableCommands = commands;
    } catch (_) {
      _availableCommands = [];
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<String> _generateShortDesc(String prompt, int genId) async {
    if (genId != _genId) return "Custom prompt";
    if (prompt.trim().isEmpty) return "Custom prompt";
    try {
      // One-shot exemplar keeps small local models from echoing the input
      // verbatim or adding punctuation / quotes around the label.
      final text = await _channel.generate(
        'Summarize this instruction as a short UI label: 3-6 words, Title Case, '
        'no punctuation, no quotes, no trailing period.\n'
        'Example:\n'
        'Instruction: "Rewrite the text to sound more professional and concise."\n'
        'Label: Make It More Professional\n'
        'Now do the same for:\n'
        'Instruction: "$prompt"\n'
        'Label:',
      );
      if (genId != _genId) return "Custom prompt";
      final cleaned = (text ?? "").trim();
      if (cleaned.isEmpty) return "Custom prompt";
      return cleaned.split("\n").first.trim();
    } catch (_) {
      return "Custom prompt";
    }
  }

  Future<Map<String, String>> _generateBatchShortDesc(
      List<PromptSpec> items, int genId) async {
    if (genId != _genId) return {};
    try {
      final payload = items
          .map((e) => {"keyword": e.keyword, "prompt": e.prompt})
          .toList(growable: false);
      final prompt = """
You are summarizing custom prompts for a UI list.
Return ONLY valid JSON in this exact schema:
{"items":[{"keyword":"...","desc":"..."}]}
Rules:
- desc must be 3-6 words, Title Case, no punctuation, no quotes
- preserve keyword exactly as given
- no extra text or markdown

Example input:
{"items":[{"keyword":"fix","prompt":"Fix grammar and typos in the text."}]}
Example output:
{"items":[{"keyword":"fix","desc":"Fix Grammar And Typos"}]}

Input:
${jsonEncode({"items": payload})}
""";
      final text = await _channel.generate(prompt);
      if (genId != _genId) return {};
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

  @override
  void dispose() {
    _genId++;
    super.dispose();
  }
}
