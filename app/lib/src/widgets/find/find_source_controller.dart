// WI #85 (Spec #61 F6, TD3): the note editor's Source-mode field controller,
// which draws Find in note's match ink in the raw markdown.
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../theme/colors.dart';
import '../editor/find_decoration.dart';

/// The Source field's [TextEditingController] (`NoteEditor._bodyCtrl`): a
/// plain controller that also draws [find]'s ink (Reqs 24-25). Inside the
/// current match every run draws in surface0; inside another match text that
/// would draw in fg2, fg3 or info draws in fg1. The fills and borders are
/// F3's highlight layer under the field, not this controller.
///
/// Setting [find] to another value repaints the field; its text and
/// selection never change. While the field composes, no ink is drawn.
class FindSourceController extends TextEditingController {
  FindSourceController({super.text});

  /// The matches in the field and the current one (field offsets), or null:
  /// no ink.
  FindDecoration? get find => _find;
  FindDecoration? _find;
  set find(FindDecoration? value) {
    if (value == _find) return;
    _find = value;
    notifyListeners();
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final find = _find;
    final composing = withComposing && value.isComposingRangeValid;
    if (find == null || composing || text.isEmpty) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
    // Each code unit's ink: 0 none, 1 another match, 2 the current match.
    final ink = List<int>.filled(text.length, 0);
    void mark(TextRange range, int kind) {
      final start = math.max(0, range.start);
      final end = math.min(text.length, range.end);
      for (var i = start; i < end; i++) {
        ink[i] = kind;
      }
    }

    for (final range in find.inkRanges) {
      mark(range, 1);
    }
    if (find.current case final current?) mark(current, 2);
    final children = <TextSpan>[];
    var start = 0;
    for (var i = 1; i <= text.length; i++) {
      if (i < text.length && ink[i] == ink[start]) continue;
      children.add(
        TextSpan(
          text: text.substring(start, i),
          style: _inked(style, ink[start]),
        ),
      );
      start = i;
    }
    return TextSpan(style: style, children: children);
  }

  /// The colours another match lifts to fg1 (Req 24).
  static const List<Color> _lifted = [
    OmColors.fg2,
    OmColors.fg3,
    OmColors.info,
  ];

  /// The style of a run with ink [kind] over the field's [style]: null (the
  /// field's own) outside a match.
  static TextStyle? _inked(TextStyle? style, int kind) => switch (kind) {
    2 => (style ?? const TextStyle()).copyWith(color: OmColors.surface0),
    1 when _lifted.contains(style?.color) => style!.copyWith(
      color: OmColors.fg1,
    ),
    _ => null,
  };
}
