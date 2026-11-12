// WI #429 (391-A4), Spec #391 Testing Strategy journey: the whole app over
// `pumpWorkspace`, with FakeMemexCli answering `memex echoes` with fixed rows,
// so each step runs through A1's LocalEchoesAccess, A2's echoesAsyncProvider,
// A3's echoes tab, A5's scroll target and A4's link actions:
// 1. open a topic note and the echoes tab, click an echo: the echoed note
//    opens scrolled to the passage, with the passage row highlighted;
// 2. Back, type, `link`: the edit is flushed first, `add-link` runs once,
//    the echo row is gone, and the typed text and the link both survive;
// 3. on a daily note with a topic echo, `link` calls `memex footer add`.
// The guard ACs (architect): one link gives exactly one immediate echoes
// re-run and one vault revision bump, both inside and past the 10 s spacing
// since the last run. Ruling D54a: the poller's later confirmation bump of
// the link's own write, and its spaced re-run 10 s or more after the link's
// run, are allowed.
//
// Time moves only through pump durations and the harness FakeClock. Never
// pumpAndSettle the workspace (OmDot pulses forever).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/editor_controller.dart';
import 'package:open_memex_app/src/state/right_panel_tab.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/widgets/editor/echo_arrival_highlight.dart';
import 'package:open_memex_app/src/widgets/editor/text_segment.dart';

import '../support/app_harness.dart';
import '../support/daily_seed.dart';
import '../support/echo_link_cli_fakes.dart';
import '../support/fake_clock.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/font_fetch_hold.dart';
import '../support/footer_cli_fakes.dart';
import '../support/segment_editing_finder.dart';
import '../support/today_cli_fakes.dart';

const _wi429Topic = '01JECHOJRNTOPIC00000000429';
const _wi429Loot = '01JECHOJRNLOOT000000000429';
const _wi429Daily = 'daily-2026-10-03';
const _wi429Combat = '01JECHOJRNCOMBAT0000000429';

const _wi429TopicBody = 'Level design notes.';
const _wi429Typed = 'Level design notes. More about pacing.';
const _wi429DailyBody = 'Slept well.';
const _wi429DailyTyped = 'Slept well. Sketched the combat loop.';

/// How many `- item i` / `  passage i` line pairs the echoed note holds.
const _wi429Pairs = 300;

/// The passage the echo points at: `  passage <k>`, row `2k + 1` of the
/// echoed note's first text segment.
const _wi429PassageK = 200;

List<String> _wi429LootLines() => [
  for (var i = 0; i < _wi429Pairs; i++) ...['- item $i\n', '  passage $i\n'],
];

/// The UTF-8 offset of the passage line in the echoed note's body.
int _wi429PassageByte() =>
    utf8.encode(_wi429LootLines().take(2 * _wi429PassageK + 1).join()).length;

Finder _wi429Key(String key) => find.byKey(Key(key));

Finder get _wi429PassageRow =>
    find.byKey(ValueKey('editor-row-0-${2 * _wi429PassageK + 1}'));

Finder get _wi429Highlight => find.byType(EchoArrivalHighlight);

class _Wi429Journey {
  _Wi429Journey(this.h, this.db, this.cli, this.echoesAt);

  final WorkspaceHarness h;
  final FakeVaultDb db;
  final FakeMemexCli cli;

  /// The harness clock's time at each `memex echoes` call, in order.
  final List<DateTime> echoesAt;

  /// How many times `vaultRevisionProvider` changed since [countBumps].
  int bumps = 0;

  void countBumps() =>
      h.container.listen<int>(vaultRevisionProvider, (_, _) => bumps++);

  int get echoesRuns => cli.callsFor('echoes').length;
  List<String> get subcommands => [for (final c in cli.calls) c.subcommand];
  String? get selected => h.read(selectedNoteIdProvider);
  EditorStateValue get editor => h.read(editorControllerProvider);
  String stored(String id) => db.getNote(id)!.contentMd;
}

Future<_Wi429Journey> _wi429Launch(WidgetTester tester) async {
  final db = FakeVaultDb.v5()
    ..seedNote(
      id: _wi429Topic,
      title: 'Level design',
      content: _wi429TopicBody,
      role: 'topic',
      version: 2,
    )
    ..seedNote(
      id: _wi429Loot,
      title: 'Loot tables',
      content: _wi429LootLines().join(),
    )
    ..seedDailyNote('2026-10-03', id: _wi429Daily, version: 4)
    ..seedTopicNote(_wi429Combat, 'Combat');
  db.db.execute('UPDATE notes SET content_md = ? WHERE id = ?', [
    _wi429DailyBody,
    _wi429Daily,
  ]);
  final clock = FakeClock();
  final echoesAt = <DateTime>[];
  final echoes = FakeMemexCli()
    ..onEchoesExcludingLinked(db, {
      _wi429Topic: [
        wi429EchoRow(
          noteId: _wi429Loot,
          title: 'Loot tables',
          passage: 'passage $_wi429PassageK',
          startByte: _wi429PassageByte(),
        ),
      ],
      _wi429Daily: [
        wi429EchoRow(
          noteId: _wi429Combat,
          title: 'Combat',
          role: 'topic',
          passage: 'Combat should read at a glance.',
        ),
      ],
    });
  final cli = FakeMemexCli()
    ..on('settings get', (_) => FakeMemexCli.ok(settingsGetMaxDepthStdout))
    ..onUpdateWrites(db)
    ..onFooterAdd(db)
    ..onAddLinkWrites(db)
    ..on('echoes', (call) {
      echoesAt.add(clock.now());
      return echoes.run(call.args, timeout: call.timeout);
    });
  final h = await pumpWorkspace(tester, db: db, cli: cli, clock: clock);
  h.container.read(rightPanelOpenProvider.notifier).state = true;
  h.container.read(rightPanelTabProvider.notifier).state = RightPanelTab.echoes;
  await pumpFrames(tester);
  return _Wi429Journey(h, db, cli, echoesAt);
}

/// The guard after a link whose immediate echoes run was call [runsBefore]
/// (ruling D54a): no run before the next poller tick but that one. The
/// revision poller then sees the link's own content write and bumps again
/// (D5's write-through confirmation, #419 D4), and its re-run keeps req 23's
/// spacing: at most one more run, no sooner than 10 s after the link's run.
void _wi429ExpectOnlySpacedRerun(_Wi429Journey j, int runsBefore) {
  expect(j.echoesRuns, greaterThan(runsBefore), reason: 'the link ran');
  final later = j.echoesAt.skip(runsBefore + 1).toList();
  expect(
    later,
    hasLength(lessThanOrEqualTo(1)),
    reason: 'at most the poller confirmation run',
  );
  for (final at in later) {
    expect(
      at.difference(j.echoesAt[runsBefore]),
      greaterThanOrEqualTo(const Duration(seconds: 10)),
      reason: 'the confirmation run keeps the 10 s spacing',
    );
  }
}

/// Opens [noteId] in the active tab and lets its echoes run answer.
Future<void> _wi429Open(
  WidgetTester tester,
  _Wi429Journey j,
  String noteId,
) async {
  j.h.read(tabsProvider.notifier).navigate(NoteTab(noteId));
  await pumpFrames(tester, frames: 8);
  expect(j.selected, noteId);
}

Future<void> _wi429Tap(WidgetTester tester, Finder f) async {
  expect(f, findsOneWidget, reason: '$f');
  await tester.tap(f);
  await pumpFrames(tester, frames: 8);
}

/// Pumps zero-length frames until the arrival highlight shows; true when it
/// did within [frames].
Future<bool> _wi429PumpUntilHighlight(
  WidgetTester tester, {
  int frames = 30,
}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump();
    if (_wi429Highlight.evaluate().isNotEmpty) return true;
  }
  return false;
}

/// [target]'s vertical middle sits about a third of the way down the
/// editor's viewport.
void _wi429ExpectAtThird(WidgetTester tester, Finder target) {
  expect(target, findsOneWidget);
  final viewport = tester.getRect(
    find
        .descendant(
          of: find.byType(EditorPage),
          matching: find.byType(Scrollable),
        )
        .first,
  );
  final rect = tester.getRect(target);
  final fraction = (rect.center.dy - viewport.top) / viewport.height;
  expect(
    fraction,
    closeTo(1 / 3, 0.08),
    reason: 'passage row $rect in viewport $viewport',
  );
}

/// Lets the save debounce fire and the CLI answer.
Future<void> _wi429Drain(WidgetTester tester, _Wi429Journey j) async {
  j.h.clock.advance(const Duration(seconds: 2));
  await tester.pump(const Duration(seconds: 2));
  await pumpFrames(tester);
}

/// Moves the harness clock by [by] in one-second steps, pumping as it goes,
/// so spaced echoes timers fire.
Future<void> _wi429Wait(
  WidgetTester tester,
  _Wi429Journey j,
  Duration by,
) async {
  for (var s = 0; s < by.inSeconds; s++) {
    j.h.clock.advance(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
  }
  await pumpFrames(tester);
}

void main() {
  holdFontFetches();

  testWidgets(
    'Journey 1 clicking an echo opens the echoed note scrolled to its passage with the row highlighted',
    (tester) async {
      final j = await _wi429Launch(tester);
      await _wi429Open(tester, j, _wi429Topic);
      expect(_wi429Key('echo-row-$_wi429Loot'), findsOneWidget);

      await tester.tap(_wi429Key('echo-open-$_wi429Loot'));

      expect(
        await _wi429PumpUntilHighlight(tester),
        isTrue,
        reason: 'the arrival shows the highlight',
      );
      expect(j.selected, _wi429Loot, reason: 'the echoed note opened');
      expect((j.h.read(tabsProvider).activeTab as NoteTab?)?.id, _wi429Loot);
      await tester.pump();
      final highlight = tester.widget<EchoArrivalHighlight>(_wi429Highlight);
      expect(
        identical(highlight.target, tester.renderObject(_wi429PassageRow)),
        isTrue,
        reason: 'the passage row is highlighted',
      );
      _wi429ExpectAtThird(tester, _wi429PassageRow);

      await tester.pump(const Duration(milliseconds: 1250));
      await tester.pump();
      expect(_wi429Highlight, findsNothing, reason: 'gone after 1.2 s');
      _wi429ExpectAtThird(tester, _wi429PassageRow);
    },
  );

  testWidgets(
    'Journey 2 Back then type then link flushes first calls addLink once and keeps the typed text and the link',
    (tester) async {
      final j = await _wi429Launch(tester);
      await _wi429Open(tester, j, _wi429Topic);
      await tester.tap(_wi429Key('echo-open-$_wi429Loot'));
      await pumpFrames(tester, frames: 8);
      expect(j.selected, _wi429Loot);

      await _wi429Tap(tester, _wi429Key('nav-back-button'));
      expect(j.selected, _wi429Topic, reason: 'Back returns to the topic');
      expect(_wi429Key('echo-row-$_wi429Loot'), findsOneWidget);

      await tester.enterText(find.byKey(editorBodyKey), _wi429Typed);
      await tester.pump();
      expect(j.cli.callsFor('update'), isEmpty, reason: 'still pending');
      final callsBefore = j.cli.calls.length;
      final runsBefore = j.echoesRuns;

      await _wi429Tap(tester, _wi429Key('echo-link-$_wi429Loot'));

      final after = j.subcommands.skip(callsBefore).toList();
      expect(after.where((s) => s == 'update'), hasLength(1));
      expect(after.where((s) => s == 'add-link'), hasLength(1));
      expect(
        after.indexOf('update'),
        lessThan(after.indexOf('add-link')),
        reason: 'the edit is flushed before the link is written',
      );
      final link = j.cli.callsFor('add-link').single;
      expect(link.flag('from'), _wi429Topic);
      expect(link.flag('to'), _wi429Loot);
      expect(link.flag('kind'), 'references');
      expect(
        _wi429Key('echo-row-$_wi429Loot'),
        findsNothing,
        reason: 'the linked echo is gone',
      );

      final expected = wi429WithAutoAddedLink(_wi429Typed, 'Loot tables');
      expect(j.stored(_wi429Topic), expected);
      expect(j.editor.contentMd, expected);
      expect(editorBodyText(tester), contains(_wi429Typed));
      expect(editorBodyText(tester), contains('[[Loot tables]]'));

      await _wi429Drain(tester, j);
      expect(j.cli.callsFor('update'), hasLength(1), reason: 'no resave');
      expect(j.stored(_wi429Topic), expected, reason: 'both survive');
      expect(j.editor.contentMd, expected);
      expect(j.editor.status, SaveStatus.clean);
      expect(j.echoesRuns, runsBefore + 1, reason: 'one immediate re-run');
      await _wi429Wait(tester, j, const Duration(seconds: 30));
      _wi429ExpectOnlySpacedRerun(j, runsBefore);
      expect(_wi429Key('echo-row-$_wi429Loot'), findsNothing);
      expect(j.stored(_wi429Topic), expected, reason: 'still both');
    },
  );

  testWidgets(
    'Journey 3 on a daily note with a topic echo link calls addFooterChip',
    (tester) async {
      final j = await _wi429Launch(tester);
      await _wi429Open(tester, j, _wi429Daily);
      expect(_wi429Key('echo-row-$_wi429Combat'), findsOneWidget);
      await tester.enterText(find.byKey(editorBodyKey), _wi429DailyTyped);
      await tester.pump();

      final runsBefore = j.echoesRuns;
      j.countBumps();

      await _wi429Tap(tester, _wi429Key('echo-link-$_wi429Combat'));

      expect(j.bumps, 1, reason: 'one vault revision bump');
      expect(j.echoesRuns, runsBefore + 1, reason: 'one immediate re-run');
      expect(j.cli.callsFor('footer add'), hasLength(1));
      final footer = j.cli.callsFor('footer add').single;
      expect(footer.flag('daily-note-id'), _wi429Daily);
      expect(footer.flag('topic-note-id'), _wi429Combat);
      expect(j.cli.callsFor('add-link'), isEmpty);
      expect(_wi429Key('echo-row-$_wi429Combat'), findsNothing);
      expect(j.editor.contentMd, _wi429DailyTyped, reason: 'typed text stays');
      expect(editorBodyText(tester), _wi429DailyTyped);

      await _wi429Drain(tester, j);
      expect(j.stored(_wi429Daily), _wi429DailyTyped);
      expect(j.editor.status, SaveStatus.clean);
    },
  );

  for (final (name, idle, pending) in [
    (
      'one link inside the 10 s spacing gives exactly one immediate echoes re-run and one revision bump',
      const Duration(seconds: 2),
      false,
    ),
    (
      'one link more than 10 s after the last echoes run gives exactly one immediate echoes re-run and one revision bump',
      const Duration(seconds: 11),
      false,
    ),
    (
      'one link with a pending edit more than 10 s after the last echoes run gives exactly one immediate echoes re-run and one revision bump',
      const Duration(seconds: 11),
      true,
    ),
  ]) {
    testWidgets(name, (tester) async {
      final j = await _wi429Launch(tester);
      await _wi429Open(tester, j, _wi429Topic);
      expect(_wi429Key('echo-row-$_wi429Loot'), findsOneWidget);
      await _wi429Wait(tester, j, idle);
      if (pending) {
        await tester.enterText(find.byKey(editorBodyKey), _wi429Typed);
        await tester.pump();
        expect(j.cli.callsFor('update'), isEmpty, reason: 'still pending');
      }
      final runsBefore = j.echoesRuns;
      j.countBumps();

      await _wi429Tap(tester, _wi429Key('echo-link-$_wi429Loot'));

      expect(j.cli.callsFor('add-link'), hasLength(1));
      expect(
        j.cli.callsFor('update'),
        hasLength(pending ? 1 : 0),
        reason: 'the pending edit is flushed first',
      );
      expect(j.bumps, 1, reason: 'one vault revision bump');
      expect(j.echoesRuns, runsBefore + 1, reason: 'one immediate re-run');
      await _wi429Wait(tester, j, const Duration(seconds: 30));
      _wi429ExpectOnlySpacedRerun(j, runsBefore);
      expect(
        j.bumps,
        lessThanOrEqualTo(2),
        reason: 'the action bump plus at most the poller confirmation',
      );
      expect(_wi429Key('echo-row-$_wi429Loot'), findsNothing);
      if (pending) {
        expect(
          j.stored(_wi429Topic),
          wi429WithAutoAddedLink(_wi429Typed, 'Loot tables'),
          reason: 'the typed text and the link both survive',
        );
      }
    });
  }
}
