import 'package:flutter/material.dart';

class DemoScreen extends StatefulWidget {
  const DemoScreen({super.key});

  @override
  State<DemoScreen> createState() => _DemoScreenState();
}

class _DemoScreenState extends State<DemoScreen> {
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
    final match = RegExp(
            r"\?(fix|rewrite|summ|polite|casual|expand|translate|bullet|improve|rephrase|formal|scribe)\b",
            caseSensitive: false)
        .firstMatch(text);
    setState(() => _detected = match?.group(0)?.toLowerCase() ?? "");
  }

  void _appendCommand(String cmd) {
    final current = _demoCtrl.text.trimRight();
    if (current.isEmpty) return;
    final next = "$current $cmd";
    _demoCtrl.text = next;
    _demoCtrl.selection =
        TextSelection.fromPosition(TextPosition(offset: next.length));
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
              const Text("1. Type or paste any text."),
              const Text("2. Add a command like ?fix to the end."),
              const Text("3. The service replaces your text automatically."),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _demoCommands
                    .map(
                      (cmd) => OutlinedButton(
                        onPressed: _demoCtrl.text.trim().isEmpty
                            ? null
                            : () => _appendCommand(cmd),
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
                  color:
                      Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                      color: Theme.of(context).colorScheme.outlineVariant),
                ),
                child: Row(
                  children: [
                    const Text("Detected: "),
                    Text(
                      _detected.isEmpty ? "None" : _detected,
                      style: TextStyle(
                        color: _detected.isEmpty
                            ? Theme.of(context)
                                .colorScheme
                                .onSurface
                                .withOpacity(0.6)
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
