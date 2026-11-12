// WI #436 (Spec #392 req 1-4b, 8, 12, 15, 24): the spell-check scheduler
// wired into the note editor. Every test drives the real editor (live
// preview rows or Source mode's field) with the shared FakeSpellingService
// and FakeClock, and reads what was published from the editor's
// SpellIssueRegistry (field-local offsets).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/editor/editor_rows.dart';
import 'package:open_memex_app/src/editor/spell_issues.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/learned_words_seam.dart';
import 'package:open_memex_app/src/state/settings.dart';
import 'package:open_memex_app/src/state/spell_check_controller.dart';
import 'package:open_memex_app/src/state/spelling_service.dart';
import 'package:open_memex_app/src/theme/app_theme.dart';
import 'package:open_memex_app/src/widgets/editor/live_preview_controller.dart';
import 'package:open_memex_app/src/widgets/editor/segment_view.dart';
import 'package:open_memex_app/src/widgets/editor/segmented_body.dart';
import 'package:open_memex_app/src/widgets/editor/spell_check_host.dart';
import 'package:open_memex_app/src/widgets/editor/spell_issue_scope.dart';

import '../../support/fake_clock.dart';
import '../../support/fake_spelling_service.dart';
import '../../support/font_fetch_hold.dart';
import '../../support/segment_editing_finder.dart';
import '../../support/spelling_editor_pump.dart';

const _ms = Duration(milliseconds: 1);
const _debounce = Duration(milliseconds: 400);

typedef _Span = (SpellIssueKind, int, int);

const _sp = SpellIssueKind.spelling;
const _gr = SpellIssueKind.grammar;

/// [issues] as (kind, start, length), for compact expectations.
List<_Span> _spans(List<SpellIssue> issues) => [
  for (final i in issues) (i.kind, i.start, i.length),
];

TextEditingController _ctrlOf(WidgetTester tester, Finder field) =>
    tester.widget<EditableText>(field).controller;

/// What the editor published for the field at [field].
List<SpellIssue> _issuesAt(WidgetTester tester, Finder field) {
  final registry = SpellIssueScope.maybeOf(tester.element(field));
  expect(registry, isNotNull, reason: 'the field has a SpellIssueRegistry');
  return registry!.issuesFor(_ctrlOf(tester, field)).value;
}

List<_Span> _spansAt(WidgetTester tester, Finder field) =>
    _spans(_issuesAt(tester, field));

/// The texts of every `check` the fake received, in order.
List<String> _checked(FakeSpellingService s) => [
  for (final c in s.callsFor('check')) c.args['text']! as String,
];

int _checksOf(FakeSpellingService s, String text) =>
    _checked(s).where((t) => t == text).length;

/// Lets the editor open and its first checks go out and come back.
Future<void> _settle(SpellingEditorHarness e) async {
  await e.advance(const Duration(seconds: 1));
  await e.advance(const Duration(seconds: 1));
}

/// Focuses [field] and gives it [value] as the platform text input does
/// (typing, a caret move, a composing update).
Future<void> _input(
  WidgetTester tester,
  Finder field,
  TextEditingValue value,
) async {
  await tester.showKeyboard(field);
  await tester.pump();
  tester.testTextInput.updateEditingValue(value);
  await tester.pump();
}

TextEditingValue _value(String text, int caret, [TextRange? composing]) =>
    TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: caret),
      composing: composing ?? TextRange.empty,
    );

/// The controller of the note editor holding [field].
SpellCheckController? _controllerAt(WidgetTester tester, Finder field) =>
    SpellCheckScope.maybeOf(tester.element(field));

// ------------------------------------------------------------- long notes

/// [n] one-line paragraphs, `Line <i> is fine.`, blank lines between.
List<String> _lines(int n) => [for (var i = 0; i < n; i++) 'Line $i is fine.'];

String _long(List<String> paragraphs) => paragraphs.join('\n\n');

/// The offset of paragraph [i] of [paragraphs] in [_long]'s text.
int _offsetOf(List<String> paragraphs, int i) {
  var at = 0;
  for (var j = 0; j < i; j++) {
    at += paragraphs[j].length + 2;
  }
  return at;
}

ScrollableState _scrollable(WidgetTester tester, SpellingEditorHarness e) =>
    tester.state<ScrollableState>(
      find
          .ancestor(of: e.textSegment(0), matching: find.byType(Scrollable))
          .first,
    );

/// The editor viewport's global top and its height (one screen).
({double top, double height}) _viewport(
  WidgetTester tester,
  SpellingEditorHarness e,
) {
  final box = _scrollable(tester, e).context.findRenderObject()! as RenderBox;
  return (top: box.localToGlobal(Offset.zero).dy, height: box.size.height);
}

/// Where segment [offset] sits from the viewport's top, in px.
double _relTop(WidgetTester tester, SpellingEditorHarness e, int offset) =>
    segmentEditingAt(tester, 0).rectForOffset(offset).top -
    _viewport(tester, e).top;

/// Scrolls so segment [offset] sits [rel] px from the viewport's top.
Future<void> _scrollTo(
  WidgetTester tester,
  SpellingEditorHarness e,
  int offset,
  double rel,
) async {
  final position = _scrollable(tester, e).position;
  position.jumpTo(position.pixels + _relTop(tester, e, offset) - rel);
  await tester.pump();
  await e.advance(_debounce);
}

// ---------------------------------------------------- two-notes harness

/// The learned keys the two-notes harness feeds `learnedWordKeysProvider`.
final _wi436Keys = StateProvider<Set<String>>((ref) => const {});

Note _wi436Note(String id, String content) => Note(
  id: id,
  title: id,
  contentMd: content,
  frontmatter: '{"role":"topic"}',
  version: 1,
  createdAt: 0,
  updatedAt: 0,
  tags: const [],
);

/// Two note editors (live preview) open side by side in one app.
Future<ProviderContainer> _wi436PumpTwoNotes(
  WidgetTester tester, {
  required FakeSpellingService spelling,
  required FakeClock clock,
  required String body,
}) async {
  tester.view.physicalSize = const Size(1600, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  Widget editor(String id) => Expanded(
    child: SegmentedBody(
      note: _wi436Note(id, body),
      content: body,
      savedVersion: 1,
      onContentChanged: (_) {},
    ),
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        spellingServiceProvider.overrideWithValue(spelling),
        clockProvider.overrideWithValue(clock),
        learnedWordKeysProvider.overrideWith((ref) => ref.watch(_wi436Keys)),
        spellCheckFlagsProvider.overrideWithValue((
          spelling: true,
          grammar: true,
        )),
      ],
      child: MaterialApp(
        theme: buildOmTheme(),
        home: Scaffold(
          body: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [editor('topic-436-a'), editor('topic-436-b')],
          ),
        ),
      ),
    ),
  );
  for (var i = 0; i < 4; i++) {
    clock.advance(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 50));
  }
  return ProviderScope.containerOf(
    tester.element(find.byType(SegmentedBody).first),
  );
}

Finder _bodyField(int i) => find.descendant(
  of: find.byType(SegmentedBody).at(i),
  matching: find.byType(EditableText),
);

// ---------------------------------------------------- bare host harness

/// A `check` that throws, as a crashed native channel does.
class _Wi436ThrowingService extends FakeSpellingService {
  @override
  Future<SpellCheckReply?> check({
    required int requestId,
    required String text,
    required int documentTag,
    required bool spelling,
    required bool grammar,
  }) {
    calls.add(SpellingCall('check', {'text': text}));
    return Future<SpellCheckReply?>.error(StateError('channel gone'));
  }
}

/// A `documentTag` the test answers itself, answering null by default.
class _Wi436LateTagService extends FakeSpellingService {
  final answers = <Completer<int?>>[];

  @override
  Future<int?> documentTag(String noteId) {
    calls.add(SpellingCall('documentTag', {'noteId': noteId}));
    final c = Completer<int?>();
    answers.add(c);
    return c.future;
  }
}

/// One [SpellCheckHost] over one plain field, with no note editor around it.
class _Wi436Host {
  _Wi436Host(
    this.tester, {
    required this.service,
    this.withFlags = true,
    this.childOf,
    TextEditingController? controller,
  }) : clock = FakeClock(),
       registry = SpellIssueRegistry(),
       ctrl = controller ?? TextEditingController();

  final WidgetTester tester;
  final FakeSpellingService service;
  final FakeClock clock;
  final SpellIssueRegistry registry;
  final bool withFlags;

  /// The widget under the field wrapper; a [TextField] by default.
  final Widget Function(TextEditingController)? childOf;
  TextEditingController ctrl;

  late final overrides = [
    spellingServiceProvider.overrideWithValue(service),
    clockProvider.overrideWithValue(clock),
    if (withFlags)
      spellCheckFlagsProvider.overrideWithValue((
        spelling: true,
        grammar: true,
      )),
  ];

  Future<void> pump(String noteId, {TextEditingController? field}) async {
    ctrl = field ?? ctrl;
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides,
        child: MaterialApp(
          home: Scaffold(
            body: SpellIssueScope(
              registry: registry,
              child: SpellCheckHost(
                noteId: noteId,
                registry: registry,
                child: SpellCheckField(
                  controller: ctrl,
                  child: childOf?.call(ctrl) ?? TextField(controller: ctrl),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await advance(const Duration(seconds: 1));
  }

  Future<void> advance(Duration d) async {
    clock.advance(d);
    await tester.pump(d);
    await tester.pump();
  }

  SpellCheckController get controller =>
      SpellCheckScope.maybeOf(tester.element(find.byType(TextField)))!;

  List<_Span> get spans => _spans(registry.issuesFor(ctrl).value);
}

void main() {
  holdFontFetches();

  // ------------------------------------------------------------- AC1

  group('debounce (AC1)', () {
    testWidgets(
      'typing sends no check until 400 ms after the last change and then exactly one',
      (tester) async {
        final spelling = FakeSpellingService()..misspell('teh');
        final e = await pumpSpellingEditor(
          tester,
          body: 'Good word.',
          spelling: spelling,
        );
        await _settle(e);
        expect(_checked(spelling), contains('Good word.'));
        spelling.clearCalls();

        await e.typeAtEnd(' teh more');
        expect(spelling.count('check'), 0, reason: 'no check while typing');
        await e.advance(_debounce - _ms);
        expect(spelling.count('check'), 0, reason: '399 ms after the change');

        // Typing again within 400 ms restarts the wait.
        await e.typeAtEnd(' x');
        await e.advance(_debounce - _ms);
        expect(spelling.count('check'), 0, reason: '399 ms after the last');
        await e.advance(_ms);
        expect(_checked(spelling), ['Good word. teh more x']);

        await e.advance(const Duration(seconds: 2));
        expect(spelling.count('check'), 1, reason: 'one edit, one check');
        expect(_spansAt(tester, e.rowFields(0).first), [(_sp, 11, 3)]);
      },
    );

    testWidgets('the note title is never sent for checking', (tester) async {
      final spelling = FakeSpellingService();
      final e = await pumpSpellingEditor(
        tester,
        body: 'Good word.',
        spelling: spelling,
      );
      await _settle(e);
      await e.typeAtEnd(' More.');
      await _settle(e);
      expect(_checked(spelling), isNot(contains('Player Loop')));
      expect(_checked(spelling), contains('Good word. More.'));
    });
  });

  // ------------------------------------------------------------- AC2

  group('viewport (AC2)', () {
    testWidgets(
      'paragraphs within one screen of the viewport are checked at open and farther ones are not',
      (tester) async {
        final spelling = FakeSpellingService();
        final paragraphs = _lines(200);
        final e = await pumpSpellingEditor(
          tester,
          body: _long(paragraphs),
          spelling: spelling,
        );
        await _settle(e);
        final h = _viewport(tester, e).height;
        var near = 0;
        var far = 0;
        for (var i = 0; i < paragraphs.length; i++) {
          final top = _relTop(tester, e, _offsetOf(paragraphs, i));
          if (top < 2 * h - 40) {
            near++;
            expect(
              _checksOf(spelling, paragraphs[i]),
              1,
              reason:
                  '${paragraphs[i]} at ${top.round()} px is within a screen',
            );
          } else if (top > 2 * h + 40) {
            far++;
            expect(
              _checksOf(spelling, paragraphs[i]),
              0,
              reason: '${paragraphs[i]} at ${top.round()} px is too far',
            );
          }
        }
        expect(near, greaterThan(5));
        expect(far, greaterThan(5));
      },
    );

    testWidgets(
      'a paragraph two screens below is checked only once scrolling brings it within one screen',
      (tester) async {
        final spelling = FakeSpellingService();
        final paragraphs = _lines(200);
        final e = await pumpSpellingEditor(
          tester,
          body: _long(paragraphs),
          spelling: spelling,
        );
        await _settle(e);
        final h = _viewport(tester, e).height;
        final t = List.generate(paragraphs.length, (i) => i).firstWhere(
          (i) => _relTop(tester, e, _offsetOf(paragraphs, i)) > 2.6 * h,
        );
        final target = paragraphs[t];
        final at = _offsetOf(paragraphs, t);
        expect(_checksOf(spelling, target), 0);

        // Still more than one screen below the viewport.
        await _scrollTo(tester, e, at, 2.25 * h);
        expect(_checksOf(spelling, target), 0, reason: 'at 2.25 screens');

        // Within one screen below.
        await _scrollTo(tester, e, at, 1.5 * h);
        expect(_checksOf(spelling, target), 1, reason: 'at 1.5 screens');

        // In view: no second check.
        await _scrollTo(tester, e, at, 0.3 * h);
        await e.advance(const Duration(seconds: 1));
        expect(_checksOf(spelling, target), 1, reason: 'exactly once');
      },
    );

    testWidgets(
      'a paragraph more than one screen above is not checked after an edit until it comes within one screen',
      (tester) async {
        final spelling = FakeSpellingService();
        final paragraphs = _lines(200);
        final e = await pumpSpellingEditor(
          tester,
          body: _long(paragraphs),
          spelling: spelling,
        );
        await _settle(e);
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pump();
        final h = _viewport(tester, e).height;
        await _scrollTo(tester, e, 0, -2.6 * h);

        // 'Line 0 is fine.' -> 'Line 0 changed.'
        (segmentEditingAt(tester, 0) as SegmentViewState).applyEdit(
          const SegmentEdit(start: 7, end: 14, replacement: 'changed'),
        );
        await tester.pump();
        expect(_relTop(tester, e, 0), lessThan(-2 * h));
        await e.advance(const Duration(seconds: 2));
        expect(
          _checksOf(spelling, 'Line 0 changed.'),
          0,
          reason: 'more than one screen above the viewport',
        );

        // Still more than one screen above the viewport.
        await _scrollTo(tester, e, 0, -1.5 * h);
        await e.advance(const Duration(seconds: 1));
        expect(
          _checksOf(spelling, 'Line 0 changed.'),
          0,
          reason: 'at 1.5 screens above',
        );

        // Within one screen above.
        await _scrollTo(tester, e, 0, -0.9 * h);
        await e.advance(const Duration(seconds: 1));
        expect(
          _checksOf(spelling, 'Line 0 changed.'),
          1,
          reason: 'at 0.9 screens above',
        );

        // In view: no second check.
        await _scrollTo(tester, e, 0, 0.1 * h);
        await e.advance(const Duration(seconds: 1));
        expect(
          _checksOf(spelling, 'Line 0 changed.'),
          1,
          reason: 'exactly once',
        );
      },
    );
  });

  // ------------------------------------------------------------- AC3

  group('cache (AC3)', () {
    testWidgets(
      'scrolling back to an unchanged checked paragraph sends no check and changing it sends one',
      (tester) async {
        final spelling = FakeSpellingService();
        final paragraphs = _lines(200);
        final e = await pumpSpellingEditor(
          tester,
          body: _long(paragraphs),
          spelling: spelling,
        );
        await _settle(e);
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pump();
        expect(_checksOf(spelling, paragraphs.first), 1);

        final position = _scrollable(tester, e).position;
        position.jumpTo(position.maxScrollExtent);
        await tester.pump();
        await e.advance(const Duration(seconds: 1));
        expect(_checksOf(spelling, paragraphs.last), 1);
        final h = _viewport(tester, e).height;
        expect(_relTop(tester, e, 0), lessThan(-2 * h));
        final before = spelling.count('check');

        position.jumpTo(0);
        await tester.pump();
        await e.advance(const Duration(seconds: 1));
        expect(
          spelling.count('check'),
          before,
          reason: 'scrolling back sends no check',
        );
        expect(_checksOf(spelling, paragraphs.first), 1);

        (segmentEditingAt(tester, 0) as SegmentViewState).applyEdit(
          SegmentEdit(
            start: paragraphs.first.length,
            end: paragraphs.first.length,
            replacement: ' Ok',
          ),
        );
        await tester.pump();
        await e.advance(_debounce);
        await e.advance(const Duration(seconds: 1));
        expect(spelling.count('check'), before + 1);
        expect(_checked(spelling).last, 'Line 0 is fine. Ok');
      },
    );
  });

  // ------------------------------------------------------------- AC4

  group('request ids (AC4)', () {
    testWidgets(
      'a reply for a paragraph whose text changed after the request is discarded',
      (tester) async {
        final spelling = FakeSpellingService()
          ..misspell('teh')
          ..holdReplies = true;
        final e = await pumpSpellingEditor(
          tester,
          body: 'teh cat.',
          spelling: spelling,
        );
        await _settle(e);
        expect([for (final h in spelling.held) h.text], ['teh cat.']);
        final first = spelling.held.single;

        await e.typeAtEnd('x');
        // Answers the old text with an issue on cat.
        first.reply([
          SpellIssue(kind: _sp, start: 4, length: 3, corrections: ['cut']),
        ]);
        await tester.pump();
        await tester.pump();
        expect(_spansAt(tester, e.rowFields(0).first), isEmpty);

        await e.advance(_debounce);
        final second = spelling.held.singleWhere((h) => h.text == 'teh cat.x');
        second.reply();
        await tester.pump();
        await tester.pump();
        expect(_spansAt(tester, e.rowFields(0).first), [(_sp, 0, 3)]);
      },
    );

    testWidgets(
      'a discarded stale reply is not cached and the text is checked afresh when it returns',
      (tester) async {
        final spelling = FakeSpellingService()
          ..misspell('teh')
          ..holdReplies = true;
        final e = await pumpSpellingEditor(
          tester,
          body: 'teh cat.',
          spelling: spelling,
        );
        await _settle(e);
        final first = spelling.held.single;
        await e.typeAtEnd('x');
        first.reply([
          SpellIssue(kind: _sp, start: 4, length: 3, corrections: ['cut']),
        ]);
        await tester.pump();
        await tester.pump();

        // The text comes back: the stale answer must not be served.
        await e.robot.typeInSegment(0, 'teh cat.');
        await tester.pump();
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pump();
        await e.advance(_debounce);
        final again = spelling.held.where((h) => h.text == 'teh cat.').toList();
        expect(
          again,
          hasLength(2),
          reason: 'sent again, not served from cache',
        );
        expect(_spansAt(tester, e.rowFields(0).first), isEmpty);

        again.last.reply();
        await tester.pump();
        await tester.pump();
        expect(_spansAt(tester, e.rowFields(0).first), [(_sp, 0, 3)]);
      },
    );

    for (final (name, order) in [
      (
        'a reply for a superseded request id is discarded when it arrives first',
        [0, 1, 2],
      ),
      (
        'a reply for a superseded request id is discarded when it arrives last',
        [2, 1, 0],
      ),
    ]) {
      testWidgets(name, (tester) async {
        final spelling = FakeSpellingService()
          ..misspell('teh')
          ..holdReplies = true;
        final e = await pumpSpellingEditor(
          tester,
          body: 'teh cat.',
          spelling: spelling,
        );
        await _settle(e);
        expect([for (final h in spelling.held) h.text], ['teh cat.']);
        final h1 = spelling.held.single;

        await e.typeAtEnd('x');
        await e.advance(_debounce);
        final h2 = spelling.held.singleWhere((h) => h.text == 'teh cat.x');

        // Back to the first text: the first request is superseded, so the
        // paragraph is sent again.
        await e.robot.typeInSegment(0, 'teh cat.');
        await tester.pump();
        await e.advance(_debounce);
        final again = spelling.held.where((h) => h.text == 'teh cat.').toList();
        expect(again, hasLength(2), reason: 'the paragraph is sent again');
        final h3 = again.last;
        expect(h3.requestId, greaterThan(h2.requestId));
        expect(h2.requestId, greaterThan(h1.requestId));

        final cat = [
          SpellIssue(kind: _sp, start: 4, length: 3, corrections: ['cut']),
        ];
        final replies = [
          () => h1.reply(cat),
          () => h2.reply(cat),
          () => h3.reply(),
        ];
        for (final i in order) {
          replies[i]();
          await tester.pump();
          await tester.pump();
          final now = _spansAt(tester, e.rowFields(0).first);
          expect(now, isNot(contains((_sp, 4, 3))), reason: 'after reply $i');
        }
        expect(_spansAt(tester, e.rowFields(0).first), [(_sp, 0, 3)]);
      });
    }
  });

  // ------------------------------------------------------------- AC5

  group('edits shift issues (AC5)', () {
    // One prose row, two paragraphs: teh at 0 and at 16.
    const body = 'teh first.\n\nOne teh two.';

    Future<SpellingEditorHarness> pump(WidgetTester tester) async {
      final e = await pumpSpellingEditor(
        tester,
        body: body,
        spelling: FakeSpellingService()..misspell('teh'),
      );
      await _settle(e);
      expect(_spansAt(tester, e.rowFields(0).first), [
        (_sp, 0, 3),
        (_sp, 16, 3),
      ]);
      return e;
    }

    testWidgets(
      'inserting text before a later issue shifts it and other paragraphs keep theirs',
      (tester) async {
        final e = await pump(tester);
        final field = e.rowFields(0).first;
        await _input(
          tester,
          field,
          _value('teh first.\n\nBig One teh two.', 16),
        );
        expect(_spansAt(tester, field), [(_sp, 0, 3), (_sp, 20, 3)]);
        expect(e.spelling.count('check'), greaterThan(0));
      },
    );

    testWidgets(
      'deleting text before a later issue shifts it back by the deleted length',
      (tester) async {
        final e = await pump(tester);
        final field = e.rowFields(0).first;
        // 'One ' deleted.
        await _input(tester, field, _value('teh first.\n\nteh two.', 12));
        expect(_spansAt(tester, field), [(_sp, 0, 3), (_sp, 12, 3)]);
      },
    );

    testWidgets('typing inside a flagged range removes its issue at once', (
      tester,
    ) async {
      final e = await pump(tester);
      final field = e.rowFields(0).first;
      await _input(tester, field, _value('teh first.\n\nOne texh two.', 19));
      expect(_spansAt(tester, field), [(_sp, 0, 3)]);
    });

    testWidgets('an edit overlapping an issue drops it', (tester) async {
      final e = await pump(tester);
      final field = e.rowFields(0).first;
      // 'One t' (12..17) replaced by 'A '.
      await _input(tester, field, _value('teh first.\n\nA eh two.', 14));
      expect(_spansAt(tester, field), [(_sp, 0, 3)]);
    });

    // Lead ruling Q2: an edit at an issue's edge drops it only when the
    // typed character extends the word. teh at 0..3 and 16..19.
    for (final (name, at, typed, spans) in [
      (
        'a word character typed right after a flagged word drops its issue at once',
        3,
        's',
        [(_sp, 17, 3)],
      ),
      (
        'a non-word character typed right after a flagged word keeps its issue',
        3,
        ',',
        [(_sp, 0, 3), (_sp, 17, 3)],
      ),
      (
        'a word character typed right before a flagged word drops its issue at once',
        16,
        'x',
        [(_sp, 0, 3)],
      ),
      (
        'a non-word character typed right before a flagged word moves its issue',
        16,
        '-',
        [(_sp, 0, 3), (_sp, 17, 3)],
      ),
    ]) {
      testWidgets(name, (tester) async {
        final e = await pump(tester);
        final field = e.rowFields(0).first;
        await _input(
          tester,
          field,
          _value(body.replaceRange(at, at, typed), at + 1),
        );
        expect(_spansAt(tester, field), spans);
      });
    }

    testWidgets(
      'an edit in one row leaves the issues of other rows unchanged',
      (tester) async {
        final e = await pumpSpellingEditor(
          tester,
          body: 'Some teh here.\n- teh item',
          spelling: FakeSpellingService()..misspell('teh'),
        );
        await _settle(e);
        final prose = e.rowFields(0).at(0);
        final item = e.rowFields(0).at(1);
        expect(_spansAt(tester, item), [(_sp, 0, 3)]);
        await _input(tester, prose, _value('Big Some teh here.', 4));
        expect(_spansAt(tester, prose), [(_sp, 9, 3)]);
        expect(_spansAt(tester, item), [(_sp, 0, 3)]);
      },
    );
  });

  // ------------------------------------------------------------- AC6

  group('caret (AC6)', () {
    // 'Good teh word.': teh at 5..8.
    for (final (name, caret, shown) in [
      (
        'a caret touching the start of a misspelled word holds its issue',
        5,
        false,
      ),
      ('a caret inside a misspelled word holds its issue', 7, false),
      (
        'a caret touching the end of a misspelled word holds its issue',
        8,
        false,
      ),
      ('a caret one before a misspelled word lets its issue show', 4, true),
      ('a caret one after a misspelled word lets its issue show', 9, true),
    ]) {
      testWidgets(name, (tester) async {
        final e = await pumpSpellingEditor(
          tester,
          body: 'Good word.',
          spelling: FakeSpellingService()..misspell('teh'),
        );
        await _settle(e);
        final field = e.rowFields(0).first;
        await _input(tester, field, _value('Good teh word.', caret));
        await e.advance(_debounce);
        await e.advance(_debounce);
        expect(_checked(e.spelling), contains('Good teh word.'));
        expect(
          _spansAt(tester, field),
          shown ? [(_sp, 5, 3)] : isEmpty,
          reason: 'caret at $caret',
        );
      });
    }

    testWidgets(
      'a misspelled word under the caret is published once the caret leaves it',
      (tester) async {
        final e = await pumpSpellingEditor(
          tester,
          body: 'Good word.',
          spelling: FakeSpellingService()..misspell('teh'),
        );
        await _settle(e);
        final field = e.rowFields(0).first;
        await _input(tester, field, _value('Good teh word.', 7));
        await e.advance(_debounce);
        await e.advance(const Duration(seconds: 1));
        expect(_spansAt(tester, field), isEmpty, reason: 'caret in the word');
        final checks = e.spelling.count('check');

        await _input(tester, field, _value('Good teh word.', 0));
        expect(_spansAt(tester, field), [(_sp, 5, 3)]);
        expect(e.spelling.count('check'), checks, reason: 'no new check');
      },
    );

    testWidgets(
      'a grammar issue covering the caret sentence appears only after the 400 ms pause',
      (tester) async {
        final e = await pumpSpellingEditor(
          tester,
          body: 'He go home. She go out.',
          spelling: FakeSpellingService()
            ..flagGrammar('He go', description: 'Agreement')
            ..flagGrammar('She go', description: 'Agreement'),
        );
        await _settle(e);
        final field = e.rowFields(0).first;
        expect(_spansAt(tester, field), [(_gr, 0, 5), (_gr, 12, 6)]);

        // Typing in the first sentence: 'home' -> 'homes'.
        await _input(tester, field, _value('He go homes. She go out.', 11));
        expect(_spansAt(tester, field), [
          (_gr, 13, 6),
        ], reason: 'the caret sentence issue waits; the other one shifts');
        await e.advance(_debounce - _ms);
        expect(_spansAt(tester, field), [(_gr, 13, 6)], reason: 'at 399 ms');
        await e.advance(_ms);
        expect(_spansAt(tester, field), [(_gr, 0, 5), (_gr, 13, 6)]);
      },
    );
  });

  // ------------------------------------------------- caret needs focus

  group('caret holds only while the field has focus (review r1)', () {
    void unfocus(WidgetTester tester) {
      FocusManager.instance.primaryFocus?.unfocus();
    }

    testWidgets(
      'a held misspelled word is published when focus leaves the field and stays when focus returns',
      (tester) async {
        final e = await pumpSpellingEditor(
          tester,
          body: 'Good word.',
          spelling: FakeSpellingService()..misspell('teh'),
        );
        await _settle(e);
        final field = e.rowFields(0).first;
        await _input(tester, field, _value('Good teh word.', 8));
        await e.advance(_debounce);
        await e.advance(const Duration(seconds: 1));
        expect(_checked(e.spelling), contains('Good teh word.'));
        expect(_spansAt(tester, field), isEmpty, reason: 'caret touches it');
        final checks = e.spelling.count('check');

        unfocus(tester);
        await tester.pump();
        expect(_spansAt(tester, field), [(_sp, 5, 3)], reason: 'focus left');
        expect(e.spelling.count('check'), checks, reason: 'no new check');

        // Back with the caret on the word: an issue already shown stays.
        await _input(tester, field, _value('Good teh word.', 8));
        expect(_spansAt(tester, field), [(_sp, 5, 3)], reason: 'focus back');
      },
    );

    testWidgets(
      'a reply that arrives after the field lost focus is published at once',
      (tester) async {
        final e = await pumpSpellingEditor(
          tester,
          body: 'Good word.',
          spelling: FakeSpellingService()..misspell('teh'),
        );
        await _settle(e);
        final field = e.rowFields(0).first;
        await _input(tester, field, _value('Good teh word.', 8));
        unfocus(tester);
        await tester.pump();
        await e.advance(_debounce);
        await e.advance(const Duration(seconds: 1));
        expect(_checked(e.spelling), contains('Good teh word.'));
        expect(_spansAt(tester, field), [(_sp, 5, 3)]);
      },
    );

    testWidgets(
      'Source mode publishes a word under the caret once the field lost focus before the reply',
      (tester) async {
        final e = await pumpSpellingEditor(
          tester,
          body: 'Good word.',
          source: true,
          spelling: FakeSpellingService()..misspell('teh'),
        );
        await _settle(e);
        await _input(tester, e.sourceField, _value('Good teh', 8));
        unfocus(tester);
        await tester.pump();
        await e.advance(_debounce);
        await e.advance(const Duration(seconds: 1));
        expect(_checked(e.spelling), contains('Good teh'));
        expect(_spansAt(tester, e.sourceField), [(_sp, 5, 3)]);
      },
    );

    testWidgets(
      'Source mode publishes a misspelling at the very end of a note opened without focus',
      (tester) async {
        // Hydrating Source mode puts the caret at the end of the text
        // without focusing the field.
        final e = await pumpSpellingEditor(
          tester,
          body: 'see you tomorow',
          source: true,
          spelling: FakeSpellingService()..misspell('tomorow'),
        );
        await _settle(e);
        final ctrl = _ctrlOf(tester, e.sourceField);
        expect(ctrl.selection.baseOffset, ctrl.text.length);
        expect(_spansAt(tester, e.sourceField), [(_sp, 8, 7)]);
      },
    );

    testWidgets(
      'a grammar issue in the caret sentence is published when focus leaves the field',
      (tester) async {
        final e = await pumpSpellingEditor(
          tester,
          body: 'He go home. She go out.',
          spelling: FakeSpellingService()
            ..flagGrammar('He go', description: 'Agreement')
            ..flagGrammar('She go', description: 'Agreement'),
        );
        await _settle(e);
        final field = e.rowFields(0).first;
        await _input(tester, field, _value('He go homes. She go out.', 11));
        expect(_spansAt(tester, field), [(_gr, 13, 6)]);

        unfocus(tester);
        await tester.pump();
        expect(_spansAt(tester, field), [
          (_gr, 0, 5),
          (_gr, 13, 6),
        ], reason: 'no caret, no sentence hold');
      },
    );

    testWidgets(
      'focus leaving a field that does not touch its controller republishes a held word',
      (tester) async {
        // A bare focus node: unlike an EditableText, nothing here notifies
        // the controller when focus moves, so only the wrapper's focus
        // listener can publish the word.
        final node = FocusNode();
        addTearDown(node.dispose);
        final host = _Wi436Host(
          tester,
          service: FakeSpellingService()..misspell('teh'),
          childOf: (_) => Focus(focusNode: node, child: const SizedBox()),
        );
        await host.pump('note-focus-node');
        node.requestFocus();
        await tester.pump();
        host.ctrl.value = _value('Good teh word.', 8);
        await tester.pump();
        await host.advance(_debounce);
        await host.advance(const Duration(seconds: 1));
        expect(_checked(host.service), ['Good teh word.']);
        expect(host.spans, isEmpty, reason: 'held under the caret');

        node.unfocus();
        await tester.pump();
        expect(host.spans, [(_sp, 5, 3)], reason: 'focus left');

        node.requestFocus();
        await tester.pump();
        expect(host.spans, [(_sp, 5, 3)], reason: 'shown words stay');
      },
    );

    testWidgets(
      'a focus change in a field the checker does not know changes nothing',
      (tester) async {
        final host = _Wi436Host(tester, service: FakeSpellingService());
        await host.pump('note-focus');
        final checks = host.service.count('check');
        host.controller.focusChanged(TextEditingController());
        await tester.pump();
        expect(host.service.count('check'), checks);
        expect(host.spans, isEmpty);
      },
    );
  });

  // ------------------------------------------------------------- AC7

  group('composition (AC7)', () {
    testWidgets(
      'a paragraph with a composing range is not sent until composition ends',
      (tester) async {
        final e = await pumpSpellingEditor(
          tester,
          body: 'Good day.',
          spelling: FakeSpellingService()..misspell('ni'),
        );
        await _settle(e);
        final field = e.rowFields(0).first;
        e.spelling.clearCalls();

        await _input(
          tester,
          field,
          _value('Good day. ni', 12, const TextRange(start: 10, end: 12)),
        );
        await e.advance(_debounce);
        await e.advance(const Duration(seconds: 2));
        expect(
          e.spelling.count('check'),
          0,
          reason: 'no check while the paragraph composes',
        );
        expect(_spansAt(tester, field), isEmpty);

        await _input(tester, field, _value('Good day. ni ', 13));
        await e.advance(_debounce);
        await e.advance(const Duration(seconds: 1));
        expect(e.spelling.count('check'), 1);
        expect(_checked(e.spelling).single, startsWith('Good day. ni'));
        expect(_spansAt(tester, field), [(_sp, 10, 2)]);
      },
    );

    testWidgets(
      'ending composition with the text unchanged lets the paragraph be checked',
      (tester) async {
        final e = await pumpSpellingEditor(
          tester,
          body: 'Good day.',
          spelling: FakeSpellingService()..misspell('ni'),
        );
        await _settle(e);
        final field = e.rowFields(0).first;
        e.spelling.clearCalls();

        await _input(
          tester,
          field,
          _value('Good day. ni', 12, const TextRange(start: 10, end: 12)),
        );
        await e.advance(_debounce);
        await e.advance(const Duration(seconds: 2));
        expect(e.spelling.count('check'), 0);

        // Return on the marked text: the composing range clears and the
        // text stays as it is.
        await _input(tester, field, _value('Good day. ni', 12));
        await e.advance(_debounce - _ms);
        expect(e.spelling.count('check'), 0, reason: 'at 399 ms');
        await e.advance(_ms);
        await e.advance(const Duration(seconds: 1));
        expect(_checked(e.spelling), ['Good day. ni']);

        // The caret still touches the word; leaving the field shows it.
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pump();
        expect(_spansAt(tester, field), [(_sp, 10, 2)]);
      },
    );

    testWidgets('the composing range never has an issue', (tester) async {
      final e = await pumpSpellingEditor(
        tester,
        body: 'Good teh day.',
        spelling: FakeSpellingService()..misspell('teh'),
      );
      await _settle(e);
      final field = e.rowFields(0).first;
      expect(_spansAt(tester, field), [(_sp, 5, 3)]);

      // Marked text over 'teh ' (5..9), the caret after it.
      await _input(
        tester,
        field,
        _value('Good teh day.', 9, const TextRange(start: 5, end: 9)),
      );
      expect(_spansAt(tester, field), isEmpty);
      await e.advance(const Duration(seconds: 2));
      expect(_spansAt(tester, field), isEmpty);
    });
  });

  // ------------------------------------------------------------- AC8

  group('learned words (AC8)', () {
    testWidgets(
      'a spelling issue for a capitalised word is dropped when its lowercase key is learned',
      (tester) async {
        final e = await pumpSpellingEditor(
          tester,
          body: 'Émile met teh crew.',
          learnedKeys: const {'émile'},
          spelling: FakeSpellingService()
            ..misspell('Émile')
            ..misspell('teh'),
        );
        await _settle(e);
        expect(_checked(e.spelling), contains('Émile met teh crew.'));
        expect(_spansAt(tester, e.rowFields(0).first), [(_sp, 10, 3)]);
      },
    );

    testWidgets(
      'adding a learned key removes the issues of that word in two open notes at once with zero new checks',
      (tester) async {
        final spelling = FakeSpellingService()
          ..misspell('Émile')
          ..misspell('teh');
        final container = await _wi436PumpTwoNotes(
          tester,
          spelling: spelling,
          clock: FakeClock(),
          body: 'Émile met teh crew.',
        );
        expect(_spansAt(tester, _bodyField(0).first), [
          (_sp, 0, 5),
          (_sp, 10, 3),
        ]);
        expect(_spansAt(tester, _bodyField(1).first), [
          (_sp, 0, 5),
          (_sp, 10, 3),
        ]);
        final checks = spelling.count('check');

        container.read(_wi436Keys.notifier).state = {'émile'};
        await tester.pump();

        expect(_spansAt(tester, _bodyField(0).first), [(_sp, 10, 3)]);
        expect(_spansAt(tester, _bodyField(1).first), [(_sp, 10, 3)]);
        expect(spelling.count('check'), checks, reason: 'no re-check');
      },
    );
  });

  // ------------------------------------------------------------- AC9

  group('skip-range filters (AC9)', () {
    testWidgets(
      'a spelling result inside a wikilink a url a tag or code is dropped',
      (tester) async {
        const body =
            'See [[teh]] and https://teh.example.com and #teh and `teh` then teh ok.';
        final e = await pumpSpellingEditor(
          tester,
          body: body,
          spelling: FakeSpellingService()..misspell('teh'),
        );
        await _settle(e);
        expect(_checked(e.spelling), contains(body));
        expect(_spansAt(tester, e.rowFields(0).first), [
          (_sp, body.indexOf('teh ok'), 3),
        ]);
      },
    );

    testWidgets(
      'a grammar result is dropped only when it intersects code a wikilink a transclusion or a url',
      (tester) async {
        const body =
            'Note [[Alpha Topic]] here. Run `code x` now. Go https://a.example.com fast. '
            'Tag #blue ok. Mark **bold** it. Peek ![[2026-09-05]] end.';
        final e = await pumpSpellingEditor(
          tester,
          body: body,
          spelling: FakeSpellingService()
            ..flagGrammar('Note [[Alpha', description: 'wikilink')
            ..flagGrammar('Run `code', description: 'code')
            ..flagGrammar('Go https', description: 'url')
            ..flagGrammar('Tag #blue', description: 'tag')
            ..flagGrammar('Mark **bold', description: 'marker')
            ..flagGrammar('Peek ![[', description: 'transclusion'),
        );
        await _settle(e);
        expect(_checked(e.spelling), contains(body));
        expect(_spansAt(tester, e.rowFields(0).first), [
          (_gr, body.indexOf('Tag #blue'), 9),
          (_gr, body.indexOf('Mark **bold'), 11),
        ]);
      },
    );

    testWidgets(
      'item rows send their text without the marker and publish field-local offsets',
      (tester) async {
        final e = await pumpSpellingEditor(
          tester,
          body:
              'Intro ok.\n- teh item\n- [ ] teh task\n> teh quote\n# teh head',
          spelling: FakeSpellingService()..misspell('teh'),
        );
        await _settle(e);
        final rows = e.rowFields(0);
        final texts = [
          for (var i = 0; i < rows.evaluate().length; i++)
            _ctrlOf(tester, rows.at(i)).text,
        ];
        expect(_checked(e.spelling), containsAll(['teh item', 'teh task']));
        for (var i = 0; i < texts.length; i++) {
          final t = texts[i];
          if (!t.contains('teh')) continue;
          expect(_spansAt(tester, rows.at(i)), [
            (_sp, t.indexOf('teh'), 3),
          ], reason: 'row "$t"');
        }
      },
    );
  });

  // ------------------------------------------------------------- AC10

  group('ignore (AC10)', () {
    testWidgets(
      'ignoreSpelling calls ignore once with the note tag and the issue stays hidden after a tab switch and return',
      (tester) async {
        final e = await pumpSpellingEditor(
          tester,
          body: 'Good teh day.',
          spelling: FakeSpellingService()..misspell('teh'),
        );
        await _settle(e);
        final field = e.rowFields(0).first;
        expect(_spansAt(tester, field), [(_sp, 5, 3)]);
        final issue = _issuesAt(tester, field).single;
        final controller = _controllerAt(tester, field);
        expect(controller, isNotNull);

        await controller!.ignoreSpelling(issue, _ctrlOf(tester, field));
        await tester.pump();
        expect(_spansAt(tester, field), isEmpty, reason: 'removed at once');
        final ignores = e.spelling.callsFor('ignore');
        expect(ignores, hasLength(1));
        expect(ignores.single.args, {
          'word': 'teh',
          'documentTag': e.spelling.tags[spellingNoteId],
        });

        // The fake checker forgets: only the session set keeps it hidden.
        e.spelling.ignoredByTag.clear();
        final checks = _checksOf(e.spelling, 'Good teh day.');
        await e.robot.open('topic-other');
        await _settle(e);
        await e.robot.open(spellingNoteId);
        await _settle(e);
        expect(_spansAt(tester, e.rowFields(0).first), isEmpty);
        expect(
          _checksOf(e.spelling, 'Good teh day.'),
          checks,
          reason: 'served from the cache',
        );
        expect(e.spelling.count('ignore'), 1);
      },
    );

    testWidgets(
      'ignoreGrammar suppresses matching grammar results for that note only',
      (tester) async {
        final e = await pumpSpellingEditor(
          tester,
          body: 'He go home.',
          spelling: FakeSpellingService()
            ..flagGrammar('He go', description: 'Agreement'),
        );
        e.workspace.db.db.execute(
          'UPDATE notes SET content_md = ? WHERE id = ?',
          ['He go home.', 'topic-other'],
        );
        await _settle(e);
        final field = e.rowFields(0).first;
        expect(_spansAt(tester, field), [(_gr, 0, 5)]);
        final issue = _issuesAt(tester, field).single;

        _controllerAt(
          tester,
          field,
        )!.ignoreGrammar(issue, _ctrlOf(tester, field));
        await tester.pump();
        expect(_spansAt(tester, field), isEmpty, reason: 'removed at once');

        // A fresh check of the paragraph still finds it: suppressed.
        await e.typeAtEnd(' Fine.');
        await e.advance(_debounce);
        await e.advance(const Duration(seconds: 1));
        expect(_checked(e.spelling), contains('He go home. Fine.'));
        expect(_spansAt(tester, e.rowFields(0).first), isEmpty);

        await e.robot.open('topic-other');
        await _settle(e);
        expect(_spansAt(tester, e.rowFields(0).first), [(_gr, 0, 5)]);
        expect(e.spelling.count('ignore'), 0);
      },
    );
  });

  // ------------------------------------------------------------- AC11

  group('document tags (AC11)', () {
    testWidgets(
      'documentTag is called once per note id across mode and tab switches and no editor dispose closes tags',
      (tester) async {
        final e = await pumpSpellingEditor(
          tester,
          body: 'Good teh day.',
          spelling: FakeSpellingService()..misspell('teh'),
        );
        await _settle(e);
        await e.toggleSource();
        await _settle(e);
        await e.typeAtEnd(' More.');
        await _settle(e);
        await e.toggleSource();
        await _settle(e);
        await e.robot.open('topic-other');
        await _settle(e);
        await e.robot.open(spellingNoteId);
        await _settle(e);

        final tags = [
          for (final c in e.spelling.callsFor('documentTag'))
            if (c.args['noteId'] == spellingNoteId) c,
        ];
        expect(tags, hasLength(1));
        expect(e.spelling.count('closeDocumentTags'), 0);
        final checks = [
          for (final c in e.spelling.callsFor('check'))
            if ((c.args['text']! as String).startsWith('Good teh day.')) c,
        ];
        expect(checks, isNotEmpty);
        for (final c in checks) {
          expect(c.args['documentTag'], e.spelling.tags[spellingNoteId]);
        }
      },
    );
  });

  // ------------------------------------------------------------- AC12

  group('settings (AC12)', () {
    testWidgets('turning spelling off clears every issue and sends no checks', (
      tester,
    ) async {
      final e = await pumpSpellingEditor(
        tester,
        body: 'Good teh day. He go home.',
        spelling: FakeSpellingService()
          ..misspell('teh')
          ..flagGrammar('He go', description: 'Agreement'),
      );
      await _settle(e);
      final field = e.rowFields(0).first;
      expect(_spansAt(tester, field), [(_sp, 5, 3), (_gr, 14, 5)]);

      await e.container.read(settingsProvider.notifier).setCheckSpelling(false);
      await tester.pump();
      expect(_spansAt(tester, field), isEmpty);

      e.spelling.clearCalls();
      await e.typeAtEnd(' More teh here.');
      await e.advance(_debounce);
      await e.advance(const Duration(seconds: 2));
      expect(e.spelling.count('check'), 0);
      expect(_spansAt(tester, e.rowFields(0).first), isEmpty);
    });

    testWidgets(
      'turning grammar off clears grammar issues and later checks send grammar false',
      (tester) async {
        final e = await pumpSpellingEditor(
          tester,
          body: 'Good teh day. He go home.',
          spelling: FakeSpellingService()
            ..misspell('teh')
            ..flagGrammar('He go', description: 'Agreement'),
        );
        await _settle(e);
        final field = e.rowFields(0).first;
        expect(_spansAt(tester, field), [(_sp, 5, 3), (_gr, 14, 5)]);
        for (final c in e.spelling.callsFor('check')) {
          expect(c.args['grammar'], isTrue);
        }

        await e.container
            .read(settingsProvider.notifier)
            .setCheckGrammar(false);
        await tester.pump();
        expect(_spansAt(tester, field), [(_sp, 5, 3)]);

        e.spelling.clearCalls();
        await e.typeAtEnd(' More.');
        await e.advance(_debounce);
        await e.advance(const Duration(seconds: 1));
        final checks = e.spelling.callsFor('check');
        expect(checks, isNotEmpty);
        for (final c in checks) {
          expect(c.args['grammar'], isFalse);
          expect(c.args['spelling'], isTrue);
        }
        expect(_spansAt(tester, e.rowFields(0).first), [(_sp, 5, 3)]);
      },
    );
  });

  // ------------------------------------------------------------- AC13

  group('tables (AC13)', () {
    testWidgets(
      'an unrevealed table row gets no checks and no issues and revealing it checks it',
      (tester) async {
        const body =
            'Intro ok.\n\n| teh | b |\n| --- | --- |\n| c | d |\n\nOutro ok.';
        final e = await pumpSpellingEditor(
          tester,
          body: body,
          spelling: FakeSpellingService()..misspell('teh'),
        );
        await _settle(e);
        // Editor row r's field of segment 0, also while it is offstage.
        Finder rowField(int r) => find.descendant(
          of: find.byKey(Key('editor-row-0-$r'), skipOffstage: false),
          matching: find.byType(EditableText, skipOffstage: false),
          skipOffstage: false,
        );
        Finder fieldWith(String prefix) {
          for (var r = 0; r < 8; r++) {
            final f = rowField(r);
            if (f.evaluate().isEmpty) continue;
            if (_ctrlOf(tester, f).text.startsWith(prefix)) return f;
          }
          throw TestFailure('no editor row starts with $prefix');
        }

        final table = fieldWith('| teh');
        final tableCtrl = _ctrlOf(tester, table) as LivePreviewController;
        expect(tableCtrl.tableRevealed, isFalse);
        await e.advance(const Duration(seconds: 2));
        expect(_checked(e.spelling).where((t) => t.contains('|')), isEmpty);
        expect(_spansAt(tester, table), isEmpty);

        // Reveal: the caret in the `c` cell.
        await tester.showKeyboard(table);
        await tester.pump();
        segmentEditingAt(
          tester,
          0,
        ).select(TextSelection.collapsed(offset: body.indexOf('| c') + 2));
        await tester.pump();
        expect(tableCtrl.tableRevealed, isTrue);
        await e.advance(_debounce);
        await e.advance(const Duration(seconds: 1));
        expect(_checksOf(e.spelling, '| teh | b |'), 1);
        expect(_spansAt(tester, table), [(_sp, 2, 3)]);

        // Unrevealed again: its issues go.
        await tester.showKeyboard(fieldWith('Intro'));
        await tester.pump();
        segmentEditingAt(
          tester,
          0,
        ).select(const TextSelection.collapsed(offset: 0));
        await tester.pump();
        expect(tableCtrl.tableRevealed, isFalse);
        await tester.pump();
        expect(_spansAt(tester, table), isEmpty);
      },
    );
  });

  // ------------------------------------------------------------- AC14

  group('Source mode (AC14)', () {
    testWidgets(
      'Source mode debounces its single field and publishes into it',
      (tester) async {
        final e = await pumpSpellingEditor(
          tester,
          body: 'Good word.',
          source: true,
          spelling: FakeSpellingService()..misspell('teh'),
        );
        await _settle(e);
        expect(_checked(e.spelling), contains('Good word.'));
        e.spelling.clearCalls();

        await e.typeAtEnd(' teh more');
        await e.advance(_debounce - _ms);
        expect(e.spelling.count('check'), 0);
        await e.advance(_ms);
        expect(_checked(e.spelling), ['Good word. teh more']);
        await e.advance(const Duration(seconds: 1));
        expect(e.spelling.count('check'), 1);
        expect(_spansAt(tester, e.sourceField), [(_sp, 11, 3)]);
      },
    );

    testWidgets(
      'Source mode drops results in the Note footer and in skip ranges',
      (tester) async {
        final e = await pumpSpellingEditor(
          tester,
          body: 'teh memex [[teh]] cat.\n\n<!-- memex:topics -->\n',
          source: true,
          spelling: FakeSpellingService()
            ..misspell('teh')
            ..misspell('memex'),
        );
        await _settle(e);
        final text = _ctrlOf(tester, e.sourceField).text;
        expect(text, contains('<!-- memex:topics -->'));
        expect(_spansAt(tester, e.sourceField), [(_sp, 0, 3), (_sp, 4, 5)]);
      },
    );

    testWidgets(
      'Source mode drops a result in footer text that shares a paragraph with the body',
      (tester) async {
        // No blank line before the marker: one paragraph starts in the body
        // and reaches into the footer, so only the footer skip range keeps
        // the stray word unflagged.
        final e = await pumpSpellingEditor(
          tester,
          body: 'Body teh.\n<!-- memex:topics -->\nStray teh line.\n',
          source: true,
          spelling: FakeSpellingService()..misspell('teh'),
        );
        await _settle(e);
        final text = _ctrlOf(tester, e.sourceField).text;
        expect(text, contains('Body teh.\n<!-- memex:topics -->\nStray teh'));
        expect(_spansAt(tester, e.sourceField), [(_sp, 5, 3)]);
      },
    );

    testWidgets('Source mode holds the issue of the word under the caret', (
      tester,
    ) async {
      final e = await pumpSpellingEditor(
        tester,
        body: 'Good word.',
        source: true,
        spelling: FakeSpellingService()..misspell('teh'),
      );
      await _settle(e);
      await _input(tester, e.sourceField, _value('Good teh word.', 7));
      await e.advance(_debounce);
      await e.advance(const Duration(seconds: 1));
      expect(_spansAt(tester, e.sourceField), isEmpty);
      await _input(tester, e.sourceField, _value('Good teh word.', 0));
      expect(_spansAt(tester, e.sourceField), [(_sp, 5, 3)]);
    });
  });

  // ------------------------------------------------------------- AC15

  group('service unavailable (AC15)', () {
    testWidgets(
      'once the service is unavailable no checks are sent no issues appear and no error shows',
      (tester) async {
        final e = await pumpSpellingEditor(
          tester,
          body: 'Good teh day.',
          spelling: FakeSpellingService()..misspell('teh'),
        );
        await _settle(e);
        expect(_spansAt(tester, e.rowFields(0).first), [(_sp, 5, 3)]);

        e.spelling.available = false;
        e.spelling.clearCalls();
        await e.typeAtEnd('\n\nOther teh line.');
        await e.advance(_debounce);
        await e.advance(const Duration(seconds: 2));
        expect(e.spelling.count('check'), 0);
        final at = 'Good teh day.\n\nOther '.length;
        expect(
          _spansAt(tester, e.rowFields(0).first),
          isNot(contains((_sp, at, 3))),
        );
        expect(e.robot.inlineError, findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('a service unavailable from the start checks nothing', (
      tester,
    ) async {
      final e = await pumpSpellingEditor(
        tester,
        body: 'Good teh day.',
        spelling: FakeSpellingService(available: false)..misspell('teh'),
      );
      await _settle(e);
      await e.typeAtEnd(' More teh.');
      await _settle(e);
      expect(e.spelling.count('check'), 0);
      expect(_spansAt(tester, e.rowFields(0).first), isEmpty);
      expect(e.robot.inlineError, findsNothing);
    });
  });

  // ------------------------------------------------------- E6 entry point

  group('checkAll (E6 entry point)', () {
    testWidgets(
      'checkAll checks paragraphs far from the viewport and publishes them',
      (tester) async {
        final paragraphs = [..._lines(200), 'Far teh end.'];
        final e = await pumpSpellingEditor(
          tester,
          body: _long(paragraphs),
          spelling: FakeSpellingService()..misspell('teh'),
        );
        await _settle(e);
        expect(_checksOf(e.spelling, 'Far teh end.'), 0);

        final field = e.rowFields(0).first;
        expect(_controllerAt(tester, field), isNotNull);
        await _controllerAt(tester, field)!.checkAll();
        await tester.pump();
        await tester.pump();
        expect(_checksOf(e.spelling, 'Far teh end.'), 1);
        expect(_checksOf(e.spelling, paragraphs.first), 1);
        expect(
          _spansAt(tester, field),
          contains((_sp, _offsetOf(paragraphs, 200) + 4, 3)),
        );
      },
    );
  });

  group('bare host (verify)', () {
    testWidgets(
      'moving the host to another note drops its issues and checks the new note',
      (tester) async {
        final h = _Wi436Host(
          tester,
          service: FakeSpellingService()..misspell('teh'),
          controller: TextEditingController(text: 'Good teh day.'),
        );
        await h.pump('note-a');
        expect(h.spans, [(_sp, 5, 3)]);
        expect(h.service.count('check'), 1);
        h.controller.ignoreSpelling(
          h.registry.issuesFor(h.ctrl).value.single,
          h.ctrl,
        );
        await tester.pump();
        expect(h.spans, isEmpty);

        h.service.clearCalls();
        await h.pump('note-b');
        // The ignore was for note-a: note-b shows the word again.
        expect(h.spans, [(_sp, 5, 3)]);
        final checks = h.service.callsFor('check');
        expect(checks, hasLength(1));
        expect(checks.single.args['documentTag'], h.service.tags['note-b']);
        expect(h.service.tags['note-b'], isNot(h.service.tags['note-a']));
      },
    );

    testWidgets('moving to another note clears the old note issues at once', (
      tester,
    ) async {
      final held = _Wi436LateTagService();
      final h = _Wi436Host(
        tester,
        service: held..misspell('teh'),
        controller: TextEditingController(text: 'Good teh day.'),
      );
      await h.pump('note-a');
      held.answers.single.complete(5);
      await h.advance(const Duration(seconds: 1));
      expect(h.spans, [(_sp, 5, 3)]);

      await h.pump('note-b');
      expect(h.spans, isEmpty, reason: 'note-b has no tag yet');
      held.answers.last.complete(6);
      await h.advance(const Duration(seconds: 1));
      expect(h.spans, [(_sp, 5, 3)]);
    });

    testWidgets('checkAll waits for the document tag and then checks', (
      tester,
    ) async {
      final held = _Wi436LateTagService();
      final h = _Wi436Host(
        tester,
        service: held..misspell('teh'),
        controller: TextEditingController(text: 'Good teh day.'),
      );
      await h.pump('note-a');
      expect(held.count('check'), 0);

      var done = false;
      final all = h.controller.checkAll().then((_) => done = true);
      await tester.pump();
      expect(done, isFalse);
      held.answers.first.complete(3);
      await tester.pump();
      await all;
      await tester.pump();

      expect(held.count('check'), 1);
      expect(held.callsFor('check').single.args['documentTag'], 3);
      expect(h.spans, [(_sp, 5, 3)]);
    });

    testWidgets('checkAll with no tag to be had checks nothing', (
      tester,
    ) async {
      final held = _Wi436LateTagService();
      final h = _Wi436Host(
        tester,
        service: held..misspell('teh'),
        controller: TextEditingController(text: 'Good teh day.'),
      );
      await h.pump('note-a');
      final all = h.controller.checkAll();
      await tester.pump();
      held.answers.first.complete(null);
      await all;
      await tester.pump();
      expect(held.count('check'), 0);
      expect(h.spans, isEmpty);
    });

    testWidgets(
      'a check that throws leaves the field with no issues and no error',
      (tester) async {
        final h = _Wi436Host(
          tester,
          service: _Wi436ThrowingService()..misspell('teh'),
          controller: TextEditingController(text: 'Good teh day.'),
        );
        await h.pump('note-a');
        await h.advance(const Duration(seconds: 2));
        expect(h.service.count('check'), 1);
        expect(h.spans, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('a field that gets another controller is checked afresh', (
      tester,
    ) async {
      final h = _Wi436Host(
        tester,
        service: FakeSpellingService()..misspell('teh'),
        controller: TextEditingController(text: 'Good teh day.'),
      );
      await h.pump('note-a');
      final first = h.ctrl;
      final firstIssues = h.registry.issuesFor(first);
      expect(h.spans, [(_sp, 5, 3)]);

      await h.pump('note-a', field: TextEditingController(text: 'More teh.'));

      expect(h.ctrl, isNot(same(first)));
      expect(h.spans, [(_sp, 5, 3)]);
      expect(_checked(h.service), ['Good teh day.', 'More teh.']);
      expect(
        identical(h.registry.issuesFor(first), firstIssues),
        isFalse,
        reason: 'the replaced controller is forgotten',
      );
    });

    testWidgets('without settings above the editor spelling stays off', (
      tester,
    ) async {
      final h = _Wi436Host(
        tester,
        service: FakeSpellingService()..misspell('teh'),
        withFlags: false,
        controller: TextEditingController(text: 'Good teh day.'),
      );
      await h.pump('note-a');
      await h.advance(const Duration(seconds: 2));
      expect(h.service.count('check'), 0);
      expect(h.spans, isEmpty);
    });
  });

  // ------------------------------------------------------- pinned contracts

  group('contracts pinned in verify', () {
    testWidgets(
      'a paragraph that starts at the Note footer is never sent while the one before it is',
      (tester) async {
        final e = await pumpSpellingEditor(
          tester,
          body: 'Good word.\n\n<!-- memex:topics -->\nFooter teh line.\n',
          source: true,
          spelling: FakeSpellingService()..misspell('teh'),
        );
        await _settle(e);
        expect(
          _ctrlOf(tester, e.sourceField).text,
          contains('<!-- memex:topics -->'),
        );
        expect(_checked(e.spelling), contains('Good word.'));
        for (final text in _checked(e.spelling)) {
          expect(text, isNot(contains('Footer')));
          expect(text, isNot(contains('memex:topics')));
        }
        expect(_spansAt(tester, e.sourceField), isEmpty);
      },
    );

    testWidgets(
      'turning grammar off serves the cached grammar result with no new check',
      (tester) async {
        final e = await pumpSpellingEditor(
          tester,
          body: 'Good teh day. He go home.',
          spelling: FakeSpellingService()
            ..misspell('teh')
            ..flagGrammar('He go', description: 'Agreement'),
        );
        await _settle(e);
        final field = e.rowFields(0).first;
        expect(_spansAt(tester, field), [(_sp, 5, 3), (_gr, 14, 5)]);
        e.spelling.clearCalls();

        await e.container
            .read(settingsProvider.notifier)
            .setCheckGrammar(false);
        await tester.pump();
        await e.advance(const Duration(seconds: 2));

        expect(e.spelling.count('check'), 0);
        expect(_spansAt(tester, field), [(_sp, 5, 3)]);

        await e.container.read(settingsProvider.notifier).setCheckGrammar(true);
        await tester.pump();
        await e.advance(const Duration(seconds: 2));
        expect(_spansAt(tester, field), [(_sp, 5, 3), (_gr, 14, 5)]);
        expect(e.spelling.count('check'), 0, reason: 'grammar:true is cached');
      },
    );

    testWidgets(
      'a grammar issue under a caret that is not editing shows with no pause',
      (tester) async {
        final e = await pumpSpellingEditor(
          tester,
          body: 'He go home. She go out.',
          spelling: FakeSpellingService()
            ..flagGrammar('He go', description: 'Agreement')
            ..flagGrammar('She go', description: 'Agreement'),
        );
        await _settle(e);
        final field = e.rowFields(0).first;
        // The caret moves into the first sentence; the text is unchanged.
        await _input(tester, field, _value('He go home. She go out.', 3));
        expect(_spansAt(tester, field), [(_gr, 0, 5), (_gr, 12, 6)]);
        await _input(tester, field, _value('He go home. She go out.', 15));
        expect(_spansAt(tester, field), [(_gr, 0, 5), (_gr, 12, 6)]);
      },
    );

    testWidgets('a row that goes away has its registry entry forgotten', (
      tester,
    ) async {
      final e = await pumpSpellingEditor(
        tester,
        body: 'Some teh here.\n- teh item',
        spelling: FakeSpellingService()..misspell('teh'),
      );
      await _settle(e);
      final registry = SpellIssueScope.maybeOf(
        tester.element(e.rowFields(0).first),
      )!;
      final ctrls = [
        for (var i = 0; i < 2; i++) _ctrlOf(tester, e.rowFields(0).at(i)),
      ];
      final before = [for (final c in ctrls) registry.issuesFor(c)];
      expect(before.every((l) => l.value.isNotEmpty), isTrue);

      await e.robot.typeInSegment(0, 'Some teh here.');
      await tester.pump();
      await tester.pump();

      expect(e.rowFields(0), findsOneWidget);
      final kept = _ctrlOf(tester, e.rowFields(0).first);
      expect(ctrls.where((c) => identical(c, kept)), hasLength(1));
      for (var i = 0; i < 2; i++) {
        expect(
          identical(registry.issuesFor(ctrls[i]), before[i]),
          identical(ctrls[i], kept),
          reason: 'only the retired row loses its registry entry (row $i)',
        );
      }
    });
  });
}
