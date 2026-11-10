// WI #349 (Spec #347 req 18, TD7): the shared keyboard dialog button.
// SKELETON (test author, red mode): the signature only; the implementer
// moves restore_dialog.dart's `_DialogButton` here.
import 'package:flutter/widgets.dart';

import 'atoms.dart';

/// An [OmButton] that works from the keyboard: it takes focus (Tab), Enter
/// and Space press it, and it reads as a labelled button. A disabled one
/// keeps its focus, so a failed run leaves the focus where it was.
/// [autofocus] gives it the focus when its route first shows.
class DialogButton extends StatelessWidget {
  const DialogButton({
    super.key,
    required this.kind,
    required this.label,
    required this.onPressed,
    this.icon,
    this.autofocus = false,
  });

  final OmButtonKind kind;
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool autofocus;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
