import 'package:material_ui/material_ui.dart';

import '../theme/colors.dart';
import '../theme/typography.dart';
import 'atoms.dart';

class PanelPlaceholderTab extends StatelessWidget {
  const PanelPlaceholderTab({
    super.key,
    required this.eyebrow,
    required this.subtitle,
    required this.empty,
    this.emptyKey,
    this.headerTrailing,
  });
  final String eyebrow;
  final String subtitle;
  final String empty;
  final Key? emptyKey;

  /// Shown at the header's trailing end (the Outline's keycap); null for the
  /// other tabs.
  final Widget? headerTrailing;
  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        PanelHeader(eyebrow: eyebrow, trailing: headerTrailing),
        if (subtitle.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
              subtitle,
              style: OmType.mono(size: 10.5, color: OmColors.fg2, height: 1.6),
            ),
          ),
        const OmHairline(),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
          child: Text(
            empty,
            key: emptyKey,
            textAlign: TextAlign.left,
            style: OmType.mono(size: 11, color: OmColors.fg2, height: 1.6),
          ),
        ),
      ],
    );
  }
}
