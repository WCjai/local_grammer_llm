import 'package:flutter/material.dart';

enum SnackType { success, error, info }

void showAppSnackBar(BuildContext context, String message,
    {SnackType type = SnackType.info}) {
  final cs = Theme.of(context).colorScheme;
  final messenger = ScaffoldMessenger.of(context);
  messenger.hideCurrentSnackBar();

  final (IconData icon, Color bg, Color fg) = switch (type) {
    SnackType.success => (Icons.check_circle_outline, cs.primary, cs.onPrimary),
    SnackType.error => (Icons.error_outline, cs.error, cs.onError),
    SnackType.info => (Icons.info_outline, cs.inverseSurface, cs.onInverseSurface),
  };

  messenger.showSnackBar(
    SnackBar(
      behavior: SnackBarBehavior.floating,
      backgroundColor: bg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      duration: type == SnackType.error
          ? const Duration(seconds: 4)
          : const Duration(seconds: 2),
      content: Row(
        children: [
          Icon(icon, color: fg, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: fg, fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    ),
  );
}
