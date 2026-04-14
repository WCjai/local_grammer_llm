enum ChatRole { user, assistant }

class ChatMessage {
  const ChatMessage({
    required this.role,
    this.text = "",
    this.suggestions,
  });

  final ChatRole role;
  final String text;
  final List<PromptSuggestion>? suggestions;
}

class PromptSuggestion {
  PromptSuggestion({
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
