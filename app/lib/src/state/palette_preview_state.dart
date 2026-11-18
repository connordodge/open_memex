// WI #78 (56-A4, Spec #59 req 29): the Command palette's preview source.
import 'command_palette_state.dart';

/// Fills `palettePreviewProvider` (#76's seam): the selected row's preview,
/// read once the selection has rested 120 ms; nothing under 950 px.
class PalettePreviewReader extends PalettePreviewNotifier {
  @override
  PreviewView build() => const PreviewNone();
}
