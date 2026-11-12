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
    this.onRetry,
  });
  final String message;
  final VoidCallback onDismiss;

  /// When given, a `Retry` button (Key `inline-error-retry`) sits between
  /// the message and the dismiss button (Spec #394 req 14).
  final VoidCallback? onRetry;

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
          if (onRetry != null) ...[
            OmButton(
              key: const Key('inline-error-retry'),
              kind: OmButtonKind.ghost,
              dense: true,
              size: 22,
              label: 'Retry',
              focusable: true,
              onPressed: onRetry,
            ),
            const SizedBox(width: 2),
          ],
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
