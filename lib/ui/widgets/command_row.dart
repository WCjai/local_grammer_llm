import 'package:flutter/material.dart';

Widget commandRow(Widget left, Widget right) {
  return Padding(
    padding: EdgeInsets.zero,
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 72),
            child: left,
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 72),
            child: right,
          ),
        ),
      ],
    ),
  );
}
