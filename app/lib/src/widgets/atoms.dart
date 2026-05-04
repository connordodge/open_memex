import 'package:flutter/material.dart';

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

enum OmButtonKind { primary, secondary, ghost, agent }

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
  });
  final VoidCallback? onPressed;
  final OmButtonKind kind;
  final double size;
  final String? label;
  final IconData? icon;
  final String? kbd;
  final String? tooltip;

  @override
  State<OmButton> createState() => _OmButtonState();
}

class _OmButtonState extends State<OmButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final (bg, fg, border, hoverBg) = switch (widget.kind) {
      OmButtonKind.primary => (
        OmColors.accent,
        OmColors.accentFg,
        Colors.transparent,
        const Color(0xFF94FFC1),
      ),
      OmButtonKind.secondary => (
        OmColors.surface3,
        OmColors.fg0,
        OmColors.line2,
        OmColors.surface4,
      ),
      OmButtonKind.ghost => (
        Colors.transparent,
        OmColors.fg1,
        Colors.transparent,
        OmColors.surface3,
      ),
      OmButtonKind.agent => (
        OmColors.agentBg,
        OmColors.agent,
        OmColors.agent.withAlpha(70),
        OmColors.agentBg,
      ),
    };

    final hasLabel = widget.label != null;
    final child = Padding(
      padding: EdgeInsets.symmetric(horizontal: hasLabel ? 12 : 0),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.icon != null) Icon(widget.icon, size: 14, color: fg),
          if (widget.icon != null && hasLabel) const SizedBox(width: 7),
          if (hasLabel)
            Flexible(
              child: Text(
                widget.label!,
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
                style: OmType.sans(
                  size: 13,
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

    final core = MouseRegion(
      cursor: widget.onPressed == null
          ? SystemMouseCursors.basic
          : SystemMouseCursors.click,
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
            color: _hover ? hoverBg : bg,
            border: Border.all(color: border, width: 1),
            borderRadius: BorderRadius.circular(6),
          ),
          child: child,
        ),
      ),
    );

    if (widget.tooltip != null) {
      return Tooltip(message: widget.tooltip!, child: core);
    }
    return core;
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
  });
  final String eyebrow;
  final int? count;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
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
          if (action != null)
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
