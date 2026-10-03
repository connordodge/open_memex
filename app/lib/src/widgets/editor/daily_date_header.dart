import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../dates.dart';
import '../../db.dart';
import '../../state/daily_state.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';

/// A `role: daily` note's fixed date header (Key `daily-date-header`, Req 4,
/// 48): the note's date as `Saturday, 5 September 2026` in place of the
/// editable title, with a `Today` badge (Key `daily-today-badge`) while the
/// date is [todayDateProvider]'s. The badge comes and goes at local midnight.
/// Renders nothing for a note without `role: daily`.
class DailyDateHeader extends ConsumerWidget {
  const DailyDateHeader({super.key, required this.note});
  final Note note;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (note.role != 'daily') return const SizedBox.shrink();
    final date = parseIsoDate(note.title);
    final isToday = note.title == ref.watch(todayDateProvider);
    return Padding(
      key: const Key('daily-date-header'),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Wrap(
        spacing: 12,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            date == null ? note.title : formatDailyHeader(date),
            style: OmType.h1Serif(),
          ),
          if (isToday) const _TodayBadge(),
        ],
      ),
    );
  }
}

class _TodayBadge extends StatelessWidget {
  const _TodayBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('daily-today-badge'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: OmColors.successBg,
        border: Border.all(color: OmColors.accent.withAlpha(70), width: 1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        'Today',
        style: OmType.mono(
          size: 11,
          weight: FontWeight.w500,
          color: OmColors.accent,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}
