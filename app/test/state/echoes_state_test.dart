// #426 (391-A2): `echoesAsyncProvider` runs `memex echoes` for the selected
// note (Spec #391 reqs 22-24, 32's re-read; Interview Ledger L5, L8).
//
// - It runs only while the echoes tab is visible (`rightPanelOpenProvider`
//   and `rightPanelTabProvider == RightPanelTab.echoes`) and a real note is
//   selected: never for no note, a plain canvas (no selected note id, A0
//   ruling) or the virtual Today note.
// - Becoming visible on a note runs once. A revision bump re-runs no sooner
//   than 10 s after the previous run started (one timer; two bumps give one
//   run). A note switch and `linkCompleted()` bypass the spacing.
// - [L8] While visible, an applied ready result with `pending > 0` re-runs
//   10 s later, until `pending` is 0, the tab is hidden or the note changes.
// - One run in flight per vault, at most one queued, the newest request
//   replaces the queued one. A result applies only while its note is still
//   selected and when its run started after the last `linkCompleted()`.
// - [D46] `linkCompleted()` keeps a run in flight that started at or after
//   the latest revision change (the link's own bump), re-tagged so its result
//   applies, instead of queueing a second run. A run that started before the
//   latest revision change (or with no revision change at all) is still
//   discarded and one fresh run follows.
// - A re-run keeps the previous result shown; a thrown error keeps the last
//   good result for that note next to the error.
// - `download()` runs with `allowDownload: true` and shows downloading;
//   success shows the result, failure `EmbedderUnavailable(cause)`; later
//   normal runs pass false. `retry()` repeats the last run kind.
//
// Seams: a plain ProviderContainer, FakeClock (no real timers, no wall-time
// waits) and A0's gated FakeEchoesAccess behind `vaultAccessProvider`.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/echoes_state.dart';
import 'package:open_memex_app/src/state/vault_access_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/vault_access/local/local_vault_access.dart';
import 'package:open_memex_app/src/vault_access/vault_access.dart';
import 'package:open_memex_app/src/widgets/right_panel.dart';

import '../support/echoes_fakes.dart';
import '../support/fake_clock.dart';

const _vaultPath = '/tmp/om-426-echoes-vault';
const _today = 'virtual-today:2026-10-03';

const _ms1 = Duration(milliseconds: 1);
const _s1 = Duration(seconds: 1);
const _s3 = Duration(seconds: 3);
const _s10 = Duration(seconds: 10);
const _justUnder10 = Duration(milliseconds: 9999);
const _s60 = Duration(seconds: 60);

/// A ready result built from run-time values (never canonicalised): one echo
/// named after [tag], and [pending] passages left.
EchoesReady _ready(String tag, {int pending = 0, bool emptyNote = false}) =>
    EchoesReady(
      [
        Echo(
          noteId: 'echo-$tag',
          noteTitle: 'Echo $tag',
          passage: 'a passage about $tag',
          noteUpdatedAt: 1000 * tag.length,
        ),
      ],
      emptyNote: emptyNote,
      pending: pending,
    );

/// [FakeEchoesAccess] that also records the most calls ever in flight at
/// once.
class _Wi426Echoes extends FakeEchoesAccess {
  _Wi426Echoes() : super(vaultPath: _vaultPath);

  int maxInFlight = 0;

  @override
  Future<EchoesResult> echoes(String noteId, {bool allowDownload = false}) {
    final answer = super.echoes(noteId, allowDownload: allowDownload);
    maxInFlight = math.max(maxInFlight, inFlight);
    return answer;
  }
}

/// A [FakeClock] whose `now()` can be skewed from its timers' time: a wall
/// clock that jumps (NTP, a manual change) while timers keep their pace.
class _Wi426SkewedClock extends FakeClock {
  Duration skew = Duration.zero;

  @override
  DateTime now() => super.now().add(skew);
}

/// The echoes domain behind the test vault access: swap it to hand the same
/// vault a new access object (a settings write does), or null for no access.
final _wi426EchoesSource = StateProvider<LocalEchoesAccess?>((_) => null);

/// The echoes provider in a plain container over the fakes, listened to from
/// the start (as the echoes tab watches it).
class _Wi426Env {
  _Wi426Env._(this.c, this.clock, this.echoes);

  factory _Wi426Env.start({
    String? note = 'n1',
    bool panelOpen = true,
    RightPanelTab tab = RightPanelTab.echoes,
    FakeClock? clock,
    void Function(_Wi426Echoes echoes)? script,
  }) {
    final clk = clock ?? FakeClock();
    final fake = _Wi426Echoes();
    script?.call(fake);
    final c = ProviderContainer(
      overrides: [
        clockProvider.overrideWithValue(clk),
        currentVaultProvider.overrideWith(
          (_) => const LocalVaultRef(_vaultPath),
        ),
        vaultDbProvider.overrideWithValue(null),
        memexCliProvider.overrideWithValue(null),
        _wi426EchoesSource.overrideWith((_) => fake),
        vaultAccessProvider.overrideWith((ref) {
          final source = ref.watch(_wi426EchoesSource);
          if (source == null) return null;
          return LocalVaultAccess(vaultPath: _vaultPath, echoes: source);
        }),
      ],
    );
    addTearDown(c.dispose);
    c.read(selectedNoteIdProvider.notifier).state = note;
    c.read(rightPanelOpenProvider.notifier).state = panelOpen;
    c.read(rightPanelTabProvider.notifier).state = tab;
    final env = _Wi426Env._(c, clk, fake);
    c.listen<EchoesViewState>(
      echoesAsyncProvider,
      (_, next) => env.seen.add(next),
      fireImmediately: true,
    );
    return env;
  }

  final ProviderContainer c;
  final FakeClock clock;
  final _Wi426Echoes echoes;

  /// Every state the provider emitted, in order.
  final List<EchoesViewState> seen = [];

  EchoesViewState get state => c.read(echoesAsyncProvider);
  EchoesNotifier get notifier => c.read(echoesAsyncProvider.notifier);
  int get runs => echoes.calls.length;
  List<String> get notes => [for (final call in echoes.calls) call.noteId];
  List<bool> get downloads => [
    for (final call in echoes.calls) call.allowDownload,
  ];

  /// Every result the provider ever showed.
  List<EchoesReady> get shownResults => [
    for (final s in seen)
      if (s is EchoesShown) s.result,
  ];

  /// Let the provider react: drain microtasks and zero-delay turns, and fire
  /// clock timers that are already due (a zero-delay `clock.after`).
  Future<void> flush() async {
    for (var i = 0; i < 5; i++) {
      clock.advance(Duration.zero);
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// Move fake time forward by [by] in steps of at most 1 s, flushing after
  /// each step so a run started by a timer settles before the next one.
  Future<void> advance(Duration by) async {
    var left = by;
    while (left > Duration.zero) {
      final step = left < _s1 ? left : _s1;
      clock.advance(step);
      left -= step;
      await flush();
    }
    await flush();
  }

  /// Hold every call that starts from now on until the returned gate opens.
  Completer<void> hold() {
    final gate = Completer<void>();
    echoes.gate = gate;
    return gate;
  }

  /// Open [gate] and stop holding later calls.
  Future<void> release(Completer<void> gate) async {
    if (identical(echoes.gate, gate)) echoes.gate = null;
    gate.complete();
    await flush();
  }

  Future<void> select(String? noteId) async {
    c.read(selectedNoteIdProvider.notifier).state = noteId;
    await flush();
  }

  Future<void> showTab(RightPanelTab tab) async {
    c.read(rightPanelTabProvider.notifier).state = tab;
    await flush();
  }

  Future<void> setPanelOpen(bool open) async {
    c.read(rightPanelOpenProvider.notifier).state = open;
    await flush();
  }

  Future<void> bump() async {
    c.read(vaultRevisionProvider.notifier).state++;
    await flush();
  }

  /// Call [action] without awaiting it (it may wait on a held run), then
  /// flush.
  Future<void> press(Future<void> Function(EchoesNotifier n) action) async {
    unawaited(action(notifier));
    await flush();
  }
}

void main() {
  group('visibility', () {
    test('echoes runs nothing while the right panel is closed', () async {
      final env = _Wi426Env.start(panelOpen: false);
      await env.flush();
      await env.bump();
      await env.advance(_s60);
      expect(env.runs, 0);

      await env.setPanelOpen(true);
      expect(env.notes, ['n1']);
      expect(env.downloads, [false]);
    });

    test('echoes runs nothing while the connections tab is shown', () async {
      final env = _Wi426Env.start(tab: RightPanelTab.connections);
      await env.flush();
      await env.bump();
      await env.advance(_s60);
      expect(env.runs, 0);

      await env.showTab(RightPanelTab.echoes);
      expect(env.notes, ['n1']);
    });

    test('echoes runs nothing while the activity tab is shown', () async {
      final env = _Wi426Env.start(tab: RightPanelTab.activity);
      await env.flush();
      await env.bump();
      await env.advance(_s60);
      expect(env.runs, 0);

      await env.showTab(RightPanelTab.echoes);
      expect(env.notes, ['n1']);
    });

    test('echoes runs nothing with no note selected', () async {
      final env = _Wi426Env.start(note: null);
      await env.flush();
      await env.bump();
      await env.advance(_s60);
      expect(env.runs, 0);
      expect(env.state, const EchoesNoNote());

      await env.select('n1');
      expect(env.notes, ['n1']);
      await env.advance(_s60);
      expect(env.notes, ['n1'], reason: 'the bump while no note was selected');
    });

    test('echoes runs nothing for the virtual Today note', () async {
      final env = _Wi426Env.start(note: _today);
      await env.flush();
      await env.bump();
      await env.advance(_s60);
      expect(env.runs, 0);
      expect(env.state, const EchoesNothingWritten());

      await env.select('n1');
      expect(env.notes, ['n1']);
    });

    test(
      'switching to the virtual Today note stops runs and shows nothing written',
      () async {
        final env = _Wi426Env.start(
          script: (e) => e.enqueue(_ready('a', pending: 3)),
        );
        await env.flush();
        expect(env.notes, ['n1']);

        await env.select(_today);
        expect(env.state, const EchoesNothingWritten());
        await env.bump();
        await env.advance(_s60);
        expect(env.notes, ['n1']);
      },
    );

    test('echoes runs nothing for a canvas', () async {
      final env = _Wi426Env.start(
        script: (e) => e.enqueue(_ready('a', pending: 3)),
      );
      await env.flush();
      expect(env.notes, ['n1']);

      // A plain canvas leaves no selected note id (A0 ruling).
      await env.select(null);
      expect(env.state, const EchoesNoNote());
      await env.bump();
      await env.advance(_s60);
      expect(env.notes, ['n1']);
    });

    test('opening the echoes tab on a note runs once', () async {
      final r = _ready('a');
      final env = _Wi426Env.start(
        tab: RightPanelTab.connections,
        script: (e) => e.result = r,
      );
      await env.flush();
      expect(env.runs, 0);

      await env.showTab(RightPanelTab.echoes);
      expect(env.notes, ['n1']);
      expect(env.downloads, [false]);
      expect(env.state, EchoesShown(r));
      await env.advance(_s60);
      expect(env.notes, ['n1']);
    });

    test('a visible tab on a selected note runs once at start', () async {
      final r = _ready('a');
      final env = _Wi426Env.start(script: (e) => e.result = r);
      await env.flush();
      expect(env.notes, ['n1']);
      expect(env.state, EchoesShown(r));
      await env.advance(_s60);
      expect(env.runs, 1);
    });

    test(
      'revision bumps while hidden cause one run when the tab is shown again',
      () async {
        final env = _Wi426Env.start();
        await env.flush();
        expect(env.runs, 1);

        await env.showTab(RightPanelTab.connections);
        await env.advance(_s3);
        await env.bump();
        await env.advance(_s3);
        await env.bump();
        await env.advance(_s60);
        expect(env.runs, 1, reason: 'nothing runs while hidden');

        await env.showTab(RightPanelTab.echoes);
        expect(env.runs, 2);
        await env.advance(_s60);
        expect(env.runs, 2);
      },
    );

    test('hiding cancels a spaced re-run', () async {
      final env = _Wi426Env.start();
      await env.flush();
      await env.advance(_s3);
      await env.bump();
      await env.advance(_s3);
      await env.setPanelOpen(false);
      await env.advance(_s60);
      expect(env.runs, 1);

      await env.setPanelOpen(true);
      expect(env.runs, 2);
    });

    test('linkCompleted while hidden runs nothing', () async {
      final env = _Wi426Env.start();
      await env.flush();
      expect(env.runs, 1);
      await env.showTab(RightPanelTab.activity);

      await env.press((n) => n.linkCompleted());
      await env.advance(_s60);
      expect(env.runs, 1);

      await env.showTab(RightPanelTab.echoes);
      expect(env.runs, 2);
    });

    // The sidebar vault pills change the recents list and settings while the
    // same vault stays open (#465 gate finding). With the echoes tab hidden
    // that must not run echoes, arm a timer or rebuild the notifier.
    for (final hide in <(String, Future<void> Function(_Wi426Env))>[
      (
        'a vault-list change with the tab hidden runs and arms nothing',
        (e) => e.showTab(RightPanelTab.connections),
      ),
      (
        'a vault-list change with the panel closed runs and arms nothing',
        (e) => e.setPanelOpen(false),
      ),
    ]) {
      test(hide.$1, () async {
        final env = _Wi426Env.start(
          script: (e) => e.result = _ready('a', pending: 3),
        );
        await env.flush();
        expect(env.runs, 1);
        await hide.$2(env);
        expect(env.clock.pendingTimers, 0, reason: 'hiding cancels timers');
        final emitted = env.seen.length;

        // The same open vault as a new, equal ref (a recents write reopens
        // nothing), and a new access object for it (a settings write).
        env.c.read(currentVaultProvider.notifier).state = const LocalVaultRef(
          _vaultPath,
        );
        final swapped = _Wi426Echoes()..result = _ready('b');
        env.c.read(_wi426EchoesSource.notifier).state = swapped;
        await env.flush();
        env.c.read(_wi426EchoesSource.notifier).state = _Wi426Echoes();
        await env.flush();

        expect(env.clock.pendingTimers, 0, reason: 'no timer armed');
        await env.advance(_s60);
        expect(env.runs, 1, reason: 'no run on the original access');
        expect(swapped.calls, isEmpty, reason: 'no run on the new access');
        expect(env.seen.length, emitted, reason: 'no state emitted');
        expect(env.clock.pendingTimers, 0);
      });
    }
  });

  group('revision spacing', () {
    test(
      'a revision bump 3 s after a run waits until 10 s after that run then runs once',
      () async {
        final env = _Wi426Env.start();
        await env.flush();
        expect(env.runs, 1);

        await env.advance(_s3);
        await env.bump();
        expect(env.runs, 1);
        await env.advance(const Duration(milliseconds: 6999));
        expect(env.runs, 1, reason: '9.999 s after the run');
        await env.advance(_ms1);
        expect(env.runs, 2, reason: '10 s after the run');
        expect(env.notes, ['n1', 'n1']);
        expect(env.downloads, [false, false]);

        await env.advance(_s60);
        expect(env.runs, 2);
      },
    );

    test('two revision bumps inside the spacing window give one run', () async {
      final env = _Wi426Env.start();
      await env.flush();

      await env.advance(_s3);
      await env.bump();
      await env.advance(const Duration(seconds: 4));
      await env.bump();
      await env.advance(const Duration(milliseconds: 2999));
      expect(env.runs, 1);
      await env.advance(_ms1);
      expect(env.runs, 2);
      await env.advance(_s60);
      expect(env.runs, 2);
    });

    test('a revision bump more than 10 s after a run runs at once', () async {
      final env = _Wi426Env.start();
      await env.flush();
      await env.advance(const Duration(seconds: 15));
      expect(env.runs, 1);

      await env.bump();
      expect(env.runs, 2);
      await env.advance(_s60);
      expect(env.runs, 2);
    });

    test('a revision bump exactly 10 s after a run runs at once', () async {
      final env = _Wi426Env.start();
      await env.flush();
      await env.advance(_s10);
      expect(env.runs, 1);

      await env.bump();
      expect(env.runs, 2);
    });

    test(
      'spacing counts from when the previous run started not when it finished',
      () async {
        final env = _Wi426Env.start(script: (e) => e.gate = Completer<void>());
        final gate = env.echoes.gate!;
        await env.flush();
        expect(env.runs, 1);

        await env.advance(const Duration(seconds: 8));
        await env.release(gate);
        await env.bump();
        await env.advance(const Duration(milliseconds: 1999));
        expect(env.runs, 1);
        await env.advance(_ms1);
        expect(env.runs, 2, reason: '10 s after the first run started');
      },
    );

    test(
      'a revision bump during an in-flight run runs once after it ends past the window',
      () async {
        final env = _Wi426Env.start(script: (e) => e.gate = Completer<void>());
        final gate = env.echoes.gate!;
        await env.flush();

        await env.advance(const Duration(seconds: 2));
        await env.bump();
        await env.advance(const Duration(seconds: 10));
        expect(env.runs, 1, reason: 'one run in flight at a time');
        expect(env.echoes.maxInFlight, 1);

        await env.release(gate);
        expect(env.runs, 2, reason: 'more than 10 s since the run started');
        await env.advance(_s60);
        expect(env.runs, 2);
        expect(env.echoes.maxInFlight, 1);
      },
    );

    test(
      'a revision bump during a short in-flight run waits until 10 s after it started',
      () async {
        final env = _Wi426Env.start(script: (e) => e.gate = Completer<void>());
        final gate = env.echoes.gate!;
        await env.flush();
        expect(env.runs, 1);

        await env.advance(const Duration(seconds: 2));
        await env.bump();
        await env.advance(const Duration(seconds: 2));
        await env.release(gate);
        expect(env.runs, 1, reason: 'the run ended at 4 s, inside the window');

        await env.advance(const Duration(milliseconds: 5999));
        expect(env.runs, 1, reason: '9.999 s after the run started');
        await env.advance(_ms1);
        expect(env.runs, 2, reason: '10 s after the run started');
        await env.advance(_s60);
        expect(env.runs, 2);
        expect(env.echoes.maxInFlight, 1);
      },
    );

    test(
      'a backward wall clock jump does not stretch the spacing past 10 s',
      () async {
        final clock = _Wi426SkewedClock();
        final env = _Wi426Env.start(clock: clock);
        await env.flush();
        expect(env.runs, 1);

        clock.skew = const Duration(hours: -1);
        await env.advance(_s3);
        await env.bump();
        await env.advance(_s10);
        expect(
          env.runs,
          2,
          reason: 'a bump runs within 10 s whatever now says',
        );
      },
    );
  });

  group('pending re-runs (L8)', () {
    test('a pending result runs again 10 s later while visible', () async {
      final last = _ready('b');
      final env = _Wi426Env.start(
        script: (e) => e
          ..enqueue(_ready('a', pending: 3))
          ..result = last,
      );
      await env.flush();
      expect(env.runs, 1);

      await env.advance(_justUnder10);
      expect(env.runs, 1);
      await env.advance(_ms1);
      expect(env.runs, 2);
      expect(env.notes, ['n1', 'n1']);
      expect(env.downloads, [false, false]);
      expect(env.state, EchoesShown(last));
    });

    test(
      'pending re-runs repeat while pending is above zero and stop at zero',
      () async {
        final env = _Wi426Env.start(
          script: (e) => e
            ..enqueue(_ready('a', pending: 5))
            ..enqueue(_ready('b', pending: 2))
            ..enqueue(_ready('c', pending: 1))
            ..enqueue(_ready('d', pending: 0))
            ..result = _ready('never', pending: 9),
        );
        await env.flush();
        expect(env.runs, 1);

        await env.advance(_s10);
        expect(env.runs, 2);
        await env.advance(_s10);
        expect(env.runs, 3);
        await env.advance(_s10);
        expect(env.runs, 4);
        expect(env.state, EchoesShown(_ready('d')));

        await env.advance(_s60);
        expect(env.runs, 4, reason: 'pending 0 stops the re-runs');
      },
    );

    test('pending re-runs stop when the echoes tab is hidden', () async {
      final env = _Wi426Env.start(
        script: (e) => e.result = _ready('a', pending: 3),
      );
      await env.flush();
      expect(env.runs, 1);

      await env.advance(const Duration(seconds: 5));
      await env.showTab(RightPanelTab.connections);
      await env.advance(_s60);
      expect(env.runs, 1);

      await env.showTab(RightPanelTab.echoes);
      expect(env.runs, 2, reason: 'showing the tab runs once');
      await env.advance(_s10);
      expect(env.runs, 3, reason: 'pending is still above zero');
    });

    test('pending re-runs stop when the right panel is closed', () async {
      final env = _Wi426Env.start(
        script: (e) => e.result = _ready('a', pending: 3),
      );
      await env.flush();
      await env.advance(const Duration(seconds: 5));
      await env.setPanelOpen(false);
      await env.advance(_s60);
      expect(env.runs, 1);
    });

    test('pending re-runs stop on a note switch', () async {
      final env = _Wi426Env.start(
        script: (e) => e
          ..enqueue(_ready('a', pending: 3))
          ..result = _ready('b'),
      );
      await env.flush();
      await env.advance(const Duration(seconds: 5));
      await env.select('n2');
      expect(env.notes, ['n1', 'n2']);

      await env.advance(_s60);
      expect(env.notes, ['n1', 'n2']);
    });

    test(
      'a pending result that arrives while hidden schedules no re-run',
      () async {
        final env = _Wi426Env.start(
          script: (e) => e
            ..gate = Completer<void>()
            ..result = _ready('a', pending: 3),
        );
        final gate = env.echoes.gate!;
        await env.flush();
        expect(env.runs, 1);

        await env.showTab(RightPanelTab.connections);
        await env.release(gate);
        await env.advance(_s60);
        expect(env.runs, 1);
      },
    );

    test(
      'a pending re-run and a revision bump in the same window give one run',
      () async {
        final env = _Wi426Env.start(
          script: (e) => e
            ..enqueue(_ready('a', pending: 3))
            ..result = _ready('b'),
        );
        await env.flush();
        await env.advance(_s3);
        await env.bump();
        await env.advance(_justUnder10 - _s3);
        expect(env.runs, 1);
        await env.advance(_ms1);
        expect(env.runs, 2);
        await env.advance(_s60);
        expect(env.runs, 2);
      },
    );

    test(
      'a slow pending run re-runs no sooner than 10 s after it started',
      () async {
        final env = _Wi426Env.start(
          script: (e) => e
            ..gate = Completer<void>()
            ..enqueue(_ready('a', pending: 3))
            ..result = _ready('b'),
        );
        final gate = env.echoes.gate!;
        await env.flush();
        await env.advance(const Duration(seconds: 4));
        await env.release(gate);
        expect(env.runs, 1);

        await env.advance(const Duration(milliseconds: 5999));
        expect(env.runs, 1, reason: '9.999 s after the run started');
        await env.advance(const Duration(milliseconds: 4001));
        expect(env.runs, 2, reason: 'by 10 s after the result arrived');
        await env.advance(_s60);
        expect(env.runs, 2);
      },
    );

    test('an unavailable result schedules no re-run', () async {
      final env = _Wi426Env.start(
        script: (e) => e.result = const EchoesUnavailable(ModelNotDownloaded()),
      );
      await env.flush();
      expect(env.runs, 1);
      expect(env.state, const EchoesUnavailableView(ModelNotDownloaded()));
      await env.advance(_s60);
      expect(env.runs, 1);
    });
  });

  group('result shown during and after a re-run', () {
    test('during a re-run the previous result stays in the view', () async {
      final first = _ready('a');
      final second = _ready('b');
      final env = _Wi426Env.start(
        script: (e) => e
          ..enqueue(first)
          ..result = second,
      );
      await env.flush();
      expect(env.state, EchoesShown(first));

      await env.advance(const Duration(seconds: 15));
      final gate = env.hold();
      await env.bump();
      expect(env.runs, 2);
      expect(env.state, EchoesShown(first, refreshing: true));

      await env.release(gate);
      expect(env.state, EchoesShown(second));
    });

    test(
      'after a failed re-run the previous result stays with the error',
      () async {
        final first = _ready('a');
        final boom = MemexException('echoes failed: boom');
        final again = StateError('again');
        final env = _Wi426Env.start(
          script: (e) => e
            ..enqueue(first)
            ..enqueue(boom)
            ..enqueue(again),
        );
        await env.flush();
        expect(env.state, EchoesShown(first));

        await env.advance(const Duration(seconds: 15));
        await env.bump();
        expect(env.runs, 2);
        expect(env.state, EchoesError(boom, lastGood: first));

        await env.advance(const Duration(seconds: 15));
        await env.bump();
        expect(env.runs, 3);
        expect(
          env.state,
          EchoesError(again, lastGood: first),
          reason: 'a second failure keeps the last good result',
        );
      },
    );

    test(
      'a failed first run shows the error with no previous result',
      () async {
        final boom = StateError('boom');
        final env = _Wi426Env.start(script: (e) => e.enqueue(boom));
        await env.flush();
        expect(env.runs, 1);
        expect(env.state, EchoesError(boom));
      },
    );

    test('a run after a failed re-run shows its new result', () async {
      final boom = StateError('boom');
      final fresh = _ready('c');
      final env = _Wi426Env.start(
        script: (e) => e
          ..enqueue(_ready('a'))
          ..enqueue(boom)
          ..result = fresh,
      );
      await env.flush();
      await env.advance(const Duration(seconds: 15));
      await env.bump();
      expect(env.state, isA<EchoesError>());

      await env.advance(const Duration(seconds: 15));
      await env.bump();
      expect(env.state, EchoesShown(fresh));
    });

    test(
      'an error after a note switch keeps no result from the old note',
      () async {
        final boom = StateError('boom');
        final env = _Wi426Env.start(
          script: (e) => e
            ..enqueue(_ready('a'))
            ..enqueue(boom),
        );
        await env.flush();
        expect(env.state, EchoesShown(_ready('a')));

        await env.select('n2');
        expect(env.notes, ['n1', 'n2']);
        expect(env.state, EchoesError(boom));
      },
    );

    test('the first run of a note shows first load while in flight', () async {
      final r = _ready('a');
      final env = _Wi426Env.start(
        script: (e) => e
          ..gate = Completer<void>()
          ..result = r,
      );
      final gate = env.echoes.gate!;
      await env.flush();
      expect(env.runs, 1);
      expect(env.state, const EchoesFirstLoad());

      await env.release(gate);
      expect(env.state, EchoesShown(r));
    });

    test(
      'a new note shows first load not the old note result while it loads',
      () async {
        final env = _Wi426Env.start(script: (e) => e.result = _ready('a'));
        await env.flush();
        expect(env.state, EchoesShown(_ready('a')));

        final gate = env.hold();
        await env.select('n2');
        expect(env.notes, ['n1', 'n2']);
        expect(env.state, const EchoesFirstLoad());
        await env.release(gate);
        expect(env.state, EchoesShown(_ready('a')));
      },
    );

    test('an empty note result shows nothing written', () async {
      final env = _Wi426Env.start(
        script: (e) => e.result = _ready('a', emptyNote: true),
      );
      await env.flush();
      expect(env.runs, 1);
      expect(env.state, const EchoesNothingWritten());
    });

    test('an unavailable result shows its reason', () async {
      final env = _Wi426Env.start(
        script: (e) => e.result = const EchoesUnavailable(Outdated()),
      );
      await env.flush();
      expect(env.runs, 1);
      expect(env.state, const EchoesUnavailableView(Outdated()));
    });
  });

  group('note switch', () {
    test('switching notes runs at once for the new note', () async {
      final r2 = _ready('b');
      final env = _Wi426Env.start(
        script: (e) => e
          ..enqueue(_ready('a'))
          ..result = r2,
      );
      await env.flush();
      await env.advance(const Duration(seconds: 2));

      await env.select('n2');
      expect(env.notes, ['n1', 'n2']);
      expect(env.downloads, [false, false]);
      expect(env.state, EchoesShown(r2));

      await env.select('n1');
      expect(env.notes, ['n1', 'n2', 'n1'], reason: 'no spacing on a switch');
    });

    test(
      'the old note in-flight result is discarded when it arrives',
      () async {
        final stale = _ready('stale');
        final r2 = _ready('fresh');
        final env = _Wi426Env.start(
          script: (e) => e
            ..gate = Completer<void>()
            ..enqueue(stale)
            ..result = r2,
        );
        final gate = env.echoes.gate!;
        await env.flush();
        expect(env.notes, ['n1']);

        await env.select('n2');
        expect(env.echoes.maxInFlight, 1);
        await env.release(gate);
        expect(env.notes, ['n1', 'n2']);
        expect(env.shownResults, isNot(contains(stale)));
        expect(env.state, EchoesShown(r2));
        expect(env.echoes.maxInFlight, 1);
      },
    );

    test(
      'a result that arrives after the selection is cleared is discarded',
      () async {
        final stale = _ready('stale');
        final env = _Wi426Env.start(
          script: (e) => e
            ..gate = Completer<void>()
            ..result = stale,
        );
        final gate = env.echoes.gate!;
        await env.flush();
        expect(env.notes, ['n1']);
        await env.select(null);
        await env.release(gate);
        expect(env.state, const EchoesNoNote());
        expect(env.shownResults, isEmpty);
        expect(env.notes, ['n1']);
      },
    );
  });

  group('one run at a time', () {
    test(
      'with one run in flight three more requests cause exactly one more run after it',
      () async {
        final env = _Wi426Env.start(script: (e) => e.gate = Completer<void>());
        final gate = env.echoes.gate!;
        await env.flush();
        expect(env.runs, 1);

        await env.press((n) => n.linkCompleted());
        await env.press((n) => n.linkCompleted());
        await env.press((n) => n.linkCompleted());
        expect(env.runs, 1);
        expect(env.echoes.inFlight, 1);

        await env.release(gate);
        expect(env.runs, 2);
        await env.advance(_s60);
        expect(env.runs, 2);
        expect(env.echoes.maxInFlight, 1);
      },
    );

    test(
      'with one run in flight the newest of three queued requests is the one that runs',
      () async {
        final env = _Wi426Env.start(script: (e) => e.gate = Completer<void>());
        final gate = env.echoes.gate!;
        await env.flush();

        await env.select('n2');
        await env.select('n3');
        await env.select('n4');
        expect(env.notes, ['n1']);

        await env.release(gate);
        expect(env.notes, ['n1', 'n4']);
        await env.advance(_s60);
        expect(env.notes, ['n1', 'n4']);
        expect(env.echoes.maxInFlight, 1);
      },
    );

    test(
      'a download requested during an in-flight run runs after it with allowDownload true',
      () async {
        final env = _Wi426Env.start(script: (e) => e.gate = Completer<void>());
        final gate = env.echoes.gate!;
        await env.flush();

        await env.press((n) => n.download());
        expect(env.runs, 1);
        await env.release(gate);
        expect(env.downloads, [false, true]);
        expect(env.echoes.maxInFlight, 1);
      },
    );

    test(
      'a download pressed after a queued link run replaces it and runs after the run in flight',
      () async {
        final env = _Wi426Env.start(script: (e) => e.gate = Completer<void>());
        final gate = env.echoes.gate!;
        await env.flush();
        expect(env.runs, 1);

        await env.press((n) => n.linkCompleted());
        expect(env.runs, 1);
        expect(env.state, isNot(const EchoesDownloading()));
        await env.press((n) => n.download());
        expect(env.state, const EchoesDownloading());
        expect(env.runs, 1);

        await env.release(gate);
        expect(env.downloads, [false, true]);
        expect(env.echoes.maxInFlight, 1);
        await env.advance(_s60);
        expect(env.downloads, [false, true]);
      },
    );

    test(
      'a download pressed after a queued revision run replaces it and runs after the run in flight',
      () async {
        final env = _Wi426Env.start(script: (e) => e.gate = Completer<void>());
        final gate = env.echoes.gate!;
        await env.flush();
        await env.advance(const Duration(seconds: 11));
        await env.bump();
        expect(env.runs, 1, reason: 'queued behind the run in flight');

        await env.press((n) => n.download());
        expect(env.state, const EchoesDownloading());

        await env.release(gate);
        expect(env.downloads, [false, true]);
        expect(env.echoes.maxInFlight, 1);
        await env.advance(_s60);
        expect(env.downloads, [false, true]);
      },
    );

    test('toggling the tab during a run never runs two at once', () async {
      final env = _Wi426Env.start(script: (e) => e.gate = Completer<void>());
      final gate = env.echoes.gate!;
      await env.flush();

      await env.showTab(RightPanelTab.connections);
      await env.showTab(RightPanelTab.echoes);
      await env.showTab(RightPanelTab.activity);
      await env.showTab(RightPanelTab.echoes);
      expect(env.runs, 1);

      await env.release(gate);
      await env.advance(_s60);
      expect(env.runs, 2, reason: 'the run in flight plus one queued re-show');
      expect(env.echoes.maxInFlight, 1);
    });
  });

  group('guards', () {
    test(
      'an access that inserts vectors without a revision change causes no re-runs beyond the pending rule',
      () async {
        // Each read embeds some passages (pending falls) but vector writes
        // never move the revision.
        final env = _Wi426Env.start(
          script: (e) => e
            ..enqueue(_ready('a', pending: 4))
            ..enqueue(_ready('b', pending: 2))
            ..result = _ready('c'),
        );
        await env.flush();
        expect(env.runs, 1);
        await env.advance(_justUnder10);
        expect(env.runs, 1);
        await env.advance(_ms1);
        expect(
          env.runs,
          2,
          reason: 'the first L8 re-run, 10 s after the start',
        );
        await env.advance(_justUnder10);
        expect(env.runs, 2);
        await env.advance(_ms1);
        expect(env.runs, 3, reason: 'the second L8 re-run');
        await env.advance(const Duration(seconds: 120));
        expect(env.runs, 3, reason: 'nothing pending, nothing else re-runs');
      },
    );

    test(
      'an access that inserts vectors and leaves nothing pending runs once',
      () async {
        final env = _Wi426Env.start(script: (e) => e.result = _ready('a'));
        await env.flush();
        await env.advance(const Duration(seconds: 120));
        expect(env.runs, 1);
        expect(env.clock.pendingTimers, 0);
      },
    );

    test('linkCompleted causes exactly one immediate run', () async {
      final env = _Wi426Env.start();
      await env.flush();
      await env.advance(const Duration(seconds: 2));

      await env.press((n) => n.linkCompleted());
      expect(env.runs, 2, reason: 'bypasses the 10 s spacing');
      expect(env.notes, ['n1', 'n1']);
      expect(env.downloads, [false, false]);
      await env.advance(_s60);
      expect(env.runs, 2);
    });

    test('a revision bump then linkCompleted give one immediate run', () async {
      final env = _Wi426Env.start();
      await env.flush();
      await env.advance(const Duration(seconds: 2));

      await env.bump();
      await env.press((n) => n.linkCompleted());
      expect(env.runs, 2);
      await env.advance(_s60);
      expect(env.runs, 2, reason: 'the link run replaces the spaced one');
    });

    test(
      'linkCompleted then a revision bump give the link run and one spaced run',
      () async {
        final env = _Wi426Env.start();
        await env.flush();
        await env.advance(const Duration(seconds: 2));

        await env.press((n) => n.linkCompleted());
        await env.bump();
        expect(env.runs, 2);
        await env.advance(_justUnder10);
        expect(env.runs, 2);
        await env.advance(_ms1);
        expect(env.runs, 3, reason: '10 s after the link run started');
        await env.advance(_s60);
        expect(env.runs, 3);
      },
    );

    test(
      'a result from a run started before linkCompleted is discarded',
      () async {
        final before = _ready('before');
        final stale = _ready('stale');
        final after = _ready('after');
        final env = _Wi426Env.start(
          script: (e) => e
            ..enqueue(before)
            ..enqueue(stale)
            ..result = after,
        );
        await env.flush();
        expect(env.state, EchoesShown(before));

        // D46: the stale run starts before the link's revision bump (a run
        // the bump itself starts is kept, see the D46 group).
        await env.advance(const Duration(seconds: 15));
        final gate = env.hold();
        await env.press((n) => n.retry());
        expect(env.runs, 2);
        await env.advance(_ms1);
        await env.bump();
        expect(env.runs, 2);

        await env.press((n) => n.linkCompleted());
        await env.release(gate);
        expect(env.runs, 3);
        expect(env.shownResults, isNot(contains(stale)));
        expect(env.state, EchoesShown(after));
        expect(env.echoes.maxInFlight, 1);
      },
    );

    test(
      'a first-load result from before linkCompleted is discarded',
      () async {
        final stale = _ready('stale');
        final after = _ready('after');
        final env = _Wi426Env.start(
          script: (e) => e
            ..gate = Completer<void>()
            ..enqueue(stale)
            ..result = after,
        );
        final gate = env.echoes.gate!;
        await env.flush();

        await env.press((n) => n.linkCompleted());
        await env.release(gate);
        expect(env.runs, 2);
        expect(env.shownResults, isNot(contains(stale)));
        expect(env.state, EchoesShown(after));
      },
    );
  });

  // Ruling D46: a link bumps `vaultRevisionProvider` (req 32) and then calls
  // `linkCompleted()`. The bump's run read the linked vault, so the link
  // keeps it instead of discarding it and queueing a second run.
  group('link keeps the revision bump run (D46)', () {
    test(
      'a link more than 10 s after the last run gives exactly one run and shows its result',
      () async {
        final before = _ready('before');
        final fresh = _ready('fresh');
        final extra = _ready('extra');
        final env = _Wi426Env.start(
          script: (e) => e
            ..enqueue(before)
            ..enqueue(fresh)
            ..result = extra,
        );
        await env.flush();
        expect(env.state, EchoesShown(before));

        await env.advance(const Duration(seconds: 15));
        final gate = env.hold();
        await env.bump();
        expect(env.runs, 2, reason: 'the link revision bump runs at once');

        await env.press((n) => n.linkCompleted());
        expect(env.runs, 2);
        expect(env.state, EchoesShown(before, refreshing: true));

        await env.release(gate);
        expect(env.runs, 2, reason: 'the bump run is kept, no second run');
        expect(env.state, EchoesShown(fresh));
        await env.advance(_s60);
        expect(env.runs, 2);
        expect(env.notes, ['n1', 'n1']);
        expect(env.shownResults, isNot(contains(extra)));
        expect(env.clock.pendingTimers, 0);
        expect(env.echoes.maxInFlight, 1);
      },
    );

    test(
      'linkCompleted keeps a run the spacing timer started after the revision bump',
      () async {
        final before = _ready('before');
        final fresh = _ready('fresh');
        final extra = _ready('extra');
        final env = _Wi426Env.start(
          script: (e) => e
            ..enqueue(before)
            ..enqueue(fresh)
            ..result = extra,
        );
        await env.flush();
        await env.advance(_s3);
        await env.bump();
        expect(env.runs, 1, reason: 'spaced to 10 s after the first run');

        final gate = env.hold();
        await env.advance(const Duration(seconds: 7));
        expect(env.runs, 2, reason: 'the timer run starts after the bump');

        await env.press((n) => n.linkCompleted());
        await env.release(gate);
        expect(env.runs, 2);
        expect(env.state, EchoesShown(fresh));
        await env.advance(_s60);
        expect(env.runs, 2);
        expect(env.shownResults, isNot(contains(extra)));
      },
    );

    test(
      'linkCompleted keeps a download that started after the revision bump',
      () async {
        final mid = _ready('mid');
        final downloaded = _ready('downloaded');
        final extra = _ready('extra');
        final env = _Wi426Env.start(
          script: (e) => e
            ..enqueue(_ready('before'))
            ..enqueue(mid)
            ..enqueue(downloaded)
            ..result = extra,
        );
        await env.flush();
        await env.advance(const Duration(seconds: 15));
        await env.bump();
        expect(env.state, EchoesShown(mid));

        await env.advance(_s1);
        final gate = env.hold();
        await env.press((n) => n.download());
        expect(env.state, const EchoesDownloading());

        await env.press((n) => n.linkCompleted());
        expect(
          env.state,
          const EchoesDownloading(),
          reason: 'the kept download still belongs to this link epoch',
        );
        await env.release(gate);
        expect(env.downloads, [false, false, true]);
        expect(env.state, EchoesShown(downloaded));
        await env.advance(_s60);
        expect(env.downloads, [false, false, true]);
      },
    );

    test(
      'linkCompleted discards a run that started 1 ms before the revision bump and one fresh run follows',
      () async {
        final before = _ready('before');
        final stale = _ready('stale');
        final fresh = _ready('fresh');
        final env = _Wi426Env.start(
          script: (e) => e
            ..enqueue(before)
            ..enqueue(stale)
            ..result = fresh,
        );
        await env.flush();
        await env.advance(const Duration(seconds: 15));
        final gate = env.hold();
        await env.bump();
        expect(env.runs, 2);

        await env.advance(_ms1);
        await env.bump();
        expect(env.runs, 2, reason: 'the link bump waits on the run in flight');

        await env.press((n) => n.linkCompleted());
        await env.release(gate);
        expect(env.runs, 3, reason: 'exactly one fresh run');
        expect(env.state, EchoesShown(fresh));
        expect(env.shownResults, isNot(contains(stale)));
        await env.advance(_s60);
        expect(env.runs, 3);
        expect(env.clock.pendingTimers, 0);
        expect(env.echoes.maxInFlight, 1);
      },
    );

    test(
      'linkCompleted discards a run started before the revision bump after a backward clock jump',
      () async {
        final clock = _Wi426SkewedClock();
        final before = _ready('before');
        final stale = _ready('stale');
        final fresh = _ready('fresh');
        final env = _Wi426Env.start(
          clock: clock,
          script: (e) => e
            ..enqueue(before)
            ..enqueue(stale)
            ..result = fresh,
        );
        await env.flush();
        await env.advance(const Duration(seconds: 15));
        final gate = env.hold();
        await env.bump();
        expect(env.runs, 2);

        // The wall clock jumps back an hour: the link bump now reads earlier
        // than the run in flight, which still started before it.
        clock.skew = const Duration(hours: -1);
        await env.bump();
        await env.press((n) => n.linkCompleted());
        await env.release(gate);
        expect(env.runs, 3, reason: 'exactly one fresh run');
        expect(env.state, EchoesShown(fresh));
        expect(env.shownResults, isNot(contains(stale)));
        await env.advance(_s60);
        expect(env.runs, 3);
        expect(env.echoes.maxInFlight, 1);
      },
    );
  });

  group('download', () {
    test(
      'download passes allowDownload true and shows downloading until it completes',
      () async {
        final r = _ready('a');
        final env = _Wi426Env.start(
          script: (e) => e
            ..enqueue(const EchoesUnavailable(ModelNotDownloaded()))
            ..result = r,
        );
        await env.flush();
        expect(env.state, const EchoesUnavailableView(ModelNotDownloaded()));

        await env.advance(_s1);
        final gate = env.hold();
        await env.press((n) => n.download());
        expect(env.downloads, [false, true]);
        expect(env.notes, ['n1', 'n1']);
        expect(env.state, const EchoesDownloading());
        await env.advance(const Duration(seconds: 30));
        expect(env.state, const EchoesDownloading());
        expect(env.runs, 2);

        await env.release(gate);
        expect(env.state, EchoesShown(r));
      },
    );

    test(
      'a failed download shows EmbedderUnavailable with the cause',
      () async {
        const cause = EmbedderUnavailable('could not fetch the model');
        final env = _Wi426Env.start(
          script: (e) => e
            ..enqueue(const EchoesUnavailable(ModelNotDownloaded()))
            ..result = const EchoesUnavailable(cause),
        );
        await env.flush();
        await env.press((n) => n.download());
        expect(env.downloads, [false, true]);
        expect(env.state, const EchoesUnavailableView(cause));
      },
    );

    test(
      'a download that throws shows EmbedderUnavailable with the error message',
      () async {
        final env = _Wi426Env.start(
          script: (e) => e
            ..enqueue(const EchoesUnavailable(ModelNotDownloaded()))
            ..enqueue(MemexException('echoes failed: disk full')),
        );
        await env.flush();
        await env.press((n) => n.download());
        expect(env.downloads, [false, true]);
        expect(
          env.state,
          const EchoesUnavailableView(
            EmbedderUnavailable('echoes failed: disk full'),
          ),
        );
      },
    );

    test(
      'a download answered unavailable for another reason shows it',
      () async {
        final env = _Wi426Env.start(
          script: (e) => e
            ..enqueue(const EchoesUnavailable(ModelNotDownloaded()))
            ..result = const EchoesUnavailable(Outdated()),
        );
        await env.flush();
        await env.press((n) => n.download());
        expect(env.state, const EchoesUnavailableView(Outdated()));
      },
    );

    test(
      'a later normal run after a download passes allowDownload false',
      () async {
        final env = _Wi426Env.start(
          script: (e) => e
            ..enqueue(const EchoesUnavailable(ModelNotDownloaded()))
            ..enqueue(_ready('a', pending: 2))
            ..result = _ready('b'),
        );
        await env.flush();
        await env.press((n) => n.download());
        expect(env.downloads, [false, true]);

        await env.advance(_s10);
        expect(env.downloads, [false, true, false], reason: 'the L8 re-run');

        await env.advance(const Duration(seconds: 15));
        await env.bump();
        expect(env.downloads, [false, true, false, false]);

        await env.press((n) => n.linkCompleted());
        expect(env.downloads, [false, true, false, false, false]);
      },
    );
  });

  group('retry', () {
    test(
      'retry after a failed download retries with allowDownload true',
      () async {
        const cause = EmbedderUnavailable('could not fetch the model');
        final r = _ready('a');
        final env = _Wi426Env.start(
          script: (e) => e
            ..enqueue(const EchoesUnavailable(ModelNotDownloaded()))
            ..enqueue(const EchoesUnavailable(cause))
            ..result = r,
        );
        await env.flush();
        await env.press((n) => n.download());
        expect(env.state, const EchoesUnavailableView(cause));

        final gate = env.hold();
        await env.press((n) => n.retry());
        expect(env.downloads, [false, true, true]);
        expect(env.state, const EchoesDownloading());
        await env.release(gate);
        expect(env.state, EchoesShown(r));
      },
    );

    test(
      'retry after a failed normal run retries without allowDownload',
      () async {
        final boom = StateError('boom');
        final r = _ready('a');
        final env = _Wi426Env.start(
          script: (e) => e
            ..enqueue(boom)
            ..result = r,
        );
        await env.flush();
        expect(env.state, EchoesError(boom));

        await env.press((n) => n.retry());
        expect(env.downloads, [false, false]);
        expect(env.state, EchoesShown(r));
      },
    );

    test(
      'retry after a normal run answered embedder unavailable retries without allowDownload',
      () async {
        const cause = EmbedderUnavailable('timed out');
        final env = _Wi426Env.start(
          script: (e) => e
            ..enqueue(const EchoesUnavailable(cause))
            ..result = _ready('a'),
        );
        await env.flush();
        expect(env.state, const EchoesUnavailableView(cause));

        await env.press((n) => n.retry());
        expect(env.downloads, [false, false]);
      },
    );

    test(
      'retry after a download then a failed normal run retries without allowDownload',
      () async {
        final boom = StateError('boom');
        final env = _Wi426Env.start(
          script: (e) => e
            ..enqueue(const EchoesUnavailable(ModelNotDownloaded()))
            ..enqueue(_ready('a'))
            ..enqueue(boom)
            ..result = _ready('b'),
        );
        await env.flush();
        await env.press((n) => n.download());
        await env.advance(const Duration(seconds: 15));
        await env.bump();
        expect(env.state, EchoesError(boom, lastGood: _ready('a')));

        await env.press((n) => n.retry());
        expect(env.downloads, [false, true, false, false]);
      },
    );
  });

  group('lifecycle', () {
    test('disposing the container cancels pending echoes timers', () async {
      final env = _Wi426Env.start(
        script: (e) => e.result = _ready('a', pending: 3),
      );
      await env.flush();
      expect(env.runs, 1);
      await env.advance(_s3);
      await env.bump();

      env.c.dispose();
      expect(env.clock.pendingTimers, 0);
      env.clock.advance(_s60);
      await env.flush();
      expect(env.runs, 1);
    });

    test('a result arriving after dispose is dropped without error', () async {
      final env = _Wi426Env.start(
        script: (e) => e
          ..gate = Completer<void>()
          ..result = _ready('a', pending: 3),
      );
      final gate = env.echoes.gate!;
      await env.flush();
      expect(env.runs, 1);

      env.c.dispose();
      await env.release(gate);
      env.clock.advance(_s60);
      await env.flush();
      expect(env.runs, 1);
      expect(env.clock.pendingTimers, 0);
    });
  });
  group('verify contracts', () {
    test(
      'a queued download stays a download when a later request replaces the queue',
      () async {
        final env = _Wi426Env.start(script: (e) => e.gate = Completer<void>());
        final gate = env.echoes.gate!;
        await env.flush();
        expect(env.runs, 1);

        await env.press((n) => n.download());
        expect(env.state, const EchoesDownloading());
        await env.press((n) => n.linkCompleted());
        expect(env.state, const EchoesDownloading());
        expect(env.runs, 1);

        await env.release(gate);
        expect(env.downloads, [false, true]);
        expect(env.echoes.maxInFlight, 1);
      },
    );

    test(
      'a download in flight is not shown as downloading on another note',
      () async {
        final env = _Wi426Env.start(script: (e) => e.result = _ready('a'));
        await env.flush();
        final gate = env.hold();
        await env.press((n) => n.download());
        expect(env.state, const EchoesDownloading());

        await env.select('n2');
        expect(env.state, const EchoesFirstLoad());
        await env.release(gate);
        expect(env.notes, ['n1', 'n1', 'n2']);
        expect(env.downloads, [false, true, false]);
      },
    );

    test(
      'a download in flight is not shown as downloading after linkCompleted',
      () async {
        final r = _ready('a');
        final env = _Wi426Env.start(script: (e) => e.result = r);
        await env.flush();
        final gate = env.hold();
        await env.press((n) => n.download());
        expect(env.state, const EchoesDownloading());

        await env.press((n) => n.linkCompleted());
        expect(env.state, EchoesShown(r, refreshing: true));
        await env.release(gate);
        expect(env.downloads, [false, true, false]);
        expect(env.state, EchoesShown(r));
      },
    );

    test(
      'a download at once cancels the spaced timer of an earlier revision bump',
      () async {
        final env = _Wi426Env.start(script: (e) => e.result = _ready('a'));
        await env.flush();
        await env.advance(_s3);
        await env.bump();
        expect(env.runs, 1);
        expect(env.clock.pendingTimers, 1);

        await env.press((n) => n.download());
        expect(env.downloads, [false, true]);
        expect(env.clock.pendingTimers, 0);
        await env.advance(_s60);
        expect(env.runs, 2);
      },
    );

    test(
      'a selection change before the first run starts gives one run for the new note',
      () async {
        final env = _Wi426Env.start();
        env.c.read(selectedNoteIdProvider.notifier).state = 'n2';
        await env.flush();
        await env.advance(_s60);
        expect(env.notes, ['n2']);
      },
    );

    test(
      'download and retry run nothing while the echoes tab is hidden',
      () async {
        final env = _Wi426Env.start(tab: RightPanelTab.connections);
        await env.flush();
        await env.press((n) => n.download());
        await env.press((n) => n.retry());
        await env.advance(_s60);
        expect(env.runs, 0);
      },
    );

    test('download and retry run nothing for the virtual Today note', () async {
      final env = _Wi426Env.start(note: _today);
      await env.flush();
      await env.press((n) => n.download());
      await env.press((n) => n.retry());
      await env.advance(_s60);
      expect(env.runs, 0);
      expect(env.state, const EchoesNothingWritten());
    });

    test(
      'a vault change drops the old vault in-flight result and runs again',
      () async {
        final env = _Wi426Env.start(
          script: (e) => e
            ..gate = Completer<void>()
            ..enqueue(_ready('old'))
            ..enqueue(_ready('new')),
        );
        final gate = env.echoes.gate!;
        await env.flush();
        expect(env.runs, 1);

        env.c.read(currentVaultProvider.notifier).state = const LocalVaultRef(
          '/tmp/om-426-other-vault',
        );
        await env.flush();
        expect(env.runs, 2, reason: 'a new vault starts its own first run');
        await env.release(gate);

        expect(env.state, EchoesShown(_ready('new')));
        expect(env.shownResults, isNot(contains(_ready('old'))));
        expect(env.echoes.maxInFlight, 2);
      },
    );

    test(
      'a new access for the same vault keeps the run in flight and the first load',
      () async {
        final env = _Wi426Env.start(
          script: (e) => e
            ..gate = Completer<void>()
            ..enqueue(_ready('a')),
        );
        final gate = env.echoes.gate!;
        await env.flush();
        expect(env.runs, 1);
        expect(env.state, const EchoesFirstLoad());

        env.c.invalidate(vaultAccessProvider);
        await env.flush();
        env.c.invalidate(vaultAccessProvider);
        await env.flush();
        expect(env.runs, 1, reason: 'no second run on the same vault');
        expect(env.echoes.maxInFlight, 1);
        expect(env.state, const EchoesFirstLoad());

        await env.release(gate);
        expect(env.state, EchoesShown(_ready('a')));
        expect(env.runs, 1, reason: 'the result of the old access applies');
        await env.advance(_s60);
        expect(env.runs, 1);
      },
    );

    test(
      'a new access for the same vault keeps the shown result and the spacing',
      () async {
        final env = _Wi426Env.start(
          script: (e) => e
            ..enqueue(_ready('old'))
            ..enqueue(_ready('new')),
        );
        await env.flush();
        expect(env.state, EchoesShown(_ready('old')));
        await env.advance(const Duration(seconds: 3));

        env.c.invalidate(vaultAccessProvider);
        await env.flush();
        expect(
          env.state,
          EchoesShown(_ready('old')),
          reason: 'not reset to first load',
        );
        expect(env.runs, 1);

        await env.bump();
        await env.advance(const Duration(milliseconds: 6999));
        expect(env.runs, 1, reason: 'still 10 s from the first run start');
        await env.advance(_ms1);
        expect(env.runs, 2);
        expect(env.state, EchoesShown(_ready('new')));
      },
    );

    test(
      'a new access for the same vault keeps a re-run in flight and its refreshing result',
      () async {
        final env = _Wi426Env.start(
          script: (e) => e
            ..enqueue(_ready('old'))
            ..enqueue(_ready('new')),
        );
        await env.flush();
        await env.advance(_s10);
        final gate = env.hold();
        await env.bump();
        expect(env.runs, 2);
        expect(env.state, EchoesShown(_ready('old'), refreshing: true));

        env.c.invalidate(vaultAccessProvider);
        await env.flush();
        expect(env.runs, 2);
        expect(env.echoes.maxInFlight, 1);
        expect(env.state, EchoesShown(_ready('old'), refreshing: true));

        await env.release(gate);
        expect(env.state, EchoesShown(_ready('new')));
      },
    );

    test(
      'a new access for the same vault keeps an in-flight download downloading',
      () async {
        final env = _Wi426Env.start(script: (e) => e.result = _ready('a'));
        await env.flush();
        final gate = env.hold();
        await env.press((n) => n.download());
        expect(env.state, const EchoesDownloading());

        env.c.invalidate(vaultAccessProvider);
        await env.flush();
        expect(env.state, const EchoesDownloading());
        expect(env.runs, 2);
        expect(env.echoes.maxInFlight, 1);
        await env.release(gate);
        expect(env.state, EchoesShown(_ready('a')));
      },
    );

    test(
      'the next run after a new access for the same vault uses it',
      () async {
        final env = _Wi426Env.start(script: (e) => e.result = _ready('old'));
        await env.flush();
        final second = _Wi426Echoes()..result = _ready('second');
        env.c.read(_wi426EchoesSource.notifier).state = second;
        await env.flush();
        expect(env.runs, 1, reason: 'the swap alone runs nothing');
        expect(second.calls, isEmpty);

        await env.advance(_s10);
        await env.bump();
        expect(second.calls.length, 1);
        expect(env.runs, 1, reason: 'the old access gets no more calls');
        expect(env.state, EchoesShown(_ready('second')));
      },
    );

    test('an access that arrives for the open vault runs once', () async {
      final env = _Wi426Env.start(script: (e) => e.result = _ready('a'));
      env.c.read(_wi426EchoesSource.notifier).state = null;
      await env.flush();
      await env.advance(_s60);
      expect(env.runs, 0, reason: 'no access, no run');
      expect(env.state, isNot(isA<EchoesError>()));

      final late = _Wi426Echoes()..result = _ready('late');
      env.c.read(_wi426EchoesSource.notifier).state = late;
      await env.flush();
      expect(late.calls.length, 1);
      expect(env.state, EchoesShown(_ready('late')));
      await env.advance(_s60);
      expect(late.calls.length, 1);
    });

    test('losing the access cancels the spaced re-run', () async {
      final env = _Wi426Env.start(script: (e) => e.result = _ready('a'));
      await env.flush();
      await env.advance(_s3);
      await env.bump();
      expect(env.clock.pendingTimers, 1);

      env.c.read(_wi426EchoesSource.notifier).state = null;
      await env.flush();
      expect(env.clock.pendingTimers, 0);
      await env.advance(_s60);
      expect(env.runs, 1);
    });

    test('echoes runs nothing and does not throw with no vault open', () async {
      final clock = FakeClock();
      final c = ProviderContainer(
        overrides: [
          clockProvider.overrideWithValue(clock),
          vaultAccessProvider.overrideWith((_) => null),
        ],
      );
      addTearDown(c.dispose);
      c.read(selectedNoteIdProvider.notifier).state = 'n1';
      c.read(rightPanelOpenProvider.notifier).state = true;
      c.read(rightPanelTabProvider.notifier).state = RightPanelTab.echoes;
      c.listen<EchoesViewState>(echoesAsyncProvider, (_, _) {});
      await Future<void>.delayed(Duration.zero);
      c.read(vaultRevisionProvider.notifier).state++;
      clock.advance(_s60);
      await Future<void>.delayed(Duration.zero);
      await c.read(echoesAsyncProvider.notifier).download();
      await c.read(echoesAsyncProvider.notifier).retry();
      await c.read(echoesAsyncProvider.notifier).linkCompleted();
      expect(clock.pendingTimers, 0);
      expect(c.read(echoesAsyncProvider), isNot(isA<EchoesError>()));
    });
  });
}
