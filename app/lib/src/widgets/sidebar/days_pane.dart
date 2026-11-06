import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../db/daily_reads.dart';
import '../../state/daily_state.dart';
import '../../state/days_list.dart';
import '../../state/tabs_state.dart';
import '../../theme/colors.dart';
import '../../theme/review_state_colors.dart';
import '../../theme/typography.dart';
import '../../vault_access/vault_async_view.dart';
import '../atoms.dart';

/// The sidebar's Days mode (Req 49, Key `days-pane`): the `Today` row
/// (`days-row-today`) first, then the daily notes grouped by month newest
/// first (`days-month-<yyyy-mm>` headers, `days-row-<yyyy-mm-dd>` rows). With
/// no saved daily notes the `Today` row is followed by the empty copy
/// (`days-empty`, Req 53).
///
/// Rebuilds on every vault revision (through `dailyNotesAsyncProvider`,
/// rendered by `VaultAsyncView`: a reload keeps the previous rows, a hosted
/// first load shows the loading state in place of the pane) and at local
/// midnight (through `todayDateProvider`), when a new `Today` row appears and
/// yesterday's row shows its date. Fills the bounded height its parent gives
/// it.
class DaysPane extends ConsumerWidget {
  const DaysPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      VaultAsyncView<List<DailyNoteRow>>(
        value: ref.watch(dailyNotesAsyncProvider),
        empty: const <DailyNoteRow>[],
        builder: (c, notes) => _build(c, ref, notes),
      );

  Widget _build(BuildContext context, WidgetRef ref, List<DailyNoteRow> notes) {
    final list = buildDaysList(notes, today: ref.watch(todayDateProvider));
    final activeTab = ref.watch(activeTabProvider);
    final today = list.today;
    final todayTab = switch (today.note) {
      final note? => NoteTab(note.noteId),
      null => VirtualTodayTab(today.date),
    };

    return ListView(
      key: const Key('days-pane'),
      padding: const EdgeInsets.fromLTRB(6, 2, 6, 12),
      children: [
        _DayRow(
          key: const Key('days-row-today'),
          label: 'Today',
          note: today.note,
          active: activeTab == todayTab,
          onTap: () => ref
              .read(tabsProvider.notifier)
              .openToday(date: today.date, noteId: today.note?.noteId),
        ),
        if (today.isVirtual && list.groups.isEmpty) const _EmptyDays(),
        for (final group in list.groups) ...[
          _MonthHeader(key: Key('days-month-${group.month}'), group.header),
          for (final row in group.rows)
            _DayRow(
              key: Key('days-row-${row.date}'),
              label: row.date,
              note: row,
              active: activeTab == NoteTab(row.noteId),
              onTap: () =>
                  ref.read(tabsProvider.notifier).follow(NoteTab(row.noteId)),
            ),
        ],
      ],
    );
  }
}

/// One Days row: [label] (`Today` or the ISO date), the review dot and the
/// one-line preview of [note]. A row without a [note] (the virtual Today
/// note) has neither.
class _DayRow extends StatelessWidget {
  const _DayRow({
    super.key,
    required this.label,
    required this.note,
    required this.active,
    required this.onTap,
  });

  final String label;
  final DailyNoteRow? note;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final preview = note?.preview ?? '';
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
          decoration: BoxDecoration(
            color: active ? OmColors.surface4 : Colors.transparent,
            borderRadius: BorderRadius.circular(5),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      label,
                      style: OmType.mono(
                        size: 12,
                        color: active ? OmColors.fg0 : OmColors.fg1,
                      ),
                    ),
                  ),
                  if (note case final n?)
                    _ReviewDot(date: n.date, state: n.reviewState),
                ],
              ),
              if (preview.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  preview,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: OmType.sans(size: 12.5, color: OmColors.fg2),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The review dot of the daily note of [date] (Req 20, Key
/// `days-dot-<date>`): the colour of [state] from the theme helper, and the
/// state's label for screen readers, so colour is never the only signal.
class _ReviewDot extends StatelessWidget {
  const _ReviewDot({required this.date, required this.state});

  final String date;
  final ReviewState state;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      key: Key('days-dot-$date'),
      label: state.label,
      child: OmDot(color: reviewStateColor(state), size: 7),
    );
  }
}

/// A month group header, e.g. `October 2026` (drawn upper-case).
class _MonthHeader extends StatelessWidget {
  const _MonthHeader(this.header, {super.key});

  final String header;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 14, 10, 4),
      child: Align(alignment: Alignment.centerLeft, child: Eyebrow(header)),
    );
  }
}

/// The empty Days copy (Req 53), shown under the `Today` row when the vault
/// has no saved daily notes.
class _EmptyDays extends StatelessWidget {
  const _EmptyDays();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
      child: Text(
        "Start typing in today's note.",
        key: const Key('days-empty'),
        style: OmType.mono(size: 11.5, color: OmColors.fg3),
      ),
    );
  }
}
