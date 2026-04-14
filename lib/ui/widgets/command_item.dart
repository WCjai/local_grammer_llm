import 'package:flutter/material.dart';

class CommandItem extends StatelessWidget {
  const CommandItem({
    super.key,
    required this.command,
    required this.desc,
    this.maxDescLines,
  });

  final String command;
  final String desc;
  final int? maxDescLines;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            command,
            style: TextStyle(color: color, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 2),
          Text(
            desc,
            maxLines: maxDescLines,
            overflow:
                maxDescLines == null ? TextOverflow.visible : TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}
