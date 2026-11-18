// The right panel's Outline tab (Spec #58, WI #68): design B "Mono tree".
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../editor/outline.dart';
import '../../state/outline_state.dart';
import '../../theme/colors.dart';
import '../../vault_access/vault_async_view.dart';
import '../atoms.dart';
import '../panel_placeholder_tab.dart';
import 'outline_row.dart';

const _eyebrow = 'outline · this note';
const _noNote = 'open a note to see its outline.';
const _noHeadings = 'no headings yet — start a line with # to add one.';

/// What the tab shows while the editor's note is still loading on a local
/// vault (or failed to load): the header alone, never another state's copy.
const _pending = NoteOutline(noteId: '', content: '', entries: []);

/// The `outline` tab body: the editor's note's entries, or a placeholder.
///
/// - No note open: the header and `open a note to see its outline.`
/// - A note with no headings: the header and the no headings copy (Key
///   `outline-empty`).
/// - Otherwise the header with the entry count and the [OutlineList].
/// - A hosted note still loading: the shared loading state.
///
/// The header always carries the `⌘⇧O` keycap.
class OutlineTab extends ConsumerWidget {
  const OutlineTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return VaultAsyncView<NoteOutline?>(
      value: ref.watch(outlineProvider),
      empty: _pending,
      builder: (context, outline) {
        if (identical(outline, _pending)) {
          return const Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PanelHeader(eyebrow: _eyebrow, trailing: _Keycap()),
              OmHairline(),
            ],
          );
        }
        if (outline == null) {
          return const PanelPlaceholderTab(
            eyebrow: _eyebrow,
            subtitle: '',
            empty: _noNote,
            headerTrailing: _Keycap(),
          );
        }
        if (outline.entries.isEmpty) {
          return const PanelPlaceholderTab(
            eyebrow: _eyebrow,
            subtitle: '',
            empty: _noHeadings,
            emptyKey: Key('outline-empty'),
            headerTrailing: _Keycap(),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PanelHeader(
              eyebrow: _eyebrow,
              count: outline.entries.length,
              trailing: const _Keycap(),
            ),
            const OmHairline(),
            Expanded(child: OutlineList(entries: outline.entries)),
          ],
        );
      },
    );
  }
}

/// The header's `⌘⇧O` keycap: [OmKbd] in a 1 px line2 box.
class _Keycap extends StatelessWidget {
  const _Keycap();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        border: Border.all(color: OmColors.line2),
        borderRadius: BorderRadius.circular(3),
      ),
      child: const OmKbd('⌘⇧O'),
    );
  }
}

/// The Outline's scrolling list of entries (Key `outline-list`), one row per
/// entry (Key `outline-entry-<index>`, the whole row's click target).
///
/// [currentIndex] is the current section's row, [focusedIndex] the row with
/// keyboard focus; [onActivate] runs with a row's entry when it is tapped.
class OutlineList extends StatelessWidget {
  const OutlineList({
    super.key,
    required this.entries,
    this.currentIndex,
    this.focusedIndex,
    this.onActivate,
  });

  final List<OutlineEntry> entries;
  final int? currentIndex;
  final int? focusedIndex;
  final void Function(OutlineEntry entry)? onActivate;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      key: const Key('outline-list'),
      padding: const EdgeInsets.only(top: 6, bottom: 12),
      itemCount: entries.length,
      itemBuilder: (context, i) => OutlineRow(
        key: Key('outline-entry-$i'),
        entry: entries[i],
        current: i == currentIndex,
        focused: i == focusedIndex,
        onActivate: onActivate,
      ),
    );
  }
}
