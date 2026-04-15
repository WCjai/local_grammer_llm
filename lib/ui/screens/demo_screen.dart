import 'package:flutter/material.dart';

class DemoScreen extends StatefulWidget {
  const DemoScreen({super.key});

  @override
  State<DemoScreen> createState() => _DemoScreenState();
}

class _DemoScreenState extends State<DemoScreen> {
  final _accessibilityCtrl = TextEditingController(
    text: 'im doing well how about u',
  );
  final _highlightCtrl = TextEditingController(
    text:
        'hey i wantd to let you know that the meetting has been rescheduld to '
        'next wendsday at 3pm insted of thursday. plz confirm if that works '
        'for you and let me know if you need anyting else before than. thx',
  );

  String _detected = '';

  @override
  void initState() {
    super.initState();
    _updateDetected(_accessibilityCtrl.text);
  }

  void _updateDetected(String text) {
    final match = RegExp(
      r'\?(fix|rewrite|summ|polite|casual|expand|translate|bullet|improve|rephrase|formal|scribe)\b',
      caseSensitive: false,
    ).firstMatch(text);
    setState(() => _detected = match?.group(0)?.toLowerCase() ?? '');
  }

  void _appendCommand(String cmd) {
    final current = _accessibilityCtrl.text.trimRight();
    if (current.isEmpty) return;
    final next = '$current $cmd';
    _accessibilityCtrl.text = next;
    _accessibilityCtrl.selection =
        TextSelection.fromPosition(TextPosition(offset: next.length));
    _updateDetected(next);
  }

  @override
  void dispose() {
    _accessibilityCtrl.dispose();
    _highlightCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('How to Use'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Type It (Commands)'),
              Tab(text: 'Highlight It (Menu)'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _buildAccessibilityTab(context),
            _buildHighlightTab(context),
          ],
        ),
      ),
    );
  }

  // ── Tab 1: Accessibility ─────────────────────────────────────

  Widget _buildAccessibilityTab(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _tutorialVisual('assets/tutorial/accessibility_demo.gif'),
        const SizedBox(height: 20),
        Text(
          'Type any command (like ?fix or ?casual) at the end of the '
          'text below to see it transform in real-time.',
          style: tt.bodyLarge?.copyWith(color: cs.onSurface),
        ),
        const SizedBox(height: 20),
        Card(
          elevation: 2,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Try it out', style: tt.titleMedium),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: const [
                    '?fix',
                    '?rewrite',
                    '?polite',
                    '?casual',
                  ]
                      .map(
                        (cmd) => ActionChip(
                          label: Text(cmd),
                          onPressed: () => _appendCommand(cmd),
                        ),
                      )
                      .toList(),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _accessibilityCtrl,
                  maxLines: 4,
                  onChanged: _updateDetected,
                  decoration: InputDecoration(
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ── Tab 2: Highlight / Process Text ──────────────────────────

  Widget _buildHighlightTab(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _tutorialVisual('assets/tutorial/highlight_demo.gif'),
        const SizedBox(height: 20),
        Text(
          'Long-press to highlight the text below, tap the three dots (\u22EE) '
          'in the copy/paste menu, and select "Local Scribe".',
          style: tt.bodyLarge?.copyWith(color: cs.onSurface),
        ),
        const SizedBox(height: 20),
        Card(
          elevation: 2,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Try it out', style: tt.titleMedium),
                const SizedBox(height: 12),
                TextField(
                  controller: _highlightCtrl,
                  maxLines: null,
                  minLines: 6,
                  decoration: InputDecoration(
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ── Shared tutorial visual widget ────────────────────────────

  Widget _tutorialVisual(String assetPath) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: AspectRatio(
        aspectRatio: 16 / 10,
        child: Image.asset(
          assetPath,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _gifPlaceholder(),
        ),
      ),
    );
  }

  Widget _gifPlaceholder() {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.play_circle_outline, size: 48, color: cs.primary),
            const SizedBox(height: 8),
            Text(
              'Tutorial video coming soon',
              style: TextStyle(color: cs.onSurface.withValues(alpha: 0.6)),
            ),
          ],
        ),
      ),
    );
  }
}
