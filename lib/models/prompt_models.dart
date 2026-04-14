class CommandInfo {
  const CommandInfo({required this.command, required this.desc});

  final String command;
  final String desc;
}

class PromptSpec {
  const PromptSpec({
    required this.keyword,
    required this.prompt,
    required this.hash,
  });

  final String keyword;
  final String prompt;
  final String hash;
}

class PromptEntry {
  const PromptEntry({
    required this.keyword,
    required this.prompt,
    required this.builtIn,
  });

  final String keyword;
  final String prompt;
  final bool builtIn;
}
