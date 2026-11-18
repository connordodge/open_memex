// WI #77 (56-A3, Spec #59 reqs 19-22): the Command palette's Commands
// source. Skeleton: no rows yet.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'command_palette_state.dart';

/// Fills #76's `paletteCommandsSourceProvider`: requirement 19's commands
/// available on the open vault (New note and New canvas only when
/// `VaultAccess.canWrite`), fuzzy-matched against the trimmed input, best
/// first, ties in fixed order. The right-panel label follows
/// `rightPanelOpenProvider`; Open today's meta is today's date; the current
/// sidebar mode's Show row has meta `shown`.
final Override paletteCommandsOverride = paletteCommandsSourceProvider
    .overrideWith(
      (ref) =>
          (_) => const [],
    );
