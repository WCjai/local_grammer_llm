import 'package:flutter/material.dart';
import 'package:local_grammer_llm/services/platform_channel_service.dart';
import 'package:local_grammer_llm/ui/widgets/app_snackbar.dart';

class ManagePromptsScreen extends StatefulWidget {
  const ManagePromptsScreen({super.key});

  @override
  State<ManagePromptsScreen> createState() => _ManagePromptsScreenState();
}

class _ManagePromptsScreenState extends State<ManagePromptsScreen> {
  final _channel = LlmChannelService();

  bool _loading = true;
  List<Map<String, dynamic>> _prompts = [];

  @override
  void initState() {
    super.initState();
    _loadPrompts();
  }

  Future<void> _loadPrompts() async {
    try {
      final list = await _channel.getPrompts();
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
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _prompts = [];
        _loading = false;
      });
      showAppSnackBar(context, "Load prompts error: $e", type: SnackType.error);
    }
  }

  Future<void> _addPrompt() async {
    final result = await _showPromptDialog();
    if (result == null) return;
    try {
      await _channel.addPrompt(
        keyword: result["keyword"]!,
        prompt: result["prompt"]!,
      );
      await _loadPrompts();
    } catch (e) {
      showAppSnackBar(context, "Add prompt error: $e", type: SnackType.error);
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
      await _channel.updatePrompt(
        keyword: result["keyword"]!,
        prompt: result["prompt"]!,
        oldKeyword: oldKeyword,
      );
      await _loadPrompts();
    } catch (e) {
      showAppSnackBar(context, "Update prompt error: $e", type: SnackType.error);
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
      await _channel.deletePrompt(keyword);
      await _loadPrompts();
    } catch (e) {
      showAppSnackBar(context, "Delete prompt error: $e", type: SnackType.error);
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
                showAppSnackBar(context, "Keyword and prompt are required.", type: SnackType.error);
                return;
              }
              if (allowKeywordEdit && _isBuiltInKeyword(keyword)) {
                showAppSnackBar(context, "That is a default keyword.", type: SnackType.error);
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
      "fix", "rewrite", "scribe", "summ", "polite", "casual",
      "expand", "translate", "bullet", "improve", "rephrase", "formal",
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
