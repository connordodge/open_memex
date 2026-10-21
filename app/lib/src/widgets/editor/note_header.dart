import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../db.dart';
import '../../state/tabs_state.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import 'daily_date_header.dart';
import 'review_chip.dart';

/// The top of an open note (Key `note-header`): the meta rail, the
/// [DailyDateHeader] slot, the title field (Key `editor-title`), the
/// [ReviewChip] slot and the tags.
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
        if (note.role != 'daily')
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
        if (note.tags.isNotEmpty) ...[
          const SizedBox(height: 12),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final t in note.tags)
                Text(
                  '#$t',
                  style: OmType.mono(size: 12, color: OmColors.accentSoft),
                ),
            ],
          ),
        ],
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

class _MetaRail extends StatelessWidget {
  const _MetaRail({required this.note});
  final Note note;
  @override
  Widget build(BuildContext context) {
    final updated = formatUpdatedAgo(note.updatedAt, now: DateTime.now());
    final words = noteWordCount(note.contentMd);
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
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(LucideIcons.clock, size: 11, color: OmColors.fg3),
              const SizedBox(width: 5),
              Text(
                'updated $updated',
                style: OmType.mono(size: 11, color: OmColors.fg3),
              ),
            ],
          ),
          Text('·', style: OmType.mono(size: 11, color: OmColors.fg4)),
          Text(
            '$words words',
            style: OmType.mono(size: 11, color: OmColors.fg3),
          ),
        ],
      ),
    );
  }
}

/// How long before [now] the time [unixMs] was, as the meta rail shows it
/// ("just now", "5 minutes ago", "1 hour ago", "3 days ago").
@visibleForTesting
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

/// The number of whitespace-separated words in [s].
@visibleForTesting
int noteWordCount(String s) {
  final words = s.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
  return words.length;
}
