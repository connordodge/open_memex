// WI #78 (56-A4, Spec #59 reqs 17-18, 28, 30-33, 42): the Command palette's
// Passages runner, passage chooser and the overrides that fill #76's seam.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'command_palette_state.dart';
import 'palette_preview_state.dart';

/// Fills `palettePassagesProvider` (#76's seam): the debounced, queued
/// `search` runs behind the Passages group.
class PalettePassagesRunner extends PalettePassagesNotifier {
  @override
  PassagesView build() => const PassagesIdle();
}

/// The overrides that fill #76's Passages, preview and passage chooser
/// seams, spread into `appRootOverrides` (lead ruling W1).
final List<Override> palettePassagesOverrides = [
  palettePassagesProvider.overrideWith(PalettePassagesRunner.new),
  palettePreviewProvider.overrideWith(PalettePreviewReader.new),
  palettePassageChooserProvider.overrideWith(
    (ref) => (item, {required newTab}) {},
  ),
];
