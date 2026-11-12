// WI #411 (Spec #394 req 22-24, 46; pack #411 "Segmented control",
// "Embeddings switch row", "Switch"): the Connect tab's client choice and
// its `Include semantic recall` switch.
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../../state/agents_sheet/connect_tab_state.dart';
import '../../../theme/colors.dart';
import '../../../theme/typography.dart';

/// The `Claude Desktop` / `Claude Code` segmented control. The segments
/// wrap onto a second line when they don't fit side by side.
class ConnectClientSwitch extends StatelessWidget {
  const ConnectClientSwitch({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final ConnectClient value;
  final ValueChanged<ConnectClient> onChanged;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: OmColors.surface0,
          border: Border.all(color: OmColors.line2),
          borderRadius: BorderRadius.circular(7),
        ),
        child: Wrap(
          spacing: 2,
          runSpacing: 2,
          children: [
            for (final (client, label) in const [
              (ConnectClient.claudeDesktop, 'Claude Desktop'),
              (ConnectClient.claudeCode, 'Claude Code'),
            ])
              _Segment(
                label: label,
                selected: client == value,
                onPressed: () => onChanged(client),
              ),
          ],
        ),
      ),
    );
  }
}

/// Whether [event] is a first press (not a repeat or release) of Enter or
/// Space, the keys that activate a focused control.
bool _activates(KeyEvent event) {
  final key = event.logicalKey;
  return key == LogicalKeyboardKey.enter ||
      key == LogicalKeyboardKey.numpadEnter ||
      key == LogicalKeyboardKey.space;
}

/// The 2 px accent ring a keyboard-focused control draws inside its box
/// (D29), shown only while the focus highlight is on.
bool _ringShown(bool focused) =>
    focused &&
    FocusManager.instance.highlightMode == FocusHighlightMode.traditional;

class _Segment extends StatefulWidget {
  const _Segment({
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final bool selected;
  final VoidCallback onPressed;

  @override
  State<_Segment> createState() => _SegmentState();
}

class _SegmentState extends State<_Segment> {
  bool _hover = false;
  bool _focused = false;

  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    if (!_activates(event)) return KeyEventResult.ignored;
    if (event is KeyDownEvent) widget.onPressed();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final on = widget.selected;
    final Color fill;
    if (on) {
      fill = OmColors.surface4;
    } else if (_hover || _ringShown(_focused)) {
      fill = OmColors.surface3;
    } else {
      fill = const Color(0x00000000);
    }
    return Focus(
      includeSemantics: false,
      onKeyEvent: _onKey,
      onFocusChange: (f) => setState(() => _focused = f),
      child: Semantics(
        container: true,
        button: true,
        selected: on,
        inMutuallyExclusiveGroup: true,
        focusable: true,
        focused: _focused,
        label: widget.label,
        onTap: widget.onPressed,
        excludeSemantics: true,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onPressed,
            child: Container(
              constraints: const BoxConstraints(minHeight: 24),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: fill,
                borderRadius: BorderRadius.circular(5),
              ),
              foregroundDecoration: _ringShown(_focused)
                  ? BoxDecoration(
                      border: Border.all(
                        color: OmColors.accent,
                        width: 2,
                        strokeAlign: BorderSide.strokeAlignInside,
                      ),
                      borderRadius: BorderRadius.circular(5),
                    )
                  : null,
              // Centred in the 24 px height, as wide as the label.
              child: Align(
                widthFactor: 1,
                child: Text(
                  widget.label,
                  maxLines: 1,
                  style: OmType.sans(
                    size: 12,
                    weight: FontWeight.w500,
                    height: 1.2,
                    color: on ? OmColors.fg0 : OmColors.fg2,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The `Include semantic recall` `--with-embeddings` row: a 30 x 18 switch
/// and its label, one Semantics toggle labelled `Include semantic recall`
/// (Spec #394 req 46). Clicking anywhere on the row, its Semantics tap, or
/// Enter / Space while focused flips it.
class ConnectRecallSwitch extends StatefulWidget {
  const ConnectRecallSwitch({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  State<ConnectRecallSwitch> createState() => _ConnectRecallSwitchState();
}

class _ConnectRecallSwitchState extends State<ConnectRecallSwitch> {
  bool _focused = false;

  void _flip() => widget.onChanged(!widget.value);

  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    if (!_activates(event)) return KeyEventResult.ignored;
    if (event is KeyDownEvent) _flip();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final on = widget.value;
    final ring = _ringShown(_focused);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Focus(
        includeSemantics: false,
        onKeyEvent: _onKey,
        onFocusChange: (f) => setState(() => _focused = f),
        child: Semantics(
          container: true,
          toggled: on,
          focusable: true,
          focused: _focused,
          label: 'Include semantic recall',
          onTap: _flip,
          excludeSemantics: true,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _flip,
              child: Row(
                children: [
                  Container(
                    width: 30,
                    height: 18,
                    decoration: BoxDecoration(
                      color: on ? OmColors.accentDeep : OmColors.surface5,
                      borderRadius: BorderRadius.circular(9),
                    ),
                    foregroundDecoration: ring
                        ? BoxDecoration(
                            border: Border.all(
                              color: OmColors.accent,
                              width: 2,
                              strokeAlign: BorderSide.strokeAlignOutside,
                            ),
                            borderRadius: BorderRadius.circular(9),
                          )
                        : null,
                    child: Stack(
                      children: [
                        Positioned(
                          left: on ? 14 : 2,
                          top: 2,
                          child: Container(
                            width: 14,
                            height: 14,
                            decoration: BoxDecoration(
                              color: on ? OmColors.accent : OmColors.fg2,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text.rich(
                      TextSpan(
                        children: [
                          const TextSpan(text: 'Include semantic recall'),
                          const TextSpan(text: '   '),
                          TextSpan(
                            text: '--with-embeddings',
                            style: OmType.mono(
                              size: 11.5,
                              height: 1.55,
                              color: OmColors.fg2,
                            ),
                          ),
                        ],
                      ),
                      style: OmType.sans(
                        size: 12.5,
                        height: 1.55,
                        color: OmColors.fg1,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
