// WI #159 test support: test controllers that render a line taller or hide
// characters, and an independent oracle for a laid-out field's real line
// boxes. Owned by #159's tests (line_boxes_test, segment_editing_test).
import 'dart:ui' show BoxHeightStyle;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/widgets/editor/live_preview_controller.dart';

/// Font size of a line [wi159SpanFor] renders tall.
const double wi159TallFontSize = 40;

/// A 22.95 px minimum strut (13.5 x 1.7) that does not force its height,
/// as live preview fields use (R13), so a taller line lays out taller.
const wi159MinimumStrut = StrutStyle(fontSize: 13.5, height: 1.7);

/// The text span for [text]: every line starting with `BIG` at
/// [wi159TallFontSize] (line height 1.0), and every `**` hidden (font size
/// 0, so it renders zero-width). No characters are added or removed.
TextSpan wi159SpanFor(String text, TextStyle? style) {
  final children = <TextSpan>[];
  for (final m in RegExp(r'[^\n]*\n|[^\n]+').allMatches(text)) {
    final line = m.group(0)!;
    final tall = line.startsWith('BIG');
    final lineStyle = tall
        ? const TextStyle(fontSize: wi159TallFontSize, height: 1)
        : null;
    var at = 0;
    for (final hidden in RegExp(r'\*\*').allMatches(line)) {
      if (hidden.start > at) {
        children.add(
          TextSpan(text: line.substring(at, hidden.start), style: lineStyle),
        );
      }
      children.add(const TextSpan(text: '**', style: TextStyle(fontSize: 0)));
      at = hidden.end;
    }
    if (at < line.length) {
      children.add(TextSpan(text: line.substring(at), style: lineStyle));
    }
  }
  return TextSpan(style: style, children: children);
}

/// A plain controller rendering through [wi159SpanFor].
class Wi159TallLineController extends TextEditingController {
  Wi159TallLineController({super.text});

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) => wi159SpanFor(text, style);
}

/// A [LivePreviewController] rendering through [wi159SpanFor] with
/// [wi159MinimumStrut], as B1's controller will (taller heading lines).
class Wi159TallLivePreviewController extends LivePreviewController {
  Wi159TallLivePreviewController({super.text});

  @override
  StrutStyle? get strutStyle => wi159MinimumStrut;

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) => wi159SpanFor(text, style);
}

/// The first [RenderEditable] at or under [finder]'s render object.
RenderEditable wi159EditableIn(WidgetTester tester, Finder finder) {
  RenderEditable? found;
  void visit(RenderObject node) {
    if (found != null) return;
    if (node is RenderEditable) {
      found = node;
    } else {
      node.visitChildren(visit);
    }
  }

  visit(tester.renderObject(finder));
  if (found == null) throw TestFailure('No RenderEditable under $finder');
  return found!;
}

/// Oracle: the line box (full line height) of the source line [line] of
/// [editable]'s laid-out text, in the editable's local coordinates. Lays
/// the editable's own span out again with its strut and scaler, and reads
/// the line's max-height selection boxes. Lines must not wrap.
Rect wi159LineBox(RenderEditable editable, TextRange line) {
  final painter = TextPainter(
    text: editable.text,
    textDirection: editable.textDirection,
    strutStyle: editable.strutStyle,
    textScaler: editable.textScaler,
    textHeightBehavior: editable.textHeightBehavior,
    textWidthBasis: editable.textWidthBasis,
  )..layout(maxWidth: editable.size.width);
  final boxes = painter.getBoxesForSelection(
    TextSelection(baseOffset: line.start, extentOffset: line.end),
    boxHeightStyle: BoxHeightStyle.max,
  );
  painter.dispose();
  if (boxes.isEmpty) throw TestFailure('No boxes for line $line');
  var rect = boxes.first.toRect();
  for (final b in boxes.skip(1)) {
    rect = rect.expandToInclude(b.toRect());
  }
  return rect;
}

/// The source line (without its line break) of [text] holding [offset].
TextRange wi159LineOf(String text, int offset) {
  final start = offset == 0 ? 0 : text.lastIndexOf('\n', offset - 1) + 1;
  final nl = text.indexOf('\n', offset);
  return TextRange(start: start, end: nl < 0 ? text.length : nl);
}

/// [rect] of [editable]'s local coordinates in global coordinates.
Rect wi159Global(RenderEditable editable, Rect rect) => Rect.fromPoints(
  editable.localToGlobal(rect.topLeft),
  editable.localToGlobal(rect.bottomRight),
);
