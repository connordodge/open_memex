// WI #76 (56-A2, Spec #59 reqs 12, 30): a Command palette group header.
import 'package:flutter/widgets.dart';

import '../../state/command_palette_state.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import 'palette_row.dart';

/// The eyebrow `COMMANDS · <n>` (`NOTES`, `RECENT`, `PASSAGES`; no ` · <n>`
/// when [count] is null) with an optional right-hand [hint]. Keys itself
/// with `PaletteKeys.group(kind)`.
class PaletteGroupHeader extends StatelessWidget {
  const PaletteGroupHeader({
    super.key,
    required this.kind,
    this.count,
    this.hint,
  });

  final PaletteGroupKind kind;
  final int? count;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final count = this.count;
    final hint = this.hint;
    return ConstrainedBox(
      key: PaletteKeys.group(kind),
      constraints: const BoxConstraints(minHeight: 30),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 4),
        child: Row(
          children: [
            Expanded(
              child: Text(
                [
                  kind.name.toUpperCase(),
                  if (count != null) '$count',
                ].join(' · '),
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
                style: OmType.mono(
                  size: 11,
                  weight: FontWeight.w500,
                  color: OmColors.fg2,
                  height: 14 / 11,
                  letterSpacing: 1,
                ),
              ),
            ),
            if (hint != null)
              Text(
                hint,
                maxLines: 1,
                softWrap: false,
                style: OmType.mono(
                  size: 10.5,
                  color: OmColors.fg2,
                  height: 13 / 10.5,
                  letterSpacing: 0.2,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
