// WI #166 (B3): live preview links. Ghost detection from
// `noteTitlesAsyncProvider` (R4, D14), Cmd-hover cursor and hover style,
// Cmd+click navigation (wikilinks, transclusion tokens, URL links) and
// `EditorController.flushPendingSave()` (D14, D9). Design pack
// design/156-live-preview/packs/166.md (flows F2-1, F2-2, F2-3).
//
// Widget tests run the whole workspace on FakeVaultDb + FakeMemexCli with a
// FakeClock (the save debounce never fires unless a test advances it) and a
// fake UrlOpener, under macOS only (mac_editing.dart). Rendered link styles
// are read from the field render object span, the way the engine paints
// them; points come from the segment handle caret rects.
import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/editor_controller.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/url_opener.dart';
import 'package:open_memex_app/src/state/vault_access_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/vault_access/vault_scoped.dart';
import 'package:open_memex_app/src/widgets/editor/line_boxes.dart';
import 'package:open_memex_app/src/widgets/editor/link_region.dart';
import 'package:open_memex_app/src/widgets/editor/live_preview_controller.dart';

import '../robots/segmented_editor_robot.dart';
import '../support/app_harness.dart';
import '../support/daily_seed.dart';
import '../support/editor_access_doubles.dart';
import '../support/editor_scope.dart';
import '../support/fake_clock.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/font_fetch_hold.dart';
import '../support/mac_editing.dart';
import '../support/segment_editing_finder.dart';
import '../support/today_cli_fakes.dart';
import '../support/wi159_line_geometry.dart' show wi159EditableIn;

/// The note titled `Known` that resolved wikilinks open.
const _knownId = 'topic-known';

/// A fake [UrlOpener] that records every URL and opens nothing.
class _FakeUrlOpener implements UrlOpener {
  final List<String> opened = [];

  @override
  Future<void> open(String url) async => opened.add(url);
}

/// Everything a links test needs after [_launch].
class _Links {
  _Links(this.r, this.opener);

  final SegmentedEditorRobot r;
  final _FakeUrlOpener opener;

  WidgetTester get tester => r.tester;
  WorkspaceHarness get h => r.h;

  List<WorkspaceTab> get tabs => h.read(tabsProvider).tabs;

  /// Every CLI call other than the harness `settings get` reads.
  List<FakeCliCall> get writes =>
      h.cli.calls.where((c) => c.subcommand != 'settings get').toList();

  int get noteCount =>
      (h.db.db.select('SELECT COUNT(*) AS n FROM notes').single['n'] as num)
          .toInt();

  /// Lets queued tab persistence finish before the harness deletes the
  /// temp vault: `UiStateStore.flush()` chains real file IO (which only
  /// runs outside the fake zone) with fake-zone callbacks (which only run on
  /// a pump), so alternate the two until the flush completes (bounded; the
  /// real IO side yields 1 ms per round, since 200 zero-length rounds ran
  /// out under suite load, with the load average near 37).
  Future<void> settle() async {
    await pumpFrames(tester);
    final store = h.read(tabsProvider.notifier).store;
    var flushed = false;
    unawaited(store.flush().then((_) => flushed = true));
    for (var i = 0; i < 5000 && !flushed; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1)),
      );
      await tester.pump();
    }
    expect(flushed, isTrue, reason: 'tab persistence finished');
  }
}

/// Pumps the workspace on [seedSegmentedVault] with the topic note body
/// [body] (plus a topic note `Known`, id [_knownId]), applies [seed] to the
/// database, overrides `urlOpenerProvider` with a fake (always: no test
/// launches `/usr/bin/open`) and opens the topic note.
Future<_Links> _launch(
  WidgetTester tester,
  String body, {
  void Function(FakeVaultDb db)? seed,
  List<Override> overrides = const [],
}) async {
  final vault = seedSegmentedVault(topicBody: body);
  vault.db.seedTopicNote(_knownId, 'Known');
  seed?.call(vault.db);
  final opener = _FakeUrlOpener();
  final h = await pumpWorkspace(
    tester,
    db: vault.db,
    cli: vault.cli,
    overrides: [urlOpenerProvider.overrideWithValue(opener), ...overrides],
  );
  final r = SegmentedEditorRobot(tester, h);
  await r.open(fixtureTopicId);
  await pumpFrames(tester);
  return _Links(r, opener);
}

/// Overrides `noteTitlesAsyncProvider` with [load]'s titles, scoped to the
/// open vault (the real provider stays unchanged; D14).
Override _titles(Future<List<NoteTitle>> Function() load) =>
    noteTitlesAsyncProvider.overrideWith((ref) async {
      final vault = ref.watch(currentVaultProvider);
      return VaultScoped(vault, await load());
    });

/// [count] distinct titles built at run time; `Known` (id [_knownId]) is
/// one of them when [withKnown].
List<NoteTitle> _manyTitles(int count, {bool withKnown = true}) => [
  if (withKnown) NoteTitle(id: _knownId, title: 'Known', updatedAt: 1),
  for (var i = withKnown ? 1 : 0; i < count; i++)
    NoteTitle(id: 'bulk-$i', title: 'Bulk note $i', updatedAt: i),
];

/// `[start, end)` of the [nth] occurrence of [needle] in segment [seg].
(int, int) _find(
  SegmentedEditorRobot r,
  int seg,
  String needle, {
  int nth = 0,
}) {
  final text = r.segmentText(seg);
  var at = -1;
  for (var i = 0; i <= nth; i++) {
    at = text.indexOf(needle, at + 1);
    expect(at, isNonNegative, reason: 'segment $seg holds "$needle" #$i');
  }
  return (at, at + needle.length);
}

/// A global point in the middle of the shown text [needle] of segment
/// [seg] (between the caret rects at its first and past its last code
/// unit, so hidden markers around it are excluded).
Offset _pointOn(SegmentedEditorRobot r, int seg, String needle, {int nth = 0}) {
  final (start, end) = _find(r, seg, needle, nth: nth);
  final a = r.segment(seg).rectForOffset(start);
  final b = r.segment(seg).rectForOffset(end);
  expect(
    a.center.dy,
    closeTo(b.center.dy, 0.5),
    reason: '"$needle" lays out on one line',
  );
  expect(b.left, greaterThan(a.left), reason: '"$needle" has a width');
  return Offset((a.left + b.left) / 2, a.center.dy);
}

/// The effective style of the code unit at [offset] of segment [seg]'s
/// rendered span: every ancestor style merged down to its leaf.
TextStyle _renderedStyleAt(WidgetTester tester, int seg, int offset) {
  final root = wi159EditableIn(tester, find.byKey(textSegmentKey(seg))).text!;
  TextStyle? found;
  var pos = 0;
  bool visit(InlineSpan span, TextStyle inherited) {
    final style = span.style == null ? inherited : inherited.merge(span.style);
    if (span is TextSpan) {
      final text = span.text ?? '';
      if (offset >= pos && offset < pos + text.length) {
        found = style;
        return false;
      }
      pos += text.length;
      for (final child in span.children ?? const <InlineSpan>[]) {
        if (!visit(child, style)) return false;
      }
    }
    return true;
  }

  visit(root, const TextStyle());
  expect(found, isNotNull, reason: 'offset $offset is in the rendered span');
  return found!;
}

/// The rendered style of the first code unit of [needle] in segment [seg].
TextStyle _styleOf(
  WidgetTester tester,
  SegmentedEditorRobot r,
  int seg,
  String needle, {
  int nth = 0,
}) => _renderedStyleAt(tester, seg, _find(r, seg, needle, nth: nth).$1);

/// Whether [style] is the ghost wikilink style (pack 166: `fg2` text, a
/// dashed `fg3` underline).
bool _isGhost(TextStyle style) =>
    style.color == OmColors.fg2 &&
    style.decorationStyle == TextDecorationStyle.dashed;

/// Whether [style] is the resolved wikilink style (`accent`, not dashed).
bool _isResolvedLink(TextStyle style) =>
    style.color == OmColors.accent &&
    style.decorationStyle != TextDecorationStyle.dashed;

bool _isUnderlined(TextStyle style) =>
    style.decoration?.contains(TextDecoration.underline) ?? false;

/// The live preview controller (the one its LinkRegion gets) of segment
/// [seg]'s editor row holding segment offset [offset]. C1 (#167) gives each
/// row its own controller and LinkRegion; with no [offset] the segment must
/// show exactly one row.
LivePreviewController _controllerOf(
  WidgetTester tester,
  int seg, {
  int? offset,
}) {
  final regions = find.descendant(
    of: find.byKey(textSegmentKey(seg)),
    matching: find.byType(LinkRegion),
  );
  if (offset == null) return tester.widget<LinkRegion>(regions).controller;
  final handle = segmentEditingAt(tester, seg);
  final all = tester.widgetList<LinkRegion>(regions).toList();
  expect(all, hasLength(handle.rowCount), reason: 'one LinkRegion per row');
  return all[segmentRowHolding(handle, offset)].controller;
}

/// The mouse cursor the app shows for the test mouse (device 1).
MouseCursor? _cursor() =>
    RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1);

Future<void> _cmdDown(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft, platform: 'macos');
  await tester.pump();
}

Future<void> _cmdUp(WidgetTester tester) async {
  await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft, platform: 'macos');
  await tester.pump();
}

/// Adds a hovering mouse at [at] (no button down) and pumps; the caller
/// removes it with [_removeMouse].
Future<TestGesture> _mouseAt(WidgetTester tester, Offset at) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: at);
  await tester.pump();
  await mouse.moveTo(at);
  await tester.pump();
  return mouse;
}

Future<void> _removeMouse(WidgetTester tester, TestGesture mouse) async {
  await mouse.removePointer();
  await tester.pump();
}

/// Removes the mouse a `macCmdClick` (a mouse `tapAt`) leaves added, so a
/// later [_mouseAt] can add it again without a MouseTracker assertion.
Future<void> _dropClickMouse(WidgetTester tester) async {
  final stale = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await _removeMouse(tester, stale);
}

void main() {
  // settle() lets real IO run; held font fetches keep google_fonts' failed
  // HTTP loads out of every test zone.
  holdFontFetches();

  // -------------------------------------------------------------------------
  // AC1-AC3: ghost detection
  // -------------------------------------------------------------------------
  group('ghost detection', () {
    testWidgets(
      'with titles loaded a missing wikilink renders as a ghost and a padded known wikilink resolves',
      (tester) async {
        final t = await _launch(
          tester,
          'See [[Missing]] and [[ Known ]] now\n',
        );
        final r = t.r;

        final missing = _styleOf(tester, r, 0, 'Missing');
        expect(_isGhost(missing), isTrue, reason: '$missing');
        final known = _styleOf(tester, r, 0, 'Known');
        expect(_isResolvedLink(known), isTrue, reason: '$known');
        expect(_isGhost(known), isFalse);
        await t.settle();
      },
      variant: macOnly,
    );

    testWidgets(
      'a lower case known wikilink is a ghost when only Known exists',
      (tester) async {
        final t = await _launch(tester, 'See [[known]] and [[Known]] now\n');
        final r = t.r;

        final lower = _styleOf(tester, r, 0, 'known');
        expect(_isGhost(lower), isTrue, reason: '$lower');
        final exact = _styleOf(tester, r, 0, 'Known');
        expect(_isResolvedLink(exact), isTrue, reason: '$exact');
        await t.settle();
      },
      variant: macOnly,
    );

    testWidgets('ghost detection applies to every text segment of the note', (
      tester,
    ) async {
      final t = await _launch(
        tester,
        'One [[Missing]]\n![[2026-09-05#^b7k2m9]]\nTwo [[Missing]] and [[Known]]\n',
      );
      final r = t.r;
      expect(r.card(1), findsOneWidget);

      expect(_isGhost(_styleOf(tester, r, 0, 'Missing')), isTrue);
      expect(_isGhost(_styleOf(tester, r, 2, 'Missing')), isTrue);
      expect(_isResolvedLink(_styleOf(tester, r, 2, 'Known')), isTrue);
      await t.settle();
    }, variant: macOnly);

    testWidgets(
      'a wikilink with an alias and a kind resolves by its trimmed title',
      (tester) async {
        final t = await _launch(
          tester,
          'See [[ Known ~ref|the doc]] and [[Missing|other]] now\n',
        );
        final r = t.r;

        expect(_isResolvedLink(_styleOf(tester, r, 0, 'the doc')), isTrue);
        expect(_isGhost(_styleOf(tester, r, 0, 'other')), isTrue);
        await t.settle();
      },
      variant: macOnly,
    );

    testWidgets('before the titles load every wikilink renders resolved', (
      tester,
    ) async {
      final load = Completer<List<NoteTitle>>();
      final t = await _launch(
        tester,
        'See [[Missing]] and [[known]] now\n',
        overrides: [_titles(() => load.future)],
      );
      final r = t.r;

      expect(_isResolvedLink(_styleOf(tester, r, 0, 'Missing')), isTrue);
      expect(_isResolvedLink(_styleOf(tester, r, 0, 'known')), isTrue);

      // Once they load, the same field shows the ghosts.
      load.complete(_manyTitles(3));
      await pumpFrames(tester);
      expect(_isGhost(_styleOf(tester, r, 0, 'Missing')), isTrue);
      expect(_isGhost(_styleOf(tester, r, 0, 'known')), isTrue);
      await t.settle();
    }, variant: macOnly);

    testWidgets(
      'with exactly 1000 titles loaded every wikilink renders resolved',
      (tester) async {
        var current = _manyTitles(1000);
        expect(current, hasLength(1000));
        final t = await _launch(
          tester,
          'See [[Missing]] and [[known]] now\n',
          overrides: [_titles(() async => current)],
        );
        final r = t.r;

        expect(_isResolvedLink(_styleOf(tester, r, 0, 'Missing')), isTrue);
        expect(_isResolvedLink(_styleOf(tester, r, 0, 'known')), isTrue);

        // One title fewer and the list is complete: the ghosts show.
        current = _manyTitles(999);
        t.h.container.invalidate(noteTitlesAsyncProvider);
        await pumpFrames(tester);
        expect(_isGhost(_styleOf(tester, r, 0, 'Missing')), isTrue);
        expect(_isGhost(_styleOf(tester, r, 0, 'known')), isTrue);

        // Back at the cap: resolved again.
        current = _manyTitles(1000);
        t.h.container.invalidate(noteTitlesAsyncProvider);
        await pumpFrames(tester);
        expect(_isResolvedLink(_styleOf(tester, r, 0, 'Missing')), isTrue);
        expect(_isResolvedLink(_styleOf(tester, r, 0, 'known')), isTrue);
        await t.settle();
      },
      variant: macOnly,
    );

    testWidgets(
      'with 999 titles loaded a missing wikilink renders as a ghost',
      (tester) async {
        final titles = _manyTitles(999);
        final t = await _launch(
          tester,
          'See [[Missing]] and [[Known]] now\n',
          overrides: [_titles(() async => titles)],
        );
        final r = t.r;

        expect(_isGhost(_styleOf(tester, r, 0, 'Missing')), isTrue);
        expect(_isResolvedLink(_styleOf(tester, r, 0, 'Known')), isTrue);
        await t.settle();
      },
      variant: macOnly,
    );

    testWidgets(
      'a transclusion token resolves when a note titled with its date exists and is a ghost otherwise',
      (tester) async {
        // The seeded daily note is titled 2026-09-05; no note is titled
        // 2026-09-07. Inline tokens stay in the text segment.
        final t = await _launch(
          tester,
          'A ![[2026-09-05#^ab12]] and ![[2026-09-07#^ab12]] end\n',
        );
        final r = t.r;
        expect(r.allCards, findsNothing);

        final present = _styleOf(tester, r, 0, '2026-09-05');
        expect(_isResolvedLink(present), isTrue, reason: '$present');
        final absent = _styleOf(tester, r, 0, '2026-09-07');
        expect(_isGhost(absent), isTrue, reason: '$absent');
        await t.settle();
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // AC4: plain click
  // -------------------------------------------------------------------------
  group('plain click', () {
    testWidgets(
      'a plain click on a wikilink places the caret inside it and opens nothing',
      (tester) async {
        final t = await _launch(tester, 'See [[Known]] now\n');
        final r = t.r;
        final (start, end) = _find(r, 0, '[[Known]]');
        final tabsBefore = List.of(t.tabs);

        await tester.tapAt(
          _pointOn(r, 0, 'Known'),
          kind: PointerDeviceKind.mouse,
        );
        await pumpFrames(tester);

        final selection = r.segmentSelection(0);
        expect(selection.isCollapsed, isTrue);
        expect(selection.baseOffset, greaterThan(start));
        expect(selection.baseOffset, lessThan(end));
        r.expectActiveNote(fixtureTopicId);
        expect(t.tabs, tabsBefore);
        expect(t.opener.opened, isEmpty);

        // The same spot with Cmd held opens it (not a double click).
        await tester.pump(const Duration(seconds: 1));
        await tester.macCmdClick(_pointOn(r, 0, 'Known'));
        await pumpFrames(tester);
        r.expectActiveNote(_knownId);
        await t.settle();
      },
      variant: macOnly,
    );

    testWidgets(
      'a plain click on a URL link places the caret and opens nothing',
      (tester) async {
        final t = await _launch(tester, 'Go [docs](https://x.y) now\n');
        final r = t.r;
        final (start, end) = _find(r, 0, '[docs](https://x.y)');

        await tester.tapAt(
          _pointOn(r, 0, 'docs'),
          kind: PointerDeviceKind.mouse,
        );
        await pumpFrames(tester);

        final selection = r.segmentSelection(0);
        expect(selection.isCollapsed, isTrue);
        expect(selection.baseOffset, inInclusiveRange(start + 1, end - 1));
        expect(t.opener.opened, isEmpty);
        r.expectActiveNote(fixtureTopicId);

        // The same spot with Cmd held opens it (not a double click).
        await tester.pump(const Duration(seconds: 1));
        await tester.macCmdClick(_pointOn(r, 0, 'docs'));
        await pumpFrames(tester);
        expect(t.opener.opened, ['https://x.y']);
        await t.settle();
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // AC5: Cmd-hover cursor and hover style (F2-1, F2-2, F2-3)
  // -------------------------------------------------------------------------
  group('Cmd hover', () {
    testWidgets(
      'with Cmd held hovering a resolved wikilink shows the click cursor',
      (tester) async {
        final t = await _launch(tester, 'Read [[Zeta Game]] today\n');
        final r = t.r;
        final (start, end) = _find(r, 0, '[[Zeta Game]]');
        final at = _pointOn(r, 0, 'Zeta Game');

        await _cmdDown(tester);
        final mouse = await _mouseAt(tester, at);
        try {
          expect(_cursor(), SystemMouseCursors.click);
          expect(
            _controllerOf(tester, 0).cmdHover,
            TextRange(start: start, end: end),
          );
          final style = _styleOf(tester, r, 0, 'Zeta Game');
          expect(_isUnderlined(style), isTrue, reason: '$style');
          expect(style.color, OmColors.accent);
        } finally {
          await _removeMouse(tester, mouse);
          await _cmdUp(tester);
        }
        await t.settle();
      },
      variant: macOnly,
    );

    testWidgets('with Cmd held hovering a ghost keeps the text cursor', (
      tester,
    ) async {
      final t = await _launch(
        tester,
        'Still to read: [[Obsidian live preview notes]].\n',
      );
      final r = t.r;
      final at = _pointOn(r, 0, 'Obsidian live preview notes');

      await _cmdDown(tester);
      final mouse = await _mouseAt(tester, at);
      try {
        expect(_cursor(), SystemMouseCursors.text);
        expect(_controllerOf(tester, 0).cmdHover, isNull);
        final style = _styleOf(tester, r, 0, 'Obsidian live preview notes');
        expect(_isGhost(style), isTrue, reason: '$style');
      } finally {
        await _removeMouse(tester, mouse);
        await _cmdUp(tester);
      }
      await t.settle();
    }, variant: macOnly);

    testWidgets(
      'without Cmd hovering a resolved wikilink keeps the text cursor and no hover',
      (tester) async {
        final t = await _launch(tester, 'Read [[Zeta Game]] today\n');
        final r = t.r;
        final mouse = await _mouseAt(tester, _pointOn(r, 0, 'Zeta Game'));
        try {
          expect(_cursor(), SystemMouseCursors.text);
          expect(_controllerOf(tester, 0).cmdHover, isNull);
          final style = _styleOf(tester, r, 0, 'Zeta Game');
          expect(_isUnderlined(style), isFalse, reason: '$style');

          // Moving onto it again with Cmd held is what shows the hover.
          await mouse.moveTo(_pointOn(r, 0, 'today'));
          await tester.pump();
          await _cmdDown(tester);
          await mouse.moveTo(_pointOn(r, 0, 'Zeta Game'));
          await tester.pump();
          expect(_cursor(), SystemMouseCursors.click);
          expect(_isUnderlined(_styleOf(tester, r, 0, 'Zeta Game')), isTrue);
        } finally {
          await _removeMouse(tester, mouse);
          if (HardwareKeyboard.instance.isMetaPressed) await _cmdUp(tester);
        }
        await t.settle();
      },
      variant: macOnly,
    );

    testWidgets('with Cmd held hovering a URL link shows the click cursor', (
      tester,
    ) async {
      final t = await _launch(
        tester,
        'Read the [Flutter TextSpan docs](https://x.y) and more\n',
      );
      final r = t.r;
      final (start, end) = _find(r, 0, '[Flutter TextSpan docs](https://x.y)');

      await _cmdDown(tester);
      final mouse = await _mouseAt(
        tester,
        _pointOn(r, 0, 'Flutter TextSpan docs'),
      );
      try {
        expect(_cursor(), SystemMouseCursors.click);
        expect(
          _controllerOf(tester, 0).cmdHover,
          TextRange(start: start, end: end),
        );
      } finally {
        await _removeMouse(tester, mouse);
        await _cmdUp(tester);
      }
      await t.settle();
    }, variant: macOnly);

    testWidgets(
      'pressing Cmd while resting over a resolved wikilink shows the click cursor and releasing it restores the text cursor',
      (tester) async {
        final t = await _launch(tester, 'Read [[Zeta Game]] today\n');
        final r = t.r;
        final (start, end) = _find(r, 0, '[[Zeta Game]]');
        final mouse = await _mouseAt(tester, _pointOn(r, 0, 'Zeta Game'));
        try {
          expect(_cursor(), SystemMouseCursors.text);

          await _cmdDown(tester);
          await tester.pump();
          expect(_cursor(), SystemMouseCursors.click);
          expect(
            _controllerOf(tester, 0).cmdHover,
            TextRange(start: start, end: end),
          );

          await _cmdUp(tester);
          await tester.pump();
          expect(_cursor(), SystemMouseCursors.text);
          expect(_controllerOf(tester, 0).cmdHover, isNull);
        } finally {
          await _removeMouse(tester, mouse);
        }
        await t.settle();
      },
      variant: macOnly,
    );

    testWidgets(
      'with Cmd held moving off a resolved wikilink clears the hover and restores the text cursor',
      (tester) async {
        final t = await _launch(tester, 'Read [[Zeta Game]] today\n');
        final r = t.r;
        final on = _pointOn(r, 0, 'Zeta Game');
        final off = _pointOn(r, 0, 'today');

        await _cmdDown(tester);
        final mouse = await _mouseAt(tester, on);
        try {
          expect(_controllerOf(tester, 0).cmdHover, isNotNull);

          await mouse.moveTo(off);
          await tester.pump();
          expect(_cursor(), SystemMouseCursors.text);
          expect(_controllerOf(tester, 0).cmdHover, isNull);
          final style = _styleOf(tester, r, 0, 'Zeta Game');
          expect(_isUnderlined(style), isFalse, reason: '$style');
        } finally {
          await _removeMouse(tester, mouse);
          await _cmdUp(tester);
        }
        await t.settle();
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // AC6, AC7: Cmd+click on a resolved wikilink
  // -------------------------------------------------------------------------
  group('Cmd+click wikilink', () {
    testWidgets(
      'Cmd+click on a resolved wikilink opens NoteTab of that note in tabsProvider',
      (tester) async {
        final t = await _launch(tester, 'See [[Known]] now\n');
        final r = t.r;
        final before = t.tabs.length;

        await tester.macCmdClick(_pointOn(r, 0, 'Known'));
        await pumpFrames(tester);

        r.expectActiveNote(_knownId);
        expect(t.tabs, contains(const NoteTab(_knownId)));
        expect(t.tabs.length, before + 1);
        await t.settle();
      },
      variant: macOnly,
    );

    testWidgets(
      'Cmd+click on a resolved wikilink focuses the already open tab of that note',
      (tester) async {
        final t = await _launch(tester, 'See [[Known]] now\n');
        final r = t.r;
        await r.open(_knownId);
        await r.open(fixtureTopicId);
        final before = List.of(t.tabs);

        await tester.macCmdClick(_pointOn(r, 0, 'Known'));
        await pumpFrames(tester);

        r.expectActiveNote(_knownId);
        expect(t.tabs.toSet(), before.toSet());
        expect(
          t.tabs.where((tab) => tab == const NoteTab(_knownId)),
          hasLength(1),
        );
        await t.settle();
      },
      variant: macOnly,
    );

    testWidgets(
      'Cmd+click on an aliased wikilink opens the note of its title',
      (tester) async {
        final t = await _launch(tester, 'See [[ Known |the doc]] now\n');
        final r = t.r;

        await tester.macCmdClick(_pointOn(r, 0, 'the doc'));
        await pumpFrames(tester);

        r.expectActiveNote(_knownId);
        await t.settle();
      },
      variant: macOnly,
    );

    testWidgets('Cmd+click on plain text next to a wikilink opens nothing', (
      tester,
    ) async {
      final t = await _launch(tester, 'See [[Known]] and more words\n');
      final r = t.r;
      final before = List.of(t.tabs);

      await tester.macCmdClick(_pointOn(r, 0, 'more words'));
      await pumpFrames(tester);

      r.expectActiveNote(fixtureTopicId);
      expect(t.tabs, before);
      expect(t.opener.opened, isEmpty);

      // The wikilink beside it does open (not a double click).
      await tester.pump(const Duration(seconds: 1));
      await tester.macCmdClick(_pointOn(r, 0, 'Known'));
      await pumpFrames(tester);
      r.expectActiveNote(_knownId);
      await t.settle();
    }, variant: macOnly);

    testWidgets(
      'typing a character and Cmd+clicking a wikilink before the debounce saves the edited body before the tab switch',
      (tester) async {
        const body = 'See [[Known]] now\n';
        const edited = 'See [[Known]] now!\n';
        final t = await _launch(tester, body);
        final r = t.r;
        final h = t.h;

        // The updates the CLI had received when the tab switched.
        List<String?>? sentAtSwitch;
        final sub = h.container.listen<TabsState>(tabsProvider, (_, next) {
          if (next.activeTab == const NoteTab(_knownId)) {
            sentAtSwitch ??= [
              for (final c in h.cli.callsFor('update')) c.stdinBody,
            ];
          }
        });
        addTearDown(sub.close);

        await r.focusSegment(0);
        await r.typeInSegment(0, edited);
        expect(h.cli.callsFor('update'), isEmpty, reason: 'debounce pending');

        await tester.macCmdClick(_pointOn(r, 0, 'Known'));
        await pumpFrames(tester);

        r.expectActiveNote(_knownId);
        expect(sentAtSwitch, [edited]);
        final update = h.cli.callsFor('update').single;
        expect(update.flag('note-id'), fixtureTopicId);
        expect(h.db.getNote(fixtureTopicId)!.contentMd, edited);

        // The flushed debounce never fires a second save.
        await r.waitForSave();
        expect(h.cli.callsFor('update'), hasLength(1));

        // Coming back shows the edit: nothing was lost.
        await r.open(fixtureTopicId);
        expect(r.segmentText(0), edited);
        await t.settle();
      },
      variant: macOnly,
    );

    testWidgets(
      'Cmd+click on a resolved wikilink with no pending edit sends no update',
      (tester) async {
        final t = await _launch(tester, 'See [[Known]] now\n');
        final r = t.r;

        await tester.macCmdClick(_pointOn(r, 0, 'Known'));
        await pumpFrames(tester);
        await r.waitForSave();

        r.expectActiveNote(_knownId);
        expect(t.h.cli.callsFor('update'), isEmpty);
        await t.settle();
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // AC8: Cmd+click on a transclusion token
  // -------------------------------------------------------------------------
  group('Cmd+click transclusion', () {
    testWidgets(
      'Cmd+click on a transclusion token opens the daily note for its date',
      (tester) async {
        final t = await _launch(tester, 'See ![[2026-09-05#^b7k2m9]] now\n');
        final r = t.r;
        expect(r.allCards, findsNothing);

        await tester.macCmdClick(_pointOn(r, 0, '2026-09-05'));
        await pumpFrames(tester);

        r.expectActiveNote(fixtureDailyId);
        await t.settle();
      },
      variant: macOnly,
    );

    testWidgets(
      'Cmd+click on a transclusion token with no daily note for its date does nothing',
      (tester) async {
        // A topic note titled with the date makes the token resolve, but
        // there is no daily note for 2026-09-06.
        final t = await _launch(
          tester,
          'See ![[2026-09-06#^ab12]] or ![[2026-09-05#^b7k2m9]] now\n',
          seed: (db) => db.seedTopicNote('topic-dated', '2026-09-06'),
        );
        final r = t.r;
        expect(_isResolvedLink(_styleOf(tester, r, 0, '2026-09-06')), isTrue);
        final before = List.of(t.tabs);

        await tester.macCmdClick(_pointOn(r, 0, '2026-09-06'));
        await pumpFrames(tester);

        r.expectActiveNote(fixtureTopicId);
        expect(t.tabs, before);
        expect(t.tabs, isNot(contains(const NoteTab('topic-dated'))));
        expect(t.writes, isEmpty);

        // The token beside it, whose daily note exists, does open.
        await tester.pump(const Duration(seconds: 1));
        await tester.macCmdClick(_pointOn(r, 0, '2026-09-05'));
        await pumpFrames(tester);
        r.expectActiveNote(fixtureDailyId);
        await t.settle();
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // AC9: Cmd+click on a ghost
  // -------------------------------------------------------------------------
  group('Cmd+click ghost', () {
    testWidgets(
      'Cmd+click on a ghost creates no note, opens no tab and leaves the text unchanged',
      (tester) async {
        const body = 'See [[Missing]] or [[Known]] now\n';
        final t = await _launch(tester, body);
        final r = t.r;
        expect(_isGhost(_styleOf(tester, r, 0, 'Missing')), isTrue);
        final tabsBefore = List.of(t.tabs);
        final notesBefore = t.noteCount;
        final at = _pointOn(r, 0, 'Missing');

        await tester.macCmdClick(at);
        await pumpFrames(tester);
        await r.waitForSave();

        r.expectActiveNote(fixtureTopicId);
        expect(t.tabs, tabsBefore);
        expect(t.noteCount, notesBefore);
        expect(t.writes, isEmpty);
        expect(r.segmentText(0), body);
        expect(t.opener.opened, isEmpty);

        // The text cursor stays over the ghost with Cmd held. The click
        // left its mouse (device 1) added; remove it before hovering anew.
        await _dropClickMouse(tester);
        await _cmdDown(tester);
        final mouse = await _mouseAt(tester, at);
        try {
          expect(_cursor(), SystemMouseCursors.text);
        } finally {
          await _removeMouse(tester, mouse);
          await _cmdUp(tester);
        }

        // The resolved wikilink beside it does open.
        await tester.pump(const Duration(seconds: 1));
        await tester.macCmdClick(_pointOn(r, 0, 'Known'));
        await pumpFrames(tester);
        r.expectActiveNote(_knownId);
        await t.settle();
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // AC10: Cmd+click on [text](url)
  // -------------------------------------------------------------------------
  group('Cmd+click URL link', () {
    for (final (name, url, opens) in [
      (
        'Cmd+click on an https link calls the UrlOpener with its URL',
        'https://x.y',
        true,
      ),
      (
        'Cmd+click on an http link calls the UrlOpener with its URL',
        'http://x.y',
        true,
      ),
      (
        'Cmd+click on a mailto link calls the UrlOpener with its URL',
        'mailto:a@b.c',
        true,
      ),
      ('Cmd+click on a file link calls nothing', 'file:///etc', false),
      ('Cmd+click on a javascript link calls nothing', 'javascript:x', false),
      ('Cmd+click on a link with no scheme calls nothing', 'x.y/z', false),
    ]) {
      testWidgets(name, (tester) async {
        final body = 'Go [a]($url) or [ok](https://ok.y) now\n';
        final t = await _launch(tester, body);
        final r = t.r;
        final before = List.of(t.tabs);

        await tester.macCmdClick(_pointOn(r, 0, 'a'));
        await pumpFrames(tester);

        expect(t.opener.opened, opens ? [url] : isEmpty);
        expect(t.tabs, before);
        expect(r.segmentText(0), body);

        // An https link beside it opens (not a double click).
        await tester.pump(const Duration(seconds: 1));
        await tester.macCmdClick(_pointOn(r, 0, 'ok'));
        await pumpFrames(tester);
        expect(t.opener.opened, [if (opens) url, 'https://ok.y']);
        await t.settle();
      }, variant: macOnly);
    }
  });

  // -------------------------------------------------------------------------
  // LinkRegion contracts its doc comments promise (verify mode)
  // -------------------------------------------------------------------------
  group('link region contracts', () {
    testWidgets(
      'with Cmd held the space just past a wikilink shows no hover and a Cmd+click there opens nothing',
      (tester) async {
        final t = await _launch(tester, 'Read [[Zeta Game]] today\n');
        final r = t.r;
        final (_, shownEnd) = _find(r, 0, 'Zeta Game');
        final (todayStart, _) = _find(r, 0, 'today');
        final a = r.segment(0).rectForOffset(shownEnd);
        final b = r.segment(0).rectForOffset(todayStart);
        expect(b.left, greaterThan(a.left), reason: 'a visible space between');
        final gap = Offset((a.left + b.left) / 2, a.center.dy);
        final before = List.of(t.tabs);

        await _cmdDown(tester);
        final mouse = await _mouseAt(tester, gap);
        try {
          expect(_cursor(), SystemMouseCursors.text);
          expect(_controllerOf(tester, 0).cmdHover, isNull);
        } finally {
          await _removeMouse(tester, mouse);
          await _cmdUp(tester);
        }

        await tester.macCmdClick(gap);
        await pumpFrames(tester);
        r.expectActiveNote(fixtureTopicId);
        expect(t.tabs, before);

        // The wikilink itself does open (not a double click).
        await tester.pump(const Duration(seconds: 1));
        await tester.macCmdClick(_pointOn(r, 0, 'Zeta Game'));
        await pumpFrames(tester);
        r.expectActiveNote(fixtureZetaId);
        await t.settle();
      },
      variant: macOnly,
    );

    testWidgets(
      'with Cmd held hovering emphasised text inside link text shows the link and a Cmd+click opens its URL',
      (tester) async {
        final t = await _launch(
          tester,
          'Go [see *it* here](https://x.y) end\n',
        );
        final r = t.r;
        final (start, end) = _find(r, 0, '[see *it* here](https://x.y)');

        await _cmdDown(tester);
        final mouse = await _mouseAt(tester, _pointOn(r, 0, 'it'));
        try {
          expect(_cursor(), SystemMouseCursors.click);
          expect(
            _controllerOf(tester, 0).cmdHover,
            TextRange(start: start, end: end),
          );
        } finally {
          await _removeMouse(tester, mouse);
          await _cmdUp(tester);
        }

        await tester.macCmdClick(_pointOn(r, 0, 'it'));
        await pumpFrames(tester);
        expect(t.opener.opened, ['https://x.y']);
        r.expectActiveNote(fixtureTopicId);
        await t.settle();
      },
      variant: macOnly,
    );

    testWidgets(
      'a wikilink inside fenced code is no link for Cmd hover or Cmd+click',
      (tester) async {
        final t = await _launch(
          tester,
          'Intro [[Known]]\n```\n[[Zeta Game]] and [a](https://x.y)\n```\nOutro\n',
        );
        final r = t.r;
        final before = List.of(t.tabs);

        await _cmdDown(tester);
        final mouse = await _mouseAt(tester, _pointOn(r, 0, 'Zeta Game'));
        try {
          expect(_cursor(), SystemMouseCursors.text);
          final (zeta, _) = _find(r, 0, 'Zeta Game');
          final code = _controllerOf(tester, 0, offset: zeta);
          expect(code.text, contains('[[Zeta Game]]'), reason: 'the code row');
          expect(code.cmdHover, isNull);
        } finally {
          await _removeMouse(tester, mouse);
          await _cmdUp(tester);
        }

        await tester.macCmdClick(_pointOn(r, 0, 'Zeta Game'));
        await pumpFrames(tester);
        await tester.pump(const Duration(seconds: 1));
        await tester.macCmdClick(_pointOn(r, 0, 'https'));
        await pumpFrames(tester);
        r.expectActiveNote(fixtureTopicId);
        expect(t.tabs, before);
        expect(t.opener.opened, isEmpty);

        // The wikilink outside the fence does open.
        await tester.pump(const Duration(seconds: 1));
        await tester.macCmdClick(_pointOn(r, 0, 'Known'));
        await pumpFrames(tester);
        r.expectActiveNote(_knownId);
        await t.settle();
      },
      variant: macOnly,
    );

    testWidgets(
      'an edit under a resting Cmd hover moves the hover with the wikilink and clears it once the wikilink moves away',
      (tester) async {
        final t = await _launch(tester, 'Read [[Zeta Game]] today\n');
        final r = t.r;
        final (start, end) = _find(r, 0, '[[Zeta Game]]');
        await r.focusSegment(0);

        await _cmdDown(tester);
        final mouse = await _mouseAt(tester, _pointOn(r, 0, 'Zeta Game'));
        try {
          expect(
            _controllerOf(tester, 0).cmdHover,
            TextRange(start: start, end: end),
          );

          // One character before it: the token shifts under the pointer.
          await r.typeInSegment(0, 'Reads [[Zeta Game]] today\n');
          await pumpFrames(tester);
          expect(
            _controllerOf(tester, 0).cmdHover,
            TextRange(start: start + 1, end: end + 1),
          );
          expect(_cursor(), SystemMouseCursors.click);

          // A long prefix pushes it out from under the pointer.
          await r.typeInSegment(
            0,
            'A much longer opening that pushes it: [[Zeta Game]] today\n',
          );
          await pumpFrames(tester);
          expect(_controllerOf(tester, 0).cmdHover, isNull);
          expect(_cursor(), SystemMouseCursors.text);
        } finally {
          await _removeMouse(tester, mouse);
          await _cmdUp(tester);
        }
        await t.settle();
      },
      variant: macOnly,
    );

    testWidgets(
      'with Cmd held moving the mouse out of the field clears the hover',
      (tester) async {
        final t = await _launch(tester, 'Read [[Zeta Game]] today\n');
        final r = t.r;

        await _cmdDown(tester);
        final mouse = await _mouseAt(tester, _pointOn(r, 0, 'Zeta Game'));
        try {
          expect(_controllerOf(tester, 0).cmdHover, isNotNull);
          final field = tester.getRect(r.textSegment(0));
          await mouse.moveTo(Offset(field.center.dx, field.bottom + 40));
          await tester.pump();
          expect(_controllerOf(tester, 0).cmdHover, isNull);
          expect(_isUnderlined(_styleOf(tester, r, 0, 'Zeta Game')), isFalse);
        } finally {
          await _removeMouse(tester, mouse);
          await _cmdUp(tester);
        }
        await t.settle();
      },
      variant: macOnly,
    );

    testWidgets(
      'Cmd+click on an upper case HTTPS link calls the UrlOpener with its URL as written',
      (tester) async {
        final t = await _launch(tester, 'Go [a](HTTPS://X.y/Path) now\n');
        final r = t.r;

        await tester.macCmdClick(_pointOn(r, 0, 'a'));
        await pumpFrames(tester);

        expect(t.opener.opened, ['HTTPS://X.y/Path']);
        await t.settle();
      },
      variant: macOnly,
    );

    testWidgets('a Cmd secondary click on a resolved wikilink opens nothing', (
      tester,
    ) async {
      final t = await _launch(tester, 'See [[Known]] now\n');
      final r = t.r;
      final before = List.of(t.tabs);
      final at = _pointOn(r, 0, 'Known');

      await tester.macHolding(
        [LogicalKeyboardKey.metaLeft],
        () => tester.tapAt(
          at,
          kind: PointerDeviceKind.mouse,
          buttons: kSecondaryButton,
        ),
      );
      await pumpFrames(tester);

      r.expectActiveNote(fixtureTopicId);
      expect(t.tabs, before);

      // A primary Cmd+click on it does open.
      await tester.pump(const Duration(seconds: 1));
      await tester.macCmdClick(at);
      await pumpFrames(tester);
      r.expectActiveNote(_knownId);
      await t.settle();
    }, variant: macOnly);

    testWidgets(
      'a Cmd press on one wikilink released on another opens nothing',
      (tester) async {
        final t = await _launch(
          tester,
          'See [[Known]] and [[Zeta Game]] now\n',
        );
        final r = t.r;
        final before = List.of(t.tabs);
        final from = _pointOn(r, 0, 'Known');
        final to = _pointOn(r, 0, 'Zeta Game');

        await tester.macHolding([LogicalKeyboardKey.metaLeft], () async {
          final g = await tester.startGesture(
            from,
            kind: PointerDeviceKind.mouse,
          );
          await tester.pump();
          await g.moveTo(to);
          await tester.pump();
          // Selecting reveals markers and moves the text: aim again.
          await g.moveTo(_pointOn(r, 0, 'Zeta Game'));
          await tester.pump();
          await g.up();
          await tester.pump();
        });
        await pumpFrames(tester);

        r.expectActiveNote(fixtureTopicId);
        expect(t.tabs, before);

        // Pressed and released on the same wikilink, it opens.
        await tester.pump(const Duration(seconds: 1));
        await _dropClickMouse(tester);
        // The drag selected across both, revealing markers: measure again.
        await tester.macCmdClick(_pointOn(r, 0, 'Zeta Game'));
        await pumpFrames(tester);
        r.expectActiveNote(fixtureZetaId);
        await t.settle();
      },
      variant: macOnly,
    );

    testWidgets(
      'when two notes share a title Cmd+click opens the first one listed',
      (tester) async {
        final t = await _launch(
          tester,
          'See [[Known]] now\n',
          overrides: [
            _titles(
              () async => [
                NoteTitle(id: _knownId, title: 'Known', updatedAt: 9),
                NoteTitle(id: 'topic-other', title: 'Known', updatedAt: 8),
                NoteTitle(
                  id: fixtureTopicId,
                  title: 'Player Loop',
                  updatedAt: 7,
                ),
              ],
            ),
          ],
        );
        final r = t.r;

        await tester.macCmdClick(_pointOn(r, 0, 'Known'));
        await pumpFrames(tester);

        r.expectActiveNote(_knownId);
        expect(t.tabs, isNot(contains(const NoteTab('topic-other'))));
        await t.settle();
      },
      variant: macOnly,
    );

    testWidgets(
      'typing a character and Cmd+clicking a transclusion token before the debounce saves the edited body before the tab switch',
      (tester) async {
        const edited = 'See ![[2026-09-05#^b7k2m9]] now!\n';
        final t = await _launch(tester, 'See ![[2026-09-05#^b7k2m9]] now\n');
        final r = t.r;
        final h = t.h;

        List<String?>? sentAtSwitch;
        final sub = h.container.listen<TabsState>(tabsProvider, (_, next) {
          if (next.activeTab == const NoteTab(fixtureDailyId)) {
            sentAtSwitch ??= [
              for (final c in h.cli.callsFor('update')) c.stdinBody,
            ];
          }
        });
        addTearDown(sub.close);

        await r.focusSegment(0);
        await r.typeInSegment(0, edited);
        expect(h.cli.callsFor('update'), isEmpty, reason: 'debounce pending');

        await tester.macCmdClick(_pointOn(r, 0, '2026-09-05'));
        await pumpFrames(tester);

        r.expectActiveNote(fixtureDailyId);
        expect(sentAtSwitch, [edited]);
        expect(h.db.getNote(fixtureTopicId)!.contentMd, edited);
        await r.waitForSave();
        expect(h.cli.callsFor('update'), hasLength(1));
        await t.settle();
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // LinkRegion._apply: the isResolved setter notifies the field controller,
  // and the wikilink popover re-opens on any notification while the caret is
  // in an unclosed [[, so title loads and reloads notify only when a shown
  // target resolves differently (fix round, create_topic_partial_failure).
  // -------------------------------------------------------------------------
  group('resolution notifications', () {
    testWidgets(
      'a titles reload that changes no shown link resolution sends the field controller no notification',
      (tester) async {
        var current = _manyTitles(3);
        final t = await _launch(
          tester,
          'See [[Missing]], [[Known]], ![[2026-09-07#^ab12]] and [a](https://x.y)\n',
          overrides: [_titles(() async => current)],
        );
        final r = t.r;
        final controller = _controllerOf(tester, 0);
        var notified = 0;
        void count() => notified++;
        controller.addListener(count);
        addTearDown(() => controller.removeListener(count));

        // A new list with one more title no link in the text names.
        current = [
          ..._manyTitles(3),
          NoteTitle(id: 'topic-other', title: 'Other', updatedAt: 5),
        ];
        t.h.container.invalidate(noteTitlesAsyncProvider);
        await pumpFrames(tester);
        expect(notified, 0, reason: 'unrelated title added');

        // A fresh list with the same titles.
        current = _manyTitles(3);
        t.h.container.invalidate(noteTitlesAsyncProvider);
        await pumpFrames(tester);
        expect(notified, 0, reason: 'same titles reloaded');

        // A title equal to the URL changes nothing either: links are no
        // note targets.
        current = [
          ..._manyTitles(3),
          NoteTitle(id: 'topic-url', title: 'https://x.y', updatedAt: 5),
        ];
        t.h.container.invalidate(noteTitlesAsyncProvider);
        await pumpFrames(tester);
        expect(notified, 0, reason: 'a title equal to a URL');

        expect(_isGhost(_styleOf(tester, r, 0, 'Missing')), isTrue);
        expect(_isResolvedLink(_styleOf(tester, r, 0, 'Known')), isTrue);
        expect(_isGhost(_styleOf(tester, r, 0, '2026-09-07')), isTrue);
        await t.settle();
      },
      variant: macOnly,
    );

    testWidgets(
      'a titles reload that flips a shown wikilink notifies the field controller once and re-renders it',
      (tester) async {
        var current = _manyTitles(3);
        final t = await _launch(
          tester,
          'See [[Missing]] and [[Known]] now\n',
          overrides: [_titles(() async => current)],
        );
        final r = t.r;
        final controller = _controllerOf(tester, 0);
        var notified = 0;
        void count() => notified++;
        controller.addListener(count);
        addTearDown(() => controller.removeListener(count));
        expect(_isGhost(_styleOf(tester, r, 0, 'Missing')), isTrue);

        current = [
          ..._manyTitles(3),
          NoteTitle(id: 'topic-missing', title: 'Missing', updatedAt: 5),
        ];
        t.h.container.invalidate(noteTitlesAsyncProvider);
        await pumpFrames(tester);
        expect(notified, 1, reason: 'Missing now resolves');
        expect(_isResolvedLink(_styleOf(tester, r, 0, 'Missing')), isTrue);

        // Known goes away: a ghost again, one more notification.
        current = [
          for (final n in _manyTitles(3, withKnown: false)) n,
          NoteTitle(id: 'topic-missing', title: 'Missing', updatedAt: 5),
        ];
        t.h.container.invalidate(noteTitlesAsyncProvider);
        await pumpFrames(tester);
        expect(notified, 2, reason: 'Known no longer resolves');
        expect(_isGhost(_styleOf(tester, r, 0, 'Known')), isTrue);
        expect(_isResolvedLink(_styleOf(tester, r, 0, 'Missing')), isTrue);
        await t.settle();
      },
      variant: macOnly,
    );

    testWidgets(
      'a titles reload that flips a shown transclusion token notifies the field controller once and re-renders it',
      (tester) async {
        var current = _manyTitles(3);
        final t = await _launch(
          tester,
          'A ![[2026-09-07#^ab12]] end\n',
          overrides: [_titles(() async => current)],
        );
        final r = t.r;
        final controller = _controllerOf(tester, 0);
        var notified = 0;
        void count() => notified++;
        controller.addListener(count);
        addTearDown(() => controller.removeListener(count));
        expect(_isGhost(_styleOf(tester, r, 0, '2026-09-07')), isTrue);

        current = [
          ..._manyTitles(3),
          NoteTitle(id: 'daily-07', title: '2026-09-07', updatedAt: 5),
        ];
        t.h.container.invalidate(noteTitlesAsyncProvider);
        await pumpFrames(tester);
        expect(notified, 1);
        expect(_isResolvedLink(_styleOf(tester, r, 0, '2026-09-07')), isTrue);
        await t.settle();
      },
      variant: macOnly,
    );

    testWidgets(
      'a titles reload across the 1000 cap with every shown link resolving sends the field controller no notification',
      (tester) async {
        var current = _manyTitles(1000);
        final t = await _launch(
          tester,
          'See [[Known]] and [a](https://x.y) now\n',
          overrides: [_titles(() async => current)],
        );
        final r = t.r;
        final controller = _controllerOf(tester, 0);
        var notified = 0;
        void count() => notified++;
        controller.addListener(count);
        addTearDown(() => controller.removeListener(count));

        // Capped (everything resolves) to complete: Known still resolves.
        current = _manyTitles(999);
        t.h.container.invalidate(noteTitlesAsyncProvider);
        await pumpFrames(tester);
        expect(notified, 0, reason: '1000 to 999 titles');

        // And back to the cap.
        current = _manyTitles(1000);
        t.h.container.invalidate(noteTitlesAsyncProvider);
        await pumpFrames(tester);
        expect(notified, 0, reason: '999 to 1000 titles');
        expect(_isResolvedLink(_styleOf(tester, r, 0, 'Known')), isTrue);
        await t.settle();
      },
      variant: macOnly,
    );

    testWidgets(
      'titles that load with a shown ghost notify the field controller once',
      (tester) async {
        final load = Completer<List<NoteTitle>>();
        final t = await _launch(
          tester,
          'See [[Missing]], [[Known]] and [[Gone]] now\n',
          overrides: [_titles(() => load.future)],
        );
        final r = t.r;
        final controller = _controllerOf(tester, 0);
        var notified = 0;
        void count() => notified++;
        controller.addListener(count);
        addTearDown(() => controller.removeListener(count));

        load.complete(_manyTitles(3));
        await pumpFrames(tester);
        expect(notified, 1, reason: 'two ghosts, one notification');
        expect(_isGhost(_styleOf(tester, r, 0, 'Missing')), isTrue);
        expect(_isGhost(_styleOf(tester, r, 0, 'Gone')), isTrue);
        await t.settle();
      },
      variant: macOnly,
    );

    testWidgets(
      'an edit under a resting Cmd hover sends no extra resolution notification',
      (tester) async {
        final t = await _launch(tester, 'Read [[Zeta Game]] today\n');
        final r = t.r;
        final controller = _controllerOf(tester, 0);
        final resolvedBefore = controller.isResolved;
        expect(resolvedBefore, isNotNull);

        await r.focusSegment(0);
        await _cmdDown(tester);
        final mouse = await _mouseAt(tester, _pointOn(r, 0, 'Zeta Game'));
        try {
          expect(controller.cmdHover, isNotNull);
          final events = <String>[];
          void record() => events.add(controller.text);
          controller.addListener(record);
          addTearDown(() => controller.removeListener(record));

          // An edit (as a paste would make) that keeps the token in place.
          controller.value = TextEditingValue(
            text: '${controller.text}x',
            selection: TextSelection.collapsed(
              offset: controller.text.length + 1,
            ),
          );
          await pumpFrames(tester);
          expect(
            events.where((t) => t == controller.text),
            hasLength(1),
            reason: 'only the edit itself notified',
          );
          expect(controller.isResolved == resolvedBefore, isTrue);
        } finally {
          await _removeMouse(tester, mouse);
          await _cmdUp(tester);
        }
        await t.settle();
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // LinkRegion contracts pinned in fix round 2 (merge gate MUTATION on
  // link_region.dart): line kinds, the shown-text end boundary, transclusion
  // tokens before the titles load, unconsumed key events and one hit-test
  // per frame however many updates it coalesces.
  // -------------------------------------------------------------------------
  group('link region round 2 contracts', () {
    testWidgets(
      'a wikilink in a heading line shows the Cmd hover and a Cmd+click opens its note',
      (tester) async {
        final t = await _launch(tester, '# Plan [[Known]] here\n\nAfter\n');
        final r = t.r;
        final (start, end) = _find(r, 0, '[[Known]]');
        final at = _pointOn(r, 0, 'Known');

        await _cmdDown(tester);
        final mouse = await _mouseAt(tester, at);
        try {
          expect(_cursor(), SystemMouseCursors.click);
          expect(
            _controllerOf(tester, 0, offset: start).cmdHover,
            TextRange(start: start, end: end),
          );
        } finally {
          await _removeMouse(tester, mouse);
          await _cmdUp(tester);
        }

        await tester.macCmdClick(at);
        await pumpFrames(tester);
        r.expectActiveNote(_knownId);
        await t.settle();
      },
      variant: macOnly,
    );

    for (final (name, line) in [
      (
        'a field holding a whole heading line hit-tests its links like prose',
        '## Head [[Known]] and [docs](https://x.y)',
      ),
      (
        'a field holding a whole bullet line hit-tests its links like prose',
        '- Item [[Known]] and [docs](https://x.y)',
      ),
      (
        'a field holding a whole numbered line hit-tests its links like prose',
        '1. Item [[Known]] and [docs](https://x.y)',
      ),
      (
        'a field holding a whole task line hit-tests its links like prose',
        '- [ ] Item [[Known]] and [docs](https://x.y)',
      ),
      (
        'a field holding a whole quote line hit-tests its links like prose',
        '> Item [[Known]] and [docs](https://x.y)',
      ),
      (
        'a field holding a prose line hit-tests its links',
        'Item [[Known]] and [docs](https://x.y)',
      ),
    ]) {
      testWidgets(name, (tester) async {
        final f = await _wi166PumpLinkField(tester, line);
        final link = line.indexOf('[[Known]]');

        await _cmdDown(tester);
        final mouse = await _mouseAt(tester, f.pointOn('Known'));
        try {
          expect(_cursor(), SystemMouseCursors.click);
          expect(
            f.controller.cmdHover,
            TextRange(start: link, end: link + '[[Known]]'.length),
          );
        } finally {
          await _removeMouse(tester, mouse);
          await _cmdUp(tester);
        }

        await tester.macCmdClick(f.pointOn('docs'));
        await tester.pump();
        expect(f.opener.opened, ['https://x.y']);
      }, variant: macOnly);
    }

    testWidgets(
      'with Cmd held a point on the last shown character at the link end offset shows the hover and a Cmd+click there opens it',
      (tester) async {
        const text = 'Go [[Known]] or [docs](https://x.y) now';
        final f = await _wi166PumpLinkField(tester, text);
        final wiki = text.indexOf('[[Known]]');
        final shownEnd = text.indexOf(']]');
        final docsEnd = text.indexOf('](');

        // The right part of the last shown glyph: offsetAt gives the shown
        // text end itself, the boundary the hit-test keeps.
        final onEnd = f.pointNearEnd(shownEnd);
        expect(f.boxes.offsetAt(f.boxes.box.globalToLocal(onEnd)), shownEnd);
        final onDocsEnd = f.pointNearEnd(docsEnd);
        expect(f.boxes.offsetAt(f.boxes.box.globalToLocal(onDocsEnd)), docsEnd);

        await _cmdDown(tester);
        final mouse = await _mouseAt(tester, onEnd);
        try {
          expect(_cursor(), SystemMouseCursors.click);
          expect(
            f.controller.cmdHover,
            TextRange(start: wiki, end: wiki + '[[Known]]'.length),
          );

          // One past it, in the space after the link: no hover.
          final past = f.boxes.box.localToGlobal(
            f.boxes.caretRect(shownEnd + 3).center,
          );
          await mouse.moveTo(Offset((onEnd.dx + past.dx) / 2 + 2, onEnd.dy));
          await tester.pump();
          expect(_cursor(), SystemMouseCursors.text);
          expect(f.controller.cmdHover, isNull);
        } finally {
          await _removeMouse(tester, mouse);
          await _cmdUp(tester);
        }

        await tester.macCmdClick(onDocsEnd);
        await tester.pump();
        expect(f.opener.opened, ['https://x.y']);
      },
      variant: macOnly,
    );

    testWidgets(
      'before the titles load a transclusion token shows no Cmd hover and a Cmd+click on it opens nothing',
      (tester) async {
        final load = Completer<List<NoteTitle>>();
        final t = await _launch(
          tester,
          'See ![[2026-09-05#^b7k2m9]] now\n',
          overrides: [_titles(() => load.future)],
        );
        final r = t.r;
        final before = List.of(t.tabs);
        final at = _pointOn(r, 0, '2026-09-05');

        await _cmdDown(tester);
        final mouse = await _mouseAt(tester, at);
        try {
          expect(_cursor(), SystemMouseCursors.text);
          expect(_controllerOf(tester, 0).cmdHover, isNull);
        } finally {
          await _removeMouse(tester, mouse);
          await _cmdUp(tester);
        }

        await tester.macCmdClick(at);
        await pumpFrames(tester);
        r.expectActiveNote(fixtureTopicId);
        expect(t.tabs, before);

        // Once a note titled with its date loads, the same token opens.
        load.complete([
          ..._manyTitles(3),
          NoteTitle(id: fixtureDailyId, title: '2026-09-05', updatedAt: 4),
        ]);
        await pumpFrames(tester);
        await tester.pump(const Duration(seconds: 1));
        await tester.macCmdClick(_pointOn(r, 0, '2026-09-05'));
        await pumpFrames(tester);
        r.expectActiveNote(fixtureDailyId);
        await t.settle();
      },
      variant: macOnly,
    );

    testWidgets(
      'key events over a link field are left unhandled for the platform and the focused field',
      (tester) async {
        final f = await _wi166PumpLinkField(tester, 'Go [[Known]] now');
        final mouse = await _mouseAt(tester, f.pointOn('Known'));
        try {
          for (final key in [
            LogicalKeyboardKey.keyA,
            LogicalKeyboardKey.shiftLeft,
            LogicalKeyboardKey.metaLeft,
          ]) {
            expect(
              await tester.sendKeyDownEvent(key, platform: 'macos'),
              isFalse,
              reason: '$key down',
            );
            await tester.pump();
            expect(
              await tester.sendKeyUpEvent(key, platform: 'macos'),
              isFalse,
              reason: '$key up',
            );
            await tester.pump();
          }

          // The region still saw Cmd: pressing it now shows the hover.
          await _cmdDown(tester);
          expect(_cursor(), SystemMouseCursors.click);
          await _cmdUp(tester);
          expect(_cursor(), SystemMouseCursors.text);
        } finally {
          await _removeMouse(tester, mouse);
        }
      },
      variant: macOnly,
    );

    testWidgets(
      'several edits under a resting Cmd hover in one frame hit-test the pointer once and keep the last edit',
      (tester) async {
        const text = 'A [[Known]] b';
        final f = await _wi166PumpLinkField(tester, text);
        final link = text.indexOf('[[Known]]');
        const width = '[[Known]]'.length;

        await _cmdDown(tester);
        final mouse = await _mouseAt(tester, f.pointOn('Known'));
        try {
          expect(
            f.controller.cmdHover,
            TextRange(start: link, end: link + width),
          );
          await tester.pump();
          f.lookups = 0;

          // Three edits before the next frame, each one character longer
          // than the text the region last tokenized.
          f.controller.text = 'AB [[Known]] b';
          f.controller.text = 'BA [[Known]] b';
          f.controller.text = 'CA [[Known]] b';
          await tester.pump();
          await tester.pump();

          expect(f.lookups, 1, reason: 'one apply for the frame');
          expect(
            f.controller.cmdHover,
            TextRange(start: link + 1, end: link + 1 + width),
          );
          expect(_cursor(), SystemMouseCursors.click);
        } finally {
          await _removeMouse(tester, mouse);
          await _cmdUp(tester);
        }
      },
      variant: macOnly,
    );
  });

  // -------------------------------------------------------------------------
  // AC12: EditorController.flushPendingSave()
  // -------------------------------------------------------------------------
  group('flushPendingSave', () {
    test(
      'flushPendingSave with a pending debounce saves once immediately and cancels the timer',
      () async {
        final e = await _flushEditor();
        e.ctrl.loadNote(e.db.getNote(_flushId));
        final idle = e.clock.pendingTimers;
        e.ctrl.onContentChanged('edited ${e.clock.now().year}\n');
        expect(e.clock.pendingTimers, idle + 1, reason: 'debounce armed');

        e.ctrl.flushPendingSave();
        expect(e.clock.pendingTimers, idle, reason: 'debounce cancelled');
        await pumpEventQueue();

        expect(e.updates, hasLength(1));
        expect(e.updates.single.stdinBody, 'edited 2026\n');
        expect(e.updates.single.flag('note-id'), _flushId);

        e.clock.advance(saveDebounce * 3);
        await pumpEventQueue();
        expect(e.updates, hasLength(1), reason: 'no second save');
      },
    );

    test(
      'flushPendingSave then loading another note still saves the first note edited text',
      () async {
        final e = await _flushEditor();
        e.ctrl.loadNote(e.db.getNote(_flushId));
        e.ctrl.onContentChanged('typed before switching\n');

        e.ctrl.flushPendingSave();
        e.ctrl.loadNote(e.db.getNote(_otherFlushId));
        await pumpEventQueue();

        expect(e.updates, hasLength(1));
        expect(e.updates.single.flag('note-id'), _flushId);
        expect(e.updates.single.stdinBody, 'typed before switching\n');
        expect(e.db.getNote(_flushId)!.contentMd, 'typed before switching\n');
      },
    );

    test('flushPendingSave with no pending debounce saves nothing', () async {
      final e = await _flushEditor();
      e.ctrl.loadNote(e.db.getNote(_flushId));
      final idle = e.clock.pendingTimers;

      e.ctrl.flushPendingSave();
      await pumpEventQueue();
      e.clock.advance(saveDebounce * 3);
      await pumpEventQueue();

      expect(e.updates, isEmpty);
      expect(e.clock.pendingTimers, idle);
    });

    test(
      'flushPendingSave after the debounce already fired saves nothing more',
      () async {
        final e = await _flushEditor();
        e.ctrl.loadNote(e.db.getNote(_flushId));
        e.ctrl.onContentChanged('saved by the debounce\n');
        e.clock.advance(saveDebounce);
        await pumpEventQueue();
        expect(e.updates, hasLength(1));

        e.ctrl.flushPendingSave();
        await pumpEventQueue();
        e.clock.advance(saveDebounce * 3);
        await pumpEventQueue();

        expect(e.updates, hasLength(1));
      },
    );
  });
}

const _flushId = '01J9FLUSH000000000000000166';
const _otherFlushId = '01J9FLUSH000000000000001166';

class _FlushEditor {
  _FlushEditor(this.c, this.db, this.cli, this.clock);

  final ProviderContainer c;
  final FakeVaultDb db;
  final FakeMemexCli cli;
  final FakeClock clock;

  EditorController get ctrl => c.read(editorControllerProvider.notifier);
  List<FakeCliCall> get updates => cli.callsFor('update');
}

/// An EditorController over a local vault double (as
/// editor_controller_async_test.dart): notes [_flushId] (version 3) and
/// [_otherFlushId], `update` writes like `memex update`, time on a
/// [FakeClock].
Future<_FlushEditor> _flushEditor() async {
  final dir = await Directory.systemTemp.createTemp('om166_flush');
  final db = FakeVaultDb.v5()
    ..seedNote(id: _flushId, title: 'Flush', content: 'start\n', version: 3)
    ..seedNote(id: _otherFlushId, title: 'Other', content: 'other\n');
  final cli = FakeMemexCli()..onUpdateWrites(db);
  final clock = FakeClock(DateTime(2026, 10, 3, 9));
  final doubles = EditorVaultDoubles(notesDb: db, dailyDb: db, cli: cli);
  final c = ProviderContainer(
    overrides: [
      currentVaultProvider.overrideWith((_) => LocalVaultRef(dir.path)),
      vaultDbProvider.overrideWithValue(null),
      memexCliProvider.overrideWithValue(cli),
      clockProvider.overrideWithValue(clock),
      editorSingleVaultOverride(doubles),
    ],
  );
  addTearDown(() async {
    final store = c.read(tabsProvider.notifier).store;
    c.dispose();
    await store.flush();
    db.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  c.read(vaultAccessProvider);
  c.listen(tabsProvider, (_, _) {});
  await pumpEventQueue();
  return _FlushEditor(c, db, cli, clock);
}

/// A bare link field (see [_wi166PumpLinkField]): its controller, opener and
/// the line boxes its LinkRegion looks up, counted in [lookups].
class _Wi166LinkField {
  _Wi166LinkField(this.controller, this.opener, this.fieldKey);

  final LivePreviewController controller;
  final RecordingUrlOpener opener;
  final GlobalKey fieldKey;

  /// How many times the LinkRegion asked for the field's line boxes.
  int lookups = 0;

  /// The field's line boxes (laid out).
  LineBoxSource get boxes {
    final editable = findRenderEditable(
      fieldKey.currentContext!.findRenderObject(),
    );
    return RenderEditableLineBoxes(editable!);
  }

  LineBoxSource? lookup() {
    lookups++;
    final editable = findRenderEditable(
      fieldKey.currentContext?.findRenderObject(),
    );
    return editable == null ? null : RenderEditableLineBoxes(editable);
  }

  /// A global point in the middle of the first [needle] in the field.
  Offset pointOn(String needle) {
    final start = controller.text.indexOf(needle);
    expect(start, isNonNegative, reason: 'field holds "$needle"');
    final b = boxes;
    final a = b.caretRect(start);
    final z = b.caretRect(start + needle.length);
    expect(z.left, greaterThan(a.left), reason: '"$needle" has a width');
    return b.box.localToGlobal(Offset((a.left + z.left) / 2, a.center.dy));
  }

  /// A global point three quarters across the shown character just before
  /// [end].
  Offset pointNearEnd(int end) {
    final b = boxes;
    final a = b.caretRect(end - 1);
    final z = b.caretRect(end);
    expect(z.left, greaterThan(a.left), reason: 'a visible last character');
    return b.box.localToGlobal(
      Offset(a.left + (z.left - a.left) * 0.75, a.center.dy),
    );
  }
}

/// Pumps one unfocused [TextField] holding [text] (whole lines: not an item
/// row's text) under a [LinkRegion] whose line boxes come from the field,
/// with the titles `Known` (id [_knownId]) loaded and a recording opener.
Future<_Wi166LinkField> _wi166PumpLinkField(
  WidgetTester tester,
  String text,
) async {
  final controller = LivePreviewController(text: text);
  addTearDown(controller.dispose);
  final opener = RecordingUrlOpener();
  final field = _Wi166LinkField(controller, opener, GlobalKey());
  await pumpEditorScoped(
    tester,
    MaterialApp(
      home: Material(
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 700,
            child: LinkRegion(
              controller: controller,
              boxes: field.lookup,
              child: TextField(
                key: field.fieldKey,
                controller: controller,
                maxLines: null,
              ),
            ),
          ),
        ),
      ),
    ),
    opener: opener,
    titles: [NoteTitle(id: _knownId, title: 'Known', updatedAt: 1)],
  );
  await tester.pump();
  await tester.pump();
  return field;
}
