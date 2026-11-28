// WI #85 (Spec #61 F6): Find in note wired into the note editor, end to end
// in the real workspace.
//
// Find is triggered as the native Edit > Find menu does it: a `find` window
// channel message (`show`, `next`, `previous`, `useSelection`), never a key
// event for Cmd+F, Cmd+G or Cmd+E (TD5). The bar's own keys (Enter, Esc)
// are key events in its field. Each no-op test ends with a control that
// opens the bar, so it cannot pass on an editor that never opens one.
//
// Geometry and offsets come from the shown note's own text and line boxes,
// never constants. Clicks into the note go through the segment handles
// (plain body lines, 53-C). Never pumpAndSettle the workspace.
import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/excerpt_render.dart';
import 'package:open_memex_app/src/editor/find_in_note.dart';
import 'package:open_memex_app/src/editor/segments.dart';
import 'package:open_memex_app/src/graph/graph_scope.dart';
import 'package:open_memex_app/src/state/editor_controller.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/vault_access/vault_scoped.dart';
import 'package:open_memex_app/src/widgets/editor/excerpt_card.dart';
import 'package:open_memex_app/src/widgets/note_editor.dart';

import '../../support/canvas_seeds.dart';
import '../../support/fake_vault_db.dart';
import '../../support/font_fetch_hold.dart';
import '../../support/note_reveal_pump.dart';
import '../../support/segment_editing_finder.dart';
import '../../support/wi85_find_editor.dart';

// ------------------------------------------------------------------ helpers

/// Segment 2 offset of the plain `rye` in `Toast the rye slices.`.
int get _wi85ToastAt => wi85Seg2.indexOf('rye slices');

/// The current match is the `rye` of `Toast the rye slices.` (segment 2).
bool _wi85IsToast(FindMatch m) =>
    m.kind == FindSourceKind.body && m.segment == 2 && m.start == _wi85ToastAt;

/// Puts the caret at [offset] of segment 2 (after its table). Segment 2 holds
/// a table row whose field is Offstage, so the shared `focusSegmentAt` (which
/// counts visible fields against editor rows) cannot be used: this focuses
/// the visible field holding [offset] and selects through the handle.
Future<void> _wi85FocusSeg2(Wi85 w, int offset) async {
  final tester = w.tester;
  final seg = find.byKey(textSegmentKey(2));
  final handle = segmentEditingOf(tester, seg);
  final fields = segmentRowFields(seg);
  final hidden = handle.rowCount - fields.evaluate().length;
  final row = segmentRowHolding(handle, offset) - hidden;
  expect(row, greaterThanOrEqualTo(0), reason: 'offset is in a visible row');
  await tester.showKeyboard(fields.at(row));
  await tester.pump();
  segmentEditingOf(tester, seg).select(TextSelection.collapsed(offset: offset));
  await tester.pump();
}

bool _wi85IsCard(FindMatch m) => m.kind == FindSourceKind.card;

TextSelection _wi85Sel(FindMatch m) =>
    TextSelection(baseOffset: m.start, extentOffset: m.end);

/// The canvas fixture with every wi85 note, Alpha and Beta holding the same
/// four-line body (four `rye` matches).
const _wi85ZoomBody = 'Rye one.\nRye two.\nRye three.\nRye four.\n';

FakeVaultDb _wi85CanvasVault() {
  final db = wi85SeedVault(seedCanvasFixture(FakeVaultDb.v5()));
  for (final id in [C89.alpha, C89.beta]) {
    db.db.execute('UPDATE notes SET content_md = ? WHERE id = ?', [
      _wi85ZoomBody,
      id,
    ]);
  }
  return db;
}

Finder _wi85Zoomed(String id) => find.byKey(Key('zoomed-$id'));

/// The canvas fixture where Alpha and Beta each hold a card between two
/// `rye` lines: four matches (body, 2 in the card, body).
FakeVaultDb _wi85CardZoomVault() {
  final db = wi85SeedVault(seedCanvasFixture(FakeVaultDb.v5()));
  for (final id in [C89.alpha, C89.beta]) {
    db.db.execute('UPDATE notes SET content_md = ? WHERE id = ?', [
      'Rye one.\n$wi85Token\nRye two.\n',
      id,
    ]);
  }
  return db;
}

/// The colour the live preview draws match [m] of the ink note in at its
/// first code unit: from its body row, card row or table cell.
Color? _wi85InkAt(Wi85 w, FindMatch m, {Finder? under}) {
  switch (m.kind) {
    case FindSourceKind.card:
      final (span, at) = w.cardRowSpan(
        m.segment,
        wi85InkCardText,
        m.start,
        under: under,
      );
      return wi85ColorAt(span, at);
    case FindSourceKind.body when m.segment == 2:
      final first = m.start < wi85InkSeg2.indexOf('| plain rye');
      final cell = first ? '~~rye~~ cell' : 'plain rye cell';
      return wi85ColorAt(
        w.tableCellSpan(2, cell, under: under),
        cell.indexOf('rye'),
      );
    case FindSourceKind.body:
      final (span, at) = w.bodyRowSpan(m.segment, m.start, under: under);
      return wi85ColorAt(span, at);
    case FindSourceKind.source:
      throw StateError('no Source match in live preview');
  }
}

/// Presses [key] with Cmd (and Shift) held; returns whether Dart handled it.
Future<bool> _wi85CmdHandled(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool shift = false,
}) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft, platform: 'macos');
  if (shift) {
    await tester.sendKeyDownEvent(
      LogicalKeyboardKey.shiftLeft,
      platform: 'macos',
    );
  }
  final handled = await tester.sendKeyEvent(key, platform: 'macos');
  if (shift) {
    await tester.sendKeyUpEvent(
      LogicalKeyboardKey.shiftLeft,
      platform: 'macos',
    );
  }
  await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft, platform: 'macos');
  await tester.pump();
  return handled;
}

/// Writes [body] to the topic note as a polled server write would, and lets
/// the editor take it.
Future<void> _wi85ServerWrites(Wi85 w, String body, int version) async {
  w.h.db.db.execute(
    'UPDATE notes SET content_md = ?, version = ? WHERE id = ?',
    [body, version, wi85TopicId],
  );
  final changed = await w.container
      .read(editorControllerProvider.notifier)
      .serverChanged(wi85TopicId);
  expect(changed, isTrue, reason: 'the editor took the server write');
  await pumpFrames(w.tester);
}

void main() {
  holdFontFetches();

  // ------------------------------------------------------------- opening
  group('opening', () {
    testWidgets(
      'a find show message on a note tab opens the Find bar with the field focused and the last query selected',
      (tester) async {
        final w = await pumpWi85(tester);
        expect(w.bar, findsNothing);

        await w.openOn(wi85Query);
        await w.escInField();
        expect(w.bar, findsNothing);

        await w.send('show');
        expect(w.bar, findsOneWidget);
        expect(
          find.descendant(of: find.byType(NoteEditor), matching: w.bar),
          findsOneWidget,
          reason: 'the bar floats over the note body',
        );
        expect(w.fieldFocused, isTrue);
        expect(w.fieldEditable.controller.text, wi85Query);
        expect(
          w.fieldEditable.controller.selection,
          const TextSelection(baseOffset: 0, extentOffset: wi85Query.length),
        );
        expect(w.state.open, isTrue);
        expect(w.state.matches, hasLength(12));
      },
    );

    testWidgets(
      'a find show message on a canvas zoomed into a note opens the Find bar there',
      (tester) async {
        final w = await pumpWi85(tester, open: null, db: _wi85CanvasVault());
        await w.h.navigate(const CanvasTab(C89.newer));
        await w.h.navigate(const CanvasTab(C89.newer, zoomedNoteId: C89.alpha));
        await pumpFrames(tester);
        expect(_wi85Zoomed(C89.alpha), findsOneWidget);

        await w.openOn(wi85Query);
        expect(
          find.descendant(of: _wi85Zoomed(C89.alpha), matching: w.bar),
          findsOneWidget,
        );
        expect(w.state.matches, hasLength(4));
        await w.escInField();

        await w.send('show');
        expect(
          find.descendant(of: _wi85Zoomed(C89.alpha), matching: w.bar),
          findsOneWidget,
        );
        expect(w.fieldFocused, isTrue);
        expect(
          w.fieldEditable.controller.selection,
          const TextSelection(baseOffset: 0, extentOffset: wi85Query.length),
        );
      },
    );

    testWidgets(
      'with no note editor showing a find show message changes nothing',
      (tester) async {
        final w = await pumpWi85(tester, open: null, db: _wi85CanvasVault());
        expect(find.byType(NoteEditor), findsNothing, reason: 'empty state');
        await w.send('show');
        expect(w.bar, findsNothing);
        expect(w.state.open, isFalse);

        await w.h.navigate(const CanvasTab(C89.newer));
        expect(find.byType(NoteEditor), findsNothing, reason: 'unzoomed');
        await w.send('show');
        expect(w.bar, findsNothing);
        expect(w.state.open, isFalse);

        await w.h.navigate(GraphTab(GraphScope.topic(wi85TopicId)));
        expect(find.byType(NoteEditor), findsNothing, reason: 'graph');
        await w.send('show');
        expect(w.bar, findsNothing);
        expect(w.state.open, isFalse);

        // Control: on a note tab the same message opens the bar.
        await w.h.navigate(const NoteTab(wi85TopicId));
        await w.send('show');
        expect(w.bar, findsOneWidget);
        expect(w.state.open, isTrue);
      },
    );

    testWidgets('under a modal route a find show message changes nothing', (
      tester,
    ) async {
      final w = await pumpWi85(tester);
      unawaited(
        showDialog<void>(
          context: tester.element(find.byType(NoteEditor)),
          builder: (_) => const AlertDialog(content: Text('wi85 modal')),
        ),
      );
      await pumpFrames(tester);
      expect(find.text('wi85 modal'), findsOneWidget);

      await w.send('show');
      expect(w.bar, findsNothing);
      expect(w.state.open, isFalse);

      Navigator.of(tester.element(find.text('wi85 modal'))).pop();
      await pumpFrames(tester);
      expect(find.text('wi85 modal'), findsNothing);
      // Control: with the modal gone the same message opens the bar.
      await w.send('show');
      expect(w.bar, findsOneWidget);
      expect(w.fieldFocused, isTrue);
    });

    testWidgets('a dialog over the workspace keeps the open Find bar open', (
      tester,
    ) async {
      final w = await pumpWi85(tester);
      await w.openOn(wi85Query);
      final matches = w.state.matches.length;

      // The Command palette is a root-navigator dialog (D13).
      unawaited(
        showDialog<void>(
          context: tester.element(find.byType(NoteEditor)),
          useRootNavigator: true,
          builder: (_) => const AlertDialog(content: Text('wi85 palette')),
        ),
      );
      await pumpFrames(tester);
      expect(find.text('wi85 palette'), findsOneWidget);
      expect(w.bar, findsOneWidget);
      expect(w.state.open, isTrue);
      expect(w.state.query, wi85Query);

      Navigator.of(tester.element(find.text('wi85 palette'))).pop();
      await pumpFrames(tester);
      expect(w.bar, findsOneWidget);
      expect(w.state.matches, hasLength(matches));
    });
  });

  // ------------------------------------------------------------- sources
  group('sources', () {
    testWidgets(
      'live preview matches cover body segments and loaded card text but not the title or the Note footer',
      (tester) async {
        final w = await pumpWi85(tester);
        // Fixture: the title and the footer hold the query, which must not
        // count. (The token holds none: see the next test.)
        expect(wi85TopicTitle.toLowerCase(), contains(wi85Query));
        expect(wi85Footer.toLowerCase(), contains(wi85Query));
        expect(wi85Count(wi85Seg0 + wi85Seg2, wi85Query), 10);
        expect(wi85Count(wi85CardText, wi85Query), 2);
        expect(w.segments[1], isA<TransclusionSegment>());
        expect(w.segments.last, isA<FooterSegment>());

        await w.openOn(wi85Query);
        final matches = w.state.matches;
        expect(matches, hasLength(12));
        expect(w.counter, endsWith(' of 12'));
        expect(
          [
            for (final m in matches)
              if (m.kind == FindSourceKind.card) m.segment,
          ],
          [1, 1],
          reason: 'the card text counts at the card',
        );
        expect(
          {for (final m in matches) (m.kind, m.segment)},
          {
            (FindSourceKind.body, 0),
            (FindSourceKind.card, 1),
            (FindSourceKind.body, 2),
          },
          reason: 'body text segments and the card only',
        );
        final cardStarts = [
          for (final m in matches)
            if (m.kind == FindSourceKind.card) m.start,
        ];
        expect(cardStarts, [
          wi85CardText.indexOf('rye'),
          wi85CardText.lastIndexOf('rye'),
        ]);

        await w.h.toggleSource();
        expect(w.bar, findsOneWidget);
        expect(w.state.matches, hasLength(11), reason: 'Source counts 11');
        expect(
          w.state.matches.every((m) => m.kind == FindSourceKind.source),
          isTrue,
        );
        expect(w.counter, endsWith(' of 11'));
      },
    );

    testWidgets('the raw transclusion token behind a card is not searched', (
      tester,
    ) async {
      final w = await pumpWi85(tester);
      expect(w.segments[1], isA<TransclusionSegment>());
      const inToken = 'k1a2b3';
      expect(wi85Token, contains(inToken));
      expect(wi85CardText, isNot(contains(inToken)));
      expect(wi85Seg0 + wi85Seg2, isNot(contains(inToken)));

      await w.openOn(inToken);
      expect(w.state.matches, isEmpty, reason: 'live preview: the card shows');

      await w.h.toggleSource();
      expect(w.state.matches, hasLength(1), reason: 'Source shows the token');
      final m = w.state.matches.single;
      expect(m.kind, FindSourceKind.source);
      expect(m.start, wi85TopicBody.indexOf(inToken));

      await w.h.toggleSource();
      expect(w.state.matches, isEmpty);
    });

    testWidgets('a daily note date header is not searched', (tester) async {
      final w = await pumpWi85(tester, open: wi85DayId);
      expect(
        find.textContaining('September', findRichText: true),
        findsWidgets,
        reason: 'the date header shows the month',
      );
      await w.openOn('september');
      expect(w.state.matches, hasLength(1));
      expect(w.state.matches.single.kind, FindSourceKind.body);
      expect(w.counter, '1 of 1');
    });

    testWidgets(
      'an excerpt card whose text loads after the query adds its matches and keeps the current match',
      (tester) async {
        final load = Completer<RenderedExcerpt?>();
        final w = await pumpWi85(
          tester,
          overrides: [
            excerptRenderProvider.overrideWith((ref, token) async {
              final vault = ref.watch(currentVaultProvider);
              return VaultScoped(vault, await load.future);
            }),
          ],
        );
        await w.openOn(wi85Query);
        expect(w.state.matches, hasLength(10), reason: 'no card text yet');
        final current = await w.stepUntil(_wi85IsToast);
        final index = w.state.current!;

        load.complete(
          const RenderedExcerpt(
            date: wi85DailyDate,
            text: wi85CardText,
            removed: false,
          ),
        );
        await pumpFrames(tester);

        expect(w.state.matches, hasLength(12));
        expect(w.state.currentMatch, current, reason: 'the same match');
        expect(w.state.current, index + 2, reason: 'the card sits before it');
        expect(w.counter, '${index + 3} of 12');
      },
    );

    testWidgets('a removed excerpt stub text is not searched', (tester) async {
      final w = await pumpWi85(
        tester,
        overrides: [
          excerptRenderProvider.overrideWith((ref, token) async {
            final vault = ref.watch(currentVaultProvider);
            return VaultScoped(
              vault,
              const RenderedExcerpt(
                date: wi85DailyDate,
                text: 'removed from $wi85DailyDate',
                removed: true,
              ),
            );
          }),
        ],
      );
      await w.send('show');
      await w.typeQuery('removed from');
      expect(w.state.query, 'removed from');
      expect(w.state.matches, isEmpty, reason: 'the stub is not note text');

      // Control: body matches still count, and the card adds none.
      await w.typeQuery(wi85Query);
      expect(w.state.matches, hasLength(10));
    });

    testWidgets(
      'typing in the body with the bar open updates the counter live and keeps the current match',
      (tester) async {
        final w = await pumpWi85(tester);
        await w.openOn(wi85Query);
        final current = await w.stepUntil(_wi85IsToast);
        final index = w.state.current!;
        expect(w.counter, '${index + 1} of 12');
        final reveals = w.reveals();

        await w.robot.focusSegment(0, offset: 0);
        await w.robot.typeChars('rye ');
        await pumpFrames(tester);
        expect(reveals.count, 0, reason: 'editing the text reveals nothing');

        expect(w.robot.segmentText(0), startsWith('rye Rye bread'));
        expect(w.bar, findsOneWidget, reason: 'typing keeps the bar open');
        expect(w.state.matches, hasLength(13));
        expect(w.state.currentMatch, current, reason: 'the same match');
        expect(w.counter, '${index + 2} of 13');
      },
    );

    testWidgets(
      'a polled external content change updates the matches and keeps or moves the current match',
      (tester) async {
        final w = await pumpWi85(tester);
        await w.openOn(wi85Query);
        final current = await w.stepUntil(_wi85IsToast);
        final index = w.state.current!;
        final reveals = w.reveals();

        // A write that adds a match before the current one keeps it.
        await _wi85ServerWrites(w, 'More rye here.\n$wi85TopicBody', 5);
        expect(w.state.matches, hasLength(13));
        expect(w.state.currentMatch, current);
        expect(w.state.current, index + 1);
        expect(w.counter, '${index + 2} of 13');

        // A write that removes the current match moves it to the first match
        // after its old position (Req 38).
        final removed =
            'More rye here.\n'
            '${wi85TopicBody.replaceFirst('Toast the rye slices.', 'Toast the slices.')}';
        await _wi85ServerWrites(w, removed, 6);
        expect(w.state.matches, hasLength(12));
        final moved = w.state.currentMatch!;
        expect(moved.kind, FindSourceKind.body);
        expect(moved.segment, 2);
        final seg2 = w.h.segmentText(2);
        expect(moved.start, seg2.indexOf('Rye and caraway'));
        expect(w.state.current, index + 1);
        expect(
          reveals.count,
          0,
          reason: 'a Req 38 move from a polled write reveals nothing',
        );
      },
    );
  });

  // ------------------------------------------------- selection and focus
  group('selection and focus', () {
    testWidgets(
      'next with an editor field focused selects the new current body match and a card match leaves the caret',
      (tester) async {
        final w = await pumpWi85(tester);
        await w.openOn(wi85Query);
        await w.robot.focusSegment(0, offset: 0);
        expect(w.robot.segmentHasFocus(0), isTrue);

        await w.send('next');
        var m = w.state.currentMatch!;
        expect(m.kind, FindSourceKind.body);
        expect(w.robot.segmentHasFocus(m.segment), isTrue);
        expect(w.robot.segmentSelection(m.segment), _wi85Sel(m));

        // Step on, from the editor, to the card's first match.
        var guard = 0;
        while (!_wi85IsCard(w.state.currentMatch!)) {
          m = w.state.currentMatch!;
          await w.send('next');
          expect(++guard, lessThan(13));
        }
        final lastBody = m;
        expect(lastBody.segment, 0, reason: 'the last body match before it');
        expect(
          w.robot.segmentSelection(0),
          _wi85Sel(lastBody),
          reason: 'a card match leaves the caret where it was',
        );
        expect(w.robot.segmentHasFocus(0), isTrue);
        expect(w.fieldFocused, isFalse);
      },
    );

    testWidgets('stepping from the bar never moves the caret', (tester) async {
      final w = await pumpWi85(tester);
      await w.robot.focusSegment(0, offset: 5);
      await w.send('show');
      expect(w.fieldFocused, isTrue);
      await w.typeQuery(wi85Query);
      final before = w.state.current;
      await w.tapNext();
      await w.tapNext();
      expect(w.state.current, isNot(before));
      expect(
        w.robot.segmentSelection(0),
        const TextSelection.collapsed(offset: 5),
      );
    });

    testWidgets(
      'opening takes the current match from the first match at or after the body caret',
      (tester) async {
        final w = await pumpWi85(tester);
        final caret = wi85Seg2.indexOf('Plain line one.');
        await _wi85FocusSeg2(w, caret);
        await w.send('show');
        await w.typeQuery(wi85Query);
        expect(
          w.state.currentMatch,
          isA<FindMatch>()
              .having((m) => m.segment, 'segment', 2)
              .having((m) => m.start, 'start', wi85Seg2.indexOf('rye slices')),
          reason: 'the first match at or after the caret (Req 18)',
        );
      },
    );

    testWidgets(
      'next with the bar closed opens it on the last query without moving focus',
      (tester) async {
        final w = await pumpWi85(tester);
        await w.openOn(wi85Query);
        await w.escInField();
        expect(w.bar, findsNothing);
        final caret = wi85Seg2.indexOf('Plain line one.');
        await _wi85FocusSeg2(w, caret);

        await w.send('next');
        expect(w.bar, findsOneWidget);
        expect(w.state.query, wi85Query);
        expect(w.fieldFocused, isFalse, reason: 'focus stays in the editor');
        final m = w.state.currentMatch!;
        expect(m.segment, 2);
        expect(m.start, wi85Seg2.indexOf('rye slices'));
        expect(w.robot.segmentHasFocus(2), isTrue);
        expect(w.robot.segmentSelection(2), _wi85Sel(m));
      },
    );

    testWidgets(
      'show with the bar open moves focus back to the field and selects the query',
      (tester) async {
        final w = await pumpWi85(tester);
        await w.openOn(wi85Query);
        await w.robot.focusSegment(0, offset: 0);
        expect(w.fieldFocused, isFalse);

        await w.send('show');
        expect(w.fieldFocused, isTrue);
        expect(
          w.fieldEditable.controller.selection,
          const TextSelection(baseOffset: 0, extentOffset: wi85Query.length),
        );
        expect(w.state.query, wi85Query);
      },
    );

    testWidgets(
      'useSelection in Source mode takes the Source field selection',
      (tester) async {
        final w = await pumpWi85(tester);
        await w.h.toggleSource();
        final field = find.descendant(
          of: w.h.sourceSurface,
          matching: find.descendant(
            of: find.byKey(const Key('editor-body')),
            matching: find.byType(EditableText),
          ),
        );
        await tester.showKeyboard(field);
        await tester.pump();
        final at = wi85TopicBody.indexOf('rye bread');
        w.sourceEditable.controller.selection = TextSelection(
          baseOffset: at,
          extentOffset: at + 'rye bread'.length,
        );
        await tester.pump();

        await w.send('useSelection');
        expect(w.bar, findsOneWidget);
        expect(w.state.query, 'rye bread');
        expect(w.sourceEditable.focusNode.hasFocus, isTrue);
        expect(
          w.state.matches.every((m) => m.kind == FindSourceKind.source),
          isTrue,
        );
      },
    );

    testWidgets(
      'useSelection with rye bread selected in the body sets the query and keeps focus in the body',
      (tester) async {
        final w = await pumpWi85(tester);
        final at = wi85Seg0.indexOf('rye bread');
        await w.robot.focusSegment(0, offset: at);
        w.robot
            .segment(0)
            .select(
              TextSelection(
                baseOffset: at,
                extentOffset: at + 'rye bread'.length,
              ),
            );
        await tester.pump();

        await w.send('useSelection');
        expect(w.bar, findsOneWidget);
        expect(w.state.query, 'rye bread');
        expect(w.fieldEditable.controller.text, 'rye bread');
        expect(w.robot.segmentHasFocus(0), isTrue, reason: 'focus stays');
        expect(w.fieldFocused, isFalse);
        expect(w.state.matches, hasLength(2), reason: 'case folded');
      },
    );

    testWidgets('useSelection with the Find field focused does nothing', (
      tester,
    ) async {
      final w = await pumpWi85(tester);
      await w.openOn(wi85Query);
      expect(w.fieldFocused, isTrue);
      w.fieldEditable.controller.selection = const TextSelection(
        baseOffset: 0,
        extentOffset: 2,
      );
      await tester.pump();
      final matches = w.state.matches;

      await w.send('useSelection');
      expect(w.state.query, wi85Query, reason: 'not the field selection');
      expect(w.state.matches, matches);
      expect(w.bar, findsOneWidget);
      expect(w.fieldFocused, isTrue);

      // Control: with a body selection the same message sets the query.
      final at = wi85Seg0.indexOf('rye bread');
      await w.robot.focusSegment(0, offset: at);
      w.robot
          .segment(0)
          .select(
            TextSelection(
              baseOffset: at,
              extentOffset: at + 'rye bread'.length,
            ),
          );
      await tester.pump();
      await w.send('useSelection');
      expect(w.state.query, 'rye bread');
    });

    testWidgets('a title selection is ignored by useSelection', (tester) async {
      final w = await pumpWi85(tester);
      final title = find.descendant(
        of: find.byKey(const Key('editor-title')),
        matching: find.byType(EditableText),
      );
      await tester.showKeyboard(title);
      await tester.pump();
      tester.widget<EditableText>(title).controller.selection =
          const TextSelection(baseOffset: 0, extentOffset: 3);
      await tester.pump();
      expect(tester.widget<EditableText>(title).focusNode.hasFocus, isTrue);

      await w.send('useSelection');
      expect(w.bar, findsNothing);
      expect(w.state.open, isFalse);
      expect(w.state.query, isEmpty);

      // Control: a body selection is taken.
      final at = wi85Seg0.indexOf('rye bread');
      await w.robot.focusSegment(0, offset: at);
      w.robot
          .segment(0)
          .select(
            TextSelection(
              baseOffset: at,
              extentOffset: at + 'rye bread'.length,
            ),
          );
      await tester.pump();
      await w.send('useSelection');
      expect(w.bar, findsOneWidget);
      expect(w.state.query, 'rye bread');
    });

    testWidgets(
      'Esc in the field clears the highlights and selects the current body match in its field',
      (tester) async {
        final w = await pumpWi85(tester);
        await w.openOn(wi85Query);
        final m = await w.stepUntil(_wi85IsToast);
        expect(w.ranges(), isNotEmpty, reason: 'highlights while open');

        await w.escInField();
        expect(w.bar, findsNothing);
        expect(w.state.open, isFalse);
        expect(w.ranges(), isEmpty);
        expect(w.robot.segmentHasFocus(2), isTrue);
        expect(w.robot.segmentSelection(2), _wi85Sel(m));
        expect(w.state.lastQuery, wi85Query);
      },
    );

    testWidgets(
      'the close button clears the highlights and selects the current body match in its field',
      (tester) async {
        final w = await pumpWi85(tester);
        await w.openOn(wi85Query);
        final m = await w.stepUntil(_wi85IsToast);
        expect(w.ranges(), isNotEmpty);

        await w.tapClose();
        expect(w.bar, findsNothing);
        expect(w.ranges(), isEmpty);
        expect(w.robot.segmentHasFocus(2), isTrue);
        expect(w.robot.segmentSelection(2), _wi85Sel(m));
      },
    );

    testWidgets(
      'with a card current match closing returns the caret to its last body position',
      (tester) async {
        final w = await pumpWi85(tester);
        final caret = wi85Seg2.indexOf('Plain line one.') + 3;
        await _wi85FocusSeg2(w, caret);
        await w.send('show');
        await w.typeQuery(wi85Query);
        await w.stepUntil(_wi85IsCard);

        await w.tapClose();
        expect(w.bar, findsNothing);
        expect(w.ranges(), isEmpty);
        expect(w.robot.segmentHasFocus(2), isTrue);
        expect(
          w.robot.segmentSelection(2),
          TextSelection.collapsed(offset: caret),
        );
      },
    );

    testWidgets(
      'closing in Source mode focuses the Source field and selects the match there',
      (tester) async {
        final w = await pumpWi85(tester);
        await w.h.toggleSource();
        expect(w.h.sourceSurface, findsOneWidget);
        await w.openOn(wi85Query);
        await w.tapNext();
        final m = w.state.currentMatch!;
        expect(m.kind, FindSourceKind.source);

        await w.escInField();
        expect(w.bar, findsNothing);
        expect(w.ranges(), isEmpty);
        final field = w.sourceEditable;
        expect(field.focusNode.hasFocus, isTrue);
        expect(field.controller.selection, _wi85Sel(m));
        expect(
          field.controller.text.substring(m.start, m.end).toLowerCase(),
          wi85Query,
        );
      },
    );
  });

  // ------------------------------------------------------------- note change
  group('note change', () {
    Future<void> expectClosedKeepingQuery(Wi85 w) async {
      expect(w.bar, findsNothing);
      expect(w.state.open, isFalse);
      expect(w.state.matches, isEmpty);
      expect(w.ranges(), isEmpty);
      expect(w.state.lastQuery, wi85Query);
    }

    testWidgets(
      'navigating to another note closes the Find bar and reopening shows the last query',
      (tester) async {
        final w = await pumpWi85(tester);
        await w.openOn(wi85Query);

        await w.h.navigate(const NoteTab(wi85LinkId));
        await expectClosedKeepingQuery(w);

        await w.send('show');
        expect(w.bar, findsOneWidget);
        expect(w.fieldEditable.controller.text, wi85Query);
        expect(
          w.fieldEditable.controller.selection,
          const TextSelection(baseOffset: 0, extentOffset: wi85Query.length),
        );
        expect(w.state.matches, hasLength(3), reason: 'the link note');
      },
    );

    testWidgets('switching tabs closes the Find bar', (tester) async {
      final w = await pumpWi85(tester);
      final topic = w.h.tabs.openOrFocus(const NoteTab(wi85TopicId));
      final other = w.h.tabs.openOrFocus(const NoteTab(wi85LinkId));
      await pumpFrames(tester);
      w.h.tabs.setActive(topic);
      await pumpFrames(tester);
      await w.openOn(wi85Query);

      w.h.tabs.setActive(other);
      await pumpFrames(tester);
      await expectClosedKeepingQuery(w);
    });

    testWidgets('going Back closes the Find bar', (tester) async {
      final w = await pumpWi85(tester, open: wi85LinkId);
      await w.h.navigate(const NoteTab(wi85TopicId));
      await w.openOn(wi85Query);

      w.h.tabs.back();
      await pumpFrames(tester);
      expect(w.h.body().note.id, wi85LinkId);
      await expectClosedKeepingQuery(w);
    });

    testWidgets('closing the note tab closes the Find bar', (tester) async {
      final w = await pumpWi85(tester, open: wi85LinkId);
      final topic = w.h.tabs.openOrFocus(const NoteTab(wi85TopicId));
      await pumpFrames(tester);
      w.h.tabs.setActive(topic);
      await pumpFrames(tester);
      await w.openOn(wi85Query);

      w.h.tabs.close(const NoteTab(wi85TopicId));
      await pumpFrames(tester);
      await expectClosedKeepingQuery(w);
    });

    testWidgets('zooming out of a canvas note closes the Find bar', (
      tester,
    ) async {
      final w = await pumpWi85(tester, open: null, db: _wi85CanvasVault());
      await w.h.navigate(const CanvasTab(C89.newer));
      await w.h.navigate(const CanvasTab(C89.newer, zoomedNoteId: C89.alpha));
      await pumpFrames(tester);
      await w.openOn(wi85Query);

      await w.h.navigate(const CanvasTab(C89.newer));
      await pumpFrames(tester);
      expect(find.byType(NoteEditor), findsNothing);
      await expectClosedKeepingQuery(w);
    });

    testWidgets('switching vaults closes the Find bar', (tester) async {
      final w = await pumpWi85(tester);
      await w.openOn(wi85Query);

      final other = Directory.systemTemp.createTempSync('omv85');
      addTearDown(() {
        try {
          other.deleteSync(recursive: true);
        } on FileSystemException {
          // A queued tab write raced the delete.
        }
      });
      w.container.read(currentVaultProvider.notifier).state = LocalVaultRef(
        other.path,
      );
      await pumpFrames(tester);
      await expectClosedKeepingQuery(w);
    });
  });

  // ------------------------------------------------------------- Source
  group('Source toggle', () {
    testWidgets(
      'toggling Source mode keeps the bar open with the same query and a body current match keeps its offsets',
      (tester) async {
        final w = await pumpWi85(tester);
        await w.openOn(wi85Query);
        final m = await w.stepUntil(
          (m) => m.kind == FindSourceKind.body && m.segment == 0 && m.start > 0,
        );

        await w.h.toggleSource();
        expect(w.bar, findsOneWidget);
        expect(w.state.open, isTrue);
        expect(w.state.query, wi85Query);
        expect(w.fieldEditable.controller.text, wi85Query);
        final now = w.state.currentMatch!;
        expect(now.kind, FindSourceKind.source);
        // Segment 0 starts the Source field.
        expect(now.start, m.start);
        expect(now.end, m.end);

        // And back: the same body match again.
        await w.h.toggleSource();
        expect(w.bar, findsOneWidget);
        expect(w.state.currentMatch, m);
      },
    );

    testWidgets(
      'toggling Source mode keeps the offsets of a body match after a card',
      (tester) async {
        final w = await pumpWi85(tester);
        await w.openOn(wi85Query);
        final m = await w.stepUntil(_wi85IsToast);
        expect(m.segment, 2, reason: 'fixture: after the card token');

        await w.h.toggleSource();
        final source = w.sourceEditable.controller.text;
        final now = w.state.currentMatch!;
        expect(now.kind, FindSourceKind.source);
        // The Source offset counts segment 0, the card token and its line
        // break before segment 2's own offset.
        final at = wi85TopicBody.indexOf('rye slices');
        expect(source.indexOf('rye slices'), at);
        expect(now.start, at);
        expect(now.end, at + wi85Query.length);
        expect(source.substring(now.start, now.end).toLowerCase(), wi85Query);

        // And back: the same body match, in segment 2 again.
        await w.h.toggleSource();
        expect(w.state.currentMatch, m);
      },
    );

    testWidgets(
      'toggling Source mode maps a card current match to the first match at or after the card token',
      (tester) async {
        final w = await pumpWi85(tester);
        await w.openOn(wi85Query);
        await w.stepUntil(_wi85IsCard);

        await w.h.toggleSource();
        expect(w.bar, findsOneWidget);
        final source = w.sourceEditable.controller.text;
        final token = source.indexOf(wi85Token);
        expect(token, isNonNegative);
        final now = w.state.currentMatch!;
        expect(now.kind, FindSourceKind.source);
        expect(
          now,
          w.state.matches.firstWhere((m) => m.start >= token),
          reason: 'the first match at or after the token',
        );
      },
    );

    testWidgets('in Source mode the current match draws in surface0', (
      tester,
    ) async {
      final w = await pumpWi85(tester);
      await w.h.toggleSource();
      await w.openOn(wi85Query);
      final m = w.state.currentMatch!;
      final other = w.state.matches.firstWhere((o) => o != m);
      TextSpan spans() => w.sourceEditable.controller.buildTextSpan(
        context: tester.element(w.h.sourceSurface),
        withComposing: false,
      );

      expect(wi85ColorAt(spans(), m.start), OmColors.surface0);
      expect(wi85ColorAt(spans(), m.end - 1), OmColors.surface0);
      expect(wi85ColorAt(spans(), other.start), isNot(OmColors.surface0));

      await w.tapClose();
      expect(wi85ColorAt(spans(), m.start), isNot(OmColors.surface0));
    });
  });

  // ------------------------------------------------------------- outgoing
  group('outgoing editor', () {
    testWidgets(
      'the outgoing editor of a canvas zoom shows no Find bar and paints no highlights and only the active editor reacts',
      (tester) async {
        const duration = Duration(seconds: 3);
        final w = await pumpWi85(
          tester,
          open: null,
          db: _wi85CanvasVault(),
          zoom: duration,
        );
        Future<void> finishSwitch() async {
          await tester.pump(duration);
          await tester.pump(duration);
          await pumpFrames(tester);
        }

        await w.h.navigate(const CanvasTab(C89.newer));
        await w.h.navigate(const CanvasTab(C89.newer, zoomedNoteId: C89.alpha));
        await finishSwitch();

        w.h.tabs.navigate(const CanvasTab(C89.newer, zoomedNoteId: C89.beta));
        await tester.pump(const Duration(milliseconds: 50));
        await tester.pump(const Duration(milliseconds: 50));
        expect(_wi85Zoomed(C89.alpha), findsOneWidget, reason: 'switching');
        expect(_wi85Zoomed(C89.beta), findsOneWidget);

        await w.send('show');
        expect(_wi85Zoomed(C89.alpha), findsOneWidget, reason: 'switching');
        expect(w.bar, findsOneWidget, reason: 'one Find bar');
        expect(
          find.descendant(of: _wi85Zoomed(C89.beta), matching: w.bar),
          findsOneWidget,
        );
        await w.typeQuery(wi85Query);
        expect(w.state.matches, hasLength(4));
        expect(w.ranges(under: _wi85Zoomed(C89.beta)), isNotEmpty);
        expect(
          w.ranges(under: _wi85Zoomed(C89.alpha)),
          isEmpty,
          reason: 'the outgoing editor paints no highlights',
        );

        final before = w.state.current!;
        await w.send('next');
        expect(
          w.state.current,
          (before + 1) % 4,
          reason: 'one editor stepped once',
        );
        expect(_wi85Zoomed(C89.alpha), findsOneWidget, reason: 'switching');
        await finishSwitch();
        expect(_wi85Zoomed(C89.alpha), findsNothing);
        expect(w.bar, findsOneWidget);
      },
    );
  });

  // ------------------------------------------------------------- match ink
  group('match ink', () {
    testWidgets(
      'live preview draws the current match in surface0 and lifts other matches in body rows card rows and table cells',
      (tester) async {
        final w = await pumpWi85(
          tester,
          open: wi85InkId,
          overrides: [
            excerptRenderProvider.overrideWith((ref, token) async {
              final vault = ref.watch(currentVaultProvider);
              return VaultScoped(
                vault,
                const RenderedExcerpt(
                  date: wi85DailyDate,
                  text: wi85InkCardText,
                  removed: false,
                ),
              );
            }),
          ],
        );
        await w.openOn(wi85Query);
        final matches = w.state.matches;
        expect(matches, hasLength(6));
        expect(
          [for (final m in matches) (m.kind, m.segment)],
          [
            (FindSourceKind.body, 0),
            (FindSourceKind.body, 0),
            (FindSourceKind.card, 1),
            (FindSourceKind.card, 1),
            (FindSourceKind.body, 2),
            (FindSourceKind.body, 2),
          ],
        );
        // Matches 1, 2 and 4 sit in strike runs (fg2 at rest).
        const struck = {1, 2, 4};

        for (var step = 0; step < matches.length; step++) {
          expect(w.state.current, step);
          for (final (j, m) in matches.indexed) {
            final colour = _wi85InkAt(w, m);
            final where = 'match $j while match $step is current';
            if (j == step) {
              expect(colour, OmColors.surface0, reason: where);
            } else if (struck.contains(j)) {
              expect(colour, OmColors.fg1, reason: '$where: lifted to fg1');
            } else {
              expect(colour, isNot(OmColors.surface0), reason: where);
            }
          }
          await w.tapNext();
        }

        // Closed: no ink anywhere.
        await w.tapClose();
        for (final m in matches) {
          expect(_wi85InkAt(w, m), isNot(OmColors.surface0));
        }
        expect(_wi85InkAt(w, matches[1]), OmColors.fg2);
        expect(_wi85InkAt(w, matches[2]), OmColors.fg2);
        expect(_wi85InkAt(w, matches[4]), OmColors.fg2);
      },
    );

    testWidgets(
      'the outgoing editor of a canvas zoom colours no match in its body or card rows',
      (tester) async {
        const duration = Duration(seconds: 3);
        final w = await pumpWi85(
          tester,
          open: null,
          db: _wi85CardZoomVault(),
          zoom: duration,
        );
        await w.h.navigate(const CanvasTab(C89.newer));
        await w.h.navigate(const CanvasTab(C89.newer, zoomedNoteId: C89.alpha));
        await tester.pump(duration);
        await tester.pump(duration);
        await pumpFrames(tester);

        w.h.tabs.navigate(const CanvasTab(C89.newer, zoomedNoteId: C89.beta));
        await tester.pump(const Duration(milliseconds: 50));
        await tester.pump(const Duration(milliseconds: 50));
        final alpha = _wi85Zoomed(C89.alpha);
        final beta = _wi85Zoomed(C89.beta);
        expect(alpha, findsOneWidget, reason: 'switching');
        expect(beta, findsOneWidget);

        await w.openOn(wi85Query);
        final matches = w.state.matches;
        expect(matches, hasLength(4));
        expect(
          [for (final m in matches) m.kind],
          [
            FindSourceKind.body,
            FindSourceKind.card,
            FindSourceKind.card,
            FindSourceKind.body,
          ],
        );
        Color? inkOf(FindMatch m, Finder under) {
          if (m.kind == FindSourceKind.card) {
            final (span, at) = w.cardRowSpan(
              m.segment,
              wi85CardText,
              m.start,
              under: under,
            );
            return wi85ColorAt(span, at);
          }
          final (span, at) = w.bodyRowSpan(m.segment, m.start, under: under);
          return wi85ColorAt(span, at);
        }

        for (final step in [0, 1, 3]) {
          while (w.state.current != step) {
            await w.tapNext();
          }
          final m = w.state.currentMatch!;
          expect(
            inkOf(m, beta),
            OmColors.surface0,
            reason: 'the active editor colours match $step',
          );
          expect(
            inkOf(m, alpha),
            isNot(OmColors.surface0),
            reason: 'the outgoing editor colours nothing (match $step)',
          );
        }
      },
    );
  });

  // ------------------------------------------------------------- keys
  group('keys', () {
    testWidgets(
      'Cmd+F Cmd+G Shift+Cmd+G and Cmd+E are not handled in Dart with the bar open',
      (tester) async {
        final w = await pumpWi85(tester);
        await w.openOn(wi85Query);
        expect(w.fieldFocused, isTrue);
        final keys = [
          (LogicalKeyboardKey.keyF, false),
          (LogicalKeyboardKey.keyG, false),
          (LogicalKeyboardKey.keyG, true),
          (LogicalKeyboardKey.keyE, false),
        ];
        for (final (key, shift) in keys) {
          expect(
            await _wi85CmdHandled(tester, key, shift: shift),
            isFalse,
            reason: '$key shift $shift in the field reaches the native menu',
          );
        }
        await w.robot.focusSegment(0, offset: 0);
        for (final (key, shift) in keys) {
          expect(
            await _wi85CmdHandled(tester, key, shift: shift),
            isFalse,
            reason: '$key shift $shift in the body reaches the native menu',
          );
        }
        expect(w.bar, findsOneWidget);
      },
    );

    testWidgets('Esc in the body does not close the Find bar', (tester) async {
      final w = await pumpWi85(tester);
      await w.openOn(wi85Query);
      await w.robot.focusSegment(0, offset: 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape, platform: 'macos');
      await pumpFrames(tester);
      expect(w.bar, findsOneWidget);
      expect(w.state.open, isTrue);
    });
  });
}
