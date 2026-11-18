// WI #65 (53-C, Spec #57 R5-R9, TD3-TD4, Testing Strategy "Click tests"):
// a click's caret is the offset resolved at mouse-down against the layout
// shown then, and it stays there when the clicked line's hidden markup
// reveals (headings H1-H6, inline markup). Double and triple clicks use the
// first click's press-time offset, and select exactly what they select today
// on a line that was already revealed.
//
// Every press point is taken from the segment's `LineBoxSource` on the layout
// shown at that moment, never from constants. Every test runs under macOS
// with mouse gestures, and reads the selection after mouse-down, after the
// release and after the click has settled (Spec #57 TS "Click tests").
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/ui_state_store.dart';

import '../../support/editor_scope.dart';
import '../../support/font_fetch_hold.dart';
import '../../support/mac_editing.dart';
import '../../support/recording_tabs.dart';
import '../../support/table_harness.dart';

const _wi65KnownId = 'topic-known';

/// A `TabsNotifier` that records follows and goes nowhere, so the pumped
/// note stays on screen after a link follow.
class _Wi65Tabs extends TabsNotifier {
  _Wi65Tabs(TabsRecorder recorder)
    : followed = recorder.followed,
      super(
        store: UiStateStore(vaultPath: '/dev/null'),
        onPersistedSelection: (_) {},
        navigationObserver: recorder.observer,
      );

  final List<WorkspaceTab> followed;
  final List<WorkspaceTab> opened = [];

  @override
  int openOrFocus(WorkspaceTab tab) {
    opened.add(tab);
    return 0;
  }

  @override
  void navigate(WorkspaceTab target) {}
}

/// A pumped note body holding [text], with the note `Known` loaded so
/// `[[Known]]` is a followable wikilink.
Future<({TableBody b, _Wi65Tabs tabs})> _wi65Pump(
  WidgetTester tester,
  String text,
) async {
  final tabs = _Wi65Tabs(TabsRecorder());
  final b = await pumpTable(
    tester,
    text,
    titles: [NoteTitle(id: _wi65KnownId, title: 'Known', updatedAt: 2)],
    opener: RecordingUrlOpener(),
    overrides: [tabsProvider.overrideWith((ref) => tabs)],
  );
  // The titles load, then LinkRegion applies them after a frame.
  await tester.pump();
  await tester.pump();
  return (b: b, tabs: tabs);
}

/// The global rect of the glyph at segment [offset], on the layout shown
/// now. Fails when the glyph is not drawn (a hidden marker).
Rect _wi65Glyph(TableBody b, int offset) {
  final boxes = b.segmentBoxes();
  final rects = boxes.boxesFor(TextRange(start: offset, end: offset + 1));
  expect(rects, isNotEmpty, reason: 'a glyph at $offset');
  final rect = b.toGlobal(boxes, rects.first);
  expect(rect.width, greaterThan(0), reason: 'the glyph at $offset is shown');
  return rect;
}

/// Whether the character at segment [offset] is drawn with a width now (a
/// revealed marker is; a hidden one is not).
bool _wi65Shown(TableBody b, int offset) {
  final boxes = b.segmentBoxes();
  final rects = boxes.boxesFor(TextRange(start: offset, end: offset + 1));
  return rects.isNotEmpty && rects.first.width > 0.5;
}

/// A point on the right half of the glyph at [offset] (its nearest offset
/// is [offset] + 1 on the layout shown now).
Offset _wi65RightHalf(TableBody b, int offset) {
  final g = _wi65Glyph(b, offset);
  return Offset(g.right - g.width / 4, g.center.dy);
}

/// A point on the left half of the glyph at [offset] (its nearest offset is
/// [offset] on the layout shown now).
Offset _wi65LeftHalf(TableBody b, int offset) {
  final g = _wi65Glyph(b, offset);
  return Offset(g.left + g.width / 4, g.center.dy);
}

/// The glyph's centre at [offset].
Offset _wi65Center(TableBody b, int offset) => _wi65Glyph(b, offset).center;

/// The segment offset under global [point] on the layout shown now.
int _wi65OffsetAt(TableBody b, Offset point) {
  final boxes = b.segmentBoxes();
  return boxes.offsetAt(boxes.box.globalToLocal(point));
}

/// Lets the double-click window pass, then settles.
Future<void> _wi65Settle(WidgetTester tester) async {
  await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 200));
  await tester.pumpAndSettle();
}

/// The selection after a plain mouse click at [at]: after mouse-down, after
/// the release and after it settled.
typedef _Wi65Seen = ({
  TextSelection down,
  TextSelection up,
  TextSelection settled,
});

Future<_Wi65Seen> _wi65Click(TableBody b, Offset at) async {
  final tester = b.tester;
  final mouse = await tester.startGesture(at, kind: PointerDeviceKind.mouse);
  await tester.pump();
  final down = b.selection();
  await mouse.up();
  await tester.pump();
  final up = b.selection();
  await _wi65Settle(tester);
  return (down: down, up: up, settled: b.selection());
}

/// [seen] is a caret at [offset] after down, after release and after settle.
void _wi65ExpectCaret(_Wi65Seen seen, int offset) {
  for (final (moment, selection) in [
    ('after mouse-down', seen.down),
    ('after release', seen.up),
    ('after settle', seen.settled),
  ]) {
    expect(
      (selection.baseOffset, selection.extentOffset),
      (offset, offset),
      reason: 'a caret at $offset $moment: $selection',
    );
  }
}

/// [selection] as (base, extent).
(int, int) _wi65Range(TextSelection selection) =>
    (selection.baseOffset, selection.extentOffset);

/// [count] mouse clicks at [points] (the last point repeats), [gap] apart.
Future<void> _wi65Clicks(
  WidgetTester tester,
  List<Offset> points, {
  int count = 2,
  Duration gap = const Duration(milliseconds: 50),
}) async {
  for (var i = 0; i < count; i++) {
    if (i > 0) await tester.pump(gap);
    await tester.macClick(points[i < points.length ? i : points.length - 1]);
  }
}

String _wi65Heading(int level, String text) => '${'#' * level} $text';

void main() {
  holdFontFetches();

  // -------------------------------------------------------------------------
  // AC1: headings in an unfocused segment
  // -------------------------------------------------------------------------
  group('headings in an unfocused segment (AC1)', () {
    for (final (level, name) in [
      (
        1,
        'a click at the end of a word in an unrevealed H1 of an unfocused segment keeps the press-time caret through down release and settle',
      ),
      (
        2,
        'a click at the end of a word in an unrevealed H2 of an unfocused segment keeps the press-time caret through down release and settle',
      ),
      (
        3,
        'a click at the end of a word in an unrevealed H3 of an unfocused segment keeps the press-time caret through down release and settle',
      ),
      (
        4,
        'a click at the end of a word in an unrevealed H4 of an unfocused segment keeps the press-time caret through down release and settle',
      ),
      (
        5,
        'a click at the end of a word in an unrevealed H5 of an unfocused segment keeps the press-time caret through down release and settle',
      ),
      (
        6,
        'a click at the end of a word in an unrevealed H6 of an unfocused segment keeps the press-time caret through down release and settle',
      ),
    ]) {
      testWidgets(name, (tester) async {
        final text = '${_wi65Heading(level, 'Hello world')}\nnext line';
        final (:b, tabs: _) = await _wi65Pump(tester, text);
        final end = text.indexOf('Hello') + 'Hello'.length;
        expect(b.view().focusedRow, isNull);
        expect(_wi65Shown(b, 0), isFalse, reason: 'the marker starts hidden');

        final seen = await _wi65Click(b, _wi65RightHalf(b, end - 1));

        _wi65ExpectCaret(seen, end);
        expect(b.view().focusedRow, 0);
        expect(_wi65Shown(b, 0), isTrue, reason: 'the marker revealed');
      }, variant: macOnly);
    }

    testWidgets(
      'a click at the end of the last word of an unrevealed H3 keeps the caret at the line content end',
      (tester) async {
        final text = '${_wi65Heading(3, 'Hello world')}\nnext line';
        final (:b, tabs: _) = await _wi65Pump(tester, text);
        final end = text.indexOf('\n');

        final seen = await _wi65Click(b, _wi65RightHalf(b, end - 1));

        _wi65ExpectCaret(seen, end);
        expect(_wi65Shown(b, 0), isTrue);
      },
      variant: macOnly,
    );

    testWidgets(
      'a click inside a word of an unrevealed H2 keeps the press-time caret between its letters',
      (tester) async {
        final text = '${_wi65Heading(2, 'Hello world')}\nnext line';
        final (:b, tabs: _) = await _wi65Pump(tester, text);
        // `Hel|lo`, the right half of the first `l`.
        final at = text.indexOf('Hello') + 3;

        final seen = await _wi65Click(b, _wi65RightHalf(b, at - 1));

        _wi65ExpectCaret(seen, at);
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // AC2: headings in a focused segment, the caret on another line
  // -------------------------------------------------------------------------
  group('headings in a focused segment (AC2)', () {
    for (final (level, name) in [
      (
        1,
        'with the caret on another line of the same row a click at the end of a word in an unrevealed H1 keeps the press-time caret',
      ),
      (
        2,
        'with the caret on another line of the same row a click at the end of a word in an unrevealed H2 keeps the press-time caret',
      ),
      (
        3,
        'with the caret on another line of the same row a click at the end of a word in an unrevealed H3 keeps the press-time caret',
      ),
      (
        4,
        'with the caret on another line of the same row a click at the end of a word in an unrevealed H4 keeps the press-time caret',
      ),
      (
        5,
        'with the caret on another line of the same row a click at the end of a word in an unrevealed H5 keeps the press-time caret',
      ),
      (
        6,
        'with the caret on another line of the same row a click at the end of a word in an unrevealed H6 keeps the press-time caret',
      ),
    ]) {
      testWidgets(name, (tester) async {
        final heading = _wi65Heading(level, 'Hello world');
        final text = 'intro line\n$heading\nnext line';
        final (:b, tabs: _) = await _wi65Pump(tester, text);
        final lineStart = text.indexOf('#');
        await b.placeCaret(3);
        expect(b.view().focusedRow, 0);
        expect(_wi65Shown(b, lineStart), isFalse);
        final end = text.indexOf('Hello') + 'Hello'.length;

        final seen = await _wi65Click(b, _wi65RightHalf(b, end - 1));

        _wi65ExpectCaret(seen, end);
        expect(b.view().focusedRow, 0);
        expect(_wi65Shown(b, lineStart), isTrue);
      }, variant: macOnly);
    }

    for (final (level, name) in [
      (
        1,
        'with the caret in another row a click at the end of a word in an unrevealed H1 keeps the press-time caret',
      ),
      (
        2,
        'with the caret in another row a click at the end of a word in an unrevealed H2 keeps the press-time caret',
      ),
      (
        3,
        'with the caret in another row a click at the end of a word in an unrevealed H3 keeps the press-time caret',
      ),
      (
        4,
        'with the caret in another row a click at the end of a word in an unrevealed H4 keeps the press-time caret',
      ),
      (
        5,
        'with the caret in another row a click at the end of a word in an unrevealed H5 keeps the press-time caret',
      ),
      (
        6,
        'with the caret in another row a click at the end of a word in an unrevealed H6 keeps the press-time caret',
      ),
    ]) {
      testWidgets(name, (tester) async {
        final heading = _wi65Heading(level, 'Hello world');
        final text = '$heading\nnext line\n- item one';
        final (:b, tabs: _) = await _wi65Pump(tester, text);
        expect(b.rows(), hasLength(2));
        await b.placeCaret(text.indexOf('one') + 1);
        expect(b.view().focusedRow, 1);
        final end = text.indexOf('Hello') + 'Hello'.length;

        final seen = await _wi65Click(b, _wi65RightHalf(b, end - 1));

        _wi65ExpectCaret(seen, end);
        expect(b.view().focusedRow, 0);
        expect(_wi65Shown(b, 0), isTrue);
      }, variant: macOnly);
    }

    testWidgets(
      'with the caret on the line below in the same row a click at the end of a word in an unrevealed H2 keeps the press-time caret',
      (tester) async {
        final text = 'intro line\n${_wi65Heading(2, 'Hello world')}\nnext';
        final (:b, tabs: _) = await _wi65Pump(tester, text);
        await b.placeCaret(text.length - 1);
        final end = text.indexOf('Hello') + 'Hello'.length;

        final seen = await _wi65Click(b, _wi65RightHalf(b, end - 1));

        _wi65ExpectCaret(seen, end);
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // AC3: inline markup
  // -------------------------------------------------------------------------
  group('inline markup (AC3)', () {
    // (text, the marker character's offset, name): each click goes at the
    // end of `here`, past the markup.
    for (final (text, marker, name) in [
      (
        'see **bold** here',
        4,
        'a click past bold markup on an unrevealed line keeps the press-time caret after release and settle',
      ),
      (
        'see *italic* here',
        4,
        'a click past italic markup on an unrevealed line keeps the press-time caret after release and settle',
      ),
      (
        'see ***both*** here',
        4,
        'a click past bold italic markup on an unrevealed line keeps the press-time caret after release and settle',
      ),
      (
        'see ~~strike~~ here',
        4,
        'a click past strike markup on an unrevealed line keeps the press-time caret after release and settle',
      ),
      (
        'see `code` here',
        4,
        'a click past inline code on an unrevealed line keeps the press-time caret after release and settle',
      ),
      (
        'see [docs](https://x.y) here',
        4,
        'a click away from the link text on an unrevealed line with a URL link keeps the press-time caret after release and settle',
      ),
      (
        'see [[Known]] here',
        4,
        'a click away from the link text on an unrevealed line with a wikilink keeps the press-time caret after release and settle',
      ),
    ]) {
      testWidgets(name, (tester) async {
        final full = '$text\nnext line';
        final (:b, :tabs) = await _wi65Pump(tester, full);
        expect(_wi65Shown(b, marker), isFalse, reason: 'markup starts hidden');
        final end = full.indexOf('here') + 'here'.length;

        final seen = await _wi65Click(b, _wi65RightHalf(b, end - 1));

        _wi65ExpectCaret(seen, end);
        expect(_wi65Shown(b, marker), isTrue, reason: 'the markup revealed');
        expect(tabs.followed, isEmpty, reason: 'plain text follows nothing');
      }, variant: macOnly);
    }

    testWidgets(
      'a click inside bold text on an unrevealed line keeps the press-time caret after release and settle',
      (tester) async {
        const text = 'see **bold** here\nnext line';
        final (:b, tabs: _) = await _wi65Pump(tester, text);
        // `bo|ld`.
        final at = text.indexOf('bold') + 2;

        final seen = await _wi65Click(b, _wi65RightHalf(b, at - 1));

        _wi65ExpectCaret(seen, at);
      },
      variant: macOnly,
    );

    testWidgets(
      'with the caret on another line a click past bold markup keeps the press-time caret after release and settle',
      (tester) async {
        const text = 'intro line\nsee **bold** here\nnext';
        final (:b, tabs: _) = await _wi65Pump(tester, text);
        await b.placeCaret(2);
        final end = text.indexOf('here') + 'here'.length;

        final seen = await _wi65Click(b, _wi65RightHalf(b, end - 1));

        _wi65ExpectCaret(seen, end);
      },
      variant: macOnly,
    );

    testWidgets(
      'a click past a wikilink in an unrevealed heading keeps the press-time caret and follows nothing',
      (tester) async {
        const text = '## See [[Known]] here\nnext';
        final (:b, :tabs) = await _wi65Pump(tester, text);
        final end = text.indexOf('here') + 'here'.length;

        final seen = await _wi65Click(b, _wi65RightHalf(b, end - 1));

        _wi65ExpectCaret(seen, end);
        expect(tabs.followed, isEmpty);
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // AC4: boundaries (Spec #57 R7)
  // -------------------------------------------------------------------------
  group('boundaries (AC4)', () {
    for (final (level, name) in [
      (
        1,
        'a click on the left half of an unrevealed H1 first letter puts the caret after the marker and its space',
      ),
      (
        4,
        'a click on the left half of an unrevealed H4 first letter puts the caret after the marker and its space',
      ),
      (
        6,
        'a click on the left half of an unrevealed H6 first letter puts the caret after the marker and its space',
      ),
    ]) {
      testWidgets(name, (tester) async {
        final text = '${_wi65Heading(level, 'Hello world')}\nnext line';
        final (:b, tabs: _) = await _wi65Pump(tester, text);
        final first = level + 1;

        final seen = await _wi65Click(b, _wi65LeftHalf(b, first));

        _wi65ExpectCaret(seen, first);
      }, variant: macOnly);
    }

    testWidgets(
      'a click at the left edge of an unrevealed H2 puts the caret after the marker and its space',
      (tester) async {
        const text = '## Hello world\nnext line';
        final (:b, tabs: _) = await _wi65Pump(tester, text);
        final h = _wi65Glyph(b, 3);
        final field = b.toGlobal(
          b.segmentBoxes(),
          Offset.zero & b.segmentBoxes().box.size,
        );
        final at = Offset(field.left + 0.5, h.center.dy);
        expect(at.dx, lessThanOrEqualTo(h.left + 0.5), reason: 'at or left');

        final seen = await _wi65Click(b, at);

        _wi65ExpectCaret(seen, 3);
      },
      variant: macOnly,
    );

    testWidgets(
      'with the caret on another line a click on the left half of an unrevealed H3 first letter puts the caret after the marker and its space',
      (tester) async {
        const text = 'intro line\n### Hello world\nnext';
        final (:b, tabs: _) = await _wi65Pump(tester, text);
        await b.placeCaret(2);
        final first = text.indexOf('Hello');

        final seen = await _wi65Click(b, _wi65LeftHalf(b, first));

        _wi65ExpectCaret(seen, first);
      },
      variant: macOnly,
    );

    testWidgets(
      'a click on the left half of the first character after a hidden opening marker puts the caret after the marker',
      (tester) async {
        const text = 'see **bold** here\nnext line';
        final (:b, tabs: _) = await _wi65Pump(tester, text);
        final first = text.indexOf('bold');

        final seen = await _wi65Click(b, _wi65LeftHalf(b, first));

        _wi65ExpectCaret(seen, first);
      },
      variant: macOnly,
    );

    testWidgets(
      'a click on the left half of the first character after a hidden opening italic marker puts the caret after the marker',
      (tester) async {
        const text = 'see *italic* here\nnext line';
        final (:b, tabs: _) = await _wi65Pump(tester, text);
        final first = text.indexOf('italic');

        final seen = await _wi65Click(b, _wi65LeftHalf(b, first));

        _wi65ExpectCaret(seen, first);
      },
      variant: macOnly,
    );

    testWidgets(
      'a click on the right half of the last character before a hidden closing marker puts the caret before the closing marker',
      (tester) async {
        const text = 'see **bold** here\nnext line';
        final (:b, tabs: _) = await _wi65Pump(tester, text);
        final last = text.indexOf('bold') + 3;

        final seen = await _wi65Click(b, _wi65RightHalf(b, last));

        _wi65ExpectCaret(seen, last + 1);
      },
      variant: macOnly,
    );

    testWidgets(
      'a click on the left half of the first character after a hidden closing marker puts the caret after the closing marker',
      (tester) async {
        const text = 'see **bold** here\nnext line';
        final (:b, tabs: _) = await _wi65Pump(tester, text);
        final after = text.indexOf('** here') + 2;

        final seen = await _wi65Click(b, _wi65LeftHalf(b, after));

        _wi65ExpectCaret(seen, after);
      },
      variant: macOnly,
    );

    for (final (text, lineStart, name) in [
      (
        '# \nbody line',
        0,
        'a click on an empty H1 puts the caret at the line content end after the marker and its space',
      ),
      (
        'intro line\n### \nbody line',
        11,
        'a click on an empty H3 between two lines puts the caret at the line content end after the marker and its space',
      ),
    ]) {
      testWidgets(name, (tester) async {
        final (:b, tabs: _) = await _wi65Pump(tester, text);
        final contentEnd = text.indexOf('\n', lineStart);
        final boxes = b.segmentBoxes();
        final line = boxes.lines.firstWhere(
          (l) => l.range.start <= lineStart && lineStart <= l.range.end,
        );
        final field = b.toGlobal(boxes, Offset.zero & boxes.box.size);
        final y = boxes.box
            .localToGlobal(Offset(0, (line.top + line.bottom) / 2))
            .dy;

        for (final x in [field.left + 1, field.left + 200]) {
          final seen = await _wi65Click(b, Offset(x, y));

          _wi65ExpectCaret(seen, contentEnd);
          await b.focusOutside();
          await _wi65Settle(tester);
        }
      }, variant: macOnly);
    }
  });

  // -------------------------------------------------------------------------
  // AC5: double clicks on a line the first click revealed
  // -------------------------------------------------------------------------
  group('double click (AC5)', () {
    testWidgets(
      'a double click on a word in a heading the first click revealed selects that word',
      (tester) async {
        const text = 'intro\n## Hi world\nnext line';
        final (:b, tabs: _) = await _wi65Pump(tester, text);
        final word = text.indexOf('world');
        final at = _wi65Center(b, word);

        await _wi65Clicks(tester, [at]);

        expect(_wi65Range(b.selection()), (word, word + 5));
        expect(b.view().focusedRow, 0);
        await _wi65Settle(tester);
        expect(_wi65Range(b.selection()), (word, word + 5));
      },
      variant: macOnly,
    );

    testWidgets(
      'a double click on a bold word the first click revealed selects that word',
      (tester) async {
        const text = 'see **bold** here\nnext line';
        final (:b, tabs: _) = await _wi65Pump(tester, text);
        final word = text.indexOf('bold');

        await _wi65Clicks(tester, [_wi65Center(b, word)]);

        expect(_wi65Range(b.selection()), (word, word + 4));
      },
      variant: macOnly,
    );

    testWidgets(
      'a double click on a line the first click revealed selects the same word a double click selects on that line already revealed',
      (tester) async {
        const text = '## Hi world\nnext line';
        final (:b, tabs: _) = await _wi65Pump(tester, text);
        final word = text.indexOf('world');

        // Today's range, on the line already revealed.
        await b.placeCaret(1);
        expect(_wi65Shown(b, 0), isTrue);
        await _wi65Clicks(tester, [_wi65Center(b, word + 1)]);
        final revealed = b.selection();
        expect(_wi65Range(revealed), (word, word + 5));
        await b.focusOutside();
        await _wi65Settle(tester);
        expect(_wi65Shown(b, 0), isFalse);

        await _wi65Clicks(tester, [_wi65Center(b, word + 1)]);

        expect(_wi65Range(b.selection()), _wi65Range(revealed));
      },
      variant: macOnly,
    );

    testWidgets(
      'a double click at the end of a word on a line the first click revealed selects that word',
      (tester) async {
        const text = 'intro\n## Hello world\nnext';
        final (:b, tabs: _) = await _wi65Pump(tester, text);
        final word = text.indexOf('Hello');

        await _wi65Clicks(tester, [_wi65RightHalf(b, word + 4)]);

        expect(_wi65Range(b.selection()), (word, word + 5));
      },
      variant: macOnly,
    );

    testWidgets(
      'a second click over another word within kDoubleTapSlop selects the first click word',
      (tester) async {
        const text = 'intro\n## Hi world\nnext line';
        final (:b, tabs: _) = await _wi65Pump(tester, text);
        final word = text.indexOf('world');
        final first = _wi65Center(b, word);
        final second = first - const Offset(40, 0);
        expect(
          _wi65OffsetAt(b, second),
          lessThan(word),
          reason: 'guard: the second press is over another word',
        );

        await _wi65Clicks(tester, [first, second]);

        expect(_wi65Range(b.selection()), (word, word + 5));
      },
      variant: macOnly,
    );

    testWidgets(
      'a second click exactly kDoubleTapSlop from the first on a revealing line is still a double click',
      (tester) async {
        const text = 'intro\n## Hi world and more words\nnext line';
        final (:b, tabs: _) = await _wi65Pump(tester, text);
        final word = text.indexOf('world');
        // `worl|d`: the left half of `d`, whole pixels.
        final g = _wi65LeftHalf(b, word + 4);
        final first = Offset(g.dx.roundToDouble(), g.dy.roundToDouble());
        expect(_wi65OffsetAt(b, first), word + 4, reason: 'seam guard');
        final second = first + const Offset(kDoubleTapSlop, 0);
        expect((second - first).distance, kDoubleTapSlop);

        await _wi65Clicks(tester, [first, second]);

        expect(_wi65Range(b.selection()), (word, word + 5));
      },
      variant: macOnly,
    );

    testWidgets(
      'a second click just inside kDoubleTapTimeout of the first release still selects the first click word',
      (tester) async {
        const text = 'intro\n## Hi world\nnext line';
        final (:b, tabs: _) = await _wi65Pump(tester, text);
        final word = text.indexOf('world');

        await _wi65Clicks(tester, [
          _wi65Center(b, word),
        ], gap: kDoubleTapTimeout - const Duration(milliseconds: 20));

        expect(_wi65Range(b.selection()), (word, word + 5));
      },
      variant: macOnly,
    );

    testWidgets(
      'two clicks in one frame on a revealing line select the first click word',
      (tester) async {
        const text = 'intro\n## Hi world\nnext line';
        final (:b, tabs: _) = await _wi65Pump(tester, text);
        final word = text.indexOf('world');
        final at = _wi65Center(b, word);

        // No frame between the presses: the second sees the first's state
        // before any rebuild.
        final one = await tester.startGesture(
          at,
          kind: PointerDeviceKind.mouse,
        );
        await one.up();
        final two = await tester.startGesture(
          at,
          kind: PointerDeviceKind.mouse,
        );
        await two.up();
        await tester.pump();

        expect(_wi65Range(b.selection()), (word, word + 5));
        await _wi65Settle(tester);
        expect(_wi65Range(b.selection()), (word, word + 5));
      },
      variant: macOnly,
    );

    testWidgets(
      'a second click after kDoubleTapTimeout on a revealed line is a plain click at its own press offset',
      (tester) async {
        const text = 'intro\n## Hi world\nnext line';
        final (:b, tabs: _) = await _wi65Pump(tester, text);
        final word = text.indexOf('world');
        await _wi65Click(b, _wi65Center(b, word));
        // The line is revealed now: the second press resolves on that layout.
        final second = _wi65RightHalf(b, word + 2);
        expect(_wi65OffsetAt(b, second), word + 3, reason: 'seam guard');

        final seen = await _wi65Click(b, second);

        _wi65ExpectCaret(seen, word + 3);
      },
      variant: macOnly,
    );

    testWidgets(
      'a second click past kDoubleTapSlop from the first is a plain click at its own press offset',
      (tester) async {
        const text = 'intro\n## Hi world and more words\nnext line';
        final (:b, tabs: _) = await _wi65Pump(tester, text);
        final word = text.indexOf('world');
        final g = _wi65Center(b, word);
        final first = Offset(g.dx.roundToDouble(), g.dy.roundToDouble());
        await tester.macClick(first);
        await tester.pump(const Duration(milliseconds: 50));
        final second = first + const Offset(kDoubleTapSlop + 1, 0);
        final pressed = _wi65OffsetAt(b, second);

        final seen = await _wi65Click(b, second);

        _wi65ExpectCaret(seen, pressed);
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // AC6: triple clicks on a line the first click revealed
  // -------------------------------------------------------------------------
  group('triple click (AC6)', () {
    testWidgets(
      'a triple click whose later clicks drift onto the next line selects the first click line',
      (tester) async {
        const text = 'intro\n## Hi world\nnext line';
        final (:b, tabs: _) = await _wi65Pump(tester, text);
        final line = text.indexOf('##');
        final first = _wi65Center(b, text.indexOf('world'));
        final below = _wi65Glyph(b, text.indexOf('next'));
        final drift = Offset(first.dx, below.center.dy);
        expect((drift - first).distance, lessThan(kDoubleTapSlop));

        // Today's range on an already-revealed line: the line with its
        // terminator (see the oracle test below).
        await _wi65Clicks(tester, [first, first, drift], count: 3);

        expect(_wi65Range(b.selection()), (line, text.indexOf('next')));
      },
      variant: macOnly,
    );

    // (text, a word on the line, a hidden marker on it, name).
    for (final (text, needle, marker, name) in [
      (
        'intro\n## Hi world\nnext line',
        'world',
        6,
        'a triple click on a heading the first click revealed selects the same range a triple click selects on that line already revealed',
      ),
      (
        'intro\n## Hi world',
        'world',
        6,
        'a triple click on a last heading line the first click revealed selects the same range a triple click selects on that line already revealed',
      ),
      (
        'see **bold** here\nnext line',
        'here',
        4,
        'a triple click on a bold line the first click revealed selects the same range a triple click selects on that line already revealed',
      ),
      (
        'intro\r\n## Hi world\r\nnext line',
        'world',
        7,
        'a triple click on a heading of a CRLF note the first click revealed selects the same range a triple click selects on that line already revealed',
      ),
    ]) {
      testWidgets(name, (tester) async {
        final (:b, tabs: _) = await _wi65Pump(tester, text);
        final at = text.indexOf(needle) + 1;
        final lineStart = text.lastIndexOf('\n', at) + 1;

        // Today's range, on the line already revealed.
        await b.placeCaret(lineStart + 1);
        await _wi65Clicks(tester, [_wi65Center(b, at)], count: 3);
        final revealed = b.selection();
        expect(revealed.start, lineStart, reason: 'oracle: $revealed');
        await b.focusOutside();
        await _wi65Settle(tester);
        expect(_wi65Shown(b, marker), isFalse);

        await _wi65Clicks(tester, [_wi65Center(b, at)], count: 3);

        expect(_wi65Range(b.selection()), _wi65Range(revealed));
      }, variant: macOnly);
    }
  });

  // -------------------------------------------------------------------------
  // AC7: a plain press on a followable link on an unrevealed line
  // -------------------------------------------------------------------------
  group('link presses (AC7)', () {
    testWidgets(
      'a plain press on a followable wikilink in an unrevealed heading follows it and places no caret',
      (tester) async {
        const text = '## See [[Known]] here\nnext';
        final (:b, :tabs) = await _wi65Pump(tester, text);
        final before = b.selection();

        final seen = await _wi65Click(
          b,
          _wi65Center(b, text.indexOf('Known') + 2),
        );

        expect(tabs.followed, [const NoteTab(_wi65KnownId)]);
        expect(seen.down, before);
        expect(seen.settled, before);
        expect(b.view().focusedRow, isNull);
        expect(_wi65Shown(b, 0), isFalse, reason: 'nothing revealed');
      },
      variant: macOnly,
    );

    testWidgets(
      'a plain press on a followable wikilink right after a click on another line follows it and keeps that click caret',
      (tester) async {
        const text = 'plain ok\nSee [[Known]] here';
        final (:b, :tabs) = await _wi65Pump(tester, text);
        final first = _wi65RightHalf(b, text.indexOf('ok') + 1);
        final link = _wi65Center(b, text.indexOf('Known') + 1);
        expect((link - first).distance, lessThan(kDoubleTapSlop));
        await tester.macClick(first);
        await tester.pump(const Duration(milliseconds: 50));
        final caret = b.selection();
        expect(_wi65Range(caret), (8, 8));

        await tester.macClick(link);
        await _wi65Settle(tester);

        expect(tabs.followed, [const NoteTab(_wi65KnownId)]);
        expect(_wi65Range(b.selection()), _wi65Range(caret));
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // AC8: Shift and Cmd presses inside the click window
  // -------------------------------------------------------------------------
  group('unchanged presses (AC8)', () {
    testWidgets(
      'a Shift click within the double click window after a click on a revealing line extends the selection from that click',
      (tester) async {
        const text = '## Hello world\nnext line';
        final (:b, tabs: _) = await _wi65Pump(tester, text);
        final first = _wi65RightHalf(b, text.indexOf('Hello') + 4);
        await tester.macClick(first);
        await tester.pump(const Duration(milliseconds: 50));
        final base = b.selection().baseOffset;
        final second = _wi65RightHalf(b, text.indexOf(' world'));
        expect((second - first).distance, lessThan(kDoubleTapSlop));
        final pressed = _wi65OffsetAt(b, second);

        await tester.macClick(second, shift: true);

        expect(_wi65Range(b.selection()), (base, pressed));
      },
      variant: macOnly,
    );

    testWidgets(
      'a Cmd click on a wikilink within the double click window after a click on a revealing line follows the link',
      (tester) async {
        const text = 'see [[Known]] ok\nnext line';
        final (:b, :tabs) = await _wi65Pump(tester, text);
        final first = _wi65RightHalf(b, text.indexOf('ok') + 1);
        await tester.macClick(first);
        await tester.pump(const Duration(milliseconds: 50));
        final link = _wi65Center(b, text.indexOf('Known') + 1);
        expect((link - first).distance, lessThan(kDoubleTapSlop));

        await tester.macCmdClick(link);
        await _wi65Settle(tester);

        expect(tabs.followed, [const NoteTab(_wi65KnownId)]);
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // Contracts of the row click chain (verify)
  // -------------------------------------------------------------------------
  group('contracts of the row click chain (verify)', () {
    testWidgets(
      'a click on the left half of a hash that starts an item row text keeps the press-time caret as the item holds no heading',
      (tester) async {
        const text = '- # item\nnext line';
        final (:b, tabs: _) = await _wi65Pump(tester, text);
        // `- |# item`: the left half of the hash, no heading marker here.
        final hash = text.indexOf('#');

        final seen = await _wi65Click(b, _wi65LeftHalf(b, hash));

        _wi65ExpectCaret(seen, hash);
      },
      variant: macOnly,
    );

    testWidgets(
      'a double click past the end of the last line of an unrevealed heading keeps a caret at the text end',
      (tester) async {
        const text = '## Hello world';
        final (:b, tabs: _) = await _wi65Pump(tester, text);
        final end = _wi65Glyph(b, text.length - 1);
        final past = Offset(end.right + 60, end.center.dy);

        await _wi65Clicks(tester, [past]);

        expect(_wi65Range(b.selection()), (text.length, text.length));
        await _wi65Settle(tester);
        expect(_wi65Range(b.selection()), (text.length, text.length));
      },
      variant: macOnly,
    );

    testWidgets(
      'a triple click past the end of the last line of an unrevealed heading selects that whole line',
      (tester) async {
        const text = 'intro\n## Hello world';
        final (:b, tabs: _) = await _wi65Pump(tester, text);
        final end = _wi65Glyph(b, text.length - 1);
        final past = Offset(end.right + 60, end.center.dy);

        await _wi65Clicks(tester, [past], count: 3);

        expect(_wi65Range(b.selection()), (6, text.length));
      },
      variant: macOnly,
    );
  });
}
