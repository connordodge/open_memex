// WI #77 (56-A3, Spec #59 reqs 13-16, TD5; D19): the Command palette's
// Notes and Recent source. Skeleton: no rows yet.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'command_palette_state.dart';

/// The palette's title read limit (D19): one named large positive
/// constant, never 0, -1 or null, so every note title is read.
const kPaletteTitleLimit = 1 << 30;

/// Fills #76's `paletteTitlesSourceProvider`: Recent (the 8 newest notes)
/// for the empty input, Notes (notes and canvases by fuzzy title, top 8)
/// for a typed one, from one `allTitles(limit: kPaletteTitleLimit)` read per
/// open, re-read on a `vaultRevisionProvider` change.
final Override paletteTitlesOverride = paletteTitlesSourceProvider.overrideWith(
  (ref) =>
      (_) => const [],
);
