import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../dates.dart';
import '../../db.dart';
import '../../db/daily_reads.dart';
import '../../state/daily_state.dart';
import '../../state/vault_state.dart';
import '../../theme/colors.dart';
import '../../theme/review_state_colors.dart';
import '../../theme/typography.dart';
import '../right_panel.dart';

/// Read-only chip in the daily note header: `Unreviewed`, `Reviewed` or
/// `Changed since review`. Hover shows when the agent last reviewed; a tap
/// opens the right panel's Activity tab. Renders nothing for a note that is
/// not a daily note, or on a vault below V5.
class ReviewChip extends ConsumerWidget {
  const ReviewChip({super.key, required this.note});
  final Note note;

  static Color _fill(ReviewState state) => switch (state) {
    ReviewState.unreviewed => OmColors.surface3,
    ReviewState.reviewed => OmColors.successBg,
    ReviewState.changedSinceReview => OmColors.warnBg,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final info = note.role == 'daily'
        ? watchVaultValue<ReviewInfo?>(
            ref,
            reviewStateAsyncProvider(note.id),
            null,
          )
        : null;
    if (info == null) return const SizedBox.shrink();

    final color = reviewStateColor(info.state);
    final reviewedAt = info.reviewedAt;
    final chip = MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        key: const Key('review-chip'),
        behavior: HitTestBehavior.opaque,
        onTap: () {
          ref.read(rightPanelOpenProvider.notifier).state = true;
          ref.read(rightPanelTabProvider.notifier).state =
              RightPanelTab.activity;
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: _fill(info.state),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            info.state.label,
            style: OmType.mono(size: 10.5, color: color),
          ),
        ),
      ),
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Align(
        alignment: Alignment.centerLeft,
        child: reviewedAt == null
            ? chip
            : Tooltip(
                message: formatReviewedAt(
                  DateTime.fromMillisecondsSinceEpoch(reviewedAt),
                ),
                child: chip,
              ),
      ),
    );
  }
}
