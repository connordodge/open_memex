// WI #84 (#61 F4, ruling D7): the one find input of a live preview field.
import 'package:flutter/widgets.dart' show TextRange;

/// What Find in note decorates in one live preview field (Spec #61 Reqs 24,
/// 25 and 27; ruling D7). Every range is a field-local UTF-16 range of the
/// field's text.
///
/// - [revealRange]: the lines it touches reveal their markup as if the caret
///   were on them, even while the field is unfocused (Req 27). Null: none.
/// - [inkRanges]: every match in the field. Inside one that is not
///   [current], text that would draw in fg2, fg3 or info draws in fg1
///   (Req 24).
/// - [current]: the current match, one of [inkRanges]. Inside it every run
///   draws in surface0 (Req 25). Null: none in this field.
///
/// Two decorations are equal when every field is.
final class FindDecoration {
  const FindDecoration({
    this.revealRange,
    this.inkRanges = const <TextRange>[],
    this.current,
  });

  final TextRange? revealRange;
  final List<TextRange> inkRanges;
  final TextRange? current;
}
