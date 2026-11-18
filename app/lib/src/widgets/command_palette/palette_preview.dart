// WI #76 (56-A2) stub; #78 fills it, #77's shell places it in the wide card.
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The preview pane for the selected row (Spec #59 req 29), drawn from
/// `paletteProvider`'s `preview`. Empty until #78 fills it.
class PalettePreview extends ConsumerWidget {
  const PalettePreview({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => const SizedBox.shrink();
}
