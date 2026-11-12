// WI #411 (pack #411 "Step", "Step note"): a numbered setup step on the
// Connect tab, and the notes under a step's snippet.
import 'package:flutter/widgets.dart';

import '../../../theme/colors.dart';
import '../../../theme/typography.dart';

/// One numbered step: an 18 px surface4 circle holding [number], then the
/// [title] (sans 13 w500 fg0) and the step's [children] below it.
class ConnectStep extends StatelessWidget {
  const ConnectStep({
    super.key,
    required this.number,
    required this.title,
    this.children = const [],
  });

  final int number;
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 18,
            height: 18,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              color: OmColors.surface4,
              shape: BoxShape.circle,
            ),
            child: Text(
              '$number',
              maxLines: 1,
              style: OmType.mono(
                size: 10.5,
                weight: FontWeight.w500,
                height: 1.0,
                color: OmColors.fg1,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  title,
                  style: OmType.sans(
                    size: 13,
                    weight: FontWeight.w500,
                    height: 1.4,
                    color: OmColors.fg0,
                  ),
                ),
                if (children.isNotEmpty) const SizedBox(height: 6),
                ...children,
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A note under a step's snippet: sans 12 fg2, line height 1.55, [top]
/// (6 px) above.
class ConnectStepNote extends StatelessWidget {
  const ConnectStepNote(this.text, {super.key, this.top = 6});

  final String text;

  /// The space above the note; 0 for a note right under a step's title.
  final double top;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(top: top),
      child: Text(
        text,
        style: OmType.sans(size: 12, height: 1.55, color: OmColors.fg2),
      ),
    );
  }
}
