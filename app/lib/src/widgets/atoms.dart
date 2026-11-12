import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/colors.dart';
import '../theme/typography.dart';

/// Atomic UI primitives: small reusable widgets shared across screens.
/// Mirror the design handoff's `atoms.jsx`.

/// Mono uppercase mini-label used as section headers.
class Eyebrow extends StatelessWidget {
  const Eyebrow(
    this.text, {
    super.key,
    this.color = OmColors.fg2,
    this.trailing,
  });
  final String text;
  final Color color;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(text.toUpperCase(), style: OmType.eyebrow(color: color)),
        if (trailing != null) ...[const SizedBox(width: 8), trailing!],
      ],
    );
  }
}

enum ChipTone { neutral, accent, agent, info, warn, danger }

class OmChip extends StatelessWidget {
  const OmChip({
    super.key,
    required this.label,
    this.tone = ChipTone.neutral,
    this.leading,
  });

  final String label;
  final ChipTone tone;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final (bg, fg, border) = switch (tone) {
      ChipTone.neutral => (OmColors.surface3, OmColors.fg1, OmColors.line2),
      ChipTone.accent => (
        OmColors.successBg,
        OmColors.accent,
        OmColors.accent.withAlpha(70),
      ),
      ChipTone.agent => (
        OmColors.agentBg,
        OmColors.agent,
        OmColors.agent.withAlpha(70),
      ),
      ChipTone.info => (
        OmColors.infoBg,
        OmColors.info,
        OmColors.info.withAlpha(70),
      ),
      ChipTone.warn => (
        OmColors.warnBg,
        OmColors.warn,
        OmColors.warn.withAlpha(70),
      ),
      ChipTone.danger => (
        OmColors.dangerBg,
        OmColors.danger,
        OmColors.danger.withAlpha(70),
      ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        border: Border.all(color: border, width: 1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (leading != null) ...[leading!, const SizedBox(width: 6)],
          Text(
            label.toUpperCase(),
            style: OmType.mono(
              size: 11,
              weight: FontWeight.w500,
              color: fg,
              letterSpacing: 0.8,
            ),
          ),
        ],
      ),
    );
  }
}

/// Tiny status pill — animated when [pulse] is true.
class OmDot extends StatefulWidget {
  const OmDot({
    super.key,
    this.color = OmColors.accent,
    this.size = 6,
    this.pulse = false,
  });
  final Color color;
  final double size;
  final bool pulse;
  @override
  State<OmDot> createState() => _OmDotState();
}

class _OmDotState extends State<OmDot> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    );
    if (widget.pulse) _ctrl.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant OmDot old) {
    super.didUpdateWidget(old);
    if (widget.pulse && !_ctrl.isAnimating) _ctrl.repeat(reverse: true);
    if (!widget.pulse && _ctrl.isAnimating) _ctrl.stop();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, _) {
        final t = widget.pulse ? (0.4 + 0.6 * _ctrl.value) : 1.0;
        return Container(
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            color: widget.color.withValues(alpha: t.clamp(0.0, 1.0)),
            shape: BoxShape.circle,
          ),
        );
      },
    );
  }
}

/// Mono keyboard-shortcut hint, e.g. "⌘K".
class OmKbd extends StatelessWidget {
  const OmKbd(this.text, {super.key, this.dim = false});
  final String text;
  final bool dim;
  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: OmType.mono(
        size: 10.5,
        color: dim ? OmColors.fg3 : OmColors.fg2,
        letterSpacing: 0.2,
      ),
    );
  }
}

/// The state a [StatusDot] shows (Req 38, board A12).
enum StatusDotState { connected, cantReach, tokenRejected, checking }

/// A 6 px status dot for a vault server or hosted vault (board A12): a
/// filled accent dot when connected, a hollow warn ring when it can't be
/// reached, a filled danger dot when the token is rejected and a filled fg2
/// dot while checking. Static; always shown next to text or an icon.
class StatusDot extends StatelessWidget {
  const StatusDot({super.key, required this.state});

  final StatusDotState state;

  static const double size = 6;

  @override
  Widget build(BuildContext context) {
    final decoration = switch (state) {
      StatusDotState.connected => const BoxDecoration(
        shape: BoxShape.circle,
        color: OmColors.accent,
      ),
      StatusDotState.cantReach => BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: OmColors.warn, width: 1),
      ),
      StatusDotState.tokenRejected => const BoxDecoration(
        shape: BoxShape.circle,
        color: OmColors.danger,
      ),
      StatusDotState.checking => const BoxDecoration(
        shape: BoxShape.circle,
        color: OmColors.fg2,
      ),
    };
    return SizedBox(
      width: size,
      height: size,
      child: DecoratedBox(decoration: decoration),
    );
  }
}

enum OmButtonKind { primary, secondary, ghost, agent, danger }

class OmButton extends StatefulWidget {
  const OmButton({
    super.key,
    required this.onPressed,
    this.kind = OmButtonKind.secondary,
    this.size = 30,
    this.label,
    this.icon,
    this.kbd,
    this.tooltip,
    this.dense = false,
    this.focusable = false,
    this.hoverBackground,
    this.iconSize,
    this.focusNode,
    this.semanticLabel,
    this.toggled,
  });
  final VoidCallback? onPressed;
  final OmButtonKind kind;
  final double size;

  /// The small button style (board A12): 12 px label, 12 px icon and 10 px
  /// horizontal padding instead of 13, 14 and 12. Opt-in and independent of
  /// [size]; A12's small buttons pass `size: 24, dense: true`.
  final bool dense;
  final String? label;
  final IconData? icon;
  final String? kbd;
  final String? tooltip;

  /// Opt-in keyboard focus (Spec #393 req 8, D9): a focus stop that Enter
  /// and Space press once per key press, announced as a button labelled
  /// [semanticLabel], else [label], else [tooltip]. Keyboard focus draws a 2 px ring
  /// inside the box and the focus fill (req 10, D29) without changing the
  /// size. A disabled one stays a focus stop and ignores every press (LR3).
  final bool focusable;

  /// The hover background, and the focus fill of a [focusable] button
  /// (D29); null keeps the kind's colours.
  final Color? hoverBackground;

  /// The icon size; null keeps 12 px (dense) or 14 px.
  final double? iconSize;

  /// The focus node of a [focusable] button, so a caller can move focus to
  /// this button with `requestFocus()`. The caller owns it and disposes it.
  /// Null gives the button a node of its own; ignored unless [focusable].
  final FocusNode? focusNode;

  /// The announced label of a [focusable] button when it should differ from
  /// the visible text; null announces [label] or, without one, [tooltip].
  final String? semanticLabel;

  /// Announces a [focusable] button as a toggle that is on (true) or off
  /// (false); null announces a plain button.
  final bool? toggled;

  @override
  State<OmButton> createState() => _OmButtonState();
}

class _OmButtonState extends State<OmButton> {
  bool _hover = false;

  /// Whether the [Focus] of a focusable button has the focus.
  bool _focused = false;

  @override
  void didUpdateWidget(OmButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The Focus leaves the tree with `focusable`, without a focus change.
    if (!widget.focusable && _focused) _setFocused(false);
  }

  @override
  void dispose() {
    FocusManager.instance.removeHighlightModeListener(_onHighlightMode);
    super.dispose();
  }

  void _setFocused(bool focused) {
    // The ring follows the highlight mode only while focused.
    if (focused) {
      FocusManager.instance.addHighlightModeListener(_onHighlightMode);
    } else {
      FocusManager.instance.removeHighlightModeListener(_onHighlightMode);
    }
    _focused = focused;
  }

  void _onHighlightMode(FocusHighlightMode _) => setState(() {});

  /// Enter and Space press a focused focusable button on key down only;
  /// their repeats and key ups are swallowed too, so a held key presses
  /// once and never reaches an ancestor. A disabled button swallows them.
  /// With Shift, Control, Alt or Meta held they pass on unhandled, as
  /// with keyboardButtonShortcuts.
  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    final key = event.logicalKey;
    if (key != LogicalKeyboardKey.enter &&
        key != LogicalKeyboardKey.numpadEnter &&
        key != LogicalKeyboardKey.space) {
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isShiftPressed ||
        keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    if (event is KeyDownEvent) widget.onPressed?.call();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    // (rest, foreground, border, hover, focus fill, focus ring) per kind.
    // D29: ghost and secondary focus to surface4; primary, agent and danger
    // keep their hover colour; the ring is accent, accentFg on primary.
    final (bg, fg, border, hoverBg, focusBg, ringColor) = switch (widget.kind) {
      OmButtonKind.primary => (
        OmColors.accent,
        OmColors.accentFg,
        Colors.transparent,
        const Color(0xFF94FFC1),
        const Color(0xFF94FFC1),
        OmColors.accentFg,
      ),
      OmButtonKind.secondary => (
        OmColors.surface3,
        OmColors.fg0,
        OmColors.line2,
        OmColors.surface4,
        OmColors.surface4,
        OmColors.accent,
      ),
      OmButtonKind.ghost => (
        Colors.transparent,
        OmColors.fg1,
        Colors.transparent,
        OmColors.surface3,
        OmColors.surface4,
        OmColors.accent,
      ),
      OmButtonKind.agent => (
        OmColors.agentBg,
        OmColors.agent,
        OmColors.agent.withAlpha(70),
        OmColors.agentBg,
        OmColors.agentBg,
        OmColors.accent,
      ),
      OmButtonKind.danger => (
        OmColors.dangerBg,
        OmColors.danger,
        OmColors.danger.withAlpha(69),
        OmColors.dangerBg,
        OmColors.dangerBg,
        OmColors.accent,
      ),
    };
    // Keyboard focus only (CSS :focus-visible): no ring after a click, and
    // none while the focus highlight is off.
    final ring =
        widget.focusable &&
        _focused &&
        FocusManager.instance.highlightMode == FocusHighlightMode.traditional;
    final Color fill;
    if (ring) {
      fill = widget.hoverBackground ?? focusBg;
    } else if (_hover) {
      fill = widget.hoverBackground ?? hoverBg;
    } else {
      fill = bg;
    }

    // Small buttons (opt-in, board A12): 12 px label and icon, padding 10.
    final small = widget.dense;
    final hasLabel = widget.label != null;
    final child = Padding(
      padding: EdgeInsets.symmetric(
        horizontal: hasLabel ? (small ? 10 : 12) : 0,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.icon != null)
            Icon(
              widget.icon,
              size: widget.iconSize ?? (small ? 12 : 14),
              color: fg,
            ),
          if (widget.icon != null && hasLabel) const SizedBox(width: 7),
          if (hasLabel)
            Flexible(
              child: Text(
                widget.label!,
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
                style: OmType.sans(
                  size: small ? 12 : 13,
                  weight: FontWeight.w500,
                  color: fg,
                ),
              ),
            ),
          if (widget.kbd != null) ...[
            const SizedBox(width: 6),
            OmKbd(widget.kbd!, dim: widget.kind == OmButtonKind.primary),
          ],
        ],
      ),
    );

    final disabled = widget.onPressed == null;
    // Disabled (any kind, board A12): the whole button at 40% opacity.
    final core = Opacity(
      opacity: disabled ? 0.4 : 1.0,
      child: MouseRegion(
        cursor: disabled ? SystemMouseCursors.basic : SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPressed,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            height: widget.size,
            constraints: BoxConstraints(
              minWidth: hasLabel ? 0 : widget.size,
              minHeight: widget.size,
            ),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: fill,
              border: Border.all(color: border, width: 1),
              borderRadius: BorderRadius.circular(6),
            ),
            // The 2 px ring is drawn inside the box, so the size never
            // changes. Null without the ring keeps the default tree as is.
            foregroundDecoration: ring
                ? BoxDecoration(
                    border: Border.all(
                      color: ringColor,
                      width: 2,
                      strokeAlign: BorderSide.strokeAlignInside,
                    ),
                    borderRadius: BorderRadius.circular(6),
                  )
                : null,
            child: child,
          ),
        ),
      ),
    );

    final tipped = widget.tooltip == null
        ? core
        : Tooltip(message: widget.tooltip!, child: core);
    if (!widget.focusable) return tipped;

    // One button node labelled `semanticLabel ?? label ?? tooltip`; the
    // child semantics (the text, the tooltip, the tap detector) are
    // excluded so the label is not doubled. The Focus adds no node of its
    // own.
    return Focus(
      focusNode: widget.focusNode,
      includeSemantics: false,
      onFocusChange: (f) => setState(() => _setFocused(f)),
      onKeyEvent: _onKey,
      child: Semantics(
        container: true,
        button: true,
        enabled: !disabled,
        focusable: true,
        focused: _focused,
        toggled: widget.toggled,
        label: widget.semanticLabel ?? widget.label ?? widget.tooltip,
        onTap: widget.onPressed,
        excludeSemantics: true,
        child: tipped,
      ),
    );
  }
}

/// Section header used inside left/right panels.
class PanelHeader extends StatelessWidget {
  const PanelHeader({
    super.key,
    required this.eyebrow,
    this.count,
    this.action,
    this.onAction,
    this.trailing,
    this.padding = defaultPadding,
  });

  /// The header's padding unless a caller gives its own.
  static const defaultPadding = EdgeInsets.fromLTRB(16, 14, 16, 10);

  final String eyebrow;
  final int? count;
  final String? action;
  final VoidCallback? onAction;

  /// When given, shown in place of the text [action] (#363's MANAGE).
  final Widget? trailing;

  /// Space around the row ([defaultPadding] unless given).
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Row(
        children: [
          Eyebrow(eyebrow),
          if (count != null) ...[
            const SizedBox(width: 8),
            Text(
              '· $count',
              style: OmType.mono(
                size: 10.5,
                color: OmColors.fg3,
                letterSpacing: 0.8,
              ),
            ),
          ],
          const Spacer(),
          if (trailing case final trailing?)
            trailing
          else if (action != null)
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: onAction,
                child: Text(
                  action!.toUpperCase(),
                  style: OmType.mono(
                    size: 10.5,
                    color: OmColors.fg2,
                    letterSpacing: 0.8,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Hairline horizontal divider.
class OmHairline extends StatelessWidget {
  const OmHairline({super.key, this.color});
  final Color? color;
  @override
  Widget build(BuildContext context) =>
      Container(height: 1, color: color ?? OmColors.line1);
}
