// WI #411 (Spec #394 req 13, 29; pack #411 "Not on the board", RULINGS
// #17): the Claude Desktop pane's setup status line and its `Check again`.
import 'package:flutter/widgets.dart';

import '../../../agents_sheet/connect/claude_config_match.dart';
import '../../../theme/colors.dart';
import '../../../theme/typography.dart';
import '../../atoms.dart';

/// [setup]'s status line (CM's exact copy) in sans 12.5 fg1, never an
/// error colour, after a 7 px dot (accent when Claude Desktop is set up
/// for this vault, fg2 otherwise), with a `Check again` ghost button on the
/// right.
class ConnectDetectionLine extends StatelessWidget {
  const ConnectDetectionLine({
    super.key,
    required this.setup,
    required this.onCheckAgain,
  });

  final ClaudeDesktopSetup setup;
  final VoidCallback onCheckAgain;

  @override
  Widget build(BuildContext context) {
    final setUp = switch (setup) {
      ClaudeDesktopLocalMatch() || ClaudeDesktopHostedMatch() => true,
      _ => false,
    };
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Row(
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              color: setUp ? OmColors.accent : OmColors.fg2,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              setup.statusText,
              style: OmType.sans(size: 12.5, height: 1.5, color: OmColors.fg1),
            ),
          ),
          const SizedBox(width: 8),
          OmButton(
            onPressed: onCheckAgain,
            kind: OmButtonKind.ghost,
            size: 24,
            dense: true,
            focusable: true,
            label: 'Check again',
          ),
        ],
      ),
    );
  }
}
