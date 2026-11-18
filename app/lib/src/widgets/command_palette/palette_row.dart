// WI #76 (56-A2, Spec #59 reqs 18, 25, 40; D17): one Command palette row and
// the palette's frozen Keys. Row presses belong to PaletteRow.
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/command_palette_state.dart';

/// The palette's frozen widget keys (#76). #77's and #78's tests find
/// widgets by these exact strings:
/// - [commandBar] `command-bar`, [palette] `command-palette`, [input]
///   `palette-input`;
/// - [group] `palette-group-<commands|notes|recent|passages>` (on the group
///   header);
/// - [row] `palette-row-command-<enum name>`,
///   `palette-row-<note|daily|canvas>-<id>`, `palette-row-passage-<chunk id>`
///   (PaletteRow keys itself);
/// - [passagesState] `palette-passages-<state>` (state names are #78's,
///   e.g. `searching`, `no-cli`, `memex-outdated`, `server-outdated`,
///   `error`, `model-not-downloaded`, `downloading`, `embeddings-off`,
///   `unavailable`), [download] `palette-download`, [preview]
///   `palette-preview`, [noMatches] `palette-no-matches`.
abstract final class PaletteKeys {
  static const commandBar = Key('');
  static const palette = Key('');
  static const input = Key('');
  static const download = Key('');
  static const preview = Key('');
  static const noMatches = Key('');

  /// The group header's key for [kind].
  static Key group(PaletteGroupKind kind) => const Key('');

  /// The row's key for [id].
  static Key row(PaletteItemId id) => const Key('');

  /// A Passages state row's key.
  static Key passagesState(String state) => const Key('');
}

/// One palette row (design pack 76): kind icon, title with
/// [PaletteItem.matched] characters in `accent`, meta; a passage adds up to 2
/// lines of passage text with its marks in `accentMark`. [selected] fills
/// `surface4`; [showEnterChip] (the list-only layout) adds the `↵` chip to a
/// selected row. Hover calls the palette's `hover(id)`; a press calls
/// `hover(id)` then `choose(newTab: <⌘ held at the press>)`. Semantics: a
/// button with the selected state, labelled `<title>, <meta>` (`<title>`
/// with no meta). Keys itself with [PaletteKeys.row].
class PaletteRow extends ConsumerWidget {
  const PaletteRow({
    super.key,
    required this.item,
    required this.selected,
    this.showEnterChip = false,
  });

  final PaletteItem item;
  final bool selected;
  final bool showEnterChip;

  @override
  Widget build(BuildContext context, WidgetRef ref) => const SizedBox.shrink();
}
