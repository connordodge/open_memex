import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// The controller of every live preview field (D7): today a pass-through
/// whose [buildTextSpan] renders exactly the controller's text. B1 owns its
/// body (styling, marker hiding); hosts only set its props.
///
/// Host-set props, all optional with safe defaults:
/// - [itemText]: the field holds only an item row's text (its marker is in
///   the marker column);
/// - [taskDone]: the field is a done task's text;
/// - [quote]: the field is a quote line's text;
/// - [atSegmentStart]: the field's text starts at its text segment's start;
/// - [revealGate]: true while the field's text segment has focus (markers
///   may reveal only then).
class LivePreviewController extends TextEditingController {
  LivePreviewController({super.text});

  LivePreviewController.fromValue(super.value) : super.fromValue();

  /// The field holds only an item row's text. Default false.
  bool itemText = false;

  /// The field is a done task's text. Default false.
  bool taskDone = false;

  /// The field is a quote line's text. Default false.
  bool quote = false;

  /// The field's text starts at its text segment's start. Default true.
  bool atSegmentStart = true;

  /// True while the field's text segment has focus. Default: never true.
  ValueListenable<bool> revealGate = const AlwaysStoppedAnimation<bool>(false);

  /// The strut a `TextSegmentField` editing this controller lays its text
  /// out with; null (the pass-through) keeps the field's default strut.
  /// B1 returns the 22.95 px minimum strut (R13), so taller heading lines
  /// lay out taller.
  StrutStyle? get strutStyle => null;
}
