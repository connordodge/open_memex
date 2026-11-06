import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../db/tags_reads.dart';
import '../../state/tabs_state.dart';
import '../../state/tags_browse_state.dart';
import '../../state/tags_state.dart';
import '../../state/vault_state.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../vault_access/vault_async_view.dart';
import '../../vault_access/vault_scoped.dart';
import '../atoms.dart';

/// The Tags empty-state copy (design pack 251, B2 cells 4, 5 and 7).
const _emptyCopy = 'No tags yet. Type #name in any note to tag it.';

/// A tag row is at least this high; it grows with the text scale.
const _rowHeight = 24.0;

/// Left padding of a top-level tag row and of the System row.
const _rowLeft = 10.0;

/// Left padding of a tag row inside the System group (16 more).
const _systemChildLeft = 26.0;

/// Left padding of a note row under a top-level tag, and under a system tag
/// (16 more).
const _noteLeft = 26.0;
const _systemNoteLeft = 42.0;

/// Top padding of the list.
const _listTop = 4.0;

/// Scroll attempts for a `revealTag` request before it is dropped.
const _maxScrollAttempts = 4;

/// The sidebar's Tags mode (Key `tags-pane`, WI #251): the non-system tags
/// alphabetically with their note counts, then a collapsed `SYSTEM` group.
///
/// One tag at a time is expanded (`expandedTagProvider`); its notes sit
/// directly under its row, newest first. A tag row click only expands or
/// collapses; a note row click records `follow(NoteTab(id))`. With no
/// non-system tags the empty state (`tags-empty`) shows above `SYSTEM`. A
/// failed first load shows the empty state too, as the Topics pane does.
///
/// Serves the scroll request `revealTag` leaves (`tagsScrollRequestProvider`)
/// once the tag's row can be found. Fills the bounded height its parent
/// gives it and scrolls.
class TagsPane extends ConsumerStatefulWidget {
  const TagsPane({super.key});

  @override
  ConsumerState<TagsPane> createState() => _TagsPaneState();
}

class _TagsPaneState extends ConsumerState<TagsPane> {
  final _scroll = ScrollController();

  /// The row of the tag a scroll request is waiting for.
  final _targetKey = GlobalKey();
  bool _serveScheduled = false;
  int _attempts = 0;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final value = ref.watch(tagsAsyncProvider);
    final loaded =
        currentVaultData(value, ref.watch(currentVaultProvider)) != null;
    final request = ref.watch(tagsScrollRequestProvider);
    // Start the open tag's notes read now: its row may be far down the lazy
    // list and not built for a while (`revealTag`).
    final open = ref.watch(expandedTagProvider);
    if (open != null) ref.watch(notesForTagAsyncProvider(open));
    return VaultAsyncView<List<TagRow>>(
      value: value,
      empty: const <TagRow>[],
      builder: (context, rows) {
        final plain = [
          for (final r in rows)
            if (!r.system) r,
        ];
        final system = [
          for (final r in rows)
            if (r.system) r,
        ];
        if (request != null) _scheduleServe(request, plain, system, loaded);
        return _buildList(plain, system, request?.tag);
      },
    );
  }

  Widget _buildList(List<TagRow> plain, List<TagRow> system, String? target) {
    final expanded = ref.watch(expandedTagProvider);
    final systemOpen = ref.watch(tagsSystemOpenProvider);

    Widget tagItem(TagRow row, {required bool inSystem}) {
      final open = expanded == row.tag;
      Widget tile = _TagRowTile(
        key: Key('tag-row-${row.tag}'),
        left: inSystem ? _systemChildLeft : _rowLeft,
        open: open,
        label: Text(
          '#${row.tag}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: OmType.mono(
            size: 12,
            height: 16 / 12,
            color: open ? OmColors.accentSoft : OmColors.fg1,
          ),
        ),
        count: row.noteCount,
        onTap: () => ref.read(expandedTagProvider.notifier).toggle(row.tag),
      );
      if (row.tag == target) tile = KeyedSubtree(key: _targetKey, child: tile);
      if (!open) return tile;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          tile,
          _TagNotes(tag: row.tag, left: inSystem ? _systemNoteLeft : _noteLeft),
        ],
      );
    }

    final items = <Widget>[
      if (plain.isEmpty) const _EmptyTags(),
      for (final row in plain) tagItem(row, inSystem: false),
      if (system.isNotEmpty)
        Padding(
          padding: EdgeInsets.only(top: plain.isEmpty ? 0 : 8),
          child: _TagRowTile(
            key: const Key('tags-system-row'),
            left: _rowLeft,
            open: systemOpen,
            label: const Align(
              alignment: Alignment.centerLeft,
              child: Eyebrow('system'),
            ),
            count: system.length,
            onTap: () =>
                ref.read(tagsSystemOpenProvider.notifier).state = !systemOpen,
          ),
        ),
      if (system.isNotEmpty && systemOpen)
        for (final row in system) tagItem(row, inSystem: true),
    ];
    return ListView.builder(
      key: const Key('tags-pane'),
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(6, _listTop, 6, 12),
      itemCount: items.length,
      itemBuilder: (_, i) => items[i],
    );
  }

  void _scheduleServe(
    TagScrollRequest request,
    List<TagRow> plain,
    List<TagRow> system,
    bool loaded,
  ) {
    if (_serveScheduled) return;
    _serveScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _serveScheduled = false;
      if (!mounted) return;
      _serve(request, plain, system, loaded);
    });
  }

  /// Brings the row of [request]'s tag into view, then drops the request. The
  /// row may be far down the lazy list and not built yet: jump near it first
  /// and look again after the next frame.
  void _serve(
    TagScrollRequest request,
    List<TagRow> plain,
    List<TagRow> system,
    bool loaded,
  ) {
    final requests = ref.read(tagsScrollRequestProvider.notifier);
    // A newer request replaced this one: that build serves it.
    if (!identical(requests.state, request)) return;
    // The first read has not landed: the rows are not known yet.
    if (!loaded) return;
    final index = plain.indexWhere((r) => r.tag == request.tag);
    final inSystem = system.any((r) => r.tag == request.tag);
    if (index < 0 && !inSystem) {
      requests.state = null;
      return;
    }
    final target = _targetKey.currentContext;
    if (target != null) {
      Scrollable.ensureVisible(target, duration: Duration.zero);
      _attempts = 0;
      requests.state = null;
      return;
    }
    if (_attempts >= _maxScrollAttempts || !_scroll.hasClients) {
      _attempts = 0;
      requests.state = null;
      return;
    }
    _attempts++;
    final position = _scroll.position;
    final extent = max(_rowHeight, MediaQuery.textScalerOf(context).scale(16));
    // Rows above a top-level tag are all collapsed tag rows (one tag is open
    // at a time, and it is this one); a system tag is below everything.
    final estimate = index >= 0 ? _listTop + index * extent : double.infinity;
    _scroll.jumpTo(
      min(max(estimate, position.minScrollExtent), position.maxScrollExtent),
    );
    // The jump built the rows around the target: look again.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _serve(request, plain, system, loaded);
    });
  }
}

/// A tag-style row (`tag-row-<tag>` and the `SYSTEM` row): chevron, [label]
/// and the right-aligned [count]. At least 24 px high and the full width of
/// the list; a click anywhere on it calls [onTap].
class _TagRowTile extends StatelessWidget {
  const _TagRowTile({
    super.key,
    required this.left,
    required this.open,
    required this.label,
    required this.count,
    required this.onTap,
  });

  final double left;
  final bool open;
  final Widget label;
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: _rowHeight),
          padding: EdgeInsets.only(left: left, right: _rowLeft),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(4)),
          child: Row(
            children: [
              Icon(
                open ? LucideIcons.chevronDown : LucideIcons.chevronRight,
                size: 11,
                color: OmColors.fg2,
              ),
              const SizedBox(width: 5),
              Expanded(child: label),
              const SizedBox(width: 6),
              Text(
                '$count',
                maxLines: 1,
                style: OmType.mono(
                  size: 11,
                  height: 16 / 11,
                  color: OmColors.fg2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The notes of an expanded tag, newest first, directly under its row. Reads
/// `notesForTagAsyncProvider`; until the first read lands (or when it fails)
/// there are no rows.
class _TagNotes extends ConsumerWidget {
  const _TagNotes({required this.tag, required this.left});

  final String tag;
  final double left;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scoped = currentVaultData(
      ref.watch(notesForTagAsyncProvider(tag)),
      ref.watch(currentVaultProvider),
    );
    final notes = scoped?.value ?? const <TagNoteRow>[];
    final activeTab = ref.watch(activeTabProvider);
    final activeId = activeTab is NoteTab ? activeTab.id : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final note in notes)
          _TagNoteRowTile(
            key: Key('tag-note-row-$tag-${note.noteId}'),
            left: left,
            title: note.title,
            firstLine: note.firstLine,
            active: note.noteId == activeId,
            onTap: () =>
                ref.read(tabsProvider.notifier).follow(NoteTab(note.noteId)),
          ),
      ],
    );
  }
}

/// A note row: the title, and under it the first line holding the tag when
/// there is one (36 px; 22 px with the title only).
class _TagNoteRowTile extends StatelessWidget {
  const _TagNoteRowTile({
    super.key,
    required this.left,
    required this.title,
    required this.firstLine,
    required this.active,
    required this.onTap,
  });

  final double left;
  final String title;
  final String? firstLine;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final line = firstLine;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          padding: EdgeInsets.fromLTRB(left, 3, _rowLeft, 3),
          decoration: BoxDecoration(
            color: active ? OmColors.surface4 : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: OmType.mono(
                  size: 11.5,
                  height: 16 / 11.5,
                  color: active ? OmColors.fg0 : OmColors.fg1,
                ),
              ),
              if (line != null && line.isNotEmpty)
                Text(
                  line,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: OmType.mono(
                    size: 10.5,
                    height: 14 / 10.5,
                    color: OmColors.fg2,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The Tags empty state (Key `tags-empty`).
class _EmptyTags extends StatelessWidget {
  const _EmptyTags();

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: const Key('tags-empty'),
      padding: const EdgeInsets.all(10),
      child: Text(
        _emptyCopy,
        style: OmType.mono(size: 11, height: 17 / 11, color: OmColors.fg2),
      ),
    );
  }
}
