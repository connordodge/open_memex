// WI #85 (Spec #61 F6; Reqs 23, 27; D2, D3, D4 style counts; TD4): every new
// current match scrolls into view through the note reveal seam
// (`noteRevealProvider`, #66), with `RevealWithin(60)`, no flash and no
// leaveSource. In Source mode the shared reveal drops requests (D3g), so the
// Source field's own scrolling brings the match into view with the same
// 60 px top inset.
//
// Every reveal test pumps through `note_reveal_pump.dart` (ruling D5).
// Requests are counted by sequence number (one step = exactly one request,
// two equal steps = two), jumps with the pump's scroll listener, geometry
// from the shown field's own line boxes. Find is triggered with `find`
// window channel messages and the bar's buttons, never Cmd key events (TD5).
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/excerpt_render.dart';
import 'package:open_memex_app/src/editor/find_in_note.dart';
import 'package:open_memex_app/src/state/note_reveal.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/vault_access/vault_scoped.dart';
import 'package:open_memex_app/src/widgets/editor/excerpt_card.dart';
import 'package:open_memex_app/src/widgets/editor/live_preview_controller.dart';

import '../../support/fake_vault_db.dart';
import '../../support/font_fetch_hold.dart';
import '../../support/note_reveal_pump.dart';
import '../../support/wi85_find_editor.dart';

/// Line tops sit on half pixels.
const _wi85Px = 0.51;

/// The request [r] reveals [m] of note [noteId] in [content] as Find does:
/// text offsets (or the whole card), `RevealWithin(60)`, no flash, no
/// leaveSource.
void _wi85ExpectFindReveal(
  NoteRevealRequest r,
  FindMatch m, {
  required String noteId,
  required String content,
}) {
  expect(r.noteId, noteId);
  expect(r.placement, isA<RevealWithin>());
  expect((r.placement as RevealWithin).topInset, 60);
  expect(r.flash, isFalse);
  expect(r.leaveSource, isFalse);
  final at = r.at;
  if (m.kind == FindSourceKind.card) {
    expect(at, isA<RevealAtCard>());
    at as RevealAtCard;
    expect(at.segment, m.segment);
    expect(at.content, content);
    expect(at.start, m.start, reason: 'the card-local match start');
    expect(at.end, m.end, reason: 'the card-local match end');
    return;
  }
  expect(at, isA<RevealAtText>());
  at as RevealAtText;
  expect(at.segment, m.segment);
  expect(at.start, m.start);
  expect(at.end, m.end);
  expect(at.content, content);
}

int _wi85LongAt(String line) => wi85LongBody.indexOf(line);

// ------------------------------------------------------- deep card and table

const _wi85DeepCardId = 'topic-85-deep-card';
const _wi85DeepItemsId = 'topic-85-deep-items';
const _wi85DeepTableId = 'topic-85-deep-table';

/// Intro, a card, a tail: the card is segment 1.
const _wi85DeepCardBody = 'Intro line.\n$wi85Token\nTail line.\n';

/// 200 prose lines; line 180 holds the only `deep rye`.
final _wi85DeepCardText = [
  for (var i = 0; i < 200; i++) i == 180 ? 'deep rye line' : 'filler line $i',
].join('\n');

/// 200 list items; item 180 holds the only `deep rye`.
final _wi85DeepItemsText = [
  for (var i = 0; i < 200; i++)
    i == 180 ? '- deep rye item' : '- filler item $i',
].join('\n');

/// A table of 200 rows; row 180 holds the only `deep rye` (a cell).
final _wi85DeepTableBody =
    'Intro line.\n\n'
    '| Key | Value |\n'
    '| --- | --- |\n'
    '${[for (var i = 0; i < 200; i++) '| row $i | ${i == 180 ? 'deep rye cell' : 'value $i'} |'].join('\n')}\n'
    '\nTail line.\n';

FakeVaultDb _wi85DeepVault() {
  final db = wi85SeedVault();
  db.seedNote(
    id: _wi85DeepCardId,
    title: 'Deep card',
    content: _wi85DeepCardBody,
  );
  db.seedNote(
    id: _wi85DeepItemsId,
    title: 'Deep items',
    content: _wi85DeepCardBody,
  );
  db.seedNote(
    id: _wi85DeepTableId,
    title: 'Deep table',
    content: _wi85DeepTableBody,
  );
  return db;
}

/// Every card shows [text].
Override _wi85CardShows(String text) =>
    excerptRenderProvider.overrideWith((ref, token) async {
      final vault = ref.watch(currentVaultProvider);
      return VaultScoped(
        vault,
        RenderedExcerpt(date: wi85DailyDate, text: text, removed: false),
      );
    });

/// The global rect of the lines of [needle] in the one [RichText] under
/// [under] whose text holds it, from the paragraph's own line boxes.
Rect _wi85TextRect(WidgetTester tester, Finder under, String needle) {
  final text = find.descendant(
    of: under,
    matching: find.byWidgetPredicate(
      (w) => w is RichText && w.text.toPlainText().contains(needle),
    ),
  );
  expect(text, findsOneWidget, reason: '"$needle" shows once');
  final paragraph = tester.renderObject<RenderParagraph>(text);
  final at = paragraph.text.toPlainText().indexOf(needle);
  final boxes = paragraph.getBoxesForSelection(
    TextSelection(baseOffset: at, extentOffset: at + needle.length),
  );
  expect(boxes, isNotEmpty, reason: '"$needle" is laid out');
  final origin = paragraph.localToGlobal(Offset.zero);
  return boxes
      .map((b) => b.toRect())
      .reduce((a, b) => a.expandToInclude(b))
      .shift(origin);
}

void main() {
  holdFontFetches();

  testWidgets(
    'each step requests exactly one RevealWithin 60 reveal for the new current match',
    (tester) async {
      final w = await pumpWi85(tester, open: wi85LongId);
      await w.openOn(wi85LongQuery);
      expect(w.state.matches, hasLength(3));
      final reveals = w.reveals();

      await w.tapNext();
      expect(reveals.count, 1, reason: 'one step from the bar');
      _wi85ExpectFindReveal(
        reveals.last,
        w.state.currentMatch!,
        noteId: wi85LongId,
        content: w.h.shownContent(),
      );

      await w.send('next');
      expect(reveals.count, 2, reason: 'one step from the menu');
      _wi85ExpectFindReveal(
        reveals.last,
        w.state.currentMatch!,
        noteId: wi85LongId,
        content: w.h.shownContent(),
      );

      await w.tapPrevious();
      expect(reveals.count, 3, reason: 'one step back from the bar');
      _wi85ExpectFindReveal(
        reveals.last,
        w.state.currentMatch!,
        noteId: wi85LongId,
        content: w.h.shownContent(),
      );

      await w.send('previous');
      expect(reveals.count, 4, reason: 'one step back from the menu');
      _wi85ExpectFindReveal(
        reveals.last,
        w.state.currentMatch!,
        noteId: wi85LongId,
        content: w.h.shownContent(),
      );
    },
  );

  testWidgets('two steps to the same match request two reveals', (
    tester,
  ) async {
    final w = await pumpWi85(tester, open: wi85OtherId);
    await w.openOn('nothing');
    expect(w.state.matches, hasLength(1));
    final only = w.state.currentMatch!;
    final reveals = w.reveals();

    await w.tapNext();
    await w.tapNext();
    expect(reveals.count, 2);
    for (final r in reveals.requests) {
      _wi85ExpectFindReveal(
        r,
        only,
        noteId: wi85OtherId,
        content: w.h.shownContent(),
      );
    }
  });

  testWidgets(
    'after stepping to an off-screen match its line top is at least 60 px below the viewport top and above the bottom',
    (tester) async {
      final w = await pumpWi85(tester, open: wi85LongId);
      await w.openOn(wi85LongQuery);
      await w.stepUntil((m) => m.start == _wi85LongAt('first marker') + 6);
      await pumpFrames(tester);
      final second = _wi85LongAt('second marker') + 7;
      final view = w.h.viewport();
      expect(
        w.h.lineTopOf(0, second),
        greaterThan(view.bottom),
        reason: 'fixture: the second marker starts off screen below',
      );

      final jumps = w.h.jumps();
      await w.tapNext();
      expect(w.state.currentMatch!.start, second);
      expect(jumps.count, 1);
      final below = w.h.lineBoxOf(0, second);
      expect(below.top - view.top, greaterThanOrEqualTo(60 - _wi85Px));
      expect(below.bottom, lessThanOrEqualTo(view.bottom + _wi85Px));

      // Back to the first marker, now off screen above: it lands on the
      // 60 px guide.
      final first = _wi85LongAt('first marker') + 6;
      expect(w.h.lineBoxOf(0, first).bottom, lessThan(view.top));
      await w.tapPrevious();
      expect(w.state.currentMatch!.start, first);
      expect(w.h.lineTopOf(0, first) - view.top, closeTo(60, _wi85Px));
    },
  );

  testWidgets('a current match already inside the band causes no scroll', (
    tester,
  ) async {
    final w = await pumpWi85(tester, open: wi85LongId);
    await w.openOn(wi85LongQuery);
    // To the third marker (off screen), then back to the second, which is
    // 20 lines above it and inside the band.
    await w.stepUntil((m) => m.start == _wi85LongAt('third marker') + 6);
    await pumpFrames(tester);
    final second = _wi85LongAt('second marker') + 7;
    final view = w.h.viewport();
    final line = w.h.lineBoxOf(0, second);
    expect(line.top, greaterThanOrEqualTo(view.top + 60));
    expect(line.bottom, lessThanOrEqualTo(view.bottom));
    final pixels = w.h.pixels();

    final jumps = w.h.jumps();
    final reveals = w.reveals();
    await w.tapPrevious();
    expect(w.state.currentMatch!.start, second);
    expect(reveals.count, 1, reason: 'the step still asks for the reveal');
    expect(jumps.count, 0);
    expect(w.h.pixels(), pixels);
  });

  testWidgets('a current card match requests RevealAtCard for that card', (
    tester,
  ) async {
    final w = await pumpWi85(tester);
    await w.openOn(wi85Query);
    // To the match just before the card, then step onto the card.
    await w.stepUntil((m) => m.kind == FindSourceKind.body && m.segment == 0);
    await w.stepUntil(
      (m) =>
          m.kind == FindSourceKind.body &&
          m.segment == 0 &&
          m.start == wi85Seg0.lastIndexOf('rye'),
    );
    final reveals = w.reveals();
    await w.tapNext();
    final card = w.state.currentMatch!;
    expect(card.kind, FindSourceKind.card);
    expect(reveals.count, 1);
    final r = reveals.last;
    expect(r.at, isA<RevealAtCard>());
    expect((r.at as RevealAtCard).segment, 1);
    _wi85ExpectFindReveal(
      r,
      card,
      noteId: wi85TopicId,
      content: w.h.shownContent(),
    );
  });

  testWidgets(
    'a current match in a link URL reveals its line markup while focus stays in the bar',
    (tester) async {
      final w = await pumpWi85(tester, open: wi85LinkId);
      final url = wi85LinkBody.indexOf('rye-guide');
      final row = w.h.rowOf(0, url);
      final local = row.spec.toLocal(url);
      bool urlHidden() {
        final field = find.descendant(
          of: w.h.rowFinder(0, row.index),
          matching: find.byType(EditableText),
        );
        final controller =
            tester.widget<EditableText>(field).controller
                as LivePreviewController;
        return wi85HiddenAt(
          controller.buildTextSpan(
            context: tester.element(field),
            withComposing: false,
          ),
          local,
        );
      }

      expect(urlHidden(), isTrue, reason: 'fixture: the URL renders hidden');
      await w.openOn(wi85Query);
      expect(w.state.matches, hasLength(3));
      await w.stepUntil((m) => m.start == wi85LinkBody.indexOf('rye line'));
      expect(urlHidden(), isTrue);

      await w.tapNext();
      final m = w.state.currentMatch!;
      expect(m.start, url);
      expect(m.hidden, isTrue);
      expect(urlHidden(), isFalse, reason: 'the current match reveals it');
      expect(w.fieldFocused, isTrue, reason: 'focus stays in the bar');

      await w.tapNext();
      expect(w.state.currentMatch!.start, wi85LinkBody.lastIndexOf('rye'));
      expect(urlHidden(), isTrue, reason: 'stepping off hides it again');
      expect(w.fieldFocused, isTrue);
    },
  );

  testWidgets(
    'in Source mode stepping scrolls the Source field to keep the match 60 px below the viewport top',
    (tester) async {
      final w = await pumpWi85(tester, open: wi85LongId);
      await w.h.toggleSource();
      expect(w.h.sourceSurface, findsOneWidget);
      await w.openOn(wi85LongQuery);
      await w.stepUntil((m) => m.start == _wi85LongAt('first marker') + 6);
      await pumpFrames(tester);
      final view = w.h.viewport();
      final second = _wi85LongAt('second marker') + 7;
      expect(w.sourceLineBox(second).top, greaterThan(view.bottom));

      await w.tapNext();
      expect(w.state.currentMatch!.start, second);
      final below = w.sourceLineBox(second);
      expect(below.top - view.top, greaterThanOrEqualTo(60 - _wi85Px));
      expect(below.bottom, lessThanOrEqualTo(view.bottom + _wi85Px));

      final first = _wi85LongAt('first marker') + 6;
      expect(w.sourceLineBox(first).bottom, lessThan(view.top));
      await w.tapPrevious();
      expect(w.state.currentMatch!.start, first);
      expect(w.sourceLineBox(first).top - view.top, closeTo(60, _wi85Px));
    },
  );

  testWidgets('the shared reveal never leaves Source mode for a find step', (
    tester,
  ) async {
    final w = await pumpWi85(tester, open: wi85LongId);
    await w.h.toggleSource();
    await w.openOn(wi85LongQuery);
    await w.tapNext();
    await w.tapNext();
    expect(w.h.sourceSurface, findsOneWidget);
    expect(w.bar, findsOneWidget);
    expect(w.h.tabState.activeTab, const NoteTab(wi85LongId));
  });

  // ----------------------------------------------------- open, query, Cmd+E
  group('reveal on open and query change', () {
    testWidgets(
      'typing a query whose match is off screen requests exactly one reveal and scrolls it into the band',
      (tester) async {
        final w = await pumpWi85(tester, open: wi85LongId);
        final second = _wi85LongAt('second marker');
        final view = w.h.viewport();
        expect(
          w.h.lineTopOf(0, second),
          greaterThan(view.bottom),
          reason: 'fixture: the match starts off screen below',
        );
        await w.send('show');
        final reveals = w.reveals();

        await w.typeQuery('second marker');
        expect(w.state.matches, hasLength(1));
        expect(reveals.count, 1, reason: 'one query change = one reveal');
        _wi85ExpectFindReveal(
          reveals.last,
          w.state.currentMatch!,
          noteId: wi85LongId,
          content: w.h.shownContent(),
        );
        final line = w.h.lineBoxOf(0, second);
        expect(line.top - view.top, greaterThanOrEqualTo(60 - _wi85Px));
        expect(line.bottom, lessThanOrEqualTo(view.bottom + _wi85Px));

        // Another query: one more reveal, not two.
        await w.typeQuery('first marker');
        expect(reveals.count, 2);
        // A query with no match asks for none.
        await w.typeQuery('no such words');
        expect(w.state.matches, isEmpty);
        expect(reveals.count, 2);
      },
    );

    testWidgets('show with a last query requests exactly one reveal', (
      tester,
    ) async {
      final w = await pumpWi85(tester, open: wi85LongId);
      await w.openOn('second marker');
      await w.escInField();
      expect(w.bar, findsNothing);
      final reveals = w.reveals();

      await w.send('show');
      expect(w.bar, findsOneWidget);
      expect(w.state.query, 'second marker');
      expect(w.state.matches, hasLength(1));
      expect(reveals.count, 1, reason: 'opening reveals the current match');
      _wi85ExpectFindReveal(
        reveals.last,
        w.state.currentMatch!,
        noteId: wi85LongId,
        content: w.h.shownContent(),
      );

      // Show again with the bar open: no new current match, no reveal.
      await w.send('show');
      expect(reveals.count, 1);
    });

    testWidgets('next with the bar closed requests exactly one reveal', (
      tester,
    ) async {
      final w = await pumpWi85(tester, open: wi85LongId);
      await w.openOn(wi85LongQuery);
      await w.escInField();
      expect(w.bar, findsNothing);
      final reveals = w.reveals();

      await w.send('next');
      expect(w.bar, findsOneWidget);
      expect(reveals.count, 1, reason: 'open and step reveal once together');
      _wi85ExpectFindReveal(
        reveals.last,
        w.state.currentMatch!,
        noteId: wi85LongId,
        content: w.h.shownContent(),
      );
    });

    testWidgets(
      'Cmd+E with the open bars own query reveals only a current match it moves',
      (tester) async {
        final w = await pumpWi85(tester, open: wi85LongId);
        await w.openOn(wi85LongQuery);
        final third = _wi85LongAt('third marker') + 6;
        expect(w.state.currentMatch!.start, isNot(third));
        await w.robot.focusSegment(0, offset: third);
        w.robot
            .segment(0)
            .select(
              TextSelection(
                baseOffset: third,
                extentOffset: third + wi85LongQuery.length,
              ),
            );
        await tester.pump();
        final reveals = w.reveals();

        await w.send('useSelection');
        expect(w.state.query, wi85LongQuery, reason: 'the same query');
        expect(w.state.currentMatch!.start, third, reason: 'moved to caret');
        expect(reveals.count, 1, reason: 'a moved current match reveals');
        _wi85ExpectFindReveal(
          reveals.last,
          w.state.currentMatch!,
          noteId: wi85LongId,
          content: w.h.shownContent(),
        );

        // Again with the current match already there: nothing moves.
        await w.send('useSelection');
        expect(w.state.currentMatch!.start, third);
        expect(reveals.count, 1);
      },
    );
  });

  // ------------------------------------------------- deep card and table
  group('a match deep in a tall card or table', () {
    testWidgets(
      'a current match deep in a card taller than the viewport lands in the band',
      (tester) async {
        final w = await pumpWi85(
          tester,
          open: _wi85DeepCardId,
          db: _wi85DeepVault(),
          overrides: [_wi85CardShows(_wi85DeepCardText)],
        );
        final card = find.byKey(const Key('excerpt-card-1'));
        final view = w.h.viewport();
        final before = _wi85TextRect(tester, card, 'deep rye');
        expect(tester.getRect(card).height, greaterThan(view.height));
        expect(before.top, greaterThan(view.bottom), reason: 'fixture');
        await w.send('show');
        final reveals = w.reveals();

        await w.typeQuery('deep rye');
        expect(reveals.count, 1);
        final r = reveals.last.at as RevealAtCard;
        expect(r.start, _wi85DeepCardText.indexOf('deep rye'));
        expect(r.end, r.start! + 'deep rye'.length);
        final line = _wi85TextRect(tester, card, 'deep rye');
        expect(line.top - view.top, greaterThanOrEqualTo(60 - _wi85Px));
        expect(line.bottom, lessThanOrEqualTo(view.bottom + _wi85Px));
      },
    );

    testWidgets('a current match deep in a card list item lands in the band', (
      tester,
    ) async {
      final w = await pumpWi85(
        tester,
        open: _wi85DeepItemsId,
        db: _wi85DeepVault(),
        overrides: [_wi85CardShows(_wi85DeepItemsText)],
      );
      final card = find.byKey(const Key('excerpt-card-1'));
      final view = w.h.viewport();
      expect(
        _wi85TextRect(tester, card, 'deep rye item').top,
        greaterThan(view.bottom),
        reason: 'fixture',
      );
      await w.send('show');

      await w.typeQuery('deep rye');
      final line = _wi85TextRect(tester, card, 'deep rye item');
      expect(line.top - view.top, greaterThanOrEqualTo(60 - _wi85Px));
      expect(line.bottom, lessThanOrEqualTo(view.bottom + _wi85Px));
    });

    testWidgets('a card request without a range anchors on the whole card', (
      tester,
    ) async {
      final w = await pumpWi85(
        tester,
        open: _wi85DeepCardId,
        db: _wi85DeepVault(),
        overrides: [_wi85CardShows(_wi85DeepCardText)],
      );
      final card = find.byKey(const Key('excerpt-card-1'));
      final view = w.h.viewport();

      w.h.request(
        NoteRevealRequest(
          _wi85DeepCardId,
          RevealAtCard(segment: 1, content: w.h.shownContent()),
          const RevealWithin(60),
        ),
      );
      await pumpFrames(tester);
      expect(
        tester.getRect(card).top - view.top,
        closeTo(60, _wi85Px),
        reason: 'a card taller than the band sits at the 60 px guide',
      );
      expect(
        _wi85TextRect(tester, card, 'deep rye').top,
        greaterThan(view.bottom),
        reason: 'the whole card is the anchor: the deep line stays below',
      );
    });

    testWidgets(
      'a current match deep in a table taller than the viewport lands in the band',
      (tester) async {
        final w = await pumpWi85(
          tester,
          open: _wi85DeepTableId,
          db: _wi85DeepVault(),
        );
        final table = find.byWidgetPredicate((widget) {
          final k = widget.key;
          return k is ValueKey<String> && k.value.startsWith('editor-table-0-');
        });
        expect(table, findsWidgets);
        final view = w.h.viewport();
        final before = _wi85TextRect(tester, table.first, 'deep rye cell');
        expect(before.top, greaterThan(view.bottom), reason: 'fixture');
        await w.send('show');
        final reveals = w.reveals();

        await w.typeQuery('deep rye');
        expect(reveals.count, 1);
        final at = reveals.last.at as RevealAtText;
        expect(at.end, isNotNull, reason: 'Find sends the match range');
        final cell = _wi85TextRect(tester, table.first, 'deep rye cell');
        expect(cell.top - view.top, greaterThanOrEqualTo(60 - _wi85Px));
        expect(cell.bottom, lessThanOrEqualTo(view.bottom + _wi85Px));
      },
    );
  });
}
