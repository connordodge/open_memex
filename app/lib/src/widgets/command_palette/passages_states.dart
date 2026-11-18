// WI #76 (56-A2) stub; #78 fills it, #77's shell places it in the Passages
// part of the list.
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The Passages state row (Spec #59 reqs 31-33) when `paletteProvider`'s
/// `passages` lists no rows: its own header and state line. Empty until #78
/// fills it.
class PassagesStateRow extends ConsumerWidget {
  const PassagesStateRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => const SizedBox.shrink();
}

/// The Passages footer after the hit rows (req 31: the model-not-downloaded
/// footer and download button, downloading, embeddings off, unavailable).
/// Empty until #78 fills it.
class PassagesFooter extends ConsumerWidget {
  const PassagesFooter({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => const SizedBox.shrink();
}
