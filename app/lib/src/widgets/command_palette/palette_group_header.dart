// WI #76 (56-A2, Spec #59 reqs 12, 30): a Command palette group header.
import 'package:flutter/widgets.dart';

import '../../state/command_palette_state.dart';

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
  Widget build(BuildContext context) => const SizedBox.shrink();
}
