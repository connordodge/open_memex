import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../theme/colors.dart';
import '../theme/typography.dart';
import 'atoms.dart';

/// A dismissible inline error (Key `inline-error`, dismiss Key
/// `inline-error-dismiss`) showing a CLI error [message] (Req 54).
class InlineError extends StatelessWidget {
  const InlineError({
    super.key,
    required this.message,
    required this.onDismiss,
  });
  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('inline-error'),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      decoration: BoxDecoration(
        color: OmColors.dangerBg,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              message,
              style: OmType.mono(size: 11, color: OmColors.danger),
            ),
          ),
          OmButton(
            key: const Key('inline-error-dismiss'),
            kind: OmButtonKind.ghost,
            size: 22,
            icon: LucideIcons.x,
            tooltip: 'dismiss',
            onPressed: onDismiss,
          ),
        ],
      ),
    );
  }
}
