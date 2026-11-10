// WI #349 (Spec #347 req 18, TD7): the shared keyboard dialog button, moved
// from the restore dialog's `_DialogButton` with an `autofocus` option.
import 'package:flutter/widgets.dart';

import '../theme/colors.dart';
import 'atoms.dart';

/// An [OmButton] that works from the keyboard: it takes focus (Tab), Enter
/// and Space press it, and it reads as a labelled button. A disabled one
/// keeps its focus, so a failed run leaves the focus where it was.
/// [autofocus] gives it the focus when its route first shows.
class DialogButton extends StatefulWidget {
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
  State<DialogButton> createState() => _DialogButtonState();
}

class _DialogButtonState extends State<DialogButton> {
  bool _highlight = false;

  late final Map<Type, Action<Intent>> _actions = {
    ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: _press),
    ButtonActivateIntent: CallbackAction<ButtonActivateIntent>(
      onInvoke: _press,
    ),
  };

  Object? _press(Intent _) {
    widget.onPressed?.call();
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return FocusableActionDetector(
      autofocus: widget.autofocus,
      actions: _actions,
      onShowFocusHighlight: (v) => setState(() => _highlight = v),
      child: Semantics(
        button: true,
        enabled: widget.onPressed != null,
        label: widget.label,
        onTap: widget.onPressed,
        excludeSemantics: true,
        child: DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: BoxDecoration(
            border: _highlight ? Border.all(color: OmColors.accentSoft) : null,
            borderRadius: BorderRadius.circular(6),
          ),
          child: OmButton(
            kind: widget.kind,
            icon: widget.icon,
            label: widget.label,
            onPressed: widget.onPressed,
          ),
        ),
      ),
    );
  }
}
