import 'package:flutter/material.dart';

import '../../db.dart';
import '../../editor/segments.dart';
import '../../state/tabs_state.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import 'daily_date_header.dart';
import 'review_chip.dart';

/// The top of an open note (Key `note-header`): the meta rail, the
/// [DailyDateHeader] slot, the title field (Key `editor-title`) and the
/// [ReviewChip] slot.
///
/// A `role: daily` note's [DailyDateHeader] replaces the title field: its
/// title is not editable (Req 49). The unsaved virtual Today note has no
/// meta rail and no review chip.
///
/// While the note's hosted save waits for the vault server (#102) the meta
/// rail shows only [pendingLabel] (Key `pending-save-label`, board A11
/// state 1), also for the virtual Today note.
class NoteHeader extends StatelessWidget {
  const NoteHeader({
    super.key,
    required this.note,
    required this.titleCtrl,
    required this.onTitleChanged,
    this.pendingLabel,
  });
  final Note note;
  final TextEditingController titleCtrl;
  final ValueChanged<String> onTitleChanged;

  /// `not saved yet · will save when <server> is back`, or null.
  final String? pendingLabel;

  @override
  Widget build(BuildContext context) {
    // The unsaved virtual Today note was never updated or reviewed.
    final saved = VirtualTodayTab.dateOf(note.id) == null;
    return Column(
      key: const Key('note-header'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (pendingLabel case final label?)
          _PendingRail(label: label)
        else if (saved)
          _MetaRail(note: note),
        const SizedBox(height: 18),
        DailyDateHeader(note: note),
        if (note.role == 'guide')
          // The Vault Guide keeps its name: the title is shown, not edited.
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              key: const Key('guide-title'),
              note.title,
              style: OmType.h1Serif(),
            ),
          )
        else if (note.role != 'daily')
          TextField(
            key: const Key('editor-title'),
            controller: titleCtrl,
            style: OmType.h1Serif(),
            cursorColor: OmColors.accent,
            decoration: InputDecoration(
              hintText: 'Untitled',
              hintStyle: OmType.serif(
                size: 36,
                color: OmColors.fg3,
                weight: FontWeight.w500,
              ),
            ),
            onChanged: onTitleChanged,
          ),
        if (saved) ReviewChip(note: note),
      ],
    );
  }
}

/// The meta rail of a note whose hosted save is queued: the warn mono
/// label alone, in the rail's container (pack 102).
class _PendingRail extends StatelessWidget {
  const _PendingRail({required this.label});
  final String label;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: OmColors.line1, width: 1)),
      ),
      child: Text(
        label,
        key: const Key('pending-save-label'),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: OmType.mono(size: 11, color: OmColors.warn),
      ),
    );
  }
}

/// The meta rail: when the note was updated and its word count. A note's tags
/// are listed only in the Note footer (`FooterChipBar`, Connor 2026-11-09).
class _MetaRail extends StatelessWidget {
  const _MetaRail({required this.note});
  final Note note;
  @override
  Widget build(BuildContext context) {
    final updated = formatUpdatedAgo(note.updatedAt, now: DateTime.now());
    final words = noteWordCount(_personSection(note));
    final style = OmType.mono(size: 11, color: OmColors.fg2);
    return Container(
      padding: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: OmColors.line1, width: 1)),
      ),
      child: Wrap(
        spacing: 14,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text('updated $updated', style: style),
          Text('·', style: style),
          Text('$words words', style: style),
        ],
      ),
    );
  }
}

/// The text of [note] a person wrote: what the editor shows as text and cards,
/// without the footer's marker, chip and tag lines. A guide note has no footer,
/// so a marker line in it is text like any other.
String _personSection(Note note) => switch (note.role) {
  'daily' => splitDailyBody(note.contentMd).person,
  'guide' => note.contentMd,
  _ => splitNoteBody(note.contentMd).person,
};

/// How long before [now] the time [unixMs] was, as the meta rail shows it
/// ("just now", "5 minutes ago", "1 hour ago", "3 days ago").
String formatUpdatedAgo(int unixMs, {required DateTime now}) {
  final delta = now.millisecondsSinceEpoch - unixMs;
  if (delta < 60 * 1000) return 'just now';
  final m = delta ~/ 60000;
  if (m < 60) return '$m minute${m == 1 ? '' : 's'} ago';
  final h = m ~/ 60;
  if (h < 24) return '$h hour${h == 1 ? '' : 's'} ago';
  final d = h ~/ 24;
  return '$d day${d == 1 ? '' : 's'} ago';
}

/// How many days before [now]'s local date the daily note of ISO date [day]
/// (`YYYY-MM-DD`) is, as an echo row shows it (Spec #391 req 26): `today`,
/// `yesterday`, `N days ago` (2-13), `N weeks ago` (14-59, d ~/ 7),
/// `N months ago` (60-364, d ~/ 30), `N years ago` (d ~/ 365). Counted in
/// calendar days, so the time of day and DST changes never move it.
String formatDayAgo(String day, {required DateTime now}) {
  final parsed = DateTime.parse(day);
  // UTC dates are whole days apart whatever the local zone's DST changes.
  final today = DateTime.utc(now.year, now.month, now.day);
  final then = DateTime.utc(parsed.year, parsed.month, parsed.day);
  final d = today.difference(then).inDays;
  if (d <= 0) return 'today';
  if (d == 1) return 'yesterday';
  if (d < 14) return '$d days ago';
  return _longAgo(d);
}

/// How long before [now] the time [unixMs] was, on [formatUpdatedAgo]'s
/// scale up to 13 days, then `N weeks ago` (14-59 days, d ~/ 7),
/// `N months ago` (60-364, d ~/ 30) and `N years ago` (d ~/ 365): the
/// relative age of a non-daily echo (Spec #391 req 26).
String formatRelativeAgo(int unixMs, {required DateTime now}) {
  final d =
      (now.millisecondsSinceEpoch - unixMs) ~/ Duration.millisecondsPerDay;
  if (d < 14) return formatUpdatedAgo(unixMs, now: now);
  return _longAgo(d);
}

/// [days] (14 or more) in whole weeks under 60, 30-day months under 365,
/// and 365-day years from then on.
String _longAgo(int days) {
  String unit(int n, String name) => '$n $name${n == 1 ? '' : 's'} ago';
  if (days < 60) return unit(days ~/ 7, 'week');
  if (days < 365) return unit(days ~/ 30, 'month');
  return unit(days ~/ 365, 'year');
}

/// The number of whitespace-separated words in [s].
@visibleForTesting
int noteWordCount(String s) {
  final words = s.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
  return words.length;
}
