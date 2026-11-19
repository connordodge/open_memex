// WI #76 (56-A2, Spec #59 reqs 18, 25, 40; D17): one Command palette row and
// the palette's frozen Keys. Row presses belong to PaletteRow.
import 'dart:math' show max, min;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../state/command_palette_state.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';

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
  static const commandBar = Key('command-bar');
  static const palette = Key('command-palette');
  static const input = Key('palette-input');
  static const download = Key('palette-download');
  static const preview = Key('palette-preview');
  static const noMatches = Key('palette-no-matches');

  /// The group header's key for [kind].
  static Key group(PaletteGroupKind kind) => Key('palette-group-${kind.name}');

  /// The row's key for [id].
  static Key row(PaletteItemId id) =>
      Key('palette-row-${id.kind.name}-${id.id}');

  /// A Passages state row's key.
  static Key passagesState(String state) => Key('palette-passages-$state');
}

/// One palette row (design pack 76): kind icon, title with
/// [PaletteItem.matched] characters in `accent`, meta; a passage adds up to 2
/// lines of passage text with its marks in `accentMark`. [selected] fills
/// `surface4`; [showEnterChip] (the list-only layout) adds the `↵` chip to a
/// selected row. Pointer movement over the row calls the palette's
/// `hover(id)` (a rebuild under a resting pointer doesn't); a press calls
/// `hover(id)` then, only when that selected this row,
/// `choose(newTab: <⌘ held at the press>)`: a press on a row the palette no
/// longer lists chooses nothing. Semantics: a
/// button with the selected state, labelled `<title>, <meta>` (`<title>`
/// with no meta). Keys itself with [PaletteKeys.row]: don't give it that key
/// again.
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
  Widget build(BuildContext context, WidgetRef ref) {
    final item = this.item;
    final meta = item.meta;
    final chip = selected && showEnterChip;
    void press({required bool newTab}) {
      final palette = ref.read(paletteProvider.notifier);
      palette.hover(item.id);
      // A row the palette no longer lists (a regroup dropped it before this
      // frame rebuilt the list) chooses nothing, never the selected row.
      if (ref.read(paletteProvider).selected != item.id) return;
      palette.choose(newTab: newTab);
    }

    return KeyedSubtree(
      key: PaletteKeys.row(item.id),
      child: Semantics(
        container: true,
        button: true,
        selected: selected,
        label: [item.title, ?meta].join(', '),
        onTap: () => press(newTab: false),
        excludeSemantics: true,
        child: MouseRegion(
          onHover: (_) => ref.read(paletteProvider.notifier).hover(item.id),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            // The ⌘ flag is read at the press, here, never by the notifier.
            onTapUp: (_) =>
                press(newTab: HardwareKeyboard.instance.isMetaPressed),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: selected ? OmColors.surface4 : null,
                borderRadius: BorderRadius.circular(6),
              ),
              child: switch (item) {
                PassageItem() => _PassageBody(item, chip: chip),
                CommandItem() || NoteItem() => _LineBody(item, chip: chip),
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// A command, note, daily note or canvas row: one 32 px line.
class _LineBody extends StatelessWidget {
  const _LineBody(this.item, {required this.chip});

  final PaletteItem item;
  final bool chip;

  @override
  Widget build(BuildContext context) {
    final meta = item.meta;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 32),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Row(
          children: [
            _KindIcon(item),
            const SizedBox(width: 10),
            Expanded(
              child: Text.rich(
                _titleSpan(item.title, item.matched),
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (meta != null) ...[
              const SizedBox(width: 10),
              Text(meta, maxLines: 1, softWrap: false, style: _metaStyle()),
            ],
            if (chip) ...[const SizedBox(width: 10), const _EnterChip()],
          ],
        ),
      ),
    );
  }
}

/// A passage row: title and meta, then up to 2 lines of passage text.
class _PassageBody extends StatelessWidget {
  const _PassageBody(this.item, {required this.chip});

  final PassageItem item;
  final bool chip;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 7, 10, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: _KindIcon(item),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        item.title,
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.ellipsis,
                        style: OmType.sans(
                          size: 13,
                          weight: FontWeight.w500,
                          height: 16 / 13,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Text(
                        item.meta,
                        maxLines: 1,
                        softWrap: false,
                        style: _metaStyle(weight: FontWeight.w500),
                      ),
                    ),
                    if (chip) ...[
                      const SizedBox(width: 10),
                      const _EnterChip(),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text.rich(
                  _passageSpan(item.hit.snippet, item.marks),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The 14 px kind icon in `fg2`.
class _KindIcon extends StatelessWidget {
  const _KindIcon(this.item);

  final PaletteItem item;

  @override
  Widget build(BuildContext context) {
    final icon = switch (item) {
      CommandItem(:final command) => _commandIcon(command),
      NoteItem(kind: PaletteNoteKind.note) => LucideIcons.fileText,
      NoteItem(kind: PaletteNoteKind.daily) => LucideIcons.calendar,
      NoteItem(kind: PaletteNoteKind.canvas) => LucideIcons.layoutDashboard,
      PassageItem() => LucideIcons.textQuote,
    };
    return SizedBox.square(
      dimension: 14,
      child: Icon(icon, size: 14, color: OmColors.fg2),
    );
  }
}

IconData _commandIcon(PaletteCommand command) => switch (command) {
  PaletteCommand.newNote => LucideIcons.filePlus,
  PaletteCommand.newCanvas => LucideIcons.grid2x2Plus,
  PaletteCommand.attachFile => LucideIcons.paperclip,
  PaletteCommand.openToday => LucideIcons.calendarCheck,
  PaletteCommand.openVaultGraph => LucideIcons.network,
  PaletteCommand.switchVault => LucideIcons.arrowLeftRight,
  PaletteCommand.vaultSettings => LucideIcons.settings2,
  PaletteCommand.backups => LucideIcons.archive,
  PaletteCommand.agents => LucideIcons.bot,
  PaletteCommand.rightPanel => LucideIcons.panelRight,
  PaletteCommand.showDays => LucideIcons.calendarDays,
  PaletteCommand.showTopics => LucideIcons.listTree,
  PaletteCommand.showTags => LucideIcons.tag,
};

/// The selected row's `↵` chip (list-only layout).
class _EnterChip extends StatelessWidget {
  const _EnterChip();

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 23, minHeight: 18),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: OmColors.line3),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 5),
          child: Center(
            widthFactor: 1,
            heightFactor: 1,
            child: Text(
              '↵',
              maxLines: 1,
              softWrap: false,
              style: OmType.sans(
                size: 10.5,
                color: OmColors.fg2,
                height: 1.2,
                letterSpacing: 0.2,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

TextStyle _metaStyle({FontWeight weight = FontWeight.w400}) => OmType.mono(
  size: 10.5,
  weight: weight,
  color: OmColors.fg2,
  height: 13 / 10.5,
);

/// [title] in `fg0` with the [matched] characters in `accent`.
TextSpan _titleSpan(String title, List<int> matched) {
  final hits = matched.toSet();
  final accent = TextStyle(color: OmColors.accent);
  final runs = <TextSpan>[];
  var start = 0;
  for (var i = 1; i <= title.length; i++) {
    if (i == title.length || hits.contains(i) != hits.contains(start)) {
      runs.add(
        TextSpan(
          text: title.substring(start, i),
          style: hits.contains(start) ? accent : null,
        ),
      );
      start = i;
    }
  }
  return TextSpan(
    style: OmType.sans(size: 13.5, height: 16.06 / 13.5),
    children: runs,
  );
}

/// The passage [text] in `fg1` with its [marks] in `fg0` on `accentMark`.
TextSpan _passageSpan(String text, List<TextRange> marks) {
  final mark = TextStyle(
    color: OmColors.fg0,
    backgroundColor: OmColors.accentMark,
  );
  final sorted = [...marks]..sort((a, b) => a.start.compareTo(b.start));
  final runs = <TextSpan>[];
  var at = 0;
  for (final range in sorted) {
    final start = max(at, min(range.start, text.length));
    final end = min(range.end, text.length);
    if (end <= start) continue;
    if (start > at) runs.add(TextSpan(text: text.substring(at, start)));
    runs.add(TextSpan(text: text.substring(start, end), style: mark));
    at = end;
  }
  if (at < text.length) runs.add(TextSpan(text: text.substring(at)));
  return TextSpan(
    style: OmType.sans(size: 12, color: OmColors.fg1, height: 1.5),
    children: runs,
  );
}
