// WI #456 (390-A5): the sidebar's live agents footer (#390 req 18-29, D13).
//
// AgentFooter is a public ConsumerWidget in widgets/agents/agent_footer.dart
// that watches agentActivityAsyncProvider. These tests drive it through the
// real provider (A4) over FakeAgentsAccess and a FakeClock, so no wall time
// and no real timer is involved: every wait is a FakeClock.advance plus a
// pump. The height contract (the pane above stays >= 120 px) is pinned on
// the real Sidebar inside the whole app (pumpWorkspace) with a fixed view.
//
// Text finders match the frozen Keys and copy of the WI body: the name, the
// status, the age and the summary are separate Text widgets inside their
// keyed row.
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/agent_activity.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/theme/app_theme.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/vault_access/agents_access.dart';
import 'package:open_memex_app/src/widgets/agents/agent_footer.dart';
import 'package:open_memex_app/src/widgets/atoms.dart';
import 'package:open_memex_app/src/widgets/sidebar.dart';
import 'package:open_memex_app/src/widgets/sidebar/days_pane.dart';

import '../support/agents_fakes.dart';
import '../support/app_harness.dart';
import '../support/fake_clock.dart';
import '../support/font_fetch_hold.dart';

const _vaultB = LocalVaultRef('/fake/om-456-vault-b');

// ---------------------------------------------------------------------------
// Builders
// ---------------------------------------------------------------------------

/// Far enough ahead that no test's clock steps expire a presence by accident.
int get _long => agentsT0 + 3600000;

/// A connected agent named [name] in session [session], idle (last request
/// [idleMs] ago) unless [workingMs] says a tool call that long ago.
AgentPresence _agent(
  String name, {
  String? session,
  int idleMs = 0,
  int? workingMs,
  int? expiresAt,
}) => agentPresence(
  sessionId: session ?? 'S-456-$name',
  clientName: name,
  lastRequestAt: agentsT0 - idleMs,
  lastToolAt: workingMs == null ? null : agentsT0 - workingMs,
  expiresAt: expiresAt ?? _long,
);

/// An activity entry written [agoMs] before the clock's start.
AgentActivityEntry _entry(
  String id,
  String summary, {
  String client = 'claude-code',
  String? session,
  int agoMs = 0,
}) => agentEntry(
  id: id,
  summary: summary,
  clientName: client,
  sessionId: session ?? 'S-456-$client',
  createdAt: agentsT0 - agoMs,
);

AgentActivity _act({
  List<AgentPresence> agents = const [],
  List<AgentActivityEntry> recent = const [],
  bool available = true,
}) => AgentActivity(agents: agents, recent: recent, available: available);

/// [n] idle agents alpha, bravo, carol, delta ... by recency (alpha first).
List<AgentPresence> _agents(int n) => [
  for (var i = 0; i < n; i++)
    _agent(
      const ['alpha', 'bravo', 'carol', 'delta', 'echo'][i],
      idleMs: i * 1000,
    ),
];

/// [n] entries from [client] (session [session]), newest first.
List<AgentActivityEntry> _entries(
  int n, {
  String client = 'claude-code',
  String? session,
}) => [
  for (var i = 0; i < n; i++)
    _entry(
      'E-456-$i',
      'summary number $i',
      client: client,
      session: session,
      agoMs: i * 1000,
    ),
];

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

class _Env {
  _Env(this.tester, this.clock, this.access);

  final WidgetTester tester;
  final FakeClock clock;
  final FakeAgentsAccess access;

  ProviderContainer get container =>
      ProviderScope.containerOf(tester.element(find.byType(AgentFooter)));

  /// Lets reads and rebuilds land.
  Future<void> settle() async {
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
  }

  /// Moves the clock by [by] in 2 s steps (the presence tick), settling
  /// after each.
  Future<void> advance(Duration by) async {
    var left = by;
    while (left > Duration.zero) {
      final step = Duration(
        microseconds: min(
          left.inMicroseconds,
          const Duration(seconds: 2).inMicroseconds,
        ),
      );
      clock.advance(step);
      left -= step;
      await settle();
    }
  }
}

/// The harness width at [scale]: the test font draws every glyph 1em wide,
/// about 1.6 times the real mono font, so the header (eyebrow, dot and OPEN
/// API) needs more than the sidebar's 268 px to lay out at scale 1.0 and up.
double _width(double scale) => 300 * scale + 150;

/// Pumps [AgentFooter] alone, [_width] px wide (the sidebar's 268 px in the
/// real font), in a window
/// [height] tall at text scale [scale], over the real A4 provider and a
/// FakeAgentsAccess scripted with [script]. [hold] parks the first read.
Future<_Env> _pump(
  WidgetTester tester, {
  List<Object> script = const [],
  double scale = 1.0,
  double height = 900,
  bool hold = false,
  double? maxHeight,
  double? width,
}) async {
  tester.view.physicalSize = Size(1200, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final clock = FakeClock();
  final access = FakeAgentsAccess(script: script);
  if (hold) access.holdNextRead();
  await tester.pumpWidget(
    ProviderScope(
      overrides: agentsOverrides(access: access, clock: clock),
      child: MaterialApp(
        theme: buildOmTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
          backgroundColor: OmColors.surface1,
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width ?? _width(scale),
              // A bounded, loose parent that is not a Column: the footer's
              // budget is this box's height.
              child: maxHeight == null
                  ? const AgentFooter()
                  : ConstrainedBox(
                      constraints: BoxConstraints(maxHeight: maxHeight),
                      child: const AgentFooter(),
                    ),
            ),
          ),
        ),
      ),
    ),
  );
  final env = _Env(tester, clock, access);
  await env.settle();
  return env;
}

// ---------------------------------------------------------------------------
// Finders and probes
// ---------------------------------------------------------------------------

Finder _key(String k) => find.byKey(Key(k));

/// [text] inside the keyed box [k] (or the box itself).
Finder _in(String k, Finder matching) =>
    find.descendant(of: _key(k), matching: matching, matchRoot: true);

Finder _textIn(String k, String text) => _in(k, find.text(text));

Finder _rows(String prefix) => find.byWidgetPredicate(
  (w) =>
      w.key is ValueKey<String> &&
      (w.key! as ValueKey<String>).value.startsWith(prefix),
);

Finder get _agentRows => _rows('agent-footer-agent-');
Finder get _activityRows => _rows('agent-footer-activity-');

/// Every Text under the keyed box [k], joined with a space.
String _plain(WidgetTester tester, String k) => tester
    .widgetList<Text>(
      find.descendant(
        of: _key(k),
        matching: find.byType(Text),
        matchRoot: true,
      ),
    )
    .map((w) => w.data ?? w.textSpan?.toPlainText() ?? '')
    .join(' ');

TextStyle _style(WidgetTester tester, Finder text) {
  expect(text, findsOneWidget);
  final style = tester.widget<Text>(text).style;
  expect(style, isNotNull, reason: 'the Text carries its own style');
  return style!;
}

/// The footer's one Semantics label.
String _label(WidgetTester tester) {
  expect(_key('agent-footer'), findsOneWidget);
  return tester.getSemantics(_key('agent-footer')).getSemanticsData().label;
}

/// Every non-empty semantics label in the app.
List<String> _allLabels(WidgetTester tester) {
  final out = <String>[];
  void visit(SemanticsNode n) {
    final l = n.getSemanticsData().label;
    if (l.isNotEmpty) out.add(l);
    n.visitChildren((c) {
      visit(c);
      return true;
    });
  }

  visit(
    tester.binding.renderViews.first.owner!.semanticsOwner!.rootSemanticsNode!,
  );
  return out;
}

OmDot _dot(WidgetTester tester) {
  final dot = find.descendant(
    of: _key('agent-footer-dot'),
    matching: find.byType(OmDot),
    matchRoot: true,
  );
  expect(dot, findsOneWidget);
  return tester.widget<OmDot>(dot);
}

void _expectHeaderOnly(WidgetTester tester) {
  expect(find.text('AGENTS · LIVE'), findsOneWidget);
  expect(_key('agent-footer-open'), findsOneWidget);
  expect(_agentRows, findsNothing);
  expect(_activityRows, findsNothing);
  expect(_key('agent-footer-more'), findsNothing);
  expect(_key('agent-footer-empty'), findsNothing);
  expect(_key('agent-footer-last-write'), findsNothing);
  expect(_key('agent-footer-unavailable'), findsNothing);
  expect(find.textContaining('no agents connected'), findsNothing);
  expect(find.textContaining('wire memex serve'), findsNothing);
  expect(find.textContaining('unavailable'), findsNothing);
}

void main() {
  holdFontFetches();

  // -------------------------------------------------------------------------
  group('loading (AC1)', () {
    testWidgets(
      'before the first read lands only the header shows and no no agents connected text flashes',
      (tester) async {
        final env = await _pump(tester, hold: true);
        expect(env.access.holding, isTrue);

        expect(_key('agent-footer'), findsOneWidget);
        _expectHeaderOnly(tester);
        expect(_label(tester), 'Agents.');

        env.access.release();
        await env.settle();
        expect(_key('agent-footer-empty'), findsOneWidget);
      },
    );

    testWidgets(
      'after a vault switch with the new read held the footer is header only and shows none of the old agent rows',
      (tester) async {
        final env = await _pump(
          tester,
          script: [
            _act(agents: [_agent('alpha')], recent: _entries(1)),
          ],
        );
        expect(_agentRows, findsOneWidget);
        expect(_textIn('agent-footer-agent-0', 'alpha'), findsOneWidget);

        env.access
          ..holdNextRead()
          ..answer(_act(agents: [_agent('bravo')]));
        env.container.read(currentVaultProvider.notifier).state = _vaultB;
        await env.settle();

        expect(env.access.holding, isTrue, reason: 'the new vault is read');
        _expectHeaderOnly(tester);
        expect(find.text('alpha'), findsNothing);
        expect(find.textContaining('summary number'), findsNothing);

        env.access.release();
        await env.settle();
        expect(_textIn('agent-footer-agent-0', 'bravo'), findsOneWidget);
        expect(find.text('alpha'), findsNothing);
      },
    );
  });

  // -------------------------------------------------------------------------
  group('disconnected (AC2, AC3)', () {
    testWidgets(
      'disconnected with an empty recent shows no agents connected and the two hint lines in fg2 and no last agent write',
      (tester) async {
        await _pump(tester, script: [_act()]);

        expect(find.text('AGENTS · LIVE'), findsOneWidget);
        expect(_agentRows, findsNothing);
        expect(_activityRows, findsNothing);
        expect(_key('agent-footer-last-write'), findsNothing);
        expect(find.textContaining('last agent write'), findsNothing);
        expect(
          _textIn('agent-footer-empty', 'no agents connected'),
          findsOneWidget,
        );
        expect(
          _style(
            tester,
            _textIn('agent-footer-empty', 'no agents connected'),
          ).color,
          OmColors.fg2,
        );
        final hint1 = find.textContaining(
          'wire memex serve into Claude Desktop',
        );
        final hint2 = find.textContaining('to see live activity here');
        expect(hint1, findsOneWidget);
        expect(hint2, findsOneWidget);
        expect(_style(tester, hint1).color, OmColors.fg2);
        expect(_style(tester, hint2).color, OmColors.fg2);
        expect(_style(tester, hint1).fontSize, 10.5);
      },
    );

    for (final c in <(String, int, String)>[
      (
        'disconnected with a newest entry 3 minutes old shows last agent write 3m ago',
        180000,
        'last agent write 3m ago',
      ),
      (
        'disconnected with a newest entry 20 seconds old shows last agent write just now',
        20000,
        'last agent write just now',
      ),
      (
        'disconnected with a newest entry 2 hours old shows last agent write 2h ago',
        7200000,
        'last agent write 2h ago',
      ),
      (
        'disconnected with a newest entry 3 days old shows last agent write 3d ago',
        3 * 86400000,
        'last agent write 3d ago',
      ),
    ]) {
      testWidgets(c.$1, (tester) async {
        await _pump(
          tester,
          script: [
            _act(
              recent: [
                _entry('E-456-NEW', 'newest', agoMs: c.$2),
                _entry('E-456-OLD', 'older', agoMs: c.$2 + 9000000),
              ],
            ),
          ],
        );

        final line = _textIn('agent-footer-last-write', c.$3);
        expect(line, findsOneWidget);
        expect(_style(tester, line).color, OmColors.fg2);
        expect(
          _textIn('agent-footer-empty', 'no agents connected'),
          findsOneWidget,
        );
        expect(
          _activityRows,
          findsNothing,
          reason: 'no feed rows with no agents',
        );
      });
    }

    testWidgets(
      'advancing past expiry shows no agents connected with last agent write and the agent row goes',
      (tester) async {
        final env = await _pump(
          tester,
          script: [
            _act(
              agents: [_agent('alpha', expiresAt: agentsT0 + 15000)],
              recent: [
                _entry('E-456-0', 'filed one', client: 'alpha', agoMs: 180000),
              ],
            ),
          ],
        );
        expect(_agentRows, findsOneWidget);
        expect(_key('agent-footer-empty'), findsNothing);

        await env.advance(const Duration(seconds: 16));

        expect(_agentRows, findsNothing);
        expect(_activityRows, findsNothing);
        expect(_key('agent-footer-empty'), findsOneWidget);
        expect(
          _textIn('agent-footer-last-write', 'last agent write 3m ago'),
          findsOneWidget,
        );
      },
    );
  });

  // -------------------------------------------------------------------------
  group('connected agent rows (AC4)', () {
    testWidgets(
      'a working agent shows its name in fg1 and working in the agent colour and no idle text',
      (tester) async {
        await _pump(
          tester,
          script: [
            _act(agents: [_agent('claude-code', workingMs: 2000)]),
          ],
        );

        expect(_agentRows, findsOneWidget);
        final name = _textIn('agent-footer-agent-0', 'claude-code');
        final working = _textIn('agent-footer-agent-0', 'working');
        expect(_style(tester, name).color, OmColors.fg1);
        expect(_style(tester, name).fontSize, 10.5);
        expect(_style(tester, working).color, OmColors.agent);
        expect(_style(tester, working).fontSize, 10.5);
        expect(find.textContaining('idle'), findsNothing);
        expect(_key('agent-footer-empty'), findsNothing);
      },
    );

    testWidgets(
      'an idle agent whose last request was 5 minutes ago shows idle with the age in fg2 and not working',
      (tester) async {
        await _pump(
          tester,
          script: [
            _act(agents: [_agent('codex', idleMs: 300000)]),
          ],
        );

        final idle = _textIn('agent-footer-agent-0', 'idle · 5m');
        expect(_style(tester, idle).color, OmColors.fg2);
        expect(_style(tester, idle).fontSize, 10.5);
        expect(
          _style(tester, _textIn('agent-footer-agent-0', 'codex')).color,
          OmColors.fg1,
        );
        expect(find.text('working'), findsNothing);
      },
    );

    testWidgets(
      'an agent whose request is under a minute old shows idle · now and a request alone never shows working',
      (tester) async {
        await _pump(
          tester,
          script: [
            _act(agents: [_agent('codex', idleMs: 3000)]),
          ],
        );
        expect(_textIn('agent-footer-agent-0', 'idle · now'), findsOneWidget);
        expect(find.text('working'), findsNothing);
      },
    );

    testWidgets(
      'the working status turns to idle 10 s after the last tool call as the tick re-derives it',
      (tester) async {
        final env = await _pump(
          tester,
          script: [
            _act(agents: [_agent('codex', workingMs: 2000)]),
          ],
        );
        expect(_textIn('agent-footer-agent-0', 'working'), findsOneWidget);

        await env.advance(const Duration(seconds: 12));

        expect(find.text('working'), findsNothing);
        expect(_textIn('agent-footer-agent-0', 'idle · now'), findsOneWidget);
      },
    );

    testWidgets('ages update on the presence tick', (tester) async {
      final env = await _pump(
        tester,
        script: [
          _act(
            agents: [_agent('codex', idleMs: 300000)],
            recent: [
              _entry('E-456-0', 'filed one', client: 'codex', agoMs: 1000),
            ],
          ),
        ],
      );
      expect(_textIn('agent-footer-agent-0', 'idle · 5m'), findsOneWidget);
      expect(_textIn('agent-footer-activity-0', 'now'), findsOneWidget);

      await env.advance(const Duration(minutes: 2));

      expect(_textIn('agent-footer-agent-0', 'idle · 7m'), findsOneWidget);
      expect(_textIn('agent-footer-activity-0', '2m'), findsOneWidget);
    });

    testWidgets(
      'agent rows follow the order of the connected list and carry the name',
      (tester) async {
        await _pump(tester, script: [_act(agents: _agents(3))]);

        for (final (i, name) in ['alpha', 'bravo', 'carol'].indexed) {
          expect(
            _textIn('agent-footer-agent-$i', name),
            findsOneWidget,
            reason: 'row $i',
          );
        }
      },
    );
  });

  // -------------------------------------------------------------------------
  group('row limits (AC5, AC9, AC14)', () {
    for (final c in <(String, int, double, int, String?)>[
      // name, agents, scale, agent rows shown, more text
      (
        'with 4 connected agents at text scale 1.0 3 agent rows show and the more line reads +1 more',
        4,
        1.0,
        3,
        '+1 more',
      ),
      (
        'with 3 connected agents at text scale 1.0 3 agent rows show and no more line',
        3,
        1.0,
        3,
        null,
      ),
      (
        'with 2 connected agents at text scale 1.0 2 agent rows show and no more line',
        2,
        1.0,
        2,
        null,
      ),
      (
        'with 5 connected agents at text scale 1.0 3 agent rows show and the more line reads +2 more',
        5,
        1.0,
        3,
        '+2 more',
      ),
      (
        'with 4 connected agents at text scale 1.3 2 agent rows show and the more line reads +2 more',
        4,
        1.3,
        2,
        '+2 more',
      ),
      (
        'with 3 connected agents at text scale 1.3 2 agent rows show and the more line reads +1 more',
        3,
        1.3,
        2,
        '+1 more',
      ),
      (
        'with 2 connected agents at text scale 1.3 2 agent rows show and no more line',
        2,
        1.3,
        2,
        null,
      ),
      (
        'with 1 connected agents at text scale 1.3 1 agent rows show and no more line',
        1,
        1.3,
        1,
        null,
      ),
      (
        'with 4 connected agents at text scale 2.0 2 agent rows show and the more line reads +2 more',
        4,
        2.0,
        2,
        '+2 more',
      ),
    ]) {
      testWidgets(c.$1, (tester) async {
        await _pump(
          tester,
          scale: c.$3,
          script: [_act(agents: _agents(c.$2))],
        );

        expect(_agentRows, findsNWidgets(c.$4));
        for (var i = 0; i < c.$4; i++) {
          expect(_key('agent-footer-agent-$i'), findsOneWidget);
        }
        final more = c.$5;
        if (more == null) {
          expect(_key('agent-footer-more'), findsNothing);
        } else {
          expect(_textIn('agent-footer-more', more), findsOneWidget);
          expect(
            _style(tester, _textIn('agent-footer-more', more)).color,
            OmColors.fg2,
          );
        }
      });
    }

    for (final c in <(String, int, double, int)>[
      // name, entries, scale, activity rows shown
      (
        'with 5 entries at text scale 1.0 3 activity rows show newest first',
        5,
        1.0,
        3,
      ),
      (
        'with 3 entries at text scale 1.0 3 activity rows show newest first',
        3,
        1.0,
        3,
      ),
      (
        'with 2 entries at text scale 1.0 2 activity rows show newest first',
        2,
        1.0,
        2,
      ),
      (
        'with 1 entries at text scale 1.0 1 activity rows show newest first',
        1,
        1.0,
        1,
      ),
      (
        'with 5 entries at text scale 1.3 2 activity rows show newest first',
        5,
        1.3,
        2,
      ),
      (
        'with 2 entries at text scale 1.3 2 activity rows show newest first',
        2,
        1.3,
        2,
      ),
      (
        'with 1 entries at text scale 1.3 1 activity rows show newest first',
        1,
        1.3,
        1,
      ),
    ]) {
      testWidgets(c.$1, (tester) async {
        await _pump(
          tester,
          scale: c.$3,
          script: [
            _act(agents: [_agent('claude-code')], recent: _entries(c.$2)),
          ],
        );

        expect(_activityRows, findsNWidgets(c.$4));
        for (var i = 0; i < c.$4; i++) {
          expect(
            _textIn('agent-footer-activity-$i', 'summary number $i'),
            findsOneWidget,
            reason: 'row $i holds entry $i',
          );
        }
      });
    }

    testWidgets(
      'an activity row shows the summary in fg2 and its age right aligned',
      (tester) async {
        await _pump(
          tester,
          script: [
            _act(
              agents: [_agent('claude-code')],
              recent: [
                _entry('E-456-0', 'short', agoMs: 1000),
                _entry('E-456-1', 'older', agoMs: 180000),
                _entry('E-456-2', 'oldest', agoMs: 7200000),
              ],
            ),
          ],
        );

        for (final (i, age) in ['now', '3m', '2h'].indexed) {
          final row = tester.getRect(_key('agent-footer-activity-$i'));
          final ageText = _textIn('agent-footer-activity-$i', age);
          final summary = _textIn(
            'agent-footer-activity-$i',
            ['short', 'older', 'oldest'][i],
          );
          expect(ageText, findsOneWidget, reason: 'row $i age');
          expect(summary, findsOneWidget);
          final ageRect = tester.getRect(ageText);
          expect(ageRect.right, lessThanOrEqualTo(row.right + 0.01));
          expect(ageRect.right, greaterThanOrEqualTo(row.right - 12));
          expect(ageRect.left, greaterThan(tester.getRect(summary).left));
          expect(_style(tester, ageText).color, OmColors.fg2);
          expect(_style(tester, summary).color, OmColors.fg2);
          expect(_style(tester, summary).fontSize, 10.5);
        }
      },
    );

    testWidgets(
      'a long summary ellipsizes on one line and the row is as tall as a short one',
      (tester) async {
        final long =
            'filed a very long summary of everything the agent did ' * 3;
        await _pump(
          tester,
          script: [
            _act(
              agents: [_agent('claude-code')],
              recent: [
                _entry('E-456-0', long, agoMs: 1000),
                _entry('E-456-1', 'ok', agoMs: 2000),
              ],
            ),
          ],
        );

        final summary = _textIn('agent-footer-activity-0', long);
        expect(summary, findsOneWidget);
        final paragraph = tester.renderObject<RenderParagraph>(summary);
        expect(paragraph.didExceedMaxLines, isTrue, reason: 'ellipsized');
        expect(
          tester.getSize(_key('agent-footer-activity-0')).height,
          tester.getSize(_key('agent-footer-activity-1')).height,
          reason: 'one line like the short row',
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('a long agent name ellipsizes without overflow', (
      tester,
    ) async {
      await _pump(
        tester,
        script: [
          _act(
            agents: [_agent('an-agent-client-with-a-very-long-name-indeed')],
          ),
        ],
      );
      expect(_agentRows, findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  // -------------------------------------------------------------------------
  group('feed prefix (AC6, AC7, AC8)', () {
    Future<void> pumpWith(
      WidgetTester tester, {
      required List<AgentPresence> agents,
      required List<AgentActivityEntry> recent,
      double scale = 1.0,
    }) async {
      await _pump(
        tester,
        scale: scale,
        script: [_act(agents: agents, recent: recent)],
      );
    }

    void expectUnprefixed(WidgetTester tester, int rows) {
      expect(_activityRows, findsNWidgets(rows));
      for (var i = 0; i < rows; i++) {
        final text = _plain(tester, 'agent-footer-activity-$i');
        expect(text, contains('summary number $i'));
        expect(text, isNot(contains('alpha')), reason: 'row $i unprefixed');
        expect(text, isNot(contains('gone')), reason: 'row $i unprefixed');
      }
    }

    void expectPrefixed(WidgetTester tester, List<String> clients) {
      expect(_activityRows, findsNWidgets(clients.length));
      for (final (i, client) in clients.indexed) {
        final text = _plain(tester, 'agent-footer-activity-$i');
        expect(text, contains(client), reason: 'row $i prefixed');
        expect(
          text.indexOf(client),
          lessThan(text.indexOf('summary number $i')),
        );
      }
    }

    testWidgets(
      'one connected agent and entries all from its session show unprefixed activity rows',
      (tester) async {
        await pumpWith(
          tester,
          agents: [_agent('alpha')],
          recent: _entries(3, client: 'alpha'),
        );
        expectUnprefixed(tester, 3);
      },
    );

    testWidgets(
      'one connected agent plus an entry from a gone session prefixes every activity row with its client name',
      (tester) async {
        await pumpWith(
          tester,
          agents: [_agent('alpha')],
          recent: [
            _entry('E-456-0', 'summary number 0', client: 'alpha', agoMs: 0),
            _entry('E-456-1', 'summary number 1', client: 'gone', agoMs: 1000),
            _entry('E-456-2', 'summary number 2', client: 'alpha', agoMs: 2000),
          ],
        );
        expectPrefixed(tester, ['alpha', 'gone', 'alpha']);
      },
    );

    testWidgets(
      'two connected agents and entries all from one of them prefix every activity row',
      (tester) async {
        await pumpWith(
          tester,
          agents: [_agent('alpha'), _agent('bravo', idleMs: 1000)],
          recent: _entries(3, client: 'alpha'),
        );
        expectPrefixed(tester, ['alpha', 'alpha', 'alpha']);
      },
    );

    testWidgets(
      'a fourth entry from a gone session that is not shown does not prefix the three shown rows',
      (tester) async {
        await pumpWith(
          tester,
          agents: [_agent('alpha')],
          recent: [
            ..._entries(3, client: 'alpha'),
            _entry('E-456-3', 'summary number 3', client: 'gone', agoMs: 5000),
          ],
        );
        expectUnprefixed(tester, 3);
      },
    );

    testWidgets(
      'at text scale 1.3 a third entry from a gone session that is not shown does not prefix the two shown rows',
      (tester) async {
        await pumpWith(
          tester,
          scale: 1.3,
          agents: [_agent('alpha')],
          recent: [
            ..._entries(2, client: 'alpha'),
            _entry('E-456-2', 'summary number 2', client: 'gone', agoMs: 5000),
          ],
        );
        expectUnprefixed(tester, 2);
      },
    );

    testWidgets(
      'one connected agent whose session differs from every entry prefixes each row',
      (tester) async {
        await pumpWith(
          tester,
          agents: [_agent('alpha')],
          recent: _entries(2, client: 'gone'),
        );
        expectPrefixed(tester, ['gone', 'gone']);
      },
    );

    testWidgets(
      'one connected agent restarted into a new session prefixes entries of the old session with the same client name',
      (tester) async {
        await pumpWith(
          tester,
          agents: [_agent('alpha', session: 'S-NEW')],
          recent: _entries(2, client: 'alpha', session: 'S-OLD'),
        );
        expectPrefixed(tester, ['alpha', 'alpha']);
      },
    );

    testWidgets(
      'one connected agent whose entries carry its own session id stays unprefixed even with a different client name on the entries',
      (tester) async {
        await pumpWith(
          tester,
          agents: [_agent('alpha', session: 'S-SAME')],
          recent: _entries(2, client: 'renamed', session: 'S-SAME'),
        );
        final text = _plain(tester, 'agent-footer-activity-0');
        expect(text, contains('summary number 0'));
        expect(text, isNot(contains('renamed')));
        expect(text, isNot(contains('alpha')));
      },
    );
  });

  // -------------------------------------------------------------------------
  group('unavailable (AC10)', () {
    testWidgets(
      'unavailable shows only the one line under the header in fg2 and no snackbar',
      (tester) async {
        await _pump(tester, script: [_act(available: false)]);

        final line = _textIn(
          'agent-footer-unavailable',
          'agent activity unavailable on this vault server',
        );
        expect(line, findsOneWidget);
        expect(_style(tester, line).color, OmColors.fg2);
        expect(find.text('AGENTS · LIVE'), findsOneWidget);
        expect(_agentRows, findsNothing);
        expect(_activityRows, findsNothing);
        expect(_key('agent-footer-empty'), findsNothing);
        expect(_key('agent-footer-last-write'), findsNothing);
        expect(find.textContaining('wire memex serve'), findsNothing);
        expect(find.byType(SnackBar), findsNothing);
        final dot = _dot(tester);
        expect(dot.pulse, isFalse);
        expect(dot.color, OmColors.fg3);
      },
    );

    testWidgets(
      'unavailable wins over any agents or entries the view still holds',
      (tester) async {
        await _pump(
          tester,
          script: [
            _act(
              available: false,
              agents: [_agent('alpha')],
              recent: _entries(2),
            ),
          ],
        );

        expect(_key('agent-footer-unavailable'), findsOneWidget);
        expect(_agentRows, findsNothing);
        expect(_activityRows, findsNothing);
      },
    );
  });

  // -------------------------------------------------------------------------
  group('error fallback (AC11)', () {
    testWidgets(
      'a failed first read shows the disconnected state with no error colour or exception text',
      (tester) async {
        final env = await _pump(
          tester,
          script: [Exception('boom secret trace')],
        );
        expect(env.access.reads, greaterThanOrEqualTo(1));

        expect(_key('agent-footer-empty'), findsOneWidget);
        expect(find.textContaining('wire memex serve'), findsOneWidget);
        expect(find.textContaining('boom'), findsNothing);
        expect(find.textContaining('Exception'), findsNothing);
        expect(find.byType(SnackBar), findsNothing);
        final colors = [
          for (final t in tester.widgetList<Text>(
            find.descendant(
              of: _key('agent-footer'),
              matching: find.byType(Text),
            ),
          ))
            t.style?.color,
        ];
        expect(colors, isNotEmpty);
        expect(colors, isNot(contains(OmColors.danger)));
        expect(colors, isNot(contains(OmColors.warn)));
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('a failing later read keeps showing the last good agents', (
      tester,
    ) async {
      final env = await _pump(
        tester,
        script: [
          _act(agents: [_agent('alpha')]),
          Exception('network down'),
        ],
      );
      await env.advance(const Duration(seconds: 6));

      expect(env.access.reads, greaterThan(1));
      expect(_textIn('agent-footer-agent-0', 'alpha'), findsOneWidget);
      expect(find.textContaining('network down'), findsNothing);
    });
  });

  // -------------------------------------------------------------------------
  group('header (AC12, AC13)', () {
    testWidgets(
      'the dot pulses in the agent colour with one connected agent and is a static fg3 dot with none',
      (tester) async {
        final env = await _pump(
          tester,
          script: [
            _act(agents: [_agent('alpha', expiresAt: agentsT0 + 15000)]),
          ],
        );
        var dot = _dot(tester);
        expect(dot.pulse, isTrue);
        expect(dot.color, OmColors.agent);
        expect(dot.size, 5);

        await env.advance(const Duration(seconds: 16));

        expect(_key('agent-footer-empty'), findsOneWidget);
        dot = _dot(tester);
        expect(dot.pulse, isFalse);
        expect(dot.color, OmColors.fg3);
      },
    );

    testWidgets(
      'the dot is static fg3 while the first read is loading and with an empty disconnected view',
      (tester) async {
        final env = await _pump(tester, hold: true, script: [_act()]);
        var dot = _dot(tester);
        expect(dot.pulse, isFalse);
        expect(dot.color, OmColors.fg3);

        env.access.release();
        await env.settle();
        dot = _dot(tester);
        expect(dot.pulse, isFalse);
        expect(dot.color, OmColors.fg3);
      },
    );

    testWidgets(
      'the header shows the AGENTS · LIVE eyebrow and OPEN API ↗ with no tap handler',
      (tester) async {
        await _pump(tester, script: [_act()]);

        expect(find.text('AGENTS · LIVE'), findsOneWidget);
        final open = _key('agent-footer-open');
        expect(open, findsOneWidget);
        final text = find.descendant(
          of: open,
          matching: find.text('OPEN ↗'),
          matchRoot: true,
        );
        expect(text, findsOneWidget);
        // The Key names the label's own text box.
        expect(tester.getRect(open), tester.getRect(text));
        final style = _style(tester, text);
        expect(style.fontSize, 10.5);
        expect(style.color, OmColors.fg2);
        expect(style.letterSpacing, 0.8);
        expect(style.height, 1.5);

        final footer = find.byType(AgentFooter);
        for (final t in [
          GestureDetector,
          InkResponse,
          MouseRegion,
          Focus,
          TextButton,
        ]) {
          // #408 (D13) makes agent-footer-open a link: its own subtree (from
          // its Tooltip down to the label) is excluded.
          final tooltip = find
              .ancestor(of: open, matching: find.byType(Tooltip))
              .first;
          // The excluded subtree is exactly the label's box (#408 r1 F2): it
          // cannot grow to the header row or the footer.
          expect(tester.getRect(tooltip), tester.getRect(open));
          final link = find
              .descendant(of: tooltip, matching: find.byType(t))
              .evaluate()
              .toSet();
          expect(
            find
                .descendant(of: footer, matching: find.byType(t))
                .evaluate()
                .where((e) => !link.contains(e)),
            isEmpty,
            reason: 'no $t in the footer outside agent-footer-open',
          );
        }
        await tester.tap(text);
        await tester.pump();
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'the header is the same with agents connected: the dot, the eyebrow and OPEN API ↗ share a row',
      (tester) async {
        await _pump(
          tester,
          script: [
            _act(agents: [_agent('alpha')]),
          ],
        );

        final eyebrow = tester.getRect(find.text('AGENTS · LIVE'));
        final dot = tester.getRect(_key('agent-footer-dot'));
        final open = tester.getRect(_key('agent-footer-open'));
        expect(dot.left, greaterThan(eyebrow.right - 0.01));
        expect(open.left, greaterThan(dot.right));
        expect((open.center.dy - eyebrow.center.dy).abs(), lessThan(4));
      },
    );
  });

  // -------------------------------------------------------------------------
  group('semantics (AC16)', () {
    testWidgets(
      'connected exposes one label with the example sentence and the rows add no nodes',
      (tester) async {
        await _pump(
          tester,
          script: [
            _act(
              agents: [
                _agent('alpha', workingMs: 2000),
                _agent('bravo', idleMs: 300000),
              ],
              recent: [
                _entry(
                  'E-456-0',
                  'filed 4 blocks → Rest & Recharge',
                  client: 'alpha',
                ),
              ],
            ),
          ],
        );

        const expected =
            '2 agents connected. alpha working. bravo idle, 5 minutes ago. '
            'Latest: filed 4 blocks to Rest & Recharge, just now';
        expect(_label(tester), expected);
        expect(tester.getSemantics(_key('agent-footer')).childrenCount, 0);
        expect(_allLabels(tester), [expected]);
        // The visible text keeps the arrow.
        expect(find.textContaining('→'), findsOneWidget);
      },
    );

    testWidgets(
      'one agent says 1 agent connected with its idle age and no Latest when there is no feed',
      (tester) async {
        await _pump(
          tester,
          script: [
            _act(agents: [_agent('codex', idleMs: 3600000)]),
          ],
        );

        expect(_label(tester), '1 agent connected. codex idle, 1 hour ago.');
        expect(_allLabels(tester), hasLength(1));
      },
    );

    testWidgets(
      'four connected agents say 4 agents connected and list only the three shown with Latest for the newest entry',
      (tester) async {
        await _pump(
          tester,
          script: [
            _act(
              agents: _agents(4),
              recent: [
                _entry('E-456-0', 'first summary', agoMs: 120000),
                _entry('E-456-1', 'second summary', agoMs: 240000),
              ],
            ),
          ],
        );

        expect(
          _label(tester),
          '4 agents connected. alpha idle, just now. bravo idle, just now. '
          'carol idle, just now. Latest: first summary, 2 minutes ago',
        );
      },
    );

    testWidgets('at text scale 1.3 the label lists only the two shown agents', (
      tester,
    ) async {
      await _pump(tester, scale: 1.3, script: [_act(agents: _agents(3))]);

      expect(
        _label(tester),
        '3 agents connected. alpha idle, just now. bravo idle, just now.',
      );
    });

    for (final c in <(String, List<AgentActivityEntry>, String)>[
      (
        'disconnected with an empty recent exposes the bare sentence',
        const [],
        'No agents connected.',
      ),
      (
        'disconnected with a 3 minute old entry exposes Last agent write 3 minutes ago',
        [_wi456Old(180000)],
        'No agents connected. Last agent write 3 minutes ago.',
      ),
      (
        'disconnected with a 20 second old entry exposes Last agent write just now',
        [_wi456Old(20000)],
        'No agents connected. Last agent write just now.',
      ),
      (
        'disconnected with a 1 hour old entry exposes Last agent write 1 hour ago',
        [_wi456Old(3600000)],
        'No agents connected. Last agent write 1 hour ago.',
      ),
      (
        'disconnected with a 2 day old entry exposes Last agent write 2 days ago',
        [_wi456Old(2 * 86400000)],
        'No agents connected. Last agent write 2 days ago.',
      ),
    ]) {
      testWidgets(c.$1, (tester) async {
        await _pump(tester, script: [_act(recent: c.$2)]);

        expect(_label(tester), c.$3);
        expect(tester.getSemantics(_key('agent-footer')).childrenCount, 0);
        expect(_allLabels(tester), [c.$3]);
      });
    }

    testWidgets(
      'unavailable exposes Agent activity unavailable on this vault server.',
      (tester) async {
        await _pump(tester, script: [_act(available: false)]);

        expect(
          _label(tester),
          'Agent activity unavailable on this vault server.',
        );
        expect(_allLabels(tester), hasLength(1));
      },
    );

    testWidgets('the label is rebuilt after the tick moves the ages', (
      tester,
    ) async {
      final env = await _pump(
        tester,
        script: [
          _act(agents: [_agent('codex', idleMs: 300000)]),
        ],
      );
      expect(_label(tester), '1 agent connected. codex idle, 5 minutes ago.');

      await env.advance(const Duration(minutes: 2));

      expect(_label(tester), '1 agent connected. codex idle, 7 minutes ago.');
    });
  });

  // -------------------------------------------------------------------------
  group('height (AC14, AC15)', () {
    testWidgets(
      'at text scale 1.0 with 4 agents and 3 long activity rows the footer stays within 180 px',
      (tester) async {
        await _pump(
          tester,
          script: [
            _act(
              agents: _agents(4),
              recent: [
                for (var i = 0; i < 4; i++)
                  _entry(
                    'E-456-$i',
                    'a very long summary text number $i that cannot fit',
                    client: 'gone',
                    agoMs: i * 1000,
                  ),
              ],
            ),
          ],
        );

        expect(_agentRows, findsNWidgets(3));
        expect(_activityRows, findsNWidgets(3));
        expect(
          tester.getSize(_key('agent-footer')).height,
          lessThanOrEqualTo(180),
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'at text scale 1.3 with 4 agents and 3 activity rows the footer shows 2 and 2 and stays within 180 px',
      (tester) async {
        await _pump(
          tester,
          scale: 1.3,
          script: [
            _act(
              agents: _agents(4),
              recent: [
                for (var i = 0; i < 4; i++)
                  _entry(
                    'E-456-$i',
                    'a very long summary text number $i that cannot fit',
                    client: 'gone',
                    agoMs: i * 1000,
                  ),
              ],
            ),
          ],
        );

        expect(_agentRows, findsNWidgets(2));
        expect(_textIn('agent-footer-more', '+2 more'), findsOneWidget);
        expect(_activityRows, findsNWidgets(2));
        expect(
          tester.getSize(_key('agent-footer')).height,
          lessThanOrEqualTo(180),
        );
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('budget (AC14, AC15)', () {
    // At scale 1.0: header 38.5 px, +8 gap, a row 15.75 px, a line 16.8 px,
    // +6 between the groups, +2 between disconnected lines.
    Future<void> pumpBudget(
      WidgetTester tester,
      double maxHeight, {
      required List<Object> script,
    }) async {
      await _pump(tester, script: script, maxHeight: maxHeight);
      expect(tester.takeException(), isNull);
      expect(
        tester.getSize(_key('agent-footer')).height,
        lessThanOrEqualTo(max(maxHeight, 38.5) + 0.01),
      );
    }

    final disconnected = [
      _act(recent: [_entry('E-456-D', 'old', agoMs: 180000)]),
    ];
    const hint1 = 'wire memex serve into Claude Desktop';
    const hint2 = 'to see live activity here';

    for (final c in <(String, double, bool, bool)>[
      (
        'disconnected with 81 px of room drops the last write line',
        81,
        false,
        false,
      ),
      (
        'disconnected with 84 px of room shows the last write line but no hint',
        84,
        true,
        false,
      ),
      (
        'disconnected with 116 px of room keeps the last write line and drops the hint',
        116,
        true,
        false,
      ),
      (
        'disconnected with 120 px of room shows the hint and the last write line',
        120,
        true,
        true,
      ),
    ]) {
      testWidgets(c.$1, (tester) async {
        await pumpBudget(tester, c.$2, script: disconnected);

        expect(find.text('AGENTS · LIVE'), findsOneWidget);
        expect(_key('agent-footer-empty'), findsOneWidget);
        expect(
          _key('agent-footer-last-write'),
          c.$3 ? findsOneWidget : findsNothing,
        );
        expect(find.text(hint1), c.$4 ? findsOneWidget : findsNothing);
        expect(find.text(hint2), c.$4 ? findsOneWidget : findsNothing);
      });
    }

    for (final c in <(String, double, int, int, int)>[
      // name, max height, agent rows, activity rows, more count
      (
        'connected with 170 px of room shows 3 agent rows 3 activity rows and +1 more',
        170,
        3,
        3,
        1,
      ),
      (
        'connected with 150 px of room drops an activity row first',
        150,
        3,
        2,
        1,
      ),
      ('connected with 140 px of room keeps one activity row', 140, 3, 1, 1),
      (
        'connected with 125 px of room drops every activity row before an agent row',
        125,
        3,
        0,
        1,
      ),
      (
        'connected with 100 px of room drops an agent row after the activity rows',
        100,
        2,
        0,
        2,
      ),
      (
        'connected with 80 px of room keeps one agent row and the more line',
        80,
        1,
        0,
        3,
      ),
    ]) {
      testWidgets(c.$1, (tester) async {
        await pumpBudget(
          tester,
          c.$2,
          script: [_act(agents: _agents(4), recent: _entries(3))],
        );

        expect(_agentRows, findsNWidgets(c.$3));
        expect(_activityRows, findsNWidgets(c.$4));
        expect(_textIn('agent-footer-more', '+${c.$5} more'), findsOneWidget);
      });
    }

    testWidgets(
      'disconnected with 60 px of room keeps the header without overflow',
      (tester) async {
        await _pump(tester, script: disconnected, maxHeight: 60);

        expect(find.text('AGENTS · LIVE'), findsOneWidget);
        expect(tester.takeException(), isNull);
        expect(
          tester.getSize(_key('agent-footer')).height,
          lessThanOrEqualTo(60.01),
        );
      },
    );

    testWidgets(
      'disconnected with 60 px of room drops the empty line the hint and the last write but keeps the label',
      (tester) async {
        await _pump(tester, script: disconnected, maxHeight: 60);

        _expectHeaderOnly(tester);
        expect(
          _label(tester),
          'No agents connected. Last agent write 3 minutes ago.',
        );
      },
    );

    // The unavailable line may take two lines (the copy is wider than the
    // sidebar), so whatever the budget, the footer must stay inside it.
    for (final c in <(String, double, bool)>[
      (
        'unavailable with 50 px of room drops its line and keeps the header and the label',
        50,
        false,
      ),
      ('unavailable with 64 px of room does not overflow', 64, false),
      ('unavailable with 70 px of room does not overflow', 70, false),
      ('unavailable with 80 px of room does not overflow', 80, false),
      (
        'unavailable with 180 px of room shows its line under the header',
        180,
        true,
      ),
    ]) {
      testWidgets(c.$1, (tester) async {
        await pumpBudget(tester, c.$2, script: [_act(available: false)]);

        expect(find.text('AGENTS · LIVE'), findsOneWidget);
        if (c.$3) {
          expect(_key('agent-footer-unavailable'), findsOneWidget);
        } else if (c.$2 < 60) {
          expect(_key('agent-footer-unavailable'), findsNothing);
        }
        expect(
          _label(tester),
          'Agent activity unavailable on this vault server.',
        );
        expect(_agentRows, findsNothing);
        expect(_activityRows, findsNothing);
      });
    }

    testWidgets(
      'connected with 50 px of room keeps the header and drops every row without overflow',
      (tester) async {
        await _pump(
          tester,
          script: [_act(agents: _agents(4), recent: _entries(3))],
          maxHeight: 50,
        );

        expect(find.text('AGENTS · LIVE'), findsOneWidget);
        expect(_agentRows, findsNothing);
        expect(_activityRows, findsNothing);
        expect(tester.takeException(), isNull);
        expect(
          tester.getSize(_key('agent-footer')).height,
          lessThanOrEqualTo(50.01),
        );
      },
    );

    testWidgets(
      'a provider error renders the header only and no error colour',
      (tester) async {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              agentActivityAsyncProvider.overrideWith(_Wi456Throws.new),
            ],
            child: MaterialApp(
              theme: buildOmTheme(),
              home: const Scaffold(
                body: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(width: 450, child: AgentFooter()),
                ),
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 10));
        await tester.pump(const Duration(milliseconds: 10));

        _expectHeaderOnly(tester);
        expect(_label(tester), 'Agents.');
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('in the sidebar (AC14, AC15, AC17)', () {
    /// Pumps the whole app with the real Sidebar over a fixed agents view
    /// and the window [height] tall at text scale [scale], collecting
    /// framework errors: the test font draws every glyph 1em wide, so the
    /// rest of the sidebar overflows at scale 1.0 and above; only a footer
    /// error counts.
    Future<List<FlutterErrorDetails>> pumpSidebar(
      WidgetTester tester, {
      required AgentActivityView view,
      required double height,
      required double scale,
    }) async {
      final errors = <FlutterErrorDetails>[];
      final old = FlutterError.onError;
      FlutterError.onError = errors.add;
      await pumpWorkspace(
        tester,
        surfaceSize: Size(1600, height),
        overrides: [
          agentActivityAsyncProvider.overrideWith(() => _Wi456Fixed(view)),
        ],
      );
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));
      // Every layout that can report ran inside the two pumps above.
      FlutterError.onError = old;
      return errors;
    }

    void expectNoFooterError(List<FlutterErrorDetails> errors) {
      for (final e in errors) {
        final text = e.toString();
        expect(
          text.contains('overflowed'),
          isTrue,
          reason: 'only layout overflows are tolerated: $text',
        );
        // A horizontal overflow is the wide test font (the header at scale
        // 1.0 and up); a vertical one is the footer taking too much height.
        if (text.contains('on the bottom')) {
          expect(
            text,
            isNot(contains('agent_footer.dart')),
            reason: 'the footer itself overflowed: $text',
          );
        }
      }
    }

    void expectPaneRoom(WidgetTester tester) {
      expect(find.byType(DaysPane), findsOneWidget);
      expect(
        tester.getSize(find.byType(DaysPane)).height,
        greaterThanOrEqualTo(120 - 0.01),
        reason: 'the pane above keeps 120 px',
      );
    }

    testWidgets(
      'the sidebar shows the live footer and holds no footer code beyond AgentFooter',
      (tester) async {
        final errors = await pumpSidebar(
          tester,
          view: _view(agents: 2, entries: 1),
          height: 900,
          scale: 0.5,
        );

        expect(
          find.descendant(
            of: find.byType(Sidebar),
            matching: find.byType(AgentFooter),
          ),
          findsOneWidget,
        );
        expect(_agentRows, findsNWidgets(2));
        expect(_activityRows, findsNWidgets(1));
        expect(errors, isEmpty);

        final source = File('lib/src/widgets/sidebar.dart').readAsStringSync();
        expect(source, contains('const AgentFooter()'));
        expect(source, isNot(contains('_AgentFooter')));
        expect(source, isNot(contains('no agents connected')));
        expect(source, isNot(contains('OPEN API')));
        expect(source, isNot(contains('agents · live')));
        expect(
          File('lib/src/widgets/agents/agent_footer.dart').existsSync(),
          isTrue,
        );
      },
    );

    testWidgets('formatUpdatedAgo is no longer visible for testing only', (
      tester,
    ) async {
      final source = File(
        'lib/src/widgets/editor/note_header.dart',
      ).readAsStringSync();
      expect(
        RegExp(
          r'@visibleForTesting\s+String formatUpdatedAgo',
        ).hasMatch(source),
        isFalse,
      );
      expect(source, contains('String formatUpdatedAgo('));
    });

    testWidgets(
      'at 1.3 text scale in a 600 px window the footer shows at most 2 and 2 rows within 180 px and the pane keeps 120 px',
      (tester) async {
        final errors = await pumpSidebar(
          tester,
          view: _view(agents: 4, entries: 3),
          height: 600,
          scale: 1.3,
        );

        expect(_key('agent-footer'), findsOneWidget);
        expect(find.text('AGENTS · LIVE'), findsOneWidget);
        expect(_agentRows.evaluate().length, lessThanOrEqualTo(2));
        expect(_activityRows.evaluate().length, lessThanOrEqualTo(2));
        expect(
          tester.getSize(_key('agent-footer')).height,
          lessThanOrEqualTo(180),
        );
        expectPaneRoom(tester);
        expectNoFooterError(errors);
      },
    );

    testWidgets(
      'at 1.3 text scale in a tall window the sidebar footer shows 2 agent rows plus the more line and 2 activity rows',
      (tester) async {
        final errors = await pumpSidebar(
          tester,
          view: _view(agents: 4, entries: 3),
          height: 1000,
          scale: 1.3,
        );

        expect(_agentRows, findsNWidgets(2));
        expect(_textIn('agent-footer-more', '+2 more'), findsOneWidget);
        expect(_activityRows, findsNWidgets(2));
        expect(
          tester.getSize(_key('agent-footer')).height,
          lessThanOrEqualTo(180),
        );
        expectPaneRoom(tester);
        expectNoFooterError(errors);
      },
    );

    testWidgets(
      'in a tall window at 1.0 text scale the sidebar footer shows 3 agent rows plus the more line and 3 activity rows',
      (tester) async {
        final errors = await pumpSidebar(
          tester,
          view: _view(agents: 4, entries: 3),
          height: 1000,
          scale: 1.0,
        );

        expect(_agentRows, findsNWidgets(3));
        expect(_textIn('agent-footer-more', '+1 more'), findsOneWidget);
        expect(_activityRows, findsNWidgets(3));
        expect(
          tester.getSize(_key('agent-footer')).height,
          lessThanOrEqualTo(180),
        );
        expectPaneRoom(tester);
        expectNoFooterError(errors);
      },
    );

    for (final c in <(String, double)>[
      (
        'in a 560 px window activity rows drop before agent rows, the more line stays and the pane keeps 120 px',
        560.0,
      ),
      (
        'in a 520 px window activity rows drop before agent rows, the more line stays and the pane keeps 120 px',
        520.0,
      ),
      (
        'in a 500 px window activity rows drop before agent rows, the more line stays and the pane keeps 120 px',
        500.0,
      ),
    ]) {
      testWidgets(c.$1, (tester) async {
        final errors = await pumpSidebar(
          tester,
          view: _view(agents: 4, entries: 3),
          height: c.$2,
          scale: 0.5,
        );

        final agentRows = _agentRows.evaluate().length;
        final activityRows = _activityRows.evaluate().length;
        expect(find.text('AGENTS · LIVE'), findsOneWidget);
        expectPaneRoom(tester);
        expectNoFooterError(errors);
        if (activityRows > 0) {
          expect(
            agentRows,
            3,
            reason: 'agent rows drop only after every activity row',
          );
        }
        if (agentRows < 3) {
          expect(
            activityRows,
            0,
            reason: 'no feed row while an agent row is dropped',
          );
        }
        if (agentRows < 4) {
          expect(
            _textIn('agent-footer-more', '+${4 - agentRows} more'),
            findsOneWidget,
            reason: 'the more line covers the dropped agents',
          );
        }
        expect(errors, isEmpty, reason: 'no overflow at scale 0.5');
      });
    }

    for (final c in <(String, AgentActivityView)>[
      (
        'in a 480 px window at text scale 0.5 the connected footer does not overflow and the pane keeps 120 px',
        _view(agents: 4, entries: 3),
      ),
      (
        'in a 480 px window at text scale 0.5 the disconnected footer does not overflow and the pane keeps 120 px',
        AgentActivityView(
          connected: const [],
          recent: _entries(2),
          available: true,
          clockOffsetMs: 0,
        ),
      ),
    ]) {
      testWidgets(c.$1, (tester) async {
        final errors = await pumpSidebar(
          tester,
          view: c.$2,
          height: 480,
          scale: 0.5,
        );

        expect(find.text('AGENTS · LIVE'), findsOneWidget);
        expectPaneRoom(tester);
        expect(errors, isEmpty, reason: 'no overflow at scale 0.5');
      });
    }

    testWidgets(
      'a window too short for the full footer shows fewer than 3 activity rows and still the header',
      (tester) async {
        final errors = await pumpSidebar(
          tester,
          view: _view(agents: 4, entries: 3),
          height: 500,
          scale: 0.5,
        );

        expect(_key('agent-footer'), findsOneWidget);
        expect(_activityRows.evaluate().length, lessThan(3));
        expect(
          tester.getSize(_key('agent-footer')).height,
          lessThanOrEqualTo(180),
        );
        expect(find.text('AGENTS · LIVE'), findsOneWidget);
        expectNoFooterError(errors);
      },
    );

    testWidgets(
      'a window tall enough for the full footer shows 3 agent rows the more line and 3 activity rows',
      (tester) async {
        final errors = await pumpSidebar(
          tester,
          view: _view(agents: 4, entries: 3),
          height: 700,
          scale: 0.5,
        );

        expect(_agentRows, findsNWidgets(3));
        expect(_textIn('agent-footer-more', '+1 more'), findsOneWidget);
        expect(_activityRows, findsNWidgets(3));
        expectPaneRoom(tester);
        expect(errors, isEmpty);
      },
    );
  });

  group('review round 1 (#456)', () {
    // -- 180 px cap binds (req 27a) ----------------------------------------
    for (final c in <(String, double, int, int, double)>[
      // name, scale, activity rows, agent rows, footer height
      (
        'at text scale 1.6 with 4 agents and 3 entries the 180 px cap drops the third activity row first',
        1.6,
        1,
        2,
        163.2,
      ),
      (
        'at text scale 2.0 with 4 agents and 3 entries the 180 px cap drops every activity row and keeps 2 agent rows and the more line',
        2.0,
        0,
        2,
        157.5,
      ),
    ]) {
      testWidgets(c.$1, (tester) async {
        await _pump(
          tester,
          scale: c.$2,
          script: [
            _act(
              agents: _agents(4),
              recent: _entries(3, client: 'alpha'),
            ),
          ],
        );

        expect(_agentRows, findsNWidgets(c.$4));
        expect(
          _textIn('agent-footer-more', '+${4 - c.$4} more'),
          findsOneWidget,
        );
        expect(_activityRows, findsNWidgets(c.$3));
        final h = tester.getSize(_key('agent-footer')).height;
        expect(h, lessThanOrEqualTo(AgentFooter.maxFooterHeight));
        expect(h, closeTo(c.$5, 3));
        expect(tester.takeException(), isNull);
      });
    }

    // -- Server clock skew (req 14a) ---------------------------------------
    const skew = 300000;
    AgentActivity skewed({
      List<AgentPresence> agents = const [],
      List<AgentActivityEntry> recent = const [],
    }) => AgentActivity(
      agents: agents,
      recent: recent,
      available: true,
      serverNow: agentsT0 + skew,
    );

    testWidgets(
      'on a hosted vault whose server clock is 5 minutes ahead the idle age the activity age and the label ages use the local clock',
      (tester) async {
        // Server stamps: local stamp + skew. Local idle 5m, entry 3m old.
        final env = await _pump(
          tester,
          script: [
            skewed(
              agents: [
                agentPresence(
                  sessionId: 'S-456-alpha',
                  clientName: 'alpha',
                  lastRequestAt: agentsT0 + skew - 300000,
                  expiresAt: _long + skew,
                ),
              ],
              recent: [
                agentEntry(
                  id: 'E-456-0',
                  summary: 'did a thing',
                  clientName: 'alpha',
                  sessionId: 'S-456-alpha',
                  createdAt: agentsT0 + skew - 180000,
                ),
              ],
            ),
          ],
        );

        expect(
          env.container
              .read(agentActivityAsyncProvider)
              .requireValue
              .clockOffsetMs,
          skew,
        );
        expect(_textIn('agent-footer-agent-0', 'idle · 5m'), findsOneWidget);
        expect(_textIn('agent-footer-activity-0', '3m'), findsOneWidget);
        expect(
          _label(tester),
          '1 agent connected. alpha idle, 5 minutes ago. '
          'Latest: did a thing, 3 minutes ago',
        );
      },
    );

    testWidgets(
      'on a hosted vault whose server clock is 5 minutes ahead a disconnected footer shows last agent write 3m ago and the matching label',
      (tester) async {
        await _pump(
          tester,
          script: [
            skewed(
              recent: [
                agentEntry(
                  id: 'E-456-0',
                  summary: 'old write',
                  clientName: 'alpha',
                  sessionId: 'S-456-alpha',
                  createdAt: agentsT0 + skew - 180000,
                ),
              ],
            ),
          ],
        );

        expect(
          _textIn('agent-footer-last-write', 'last agent write 3m ago'),
          findsOneWidget,
        );
        expect(
          _label(tester),
          'No agents connected. Last agent write 3 minutes ago.',
        );
      },
    );

    // -- Window resize after the first layout ------------------------------
    testWidgets(
      'shrinking the window after the first layout re-plans the footer so the pane keeps 120 px and activity rows drop first and growing it back restores them',
      (tester) async {
        final errors = <FlutterErrorDetails>[];
        final old = FlutterError.onError;
        FlutterError.onError = errors.add;
        double pane() => tester.getSize(find.byType(DaysPane)).height;
        // (agent rows, activity rows, pane height) after each window size.
        (int, int, double) shape() => (
          _agentRows.evaluate().length,
          _activityRows.evaluate().length,
          pane(),
        );
        Future<void> pumps() async {
          await tester.pump(const Duration(milliseconds: 50));
          await tester.pump(const Duration(milliseconds: 50));
        }

        late (int, int, double) tall, short, tallAgain;
        late int headerStays;
        try {
          await pumpWorkspace(
            tester,
            surfaceSize: const Size(1600, 700),
            overrides: [
              agentActivityAsyncProvider.overrideWith(
                () => _Wi456Fixed(_view(agents: 4, entries: 3)),
              ),
            ],
          );
          tester.platformDispatcher.textScaleFactorTestValue = 0.5;
          await pumps();
          tall = shape();

          tester.view.physicalSize = const Size(1600, 500);
          await pumps();
          short = shape();
          headerStays = find.text('AGENTS · LIVE').evaluate().length;

          tester.view.physicalSize = const Size(1600, 700);
          await pumps();
          tallAgain = shape();
        } finally {
          // Every layout that can report ran inside the pumps above.
          FlutterError.onError = old;
        }

        expect(tall.$1, 3);
        expect(tall.$2, 3);
        expect(tall.$3, greaterThanOrEqualTo(120 - 0.01));
        expect(
          short.$3,
          greaterThanOrEqualTo(120 - 0.01),
          reason: 'the pane keeps 120 px after the window shrank',
        );
        expect(short.$2, lessThan(3), reason: 'activity rows drop first');
        if (short.$1 < 3) expect(short.$2, 0);
        expect(headerStays, 1);
        expect(tallAgain.$1, 3);
        expect(tallAgain.$2, 3, reason: 'growing back restores the rows');
        expect(tallAgain.$3, greaterThanOrEqualTo(120 - 0.01));
        expect(errors, isEmpty, reason: 'no overflow at scale 0.5');
      },
    );
  });

  group('unavailable line width (verify)', () {
    testWidgets(
      'unavailable at a narrow width ellipsizes after two lines and never takes a third',
      (tester) async {
        await _pump(tester, script: [_act(available: false)], width: 200);

        final line = tester.getSize(_key('agent-footer-unavailable')).height;
        final text = tester.widget<Text>(_key('agent-footer-unavailable'));
        expect(text.maxLines, 2);
        // Two lines of the style, never three: 2 * (10.5 * 1.6).
        expect(line, closeTo(2 * 10.5 * 1.6, 0.5));
        expect(
          tester
              .renderObject<RenderParagraph>(_key('agent-footer-unavailable'))
              .didExceedMaxLines,
          isTrue,
        );
        // At 200 px the header row itself overflows (the design never goes
        // that narrow); only the unavailable copy's own height is pinned.
        tester.takeException();
      },
    );
  });
}

/// A fixed agents view for the sidebar tests.
class _Wi456Fixed extends AgentActivityNotifier {
  _Wi456Fixed(this.view);

  final AgentActivityView view;

  @override
  FutureOr<AgentActivityView> build() => view;
}

/// An [AgentActivityView] with [agents] idle connected agents and [entries]
/// entries from the first of them.
AgentActivityView _view({required int agents, required int entries}) =>
    AgentActivityView(
      connected: [
        for (final a in _agents(agents))
          ConnectedAgent(presence: a, working: false),
      ],
      recent: _entries(entries, client: 'alpha'),
      available: true,
      clockOffsetMs: 0,
    );

AgentActivityEntry _wi456Old(int agoMs) =>
    _entry('E-456-OLD', 'old summary', agoMs: agoMs);

/// A provider whose build fails, to pin the footer's error fallback.
class _Wi456Throws extends AgentActivityNotifier {
  @override
  FutureOr<AgentActivityView> build() =>
      Future<AgentActivityView>.error(StateError('boom'));
}
