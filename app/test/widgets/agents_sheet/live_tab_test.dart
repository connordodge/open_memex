// WI #410 (Spec #394 req 9 Live badge, 17-21, 44, 47 Live; rulings D1, D14,
// D31, L410-1, L410-2; design pack design/394-agents-sheet/packs/410.md and
// RULINGS.md #5, #6, #12, #13, #14): the Agents sheet Live tab and its tab
// badge. Every widget test opens the real sheet through `pumpAgentsSheet`
// and selects Live through `agentsSheetTabProvider`.
//
// Stable Keys the implementation must carry (robot-test seams):
// - `live-agent-card-<i>`: connected agent i's card (wide) or one-line row
//   (narrow), i = index in `view.connected`; `live-agent-dot-<i>`: its 7 x 7
//   dot.
// - `live-recent-row-<i>`: Recent writes row i (newest first, 0..19).
// - `live-set-up-agent`: the `Set up an agent` OmButton.
//
// flutter_test draws every glyph one em wide (holdFontFetches keeps the
// fallback font), so the 1.5x layout tests are stricter than the real fonts.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/agent_activity.dart';
import 'package:open_memex_app/src/state/agents_sheet/agents_sheet_state.dart';
import 'package:open_memex_app/src/state/agents_sheet/live_tab_state.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/theme/typography.dart';
import 'package:open_memex_app/src/vault_access/agents_access.dart';
import 'package:open_memex_app/src/widgets/agents_sheet/agents_tab_loading.dart';
import 'package:open_memex_app/src/widgets/agents_sheet/connect_tab.dart';
import 'package:open_memex_app/src/widgets/agents_sheet/live_tab.dart';
import 'package:open_memex_app/src/widgets/atoms.dart';

import '../../support/agents_sheet_harness.dart';
import '../../support/font_fetch_hold.dart';

// ------------------------------------------------------------------ fixtures

const _sessionA = '01JAGENTSESSION0000000000A';
const _sessionB = '01JAGENTSESSION0000000000B';

/// [d] before the FakeClock start, ms epoch.
int _ago(Duration d) => agentsT0 - d.inMilliseconds;

/// A working agent: client `claude-code` v0.14.2, stdio, connected 14 min,
/// semantic recall on.
ConnectedAgent _working({int offsetMs = 0}) => ConnectedAgent(
  presence: agentPresence(
    sessionId: _sessionA,
    clientName: 'claude-code',
    clientVersion: '0.14.2',
    transport: 'stdio',
    startedAt: _ago(const Duration(minutes: 14)) + offsetMs,
    lastSeenAt: _ago(const Duration(seconds: 1)) + offsetMs,
    lastRequestAt: _ago(const Duration(seconds: 2)) + offsetMs,
    lastToolAt: _ago(const Duration(seconds: 3)) + offsetMs,
    expiresAt: agentsT0 + const Duration(minutes: 10).inMilliseconds + offsetMs,
    embeddings: true,
  ),
  working: true,
);

/// An idle agent: `claude-ai`, no version, http, connected 2 h, keyword
/// search only, last request 3 min ago (the idle age), last seen and last
/// tool call at other times, so a wrong field shows.
ConnectedAgent _idle({int offsetMs = 0}) => ConnectedAgent(
  presence: agentPresence(
    sessionId: _sessionB,
    clientName: 'claude-ai',
    clientVersion: null,
    transport: 'http',
    startedAt: _ago(const Duration(hours: 2)) + offsetMs,
    lastSeenAt: _ago(const Duration(minutes: 9)) + offsetMs,
    lastRequestAt: _ago(const Duration(minutes: 3)) + offsetMs,
    lastToolAt: _ago(const Duration(minutes: 20)) + offsetMs,
    expiresAt: agentsT0 + const Duration(minutes: 10).inMilliseconds + offsetMs,
    embeddings: false,
  ),
  working: false,
);

/// `n` entries, newest first: entry i is `summary-<i>` by `claude-code`,
/// written `i * 10 + 30` s before the clock start.
List<AgentActivityEntry> _entries(int n, {int offsetMs = 0}) => [
  for (var i = 0; i < n; i++)
    agentEntry(
      id: '01JAGENTENTRY00000000000$i',
      clientName: 'claude-code',
      summary: 'summary-$i',
      createdAt: _ago(Duration(seconds: 30 + i * 10)) + offsetMs,
    ),
];

/// Three rows with the times `now`, `2m` and `1h`.
List<AgentActivityEntry> _threeEntries() => [
  agentEntry(
    id: '01JAGENTENTRY0000000000A1',
    clientName: 'claude-code',
    summary: 'filed 4 blocks → Player Loop',
    createdAt: _ago(const Duration(seconds: 30)),
  ),
  agentEntry(
    id: '01JAGENTENTRY0000000000A2',
    clientName: 'claude-ai',
    summary: 'tagged 3 notes #design',
    createdAt: _ago(const Duration(minutes: 2)),
  ),
  agentEntry(
    id: '01JAGENTENTRY0000000000A3',
    clientName: 'claude-code',
    summary: 'moved Inbox → Archive',
    createdAt: _ago(const Duration(hours: 1)),
  ),
];

AgentActivityView _view({
  List<ConnectedAgent> connected = const [],
  List<AgentActivityEntry> recent = const [],
  bool available = true,
  int clockOffsetMs = 0,
}) => AgentActivityView(
  connected: connected,
  recent: recent,
  available: available,
  clockOffsetMs: clockOffsetMs,
);

/// Scripts `agentActivityAsyncProvider`: each build waits on [pending]; a
/// bump of [generation] rebuilds it (Riverpod keeps the previous value on
/// that AsyncLoading, as after a vault switch, D31).
class _LiveScript {
  Completer<AgentActivityView> pending = Completer();
  final generation = StateProvider<int>((_) => 0);
  _LiveScriptedActivity? notifier;

  Override get override => agentActivityAsyncProvider.overrideWith(
    () => _LiveScriptedActivity(this),
  );

  void resolve(AgentActivityView view) => pending.complete(view);

  void fail(Object error) => pending.completeError(error);

  void push(AgentActivityView view) => notifier!.push(view);
}

class _LiveScriptedActivity extends AgentActivityNotifier {
  _LiveScriptedActivity(this._script);

  final _LiveScript _script;

  @override
  FutureOr<AgentActivityView> build() {
    ref.watch(_script.generation);
    _script.notifier = this;
    return _script.pending.future;
  }

  void push(AgentActivityView view) => state = AsyncData(view);
}

// ------------------------------------------------------------------ helpers

Finder _key(String k) => find.byKey(Key(k));

/// Text [text] inside the Live tab.
Finder _t(String text) =>
    find.descendant(of: find.byType(LiveTab), matching: find.text(text));

Future<void> _selectLive(AgentsSheetHarness s) async {
  s.container.read(agentsSheetTabProvider.notifier).select(AgentsTab.live);
  await s.settle();
}

/// Opens the sheet on [view] (resolved at once) and selects Live.
Future<AgentsSheetHarness> _openLive(
  WidgetTester tester,
  AgentActivityView view, {
  Size size = const Size(1000, 800),
  double textScale = 1.0,
}) async {
  final script = _LiveScript()..resolve(view);
  final s = await pumpAgentsSheet(
    tester,
    size: size,
    textScale: textScale,
    overrides: [script.override],
  );
  await _selectLive(s);
  expect(find.byType(LiveTab), findsOneWidget);
  return s;
}

/// Compares the style [f] draws with [expected]: family, size, weight,
/// colour, letter spacing and, when [checkHeight], line height.
void _expectStyle(
  WidgetTester tester,
  Finder f,
  TextStyle expected, {
  bool checkHeight = true,
}) {
  expect(f, findsOneWidget);
  final style = tester.widget<Text>(f).style!;
  expect(style.fontFamily, expected.fontFamily, reason: 'font family');
  expect(style.fontSize, expected.fontSize, reason: 'font size');
  expect(style.fontWeight, expected.fontWeight, reason: 'font weight');
  expect(style.color, expected.color, reason: 'colour');
  expect(
    style.letterSpacing ?? 0,
    expected.letterSpacing ?? 0,
    reason: 'letter spacing',
  );
  if (checkHeight) expect(style.height, expected.height, reason: 'height');
}

/// The decoration drawn at or inside [f].
BoxDecoration _decorationOf(Finder f) {
  final boxes = find.descendant(
    of: f,
    matching: find.byWidgetPredicate(
      (w) => w is DecoratedBox && w.decoration is BoxDecoration,
    ),
    matchRoot: true,
  );
  expect(boxes, findsWidgets, reason: 'a decorated box at or in $f');
  return (boxes.evaluate().first.widget as DecoratedBox).decoration
      as BoxDecoration;
}

Color? _dotColor(String key) => _decorationOf(_key(key)).color;

Rect _rect(WidgetTester tester, Finder f) => tester.getRect(f);

/// Whether any Text inside the Live tab is drawn in an error colour.
bool _anyDangerText(WidgetTester tester) {
  for (final e
      in find
          .descendant(of: find.byType(LiveTab), matching: find.byType(Text))
          .evaluate()) {
    final c = (e.widget as Text).style?.color;
    if (c == OmColors.danger || c == OmColors.dangerBg) return true;
  }
  return false;
}

/// Every chip text as one string, as the shell's chip renders it.
String _chipText(WidgetTester tester, String key) {
  final parts = [
    for (final e
        in find
            .descendant(of: _key(key), matching: find.byType(RichText))
            .evaluate())
      (e.widget as RichText).text.toPlainText().trim(),
  ].where((t) => t.isNotEmpty);
  return parts.join(' ').replaceAll(RegExp(r'\s+'), ' ');
}

const _noAgentsLine =
    'Connect Claude Desktop or Claude Code to this vault to see it work here.';

// --------------------------------------------------------------------- tests

void main() {
  holdFontFetches();

  // ================================================================ AC 1
  group('connected cards (AC1)', () {
    testWidgets(
      'two connected agents render two cards with names meta lines and statuses',
      (tester) async {
        await _openLive(
          tester,
          _view(connected: [_working(), _idle()], recent: _threeEntries()),
        );

        expect(_key('live-agent-card-0'), findsOneWidget);
        expect(_key('live-agent-card-1'), findsOneWidget);
        expect(_key('live-agent-card-2'), findsNothing);
        expect(_t('CONNECTED · 2'), findsOneWidget);

        final a = _key('live-agent-card-0');
        final b = _key('live-agent-card-1');
        expect(
          find.descendant(of: a, matching: find.text('claude-code')),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: a,
            matching: find.text(
              'v0.14.2 · stdio · connected 14m · semantic recall on',
            ),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(of: a, matching: find.text('working')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: b, matching: find.text('claude-ai')),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: b,
            matching: find.text('http · connected 2h · keyword search only'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(of: b, matching: find.text('idle · 3m')),
          findsOneWidget,
          reason: 'idle age is formatAgentAge of last_request_at',
        );
        expect(
          find.descendant(of: b, matching: find.text('working')),
          findsNothing,
        );
      },
    );

    testWidgets('the dot is agent when working and fg2 when idle at 7 x 7', (
      tester,
    ) async {
      await _openLive(tester, _view(connected: [_working(), _idle()]));

      expect(_dotColor('live-agent-dot-0'), OmColors.agent);
      expect(_dotColor('live-agent-dot-1'), OmColors.fg2);
      expect(tester.getSize(_key('live-agent-dot-0')), const Size(7, 7));
      expect(tester.getSize(_key('live-agent-dot-1')), const Size(7, 7));
      final dot = _decorationOf(_key('live-agent-dot-0'));
      expect(dot.shape, BoxShape.circle);
    });

    testWidgets('the status colour is agent when working and fg2 when idle', (
      tester,
    ) async {
      final t = tester;
      await _openLive(t, _view(connected: [_working(), _idle()]));

      _expectStyle(
        t,
        find.descendant(
          of: _key('live-agent-card-0'),
          matching: find.text('working'),
        ),
        OmType.mono(size: 11, color: OmColors.agent),
      );
      _expectStyle(
        t,
        find.descendant(
          of: _key('live-agent-card-1'),
          matching: find.text('idle · 3m'),
        ),
        OmType.mono(size: 11, color: OmColors.fg2),
      );
    });

    testWidgets(
      'working comes from the view and is not re-derived from last_tool_at',
      (tester) async {
        // Working flag true with no tool call; working flag false with a
        // tool call one second ago.
        final noTool = ConnectedAgent(
          presence: agentPresence(
            sessionId: _sessionA,
            clientName: 'claude-code',
            lastRequestAt: _ago(const Duration(minutes: 1)),
          ),
          working: true,
        );
        final recentTool = ConnectedAgent(
          presence: agentPresence(
            sessionId: _sessionB,
            clientName: 'claude-ai',
            lastRequestAt: _ago(const Duration(minutes: 1)),
            lastToolAt: _ago(const Duration(seconds: 1)),
          ),
          working: false,
        );
        await _openLive(tester, _view(connected: [noTool, recentTool]));

        expect(_dotColor('live-agent-dot-0'), OmColors.agent);
        expect(_dotColor('live-agent-dot-1'), OmColors.fg2);
        expect(_t('working'), findsOneWidget);
        expect(_t('idle · 1m'), findsOneWidget);
      },
    );

    testWidgets(
      'server timestamps are read on the local clock through the view offset',
      (tester) async {
        // The server clock runs one hour ahead: every server stamp is an
        // hour later than its local time.
        const hour = 3600000;
        await _openLive(
          tester,
          _view(
            connected: [
              _working(offsetMs: hour),
              _idle(offsetMs: hour),
            ],
            recent: _entries(1, offsetMs: hour),
            clockOffsetMs: hour,
          ),
        );

        expect(
          _t('v0.14.2 · stdio · connected 14m · semantic recall on'),
          findsOneWidget,
        );
        expect(_t('idle · 3m'), findsOneWidget);
        expect(_t('now'), findsOneWidget, reason: 'the 30 s old write');
      },
    );

    testWidgets('card text styles and card box follow the design', (
      tester,
    ) async {
      await _openLive(
        tester,
        _view(connected: [_working(), _idle()], recent: _threeEntries()),
      );

      final card = _decorationOf(_key('live-agent-card-0'));
      expect(card.color, OmColors.surface3);
      expect(card.borderRadius, BorderRadius.circular(8));
      final border = card.border! as Border;
      expect(border.top.color, OmColors.line2);
      expect(border.top.width, 1);

      _expectStyle(
        tester,
        find.descendant(
          of: _key('live-agent-card-0'),
          matching: find.text('claude-code'),
        ),
        OmType.sans(size: 13, weight: FontWeight.w500, color: OmColors.fg0),
        checkHeight: false,
      );
      _expectStyle(
        tester,
        find.descendant(
          of: _key('live-agent-card-0'),
          matching: find.text(
            'v0.14.2 · stdio · connected 14m · semantic recall on',
          ),
        ),
        OmType.mono(size: 10.5, color: OmColors.fg2, height: 1.6),
      );
      _expectStyle(
        tester,
        _t('CONNECTED · 2'),
        OmType.mono(
          size: 10.5,
          weight: FontWeight.w500,
          color: OmColors.fg2,
          letterSpacing: 0.8,
        ),
        checkHeight: false,
      );
    });

    testWidgets('card geometry: padding dot gap status edge and card gap', (
      tester,
    ) async {
      await _openLive(tester, _view(connected: [_working(), _idle()]));

      final card0 = _rect(tester, _key('live-agent-card-0'));
      final card1 = _rect(tester, _key('live-agent-card-1'));
      final dot = _rect(tester, _key('live-agent-dot-0'));
      final name = _rect(
        tester,
        find.descendant(
          of: _key('live-agent-card-0'),
          matching: find.text('claude-code'),
        ),
      );
      final meta = _rect(
        tester,
        find.descendant(
          of: _key('live-agent-card-0'),
          matching: find.textContaining('connected 14m'),
        ),
      );
      final status = _rect(
        tester,
        find.descendant(
          of: _key('live-agent-card-0'),
          matching: find.text('working'),
        ),
      );

      // Padding 10 / 12 inside a 1 px border, dot margin-top 6.
      expect(dot.left - card0.left, inInclusiveRange(12, 13));
      expect(dot.top - card0.top, inInclusiveRange(16, 17));
      expect(name.left - dot.right, closeTo(10, 0.1), reason: 'gap 10');
      expect(
        card0.right - status.right,
        inInclusiveRange(12, 13),
        reason: 'status at the right padding edge',
      );
      expect(card1.top - card0.bottom, closeTo(8, 0.1), reason: 'margin 8');
      expect(meta.left, closeTo(name.left, 0.1));
      expect(meta.top, greaterThanOrEqualTo(name.bottom - 0.5));
    });
  });

  // ================================================================ AC 2
  group('meta line (AC2)', () {
    testWidgets(
      'embeddings true reads semantic recall on and false reads keyword search only',
      (tester) async {
        await _openLive(tester, _view(connected: [_working(), _idle()]));

        expect(find.textContaining('semantic recall on'), findsOneWidget);
        expect(find.textContaining('keyword search only'), findsOneWidget);
        expect(
          _t('v0.14.2 · stdio · connected 14m · semantic recall on'),
          findsOneWidget,
        );
        expect(_t('http · connected 2h · keyword search only'), findsOneWidget);
      },
    );

    testWidgets('a client without a version omits the v prefix part', (
      tester,
    ) async {
      await _openLive(tester, _view(connected: [_idle()]));

      expect(_t('http · connected 2h · keyword search only'), findsOneWidget);
      expect(find.textContaining('v · '), findsNothing);
      expect(find.textContaining('vnull'), findsNothing);
      expect(find.textContaining('null'), findsNothing);
    });

    testWidgets('a client with a version shows it as v<version>', (
      tester,
    ) async {
      final agent = ConnectedAgent(
        presence: agentPresence(
          clientVersion: '2.3.4',
          transport: 'bridge',
          startedAt: _ago(const Duration(hours: 5)),
          embeddings: false,
        ),
        working: false,
      );
      await _openLive(tester, _view(connected: [agent]));

      expect(
        _t('v2.3.4 · bridge · connected 5h · keyword search only'),
        findsOneWidget,
      );
    });
  });

  // ================================================================ AC 3
  group('recent writes (AC3)', () {
    testWidgets(
      'recent writes shows the explainer and a row per entry with client summary and age',
      (tester) async {
        await _openLive(
          tester,
          _view(connected: [_working()], recent: _threeEntries()),
        );

        expect(_t('RECENT WRITES'), findsOneWidget);
        expect(
          _t(
            'The newest writes by any agent. Summaries name notes and folders, never your text.',
          ),
          findsOneWidget,
        );
        expect(_key('live-recent-row-0'), findsOneWidget);
        expect(_key('live-recent-row-1'), findsOneWidget);
        expect(_key('live-recent-row-2'), findsOneWidget);
        expect(_key('live-recent-row-3'), findsNothing);

        Finder inRow(int i, String text) => find.descendant(
          of: _key('live-recent-row-$i'),
          matching: find.text(text),
        );
        expect(inRow(0, 'claude-code'), findsOneWidget);
        expect(inRow(0, 'filed 4 blocks → Player Loop'), findsOneWidget);
        expect(inRow(0, 'now'), findsOneWidget);
        expect(inRow(1, 'claude-ai'), findsOneWidget);
        expect(inRow(1, 'tagged 3 notes #design'), findsOneWidget);
        expect(inRow(1, '2m'), findsOneWidget);
        expect(inRow(2, 'moved Inbox → Archive'), findsOneWidget);
        expect(inRow(2, '1h'), findsOneWidget);
      },
    );

    testWidgets('rows keep the order they come in, newest first', (
      tester,
    ) async {
      await _openLive(
        tester,
        _view(connected: [_working()], recent: _entries(5)),
      );

      final tops = [
        for (var i = 0; i < 5; i++) tester.getTopLeft(_t('summary-$i')).dy,
      ];
      for (var i = 1; i < tops.length; i++) {
        expect(
          tops[i],
          greaterThan(tops[i - 1]),
          reason: 'row $i below ${i - 1}',
        );
      }
    });

    testWidgets('a 21st entry is not shown', (tester) async {
      await _openLive(
        tester,
        _view(connected: [_working()], recent: _entries(21)),
      );

      expect(_key('live-recent-row-19'), findsOneWidget);
      expect(_key('live-recent-row-20'), findsNothing);
      expect(_t('summary-19'), findsOneWidget);
      expect(_t('summary-20'), findsNothing);
    });

    testWidgets('exactly 20 entries all show', (tester) async {
      await _openLive(
        tester,
        _view(connected: [_working()], recent: _entries(20)),
      );

      expect(_key('live-recent-row-19'), findsOneWidget);
      expect(_t('summary-19'), findsOneWidget);
    });

    testWidgets(
      'the three-column grid is 84 then the summary then 34 with 10 gaps',
      (tester) async {
        await _openLive(
          tester,
          _view(connected: [_working()], recent: _threeEntries()),
        );

        final row = _rect(tester, _key('live-recent-row-0'));
        final client = _rect(
          tester,
          find.descendant(
            of: _key('live-recent-row-0'),
            matching: find.text('claude-code'),
          ),
        );
        final summary = _rect(
          tester,
          find.descendant(
            of: _key('live-recent-row-0'),
            matching: find.text('filed 4 blocks → Player Loop'),
          ),
        );
        final time = _rect(
          tester,
          find.descendant(
            of: _key('live-recent-row-0'),
            matching: find.text('now'),
          ),
        );

        expect(client.left, closeTo(row.left, 0.5));
        expect(summary.left - client.left, closeTo(94, 0.5), reason: '84 + 10');
        expect(time.right, closeTo(row.right, 0.5), reason: 'right aligned');
        expect(
          summary.right,
          lessThanOrEqualTo(time.left),
          reason: 'the summary column ends before the time column',
        );
        final timeText = tester.widget<Text>(
          find.descendant(
            of: _key('live-recent-row-0'),
            matching: find.text('now'),
          ),
        );
        expect(timeText.textAlign, TextAlign.right);
      },
    );

    testWidgets('row text styles and the line1 bottom border on every row', (
      tester,
    ) async {
      await _openLive(
        tester,
        _view(connected: [_working()], recent: _threeEntries()),
      );

      Finder inRow(int i, String text) => find.descendant(
        of: _key('live-recent-row-$i'),
        matching: find.text(text),
      );
      _expectStyle(
        tester,
        inRow(0, 'claude-code'),
        OmType.mono(size: 10.5, color: OmColors.fg2),
      );
      _expectStyle(
        tester,
        inRow(0, 'filed 4 blocks → Player Loop'),
        OmType.sans(size: 12.5, color: OmColors.fg1),
      );
      _expectStyle(
        tester,
        inRow(0, 'now'),
        OmType.mono(size: 10.5, color: OmColors.fg2),
        checkHeight: false,
      );
      _expectStyle(
        tester,
        _t(
          'The newest writes by any agent. Summaries name notes and folders, never your text.',
        ),
        OmType.sans(size: 12.5, color: OmColors.fg2, height: 1.55),
      );
      for (var i = 0; i < 3; i++) {
        final border =
            _decorationOf(_key('live-recent-row-$i')).border! as Border;
        expect(border.bottom.color, OmColors.line1, reason: 'row $i');
        expect(border.bottom.width, 1, reason: 'row $i');
      }
    });

    testWidgets('long client names and summaries ellipsize on one line', (
      tester,
    ) async {
      const longSummary =
          'filed 4 blocks into a note with a very very very very very long '
          'name that cannot possibly fit on one line of the Live tab';
      final s = await _openLive(
        tester,
        _view(
          connected: [_working()],
          recent: [
            agentEntry(
              clientName: 'a-client-name-far-longer-than-84-pixels',
              summary: longSummary,
              createdAt: _ago(const Duration(seconds: 5)),
            ),
          ],
        ),
      );
      expect(s, isNotNull);

      final summary = tester.widget<Text>(_t(longSummary));
      expect(summary.maxLines, 1);
      expect(summary.overflow, TextOverflow.ellipsis);
      final client = tester.widget<Text>(
        _t('a-client-name-far-longer-than-84-pixels'),
      );
      expect(client.maxLines, 1);
      expect(client.overflow, TextOverflow.ellipsis);
      expect(tester.takeException(), isNull);
    });
  });

  // ================================================================ AC 4
  group('no agents connected (AC4)', () {
    testWidgets(
      'no agents with recent writes shows the heading the last write line the button and recent writes',
      (tester) async {
        await _openLive(
          tester,
          _view(
            recent: [
              agentEntry(
                clientName: 'claude-ai',
                summary: 'filed 4 blocks → Player Loop',
                createdAt: _ago(const Duration(hours: 2)),
              ),
              agentEntry(
                id: '01JAGENTENTRY0000000000A9',
                clientName: 'claude-code',
                summary: 'older write',
                createdAt: _ago(const Duration(hours: 5)),
              ),
            ],
          ),
        );

        expect(_t('No agents connected'), findsOneWidget);
        expect(
          _t('Last agent write 2h ago, by claude-ai. $_noAgentsLine'),
          findsOneWidget,
          reason: 'the newest entry names the time and the client',
        );
        expect(_key('live-set-up-agent'), findsOneWidget);
        expect(_t('Set up an agent'), findsOneWidget);
        expect(_t('RECENT WRITES'), findsOneWidget);
        expect(_key('live-recent-row-0'), findsOneWidget);
        expect(_key('live-recent-row-1'), findsOneWidget);
        expect(_t('older write'), findsOneWidget);
        expect(find.textContaining('CONNECTED'), findsNothing);
        expect(_key('live-agent-card-0'), findsNothing);
      },
    );

    for (final (name, ago, text) in [
      (
        'the last write line reads just now under 60 seconds',
        const Duration(seconds: 59),
        'just now',
      ),
      (
        'the last write line reads 1m ago at 60 seconds',
        const Duration(seconds: 60),
        '1m ago',
      ),
      (
        'the last write line reads 3m ago for three minutes',
        const Duration(minutes: 3),
        '3m ago',
      ),
      (
        'the last write line reads 2h ago for two hours',
        const Duration(hours: 2),
        '2h ago',
      ),
      (
        'the last write line reads 4d ago for four days',
        const Duration(days: 4),
        '4d ago',
      ),
    ]) {
      testWidgets(name, (tester) async {
        await _openLive(
          tester,
          _view(
            recent: [agentEntry(clientName: 'claude-ai', createdAt: _ago(ago))],
          ),
        );

        expect(
          _t('Last agent write $text, by claude-ai. $_noAgentsLine'),
          findsOneWidget,
        );
      });
    }

    testWidgets(
      'the last write age is read on the local clock through the view offset',
      (tester) async {
        const hour = 3600000;
        await _openLive(
          tester,
          _view(
            clockOffsetMs: hour,
            recent: [
              agentEntry(
                clientName: 'claude-ai',
                createdAt: _ago(const Duration(minutes: 3)) + hour,
              ),
            ],
          ),
        );

        expect(
          _t('Last agent write 3m ago, by claude-ai. $_noAgentsLine'),
          findsOneWidget,
        );
      },
    );

    testWidgets('heading line and button follow the design', (tester) async {
      await _openLive(
        tester,
        _view(recent: [agentEntry(clientName: 'claude-ai')]),
      );

      _expectStyle(
        tester,
        _t('No agents connected'),
        OmType.sans(size: 15, weight: FontWeight.w600, color: OmColors.fg0),
        checkHeight: false,
      );
      _expectStyle(
        tester,
        _t('Last agent write just now, by claude-ai. $_noAgentsLine'),
        OmType.sans(size: 12.5, color: OmColors.fg2, height: 1.55),
      );
      final button = tester.widget<OmButton>(_key('live-set-up-agent'));
      expect(button.kind, OmButtonKind.primary);
      expect(button.label, 'Set up an agent');
      expect(button.focusable, isTrue);
      expect(button.size, 30);
      expect(button.dense, isFalse);
    });
  });

  // ================================================================ AC 5
  group('set up an agent (AC5)', () {
    testWidgets('Set up an agent selects the Connect tab', (tester) async {
      final s = await _openLive(
        tester,
        _view(recent: [agentEntry(clientName: 'claude-ai')]),
      );
      expect(s.read(agentsSheetTabProvider), AgentsTab.live);
      expect(find.byType(ConnectTab), findsNothing);

      await tester.tap(_key('live-set-up-agent'));
      await s.settle();

      expect(s.read(agentsSheetTabProvider), AgentsTab.connect);
      expect(find.byType(ConnectTab), findsOneWidget);
      expect(find.byType(LiveTab), findsNothing);
    });

    testWidgets('Set up an agent with empty recent also selects Connect', (
      tester,
    ) async {
      final s = await _openLive(tester, _view());
      await tester.tap(_key('live-set-up-agent'));
      await s.settle();

      expect(s.read(agentsSheetTabProvider), AgentsTab.connect);
    });

    testWidgets('the button is a focusable stop announced as a button', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final s = await _openLive(
        tester,
        _view(recent: [agentEntry(clientName: 'claude-ai')]),
      );
      expect(s, isNotNull);

      final node = tester.getSemantics(_key('live-set-up-agent'));
      expect(node.label, contains('Set up an agent'));
      expect(node.flagsCollection.isButton, isTrue);
      handle.dispose();
    });
  });

  // ================================================================ AC 6
  group('no agents and empty recent (AC6)', () {
    testWidgets(
      'no agents and empty recent reads no agent writes recorded and shows no recent writes',
      (tester) async {
        await _openLive(tester, _view());

        expect(_t('No agents connected'), findsOneWidget);
        expect(
          _t('No agent writes recorded for this vault yet.'),
          findsOneWidget,
        );
        expect(_t('Set up an agent'), findsOneWidget);
        expect(_t('RECENT WRITES'), findsNothing);
        expect(find.textContaining('The newest writes'), findsNothing);
        expect(find.textContaining('Last agent write'), findsNothing);
        expect(_key('live-recent-row-0'), findsNothing);
        expect(find.textContaining('No agent has connected'), findsNothing);
      },
    );
  });

  // ================================================================ AC 7
  group('older vault server (AC7)', () {
    testWidgets(
      'available false shows the two older server lines in no error colour and no cards',
      (tester) async {
        await _openLive(
          tester,
          _view(
            connected: [_working(), _idle()],
            recent: _threeEntries(),
            available: false,
          ),
        );

        expect(
          _t('Agent activity unavailable on this vault server'),
          findsOneWidget,
        );
        expect(
          _t(
            'The server is older than this app. Update memex on it to see connected agents and their writes here. Connect and Tools still work.',
          ),
          findsOneWidget,
        );
        expect(_key('live-agent-card-0'), findsNothing);
        expect(find.textContaining('CONNECTED'), findsNothing);
        expect(_t('RECENT WRITES'), findsNothing);
        expect(_t('No agents connected'), findsNothing);
        expect(_key('live-recent-row-0'), findsNothing);
        expect(_key('inline-error'), findsNothing);
        expect(_anyDangerText(tester), isFalse);
      },
    );

    testWidgets('the older server panel heading is sans 14 w600 fg0', (
      tester,
    ) async {
      await _openLive(tester, _view(available: false));

      _expectStyle(
        tester,
        _t('Agent activity unavailable on this vault server'),
        OmType.sans(size: 14, weight: FontWeight.w600, color: OmColors.fg0),
        checkHeight: false,
      );
      _expectStyle(
        tester,
        _t(
          'The server is older than this app. Update memex on it to see connected agents and their writes here. Connect and Tools still work.',
        ),
        OmType.sans(size: 12.5, color: OmColors.fg2),
        checkHeight: false,
      );
    });
  });

  // ================================================================ AC 8
  group('loading and errors (AC8, L410-1, D31)', () {
    testWidgets(
      'loading shows AgentsTabLoading and nothing of the Live content',
      (tester) async {
        final script = _LiveScript();
        final s = await pumpAgentsSheet(tester, overrides: [script.override]);
        await _selectLive(s);

        expect(find.byType(AgentsTabLoading), findsOneWidget);
        expect(find.byType(LiveTab), findsOneWidget);
        expect(find.text('loading…'), findsNothing, reason: 'before 400 ms');
        expect(find.text('No agents connected'), findsNothing);
        expect(
          find.text('No agent writes recorded for this vault yet.'),
          findsNothing,
        );

        s.clock.advance(const Duration(milliseconds: 400));
        await s.settle();
        expect(find.text('loading…'), findsOneWidget);
        expect(find.text('No agents connected'), findsNothing);
      },
    );

    testWidgets(
      'after a vault switch the stale view is not shown while the new read loads',
      (tester) async {
        final script = _LiveScript()
          ..resolve(_view(connected: [_working()], recent: _threeEntries()));
        final s = await pumpAgentsSheet(tester, overrides: [script.override]);
        await _selectLive(s);
        expect(_key('live-agent-card-0'), findsOneWidget);

        script.pending = Completer();
        s.read(script.generation.notifier).state++;
        await s.settle();

        expect(s.read(agentActivityAsyncProvider).isLoading, isTrue);
        expect(find.byType(AgentsTabLoading), findsOneWidget);
        expect(_key('live-agent-card-0'), findsNothing);
        expect(find.text('claude-code'), findsNothing);
        expect(find.text('RECENT WRITES'), findsNothing);

        script.resolve(_view(recent: _threeEntries()));
        await s.settle();
        expect(find.byType(AgentsTabLoading), findsNothing);
        expect(_t('No agents connected'), findsOneWidget);
      },
    );

    testWidgets(
      'an AsyncError renders the no agents state with no InlineError and no Retry',
      (tester) async {
        final script = _LiveScript();
        final s = await pumpAgentsSheet(tester, overrides: [script.override]);
        // The sheet's own watch is the listener the error lands on.
        script.fail(StateError('read failed'));
        await s.settle();
        await _selectLive(s);

        expect(s.read(agentActivityAsyncProvider).hasError, isTrue);
        expect(find.byType(AgentsTabLoading), findsNothing);
        expect(_t('No agents connected'), findsOneWidget);
        expect(
          _t('No agent writes recorded for this vault yet.'),
          findsOneWidget,
        );
        expect(_key('inline-error'), findsNothing);
        expect(_key('inline-error-retry'), findsNothing);
        expect(find.text('Retry'), findsNothing);
        expect(find.textContaining('read failed'), findsNothing);
      },
    );
  });

  // ================================================================ AC 9
  group('live updates (AC9, L410-2)', () {
    testWidgets(
      'the tab follows the provider through the presence tick and runs no tick of its own',
      (tester) async {
        final access = FakeAgentsAccess(
          script: [
            // First read: no agents.
            const AgentActivity(agents: [], recent: [], available: true),
          ],
        );
        final s = await pumpAgentsSheet(tester, agents: access);
        await _selectLive(s);

        expect(_t('No agents connected'), findsOneWidget);
        expect(access.reads, 1, reason: 'the provider own first read only');

        // Pumping frames without moving the clock reads nothing.
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(access.reads, 1, reason: 'the tab never reads on its own');
        final timers = s.clock.pendingTimers;

        // The next presence tick reads two agents and a write.
        access.answer(
          AgentActivity(
            agents: [_working().presence, _idle().presence],
            recent: _threeEntries(),
            available: true,
          ),
        );
        s.clock.advance(const Duration(seconds: 2));
        await s.settle();

        expect(access.reads, 2, reason: 'one tick, one read');
        expect(s.clock.pendingTimers, timers, reason: 'no timer added by Live');
        expect(_t('CONNECTED · 2'), findsOneWidget);
        expect(_t('claude-ai'), findsWidgets);
        expect(_key('live-agent-card-1'), findsOneWidget);
        expect(_dotColor('live-agent-dot-0'), OmColors.agent);
        expect(_t('working'), findsOneWidget);
        expect(_t('idle · 3m'), findsOneWidget);
        expect(_t('No agents connected'), findsNothing);
      },
    );

    testWidgets(
      'working turns to idle and ages grow on the tick with no new read data',
      (tester) async {
        final access = FakeAgentsAccess(
          script: [
            AgentActivity(
              agents: [_working().presence, _idle().presence],
              recent: _threeEntries(),
              available: true,
            ),
          ],
        );
        final s = await pumpAgentsSheet(tester, agents: access);
        await _selectLive(s);

        expect(_t('working'), findsOneWidget);
        expect(_dotColor('live-agent-dot-0'), OmColors.agent);
        expect(_t('idle · 3m'), findsOneWidget);

        // Ten seconds on: the tool call is 13 s old (D1 window is 10 s).
        s.clock.advance(const Duration(seconds: 10));
        await s.settle();
        expect(_t('working'), findsNothing);
        expect(_dotColor('live-agent-dot-0'), OmColors.fg2);

        // Two more minutes: the idle agent last requested 5 minutes ago.
        s.clock.advance(const Duration(minutes: 2));
        await s.settle();
        expect(_t('idle · 5m'), findsOneWidget);
      },
    );

    testWidgets(
      'an agent that expires drops out and the tab shows the no agents state',
      (tester) async {
        final gone = ConnectedAgent(
          presence: agentPresence(
            clientName: 'claude-code',
            expiresAt: agentsT0 + 15000,
          ),
          working: false,
        );
        final access = FakeAgentsAccess(
          script: [
            AgentActivity(
              agents: [gone.presence],
              recent: _threeEntries(),
              available: true,
            ),
          ],
        );
        final s = await pumpAgentsSheet(tester, agents: access);
        await _selectLive(s);
        expect(_t('CONNECTED · 1'), findsOneWidget);

        s.clock.advance(const Duration(seconds: 20));
        await s.settle();

        expect(_t('No agents connected'), findsOneWidget);
        expect(find.textContaining('CONNECTED'), findsNothing);
      },
    );

    testWidgets('a pushed view replaces the one on screen', (tester) async {
      final script = _LiveScript()..resolve(_view(connected: [_working()]));
      final s = await pumpAgentsSheet(tester, overrides: [script.override]);
      await _selectLive(s);
      expect(_t('CONNECTED · 1'), findsOneWidget);

      script.push(_view(connected: [_working(), _idle()]));
      await s.settle();
      expect(_t('CONNECTED · 2'), findsOneWidget);
      expect(_key('live-agent-card-1'), findsOneWidget);
    });
  });

  // ================================================================ AC 10
  group('liveTabBadgeProvider (AC10, D31, L410-1)', () {
    late _LiveScript script;
    late ProviderContainer container;

    setUp(() {
      script = _LiveScript();
      container = ProviderContainer(overrides: [script.override]);
      addTearDown(container.dispose);
      container.listen(liveTabBadgeProvider, (_, _) {});
      container.listen(agentActivityAsyncProvider, (_, _) {});
    });

    Future<void> resolved(AgentActivityView view) async {
      script.resolve(view);
      await container.read(agentActivityAsyncProvider.future);
      await Future<void>.delayed(Duration.zero);
    }

    test('two connected agents read 2 connected', () async {
      await resolved(_view(connected: [_working(), _idle()]));
      expect(container.read(liveTabBadgeProvider), '2 connected');
    });

    test('one connected agent reads 1 connected', () async {
      await resolved(_view(connected: [_idle()]));
      expect(container.read(liveTabBadgeProvider), '1 connected');
    });

    test('three connected agents read 3 connected', () async {
      final third = ConnectedAgent(
        presence: agentPresence(sessionId: '01JAGENTSESSION0000000000C'),
        working: false,
      );
      await resolved(_view(connected: [_working(), _idle(), third]));
      expect(container.read(liveTabBadgeProvider), '3 connected');
    });

    test('zero connected agents give no badge', () async {
      await resolved(_view(recent: _threeEntries()));
      expect(container.read(liveTabBadgeProvider), isNull);
    });

    test('while loading there is no badge', () async {
      expect(container.read(agentActivityAsyncProvider).isLoading, isTrue);
      expect(container.read(liveTabBadgeProvider), isNull);
    });

    test('a stale view while the next read loads gives no badge', () async {
      await resolved(_view(connected: [_working(), _idle()]));
      expect(container.read(liveTabBadgeProvider), '2 connected');

      script.pending = Completer();
      container.read(script.generation.notifier).state++;
      await Future<void>.delayed(Duration.zero);

      expect(container.read(agentActivityAsyncProvider).isLoading, isTrue);
      expect(container.read(liveTabBadgeProvider), isNull);
    });

    test('an unavailable view with agents gives no badge', () async {
      await resolved(_view(connected: [_working(), _idle()], available: false));
      expect(container.read(liveTabBadgeProvider), isNull);
    });

    test('an errored read gives no badge', () async {
      script.fail(StateError('read failed'));
      await expectLater(
        container.read(agentActivityAsyncProvider.future),
        throwsA(isA<StateError>()),
      );
      await Future<void>.delayed(Duration.zero);
      expect(container.read(agentActivityAsyncProvider).hasError, isTrue);
      expect(container.read(liveTabBadgeProvider), isNull);
    });

    test('the badge follows later views', () async {
      await resolved(_view(connected: [_working()]));
      expect(container.read(liveTabBadgeProvider), '1 connected');

      script.push(_view(connected: [_working(), _idle()]));
      expect(container.read(liveTabBadgeProvider), '2 connected');

      script.push(_view());
      expect(container.read(liveTabBadgeProvider), isNull);
    });

    testWidgets(
      'the Live chip shows 2 connected from the real provider and bare Live at zero',
      (tester) async {
        final access = FakeAgentsAccess(
          script: [
            AgentActivity(
              agents: [_working().presence, _idle().presence],
              recent: const [],
              available: true,
            ),
          ],
        );
        final s = await pumpAgentsSheet(tester, agents: access);
        expect(_chipText(tester, 'agents-tab-live'), 'Live 2 connected');

        // Both agents expire: the chip drops its count.
        s.clock.advance(const Duration(minutes: 11));
        await s.settle();
        expect(_chipText(tester, 'agents-tab-live'), 'Live');
      },
    );
  });

  // ================================================================ AC 11
  group('narrow window (AC11, Spec req 47)', () {
    final connected = [_working(), _idle()];
    final recent = _threeEntries();

    testWidgets(
      'at a 672 window the wide layout shows the client column and the meta line',
      (tester) async {
        await _openLive(
          tester,
          _view(connected: connected, recent: recent),
          size: const Size(672, 800),
        );

        expect(
          _t('v0.14.2 · stdio · connected 14m · semantic recall on'),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: _key('live-recent-row-0'),
            matching: find.text('claude-code'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: _key('live-recent-row-0'),
            matching: find.text('filed 4 blocks → Player Loop'),
          ),
          findsOneWidget,
        );
        expect(_t('claude-code · filed 4 blocks → Player Loop'), findsNothing);
      },
    );

    testWidgets(
      'at a 671 window recent rows read client dot summary with no name column',
      (tester) async {
        await _openLive(
          tester,
          _view(connected: connected, recent: recent),
          size: const Size(671, 800),
        );

        final row = _key('live-recent-row-0');
        expect(
          find.descendant(
            of: row,
            matching: find.text('claude-code · filed 4 blocks → Player Loop'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(of: row, matching: find.text('claude-code')),
          findsNothing,
        );
        expect(_t('claude-ai · tagged 3 notes #design'), findsOneWidget);
        expect(_t('claude-code · moved Inbox → Archive'), findsOneWidget);
        expect(
          find.descendant(of: row, matching: find.text('now')),
          findsOneWidget,
        );

        // Grid flexible | 34: the summary starts at the row start and the
        // time is right aligned.
        final rowRect = _rect(tester, row);
        final summary = _rect(
          tester,
          find.descendant(
            of: row,
            matching: find.text('claude-code · filed 4 blocks → Player Loop'),
          ),
        );
        final time = _rect(
          tester,
          find.descendant(of: row, matching: find.text('now')),
        );
        expect(summary.left, closeTo(rowRect.left, 0.5));
        expect(time.right, closeTo(rowRect.right, 0.5));
        _expectStyle(
          tester,
          find.descendant(
            of: row,
            matching: find.text('claude-code · filed 4 blocks → Player Loop'),
          ),
          OmType.sans(size: 12.5, color: OmColors.fg1),
        );
      },
    );

    testWidgets(
      'at 640 the agent cards are one line with name and status and no meta line',
      (tester) async {
        await _openLive(
          tester,
          _view(connected: connected, recent: recent),
          size: const Size(640, 800),
        );

        expect(_t('CONNECTED · 2'), findsOneWidget);
        expect(find.textContaining('stdio'), findsNothing);
        expect(find.textContaining('semantic recall'), findsNothing);
        expect(find.textContaining('keyword search'), findsNothing);

        for (final (i, name, status) in [
          (0, 'claude-code', 'working'),
          (1, 'claude-ai', 'idle · 3m'),
        ]) {
          final card = _key('live-agent-card-$i');
          final nameRect = _rect(
            tester,
            find.descendant(of: card, matching: find.text(name)),
          );
          final statusRect = _rect(
            tester,
            find.descendant(of: card, matching: find.text(status)),
          );
          final dot = _rect(tester, _key('live-agent-dot-$i'));
          expect(
            (nameRect.center.dy - statusRect.center.dy).abs(),
            lessThan(3),
            reason: 'name and status share one line',
          );
          expect(nameRect.left - dot.right, closeTo(8, 0.1), reason: 'gap 8');
          expect(statusRect.left, greaterThan(nameRect.left));
          expect(dot.size, const Size(7, 7));
        }
        final row0 = _rect(tester, _key('live-agent-card-0'));
        final row1 = _rect(tester, _key('live-agent-card-1'));
        expect(row1.top - row0.bottom, closeTo(6, 0.1), reason: 'rows 6 apart');
        expect(row0.height, lessThan(30), reason: 'one line');
        expect(_dotColor('live-agent-dot-0'), OmColors.agent);
        expect(_dotColor('live-agent-dot-1'), OmColors.fg2);
        _expectStyle(
          tester,
          find.descendant(
            of: _key('live-agent-card-0'),
            matching: find.text('claude-code'),
          ),
          OmType.sans(size: 13, weight: FontWeight.w500, color: OmColors.fg0),
          checkHeight: false,
        );
        _expectStyle(
          tester,
          find.descendant(
            of: _key('live-agent-card-0'),
            matching: find.text('working'),
          ),
          OmType.mono(size: 11, color: OmColors.agent),
        );
      },
    );

    testWidgets('a wide window card is taller than a one line narrow row', (
      tester,
    ) async {
      await _openLive(
        tester,
        _view(connected: connected),
        size: const Size(1000, 800),
      );
      expect(
        _rect(tester, _key('live-agent-card-0')).height,
        greaterThan(40),
        reason: 'name over meta',
      );
    });

    testWidgets(
      'the 20 row cap and the no agents button hold on the narrow layout',
      (tester) async {
        final s = await _openLive(
          tester,
          _view(recent: _entries(21)),
          size: const Size(600, 800),
        );

        expect(_t('claude-code · summary-19'), findsOneWidget);
        expect(_t('claude-code · summary-20'), findsNothing);
        await tester.ensureVisible(_key('live-set-up-agent'));
        await tester.tap(_key('live-set-up-agent'));
        await s.settle();
        expect(s.read(agentsSheetTabProvider), AgentsTab.connect);
      },
    );
  });

  // ================================================================ AC 11b
  group('nothing overflows (AC11)', () {
    const configs = [
      (Size(752, 800), 1.5, 'a 752 window (720 sheet) at 1.5x'),
      (Size(672, 800), 1.5, 'a 672 window (640 sheet) at 1.5x'),
      (Size(480, 800), 1.0, 'a 480 window at 1x'),
      (Size(480, 800), 1.5, 'a 480 window at 1.5x'),
    ];

    AgentActivityView longView() => _view(
      connected: [
        ConnectedAgent(
          presence: agentPresence(
            sessionId: _sessionA,
            clientName: 'claude-desktop-with-an-unusually-long-client-name',
            clientVersion: '10.20.30-beta.4',
            transport: 'bridge',
            startedAt: _ago(const Duration(days: 12)),
            lastToolAt: _ago(const Duration(seconds: 2)),
            embeddings: true,
          ),
          working: true,
        ),
        _idle(),
      ],
      recent: [
        for (var i = 0; i < 20; i++)
          agentEntry(
            id: '01JAGENTENTRY00000000000$i',
            clientName: 'a-very-long-client-name-for-the-column',
            summary:
                'filed 4 blocks into a note with a really long long long '
                'name and then moved it to a folder with an equally long name',
            createdAt: _ago(Duration(minutes: i * 90)),
          ),
      ],
    );

    testWidgets(
      'connected cards and recent writes do not overflow at the design sizes',
      (tester) async {
        for (final (size, scale, label) in configs) {
          final s = await _openLive(
            tester,
            longView(),
            size: size,
            textScale: scale,
          );
          expect(_key('live-agent-card-1'), findsOneWidget, reason: label);
          expect(_key('live-recent-row-19'), findsOneWidget, reason: label);
          expect(tester.takeException(), isNull, reason: label);
          expect(s, isNotNull);
        }
      },
    );

    testWidgets('the no agents state does not overflow at the design sizes', (
      tester,
    ) async {
      for (final (size, scale, label) in configs) {
        await _openLive(
          tester,
          _view(
            recent: [
              agentEntry(
                clientName: 'a-very-long-client-name-for-the-column',
                createdAt: _ago(const Duration(days: 4)),
              ),
            ],
          ),
          size: size,
          textScale: scale,
        );
        expect(_t('No agents connected'), findsOneWidget, reason: label);
        expect(_key('live-set-up-agent'), findsOneWidget, reason: label);
        expect(tester.takeException(), isNull, reason: label);
      }
    });

    testWidgets(
      'the older server state does not overflow at the design sizes',
      (tester) async {
        for (final (size, scale, label) in configs) {
          await _openLive(
            tester,
            _view(available: false),
            size: size,
            textScale: scale,
          );
          expect(
            _t('Agent activity unavailable on this vault server'),
            findsOneWidget,
            reason: label,
          );
          expect(tester.takeException(), isNull, reason: label);
        }
      },
    );
  });

  // ====================================== implementer calls pinned (verify)
  group('implementer calls (verify)', () {
    const explainer =
        'The newest writes by any agent. Summaries name notes and folders, '
        'never your text.';

    testWidgets(
      'connected agents with empty recent keep Recent writes with the explainer and no rows',
      (tester) async {
        await _openLive(tester, _view(connected: [_working(), _idle()]));

        expect(_key('live-agent-card-0'), findsOneWidget);
        expect(_t('RECENT WRITES'), findsOneWidget);
        expect(_t(explainer), findsOneWidget);
        expect(_key('live-recent-row-0'), findsNothing);
        expect(_t('No agents connected'), findsNothing);
        expect(
          _t('No agent writes recorded for this vault yet.'),
          findsNothing,
        );

        // The section sits under the last card with the 18 px gap.
        final card = _rect(tester, _key('live-agent-card-1'));
        final label = _rect(tester, _t('RECENT WRITES'));
        expect(label.top - card.bottom, closeTo(18, 0.5));
      },
    );

    testWidgets(
      'connected agents with empty recent keep Recent writes on the narrow layout',
      (tester) async {
        await _openLive(
          tester,
          _view(connected: [_working()]),
          size: const Size(640, 800),
        );

        expect(_t('RECENT WRITES'), findsOneWidget);
        expect(_t(explainer), findsOneWidget);
        expect(_key('live-recent-row-0'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('a client with a blank version omits the v prefix part', (
      tester,
    ) async {
      final agent = ConnectedAgent(
        presence: agentPresence(
          clientVersion: '',
          transport: 'stdio',
          startedAt: _ago(const Duration(hours: 5)),
          embeddings: true,
        ),
        working: false,
      );
      await _openLive(tester, _view(connected: [agent]));

      expect(_t('stdio · connected 5h · semantic recall on'), findsOneWidget);
      expect(find.textContaining('v · '), findsNothing);
      expect(find.textContaining(RegExp(r'^v ')), findsNothing);
    });

    testWidgets('a connect age under 60 seconds reads connected now', (
      tester,
    ) async {
      final agent = ConnectedAgent(
        presence: agentPresence(
          clientVersion: null,
          transport: 'stdio',
          startedAt: _ago(const Duration(seconds: 30)),
          embeddings: false,
        ),
        working: false,
      );
      await _openLive(tester, _view(connected: [agent]));

      expect(_t('stdio · connected now · keyword search only'), findsOneWidget);
    });

    testWidgets('the recent time column grows for a long age on one line', (
      tester,
    ) async {
      await _openLive(
        tester,
        _view(
          connected: [_working()],
          recent: [
            agentEntry(
              id: '01JAGENTENTRY0000000000B1',
              clientName: 'claude-code',
              summary: 'short age',
              createdAt: _ago(const Duration(seconds: 30)),
            ),
            agentEntry(
              id: '01JAGENTENTRY0000000000B2',
              clientName: 'claude-code',
              summary: 'long age',
              createdAt: _ago(const Duration(days: 150)),
            ),
          ],
        ),
      );

      Finder age(int row, String text) => find.descendant(
        of: _key('live-recent-row-$row'),
        matching: find.text(text),
      );
      final short = _rect(tester, age(0, 'now'));
      final long = _rect(tester, age(1, '150d'));
      expect(short.width, 34, reason: 'a short age keeps the 34 px column');
      expect(long.width, greaterThan(34), reason: 'a long age widens it');
      expect(long.height, short.height, reason: 'one line, never wrapped');
      expect(
        _rect(tester, _key('live-recent-row-1')).right,
        long.right,
        reason: 'the time column sits at the row end',
      );
      expect(tester.takeException(), isNull);
    });

    for (final (name, size) in [
      (
        'the Recent writes block spacing after cards is 18 8 and 6 wide',
        const Size(1000, 800),
      ),
      (
        'the Recent writes block spacing after cards is 18 8 and 6 narrow',
        const Size(640, 800),
      ),
    ]) {
      testWidgets(name, (tester) async {
        await _openLive(
          tester,
          _view(connected: [_working(), _idle()], recent: _threeEntries()),
          size: size,
        );

        final lastCard = _rect(tester, _key('live-agent-card-1'));
        final labelRect = _rect(tester, _t('RECENT WRITES'));
        final explainerRect = _rect(tester, _t(explainer));
        final row0 = _rect(tester, _key('live-recent-row-0'));
        expect(labelRect.top - lastCard.bottom, 18);
        expect(explainerRect.top - labelRect.bottom, 8);
        expect(row0.top - explainerRect.bottom, 6);
      });
    }

    testWidgets('the no agents block spacing is 6 12 and 22', (tester) async {
      await _openLive(tester, _view(recent: _threeEntries()));

      final heading = _rect(tester, _t('No agents connected'));
      final line = _rect(
        tester,
        find.descendant(
          of: find.byType(LiveTab),
          matching: find.textContaining('Last agent write'),
        ),
      );
      final button = _rect(tester, _key('live-set-up-agent'));
      final label = _rect(tester, _t('RECENT WRITES'));
      expect(line.top - heading.bottom, 6);
      expect(button.top - line.bottom, 12);
      expect(label.top - button.bottom, 22);
    });

    testWidgets('narrow connected rows are 6 apart and wide cards 8', (
      tester,
    ) async {
      await _openLive(
        tester,
        _view(connected: [_working(), _idle()]),
        size: const Size(640, 800),
      );
      var a = _rect(tester, _key('live-agent-card-0'));
      var b = _rect(tester, _key('live-agent-card-1'));
      expect(b.top - a.bottom, 6);

      await _openLive(
        tester,
        _view(connected: [_working(), _idle()]),
        size: const Size(1000, 800),
      );
      a = _rect(tester, _key('live-agent-card-0'));
      b = _rect(tester, _key('live-agent-card-1'));
      expect(b.top - a.bottom, 8);
    });
  });
}
