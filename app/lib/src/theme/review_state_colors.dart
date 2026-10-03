import 'package:flutter/painting.dart';

import '../db/daily_reads.dart';
import 'colors.dart';

/// The one colour of each review state, shared by the Days dot and the header
/// chip: grey `OmColors.fg3`, green `OmColors.accentSoft`, amber
/// `OmColors.warn`.
Color reviewStateColor(ReviewState state) => switch (state) {
  ReviewState.unreviewed => OmColors.fg3,
  ReviewState.reviewed => OmColors.accentSoft,
  ReviewState.changedSinceReview => OmColors.warn,
};
