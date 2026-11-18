// WI #38 (A4; Spec #31 req 10, 15, 16, 16a, 18, 22, 23; D2, D4, D14, D17):
// the update modal. Every test renders from A0's FakeUpdateController
// (updater_fakes.dart) under `pumpUpdaterHarness`, so no test waits on the
// real controller (#37). Local doubles carry a `_38` prefix.
//
// Copy is Spec #31 req 15's tables verbatim. Indeterminate spinners animate
// forever, so these tests pump fixed frames and never pumpAndSettle.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/agent_activity.dart';
import 'package:open_memex_app/src/state/unsent_hosted_text.dart';
import 'package:open_memex_app/src/state/url_opener.dart';
import 'package:open_memex_app/src/updater/appcast.dart';
import 'package:open_memex_app/src/updater/update_controller.dart';
import 'package:open_memex_app/src/updater/update_modal.dart';
import 'package:open_memex_app/src/updater/update_state.dart';
import 'package:open_memex_app/src/vault_access/agents_access.dart';
import 'package:open_memex_app/src/widgets/atoms.dart';
import 'package:open_memex_app/src/widgets/dialog_button.dart';

import '../support/font_fetch_hold.dart';
import '../support/updater_fakes.dart';
import '../support/updater_harness.dart';

// ------------------------------------------------------------------ finders

Finder _k(String key) => find.byKey(Key(key));

Finder get _modal => _k('update-modal');

Finder _inModal(Finder matching) =>
    find.descendant(of: _modal, matching: matching);

/// Every action Key the Spec lists, in no particular order.
const _actionKeys = [
  'update-modal-close',
  'update-modal-later',
  'update-modal-install',
  'update-modal-relaunch',
  'update-modal-try-again',
  'update-modal-download-github',
];

/// The action Keys shown, left to right.
List<String> _actions(WidgetTester tester) {
  final shown = [
    for (final k in _actionKeys)
      if (_k(k).evaluate().isNotEmpty) k,
  ];
  shown.sort(
    (a, b) =>
        tester.getTopLeft(_k(a)).dx.compareTo(tester.getTopLeft(_k(b)).dx),
  );
  return shown;
}

/// The labels of the shown actions, left to right.
List<String> _actionLabels(WidgetTester tester) => [
  for (final k in _actions(tester)) tester.widget<DialogButton>(_k(k)).label,
];

/// The data of the one Text keyed [key]; fails the test when it is missing.
String? _textOf(WidgetTester tester, String key) {
  expect(_k(key), findsOneWidget, reason: 'the modal shows $key');
  return tester.widget<Text>(_k(key)).data;
}

String? _title(WidgetTester tester) => _textOf(tester, 'update-modal-title');

String? _body(WidgetTester tester) => _textOf(tester, 'update-modal-body');

// ------------------------------------------------------------------ pumping

/// Lets the dialog route's transition finish without settling forever.
Future<void> _frames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// Pumps the harness over [controller] (a [FakeUpdateController] at [state]
/// by default) and opens the modal.
Future<UpdaterHarness> _open(
  WidgetTester tester, {
  UpdateState state = const UpdateIdle(),
  FakeUpdateController? controller,
  UpdaterFakes? fakes,
  List<Override> overrides = const [],
}) async {
  final h = await pumpUpdaterHarness(
    tester,
    fakes: fakes,
    controller: controller ?? FakeUpdateController(state),
    overrides: overrides,
  );
  unawaited(openUpdateModal(h.context, h.container.read));
  await _frames(tester);
  return h;
}

/// An item built from run-time values (never `const`).
AppcastItem _wi38Item({
  String version = '1.4.2',
  String? notes,
  String? link,
}) => testAppcastItem(
  shortVersionString: version,
  version: '${version.split('.').last}1',
  notes: notes,
  link: link,
);

// ------------------------------------------------------------------ doubles

/// A [FakeUpdateController] whose install, try again and relaunch stay in
/// flight until [hold] completes, so a test can press again mid-action.
class _Wi38HeldController extends FakeUpdateController {
  _Wi38HeldController(super.initial);

  Completer<void> hold = Completer<void>();

  @override
  Future<void> install() async {
    await super.install();
    await hold.future;
  }

  @override
  Future<void> tryAgain() async {
    await super.tryAgain();
    await hold.future;
  }

  @override
  Future<RelaunchOutcome> relaunch({
    required Future<bool> Function() confirmQuit,
  }) async {
    calls.add('relaunch');
    await hold.future;
    return RelaunchOutcome.exiting;
  }
}

/// A [FakeUpdateController] whose relaunch waits on [hold], then either
/// asks its `confirmQuit` (recording the answer) or answers [outcome].
class _Wi38LateRelaunch extends FakeUpdateController {
  _Wi38LateRelaunch(super.initial, {this.outcome, this.ask = false});

  final RelaunchOutcome? outcome;
  final bool ask;
  final Completer<void> hold = Completer<void>();

  @override
  Future<RelaunchOutcome> relaunch({
    required Future<bool> Function() confirmQuit,
  }) async {
    calls.add('relaunch');
    await hold.future;
    if (ask) {
      final confirmed = await confirmQuit();
      confirmQuitAnswers.add(confirmed);
      // D2: a refused quit is a cancelled relaunch, like the real controller.
      if (!confirmed) return RelaunchOutcome.cancelled;
    }
    return outcome ?? RelaunchOutcome.exiting;
  }
}

/// A [FakeUpdateController] whose `later()` moves to Idle, as the real
/// controller's does on Update available (req 16a).
class _Wi38LaterGoesIdle extends FakeUpdateController {
  _Wi38LaterGoesIdle(super.initial);

  @override
  void later() {
    super.later();
    emit(const UpdateIdle());
  }
}

/// A url opener whose open stays in flight until [hold] completes.
class _Wi38HeldOpener implements UrlOpener {
  final List<String> opened = [];
  final Completer<void> hold = Completer<void>();

  @override
  Future<void> open(String url) async {
    opened.add(url);
    await hold.future;
  }
}

/// A scripted agents view: [build] answers [first]; [push] replaces the
/// value; [reload] goes back to loading with the old value kept, as after a
/// vault switch (agent_activity.dart, seam convention).
class _Wi38Agents extends AgentActivityNotifier {
  _Wi38Agents(this.first);

  final FutureOr<AgentActivityView> Function() first;

  @override
  FutureOr<AgentActivityView> build() => first();

  void push(AgentActivityView view) => state = AsyncData(view);

  void reload() {
    final previous = state;
    state = const AsyncLoading<AgentActivityView>().copyWithPrevious(
      previous,
      isRefresh: false,
    );
  }
}

AgentActivityView _wi38View({required int agents}) => AgentActivityView(
  connected: [
    for (var i = 0; i < agents; i++)
      ConnectedAgent(
        presence: AgentPresence(
          sessionId: 'session-38-$i',
          clientName: 'Claude Desktop',
          transport: 'stdio',
          startedAt: 1000 + i,
          lastSeenAt: 2000 + i,
          lastRequestAt: 3000 + i,
          expiresAt: 9000000000000,
          embeddings: false,
        ),
        working: false,
      ),
  ],
  recent: const [],
  available: true,
  clockOffsetMs: 0,
);

const _agentLine =
    'Connected agents keep using the current memex until they restart.';

const _releasesPage = 'https://github.com/connordodge/open_memex/releases';

void main() {
  holdFontFetches();

  // ---------------------------------------------------------------- states

  group('states', () {
    testWidgets('checking shows its title a spinner and close', (tester) async {
      await _open(tester, state: const UpdateChecking());

      expect(_modal, findsOneWidget);
      expect(_title(tester), 'Checking for updates');
      expect(_inModal(find.text('Checking for updates')), findsOneWidget);
      final spinner = tester.widget(_k('update-modal-progress'));
      expect(spinner, isA<CircularProgressIndicator>());
      expect((spinner as ProgressIndicator).value, isNull);
      expect(_actions(tester), ['update-modal-close']);
      expect(_actionLabels(tester), ['close']);
    });

    testWidgets('up to date shows its title the installed version and close', (
      tester,
    ) async {
      final fakes = UpdaterFakes()..appVersion = ['2', '4', '6'].join('.');
      await _open(tester, state: const UpdateUpToDate(), fakes: fakes);

      expect(find.text("You're up to date"), findsOneWidget);
      expect(_title(tester), "You're up to date");
      expect(_body(tester), 'Open Memex 2.4.6 is the newest version.');
      expect(_k('update-modal-progress'), findsNothing);
      expect(_actions(tester), ['update-modal-close']);
      expect(_actionLabels(tester), ['close']);
    });

    testWidgets(
      'available shows its title the new version the notes later and install',
      (tester) async {
        final item = _wi38Item(notes: '## v1.4.2\n- Faster search');
        await _open(tester, state: UpdateAvailable(item));

        expect(_title(tester), 'Update available');
        expect(_body(tester), 'Version 1.4.2 is available.');
        expect(
          find.descendant(
            of: _k('update-modal-notes'),
            matching: find.text('## v1.4.2\n- Faster search'),
          ),
          findsOneWidget,
        );
        expect(_actions(tester), [
          'update-modal-later',
          'update-modal-install',
        ]);
        expect(_actionLabels(tester), ['later', 'install']);
      },
    );

    testWidgets(
      'downloading shows its title a progress bar with the percent and later',
      (tester) async {
        await _open(
          tester,
          state: UpdateDownloading(_wi38Item(), progress: 0.42),
        );

        expect(_title(tester), 'Downloading update');
        final bar = tester.widget(_k('update-modal-progress'));
        expect(bar, isA<LinearProgressIndicator>());
        expect((bar as ProgressIndicator).value, 0.42);
        expect(_body(tester), '42%');
        expect(_inModal(find.text('42%')), findsOneWidget);
        expect(_actions(tester), ['update-modal-later']);
        expect(_actionLabels(tester), ['later']);
      },
    );

    testWidgets(
      'downloading with an unknown length shows an indeterminate bar',
      (tester) async {
        await _open(tester, state: UpdateDownloading(_wi38Item()));

        expect(_title(tester), 'Downloading update');
        final bar = tester.widget(_k('update-modal-progress'));
        expect(bar, isA<LinearProgressIndicator>());
        expect((bar as ProgressIndicator).value, isNull);
        expect(_inModal(find.textContaining(RegExp(r'\d+%'))), findsNothing);
        expect(_actions(tester), ['update-modal-later']);
      },
    );

    for (final (name, progress, percent) in [
      ('downloading at 0.57 shows 57 percent', 0.57, '57%'),
      ('downloading at the start shows 0 percent', 0.0, '0%'),
      ('downloading at the end shows 100 percent', 1.0, '100%'),
    ]) {
      testWidgets(name, (tester) async {
        final h = await _open(
          tester,
          state: UpdateDownloading(_wi38Item(), progress: progress),
        );

        expect(_body(tester), percent);
        final bar = tester.widget<ProgressIndicator>(
          _k('update-modal-progress'),
        );
        expect(bar.value, progress);
        expect(h.controller!.current, isA<UpdateDownloading>());
      });
    }

    testWidgets(
      'verifying shows its title a spinner the signature line and later',
      (tester) async {
        await _open(tester, state: UpdateVerifying(_wi38Item()));

        expect(_title(tester), 'Verifying update');
        final spinner = tester.widget(_k('update-modal-progress'));
        expect(spinner, isA<CircularProgressIndicator>());
        expect((spinner as ProgressIndicator).value, isNull);
        expect(_body(tester), "Checking the update's signature.");
        expect(_actions(tester), ['update-modal-later']);
        expect(_actionLabels(tester), ['later']);
      },
    );

    testWidgets(
      'ready shows its title the downloaded version later and relaunch',
      (tester) async {
        await _open(
          tester,
          state: UpdateReady(
            _wi38Item(version: '1.5.0'),
            dmgPath: '/updater/a.dmg',
          ),
        );

        expect(_title(tester), 'Update ready');
        expect(
          _body(tester),
          'Version 1.5.0 is downloaded. Relaunch to apply it.',
        );
        expect(find.text(_agentLine), findsNothing);
        expect(_actions(tester), [
          'update-modal-later',
          'update-modal-relaunch',
        ]);
        expect(_actionLabels(tester), ['later', 'relaunch']);
      },
    );

    testWidgets('the open modal follows the controller state', (tester) async {
      final controller = FakeUpdateController(UpdateAvailable(_wi38Item()));
      await _open(tester, controller: controller);
      expect(_title(tester), 'Update available');

      controller.emit(UpdateDownloading(_wi38Item(), progress: 0.25));
      await tester.pump();
      expect(_title(tester), 'Downloading update');
      expect(_body(tester), '25%');

      controller.emit(UpdateVerifying(_wi38Item()));
      await tester.pump();
      expect(_title(tester), 'Verifying update');

      controller.emit(UpdateReady(_wi38Item(), dmgPath: '/updater/b.dmg'));
      await tester.pump();
      expect(_title(tester), 'Update ready');
      expect(_modal, findsOneWidget);
    });
  });

  // ---------------------------------------------------------------- errors

  group('check failures', () {
    for (final (name, cause, body) in [
      (
        'offline check failure shows its body close and try again',
        UpdateErrorCause.offline,
        "Open Memex couldn't reach the update feed. Check your connection and "
            'try again.',
      ),
      (
        'unreadable feed check failure shows its body close and try again',
        UpdateErrorCause.feedUnreadable,
        "The update feed couldn't be read. Try again later.",
      ),
      (
        'unpublished appcast check failure shows its body close and try again',
        UpdateErrorCause.noAppcast,
        'No updates have been published yet.',
      ),
    ]) {
      testWidgets(name, (tester) async {
        await _open(tester, state: UpdateError(cause));

        expect(_title(tester), 'Update check failed');
        expect(_body(tester), body);
        expect(_actions(tester), [
          'update-modal-close',
          'update-modal-try-again',
        ]);
        expect(_actionLabels(tester), ['close', 'try again']);
      });
    }
  });

  group('install failures', () {
    for (final (name, error, body, actions) in [
      (
        'bad signature install failure shows its body close and try again',
        UpdateError(UpdateErrorCause.badSignature, item: _wi38Item()),
        "The update isn't signed by the Open Memex release key, so it wasn't "
            'installed.',
        ['update-modal-close', 'update-modal-try-again'],
      ),
      (
        'missing signature install failure shows its body close and try again',
        UpdateError(UpdateErrorCause.noSignature, item: _wi38Item()),
        "The update has no signature, so it wasn't installed.",
        ['update-modal-close', 'update-modal-try-again'],
      ),
      (
        'missing public key install failure shows its body close and download from GitHub',
        UpdateError(UpdateErrorCause.noPublicKey, item: _wi38Item()),
        "This build can't verify updates. Download the update from GitHub "
            'instead.',
        ['update-modal-close', 'update-modal-download-github'],
      ),
      (
        'failed download install failure shows its body close and try again',
        UpdateError(UpdateErrorCause.downloadFailed, item: _wi38Item()),
        "The download didn't finish. Check your connection and try again.",
        ['update-modal-close', 'update-modal-try-again'],
      ),
      (
        'folder not writable install failure names the folder and offers download from GitHub',
        UpdateError(
          UpdateErrorCause.folderNotWritable,
          item: _wi38Item(),
          folder: ['', 'Applications', 'Utilities'].join('/'),
        ),
        "Open Memex can't replace itself in /Applications/Utilities. Download "
            'the update from GitHub instead.',
        ['update-modal-close', 'update-modal-download-github'],
      ),
      (
        'disk image install failure shows its body and close only',
        UpdateError(UpdateErrorCause.diskImage, item: _wi38Item()),
        "Open Memex is running from a disk image or a temporary location, so "
            "it can't replace itself. Move Open Memex to your Applications "
            'folder, open it from there and try again.',
        ['update-modal-close'],
      ),
      (
        'recorded failure names the reason and the installed version with close and try again',
        UpdateError(
          UpdateErrorCause.failureRecorded,
          reason: "the new app couldn't be copied",
        ),
        "The last update couldn't be installed: the new app couldn't be "
            'copied. Open Memex is still on 1.2.3.',
        ['update-modal-close', 'update-modal-try-again'],
      ),
    ]) {
      testWidgets(name, (tester) async {
        await _open(tester, state: error);

        expect(_title(tester), 'Update failed');
        expect(_body(tester), body);
        expect(_actions(tester), actions);
        expect(_actionLabels(tester), [
          for (final a in actions)
            switch (a) {
              'update-modal-close' => 'close',
              'update-modal-try-again' => 'try again',
              _ => 'download from GitHub',
            },
        ]);
      });
    }

    testWidgets('a recorded failure names the installed version it reads', (
      tester,
    ) async {
      final fakes = UpdaterFakes()..appVersion = ['3', '0', '1'].join('.');
      await _open(
        tester,
        fakes: fakes,
        state: const UpdateError(
          UpdateErrorCause.failureRecorded,
          reason: "the app didn't quit in time",
        ),
      );

      expect(
        _body(tester),
        "The last update couldn't be installed: the app didn't quit in time. "
        'Open Memex is still on 3.0.1.',
      );
    });
  });

  // ---------------------------------------------------------------- off

  group('updates off', () {
    for (final (name, state) in [
      (
        'with updates off the modal shows the off copy and close',
        const UpdateChecking() as UpdateState,
      ),
      (
        'with updates off a ready controller still shows the off copy',
        UpdateReady(_wi38Item(), dmgPath: '/updater/c.dmg') as UpdateState,
      ),
    ]) {
      testWidgets(name, (tester) async {
        final fakes = UpdaterFakes()..updatesEnabled = false;
        await _open(tester, state: state, fakes: fakes);

        expect(_modal, findsOneWidget);
        expect(_title(tester), 'Updates are off');
        expect(_body(tester), 'Updates are off in development builds.');
        expect(_k('update-modal-progress'), findsNothing);
        expect(_actions(tester), ['update-modal-close']);
        expect(_actionLabels(tester), ['close']);

        await tester.tap(_k('update-modal-close'));
        await _frames(tester);
        expect(_modal, findsNothing);
      });
    }
  });

  // ---------------------------------------------------------------- notes

  group('release notes', () {
    testWidgets(
      'the release notes show the raw markdown as selectable plain text',
      (tester) async {
        const raw = '## What is new\n\n- **Bold** item\n- [link](https://x.y)';
        await _open(tester, state: UpdateAvailable(_wi38Item(notes: raw)));

        final notes = _k('update-modal-notes');
        expect(notes, findsOneWidget);
        expect(
          find.descendant(of: notes, matching: find.text(raw)),
          findsOneWidget,
          reason: 'the Markdown is shown as written, not rendered',
        );
        expect(
          find.descendant(of: notes, matching: find.text('Bold item')),
          findsNothing,
        );
        final selectable =
            find
                .descendant(of: notes, matching: find.byType(SelectableText))
                .evaluate()
                .isNotEmpty ||
            find
                .ancestor(
                  of: find.descendant(of: notes, matching: find.text(raw)),
                  matching: find.byType(SelectionArea),
                )
                .evaluate()
                .isNotEmpty;
        expect(selectable, isTrue, reason: 'the notes text can be selected');
      },
    );

    testWidgets(
      'long release notes scroll inside a box at most 240 pixels tall',
      (tester) async {
        final long = [
          for (var i = 0; i < 120; i++) '- change number $i',
        ].join('\n');
        await _open(tester, state: UpdateAvailable(_wi38Item(notes: long)));

        final notes = _k('update-modal-notes');
        expect(notes, findsOneWidget);
        final box = tester.widget<ConstrainedBox>(notes);
        expect(box.constraints.maxHeight, 240);
        final height = tester.getSize(notes).height;
        expect(height, lessThanOrEqualTo(240));
        expect(height, greaterThan(200), reason: 'long notes fill the box');
        final scrollable = find.descendant(
          of: notes,
          matching: find.byType(Scrollable),
        );
        expect(scrollable, findsWidgets);
        final position = tester
            .state<ScrollableState>(scrollable.first)
            .position;
        expect(position.maxScrollExtent, greaterThan(0));
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('short release notes take only the height they need', (
      tester,
    ) async {
      await _open(
        tester,
        state: UpdateAvailable(_wi38Item(notes: 'One line of notes')),
      );

      final height = tester.getSize(_k('update-modal-notes')).height;
      expect(height, lessThan(240));
      expect(height, greaterThan(0));
    });
  });

  // ---------------------------------------------------------------- actions

  group('actions', () {
    testWidgets(
      'install calls the controller install and keeps the modal open',
      (tester) async {
        final h = await _open(tester, state: UpdateAvailable(_wi38Item()));

        await tester.tap(_k('update-modal-install'));
        await _frames(tester);

        expect(h.controller!.calls, ['install']);
        expect(_modal, findsOneWidget);
      },
    );

    testWidgets(
      'try again calls the controller tryAgain and keeps the modal open',
      (tester) async {
        final h = await _open(
          tester,
          state: const UpdateError(UpdateErrorCause.offline),
        );

        await tester.tap(_k('update-modal-try-again'));
        await _frames(tester);

        expect(h.controller!.calls, ['tryAgain']);
        expect(_modal, findsOneWidget);
      },
    );

    for (final (name, state) in [
      (
        'later on an available update calls later and closes the modal',
        UpdateAvailable(_wi38Item()) as UpdateState,
      ),
      (
        'later while downloading calls later and closes the modal',
        UpdateDownloading(_wi38Item(), progress: 0.3) as UpdateState,
      ),
      (
        'later while verifying calls later and closes the modal',
        UpdateVerifying(_wi38Item()) as UpdateState,
      ),
      (
        'later on a ready update calls later and closes the modal',
        UpdateReady(_wi38Item(), dmgPath: '/updater/d.dmg') as UpdateState,
      ),
    ]) {
      testWidgets(name, (tester) async {
        final h = await _open(tester, state: state);

        await tester.tap(_k('update-modal-later'));
        await _frames(tester);

        expect(h.controller!.calls, ['later']);
        expect(_modal, findsNothing);
        expect(h.context.mounted, isTrue, reason: 'only the modal closed');
      });
    }

    for (final (name, state) in [
      (
        'close on checking closes the modal without an action call',
        const UpdateChecking() as UpdateState,
      ),
      (
        'close on up to date closes the modal without an action call',
        const UpdateUpToDate() as UpdateState,
      ),
      (
        'close on a check failure closes the modal without an action call',
        const UpdateError(UpdateErrorCause.feedUnreadable) as UpdateState,
      ),
      (
        'close on an install failure closes the modal without an action call',
        UpdateError(UpdateErrorCause.downloadFailed, item: _wi38Item())
            as UpdateState,
      ),
    ]) {
      testWidgets(name, (tester) async {
        final h = await _open(tester, state: state);

        await tester.tap(_k('update-modal-close'));
        await _frames(tester);

        expect(_modal, findsNothing);
        expect(h.context.mounted, isTrue);
        final calls = h.controller!.calls;
        for (final action in ['install', 'tryAgain', 'relaunch']) {
          expect(calls, isNot(contains(action)));
        }
      });
    }
  });

  // ---------------------------------------------------------------- relaunch

  group('relaunch', () {
    List<Override> unsent() => [
      hasUnsentHostedTextProvider.overrideWithValue(true),
      unsentHostedTextProvider.overrideWithValue(
        UnsentHostedText(
          serverName: 'nas',
          vaultName: 'seed',
          notes: [
            UnsentHostedNote(
              title: 'Draft 38',
              since: DateTime.utc(2026, 3, 8, 9, 30),
            ),
          ],
        ),
      ),
    ];

    testWidgets(
      'relaunch with unsent hosted text asks the quit leave confirm and passes proceed',
      (tester) async {
        final h = await _open(
          tester,
          state: UpdateReady(_wi38Item(), dmgPath: '/updater/e.dmg'),
          overrides: unsent(),
        );

        await tester.tap(_k('update-modal-relaunch'));
        await _frames(tester);

        expect(h.controller!.calls, ['relaunch']);
        expect(_k('leave-confirm'), findsOneWidget);
        expect(find.text('quit anyway'), findsOneWidget);
        expect(h.controller!.confirmQuitAnswers, isEmpty);

        await tester.tap(_k('leave-confirm-proceed'));
        await _frames(tester);

        expect(h.controller!.confirmQuitAnswers, [true]);
        expect(_k('leave-confirm'), findsNothing);
      },
    );

    testWidgets(
      'relaunch cancelled at the leave confirm closes the modal and passes false',
      (tester) async {
        final h = await _open(
          tester,
          state: UpdateReady(_wi38Item(), dmgPath: '/updater/f.dmg'),
          overrides: unsent(),
        );

        await tester.tap(_k('update-modal-relaunch'));
        await _frames(tester);
        await tester.tap(_k('leave-confirm-cancel'));
        await _frames(tester);

        expect(h.controller!.confirmQuitAnswers, [false]);
        expect(_k('leave-confirm'), findsNothing);
        expect(_modal, findsNothing);
        expect(h.context.mounted, isTrue);
        expect(h.controller!.current, isA<UpdateReady>());
      },
    );

    testWidgets('relaunch with nothing unsent confirms without a dialog', (
      tester,
    ) async {
      final h = await _open(
        tester,
        state: UpdateReady(_wi38Item(), dmgPath: '/updater/g.dmg'),
      );

      await tester.tap(_k('update-modal-relaunch'));
      await _frames(tester);

      expect(h.controller!.calls, ['relaunch']);
      expect(h.controller!.confirmQuitAnswers, [true]);
      expect(_k('leave-confirm'), findsNothing);
    });

    testWidgets('a relaunch that fails keeps the modal open', (tester) async {
      final controller = FakeUpdateController(
        UpdateReady(_wi38Item(), dmgPath: '/updater/h.dmg'),
      )..relaunchOutcome = RelaunchOutcome.failed;
      final h = await _open(tester, controller: controller);

      await tester.tap(_k('update-modal-relaunch'));
      await _frames(tester);
      controller.emit(const UpdateError(UpdateErrorCause.diskImage));
      await _frames(tester);

      expect(h.controller!.calls, ['relaunch']);
      expect(_modal, findsOneWidget);
      expect(_title(tester), 'Update failed');
    });
  });

  // ---------------------------------------------------------------- GitHub

  group('download from GitHub', () {
    const tag = 'https://github.com/connordodge/open_memex/releases/tag/v1.4.2';
    for (final (name, cause, link, opened) in [
      (
        'download from GitHub opens the item release page link',
        UpdateErrorCause.noPublicKey,
        tag,
        tag,
      ),
      (
        'download from GitHub on a folder failure opens the item release page link',
        UpdateErrorCause.folderNotWritable,
        tag,
        tag,
      ),
      (
        'download from GitHub with a link off the releases path opens the releases page',
        UpdateErrorCause.noPublicKey,
        'https://evil.example/open_memex/releases/tag/v1.4.2',
        _releasesPage,
      ),
      (
        'download from GitHub with a lookalike repo link opens the releases page',
        UpdateErrorCause.folderNotWritable,
        'https://github.com/connordodge/open_memex_fork/releases/tag/v1.4.2',
        _releasesPage,
      ),
      (
        'download from GitHub with a link missing the releases slash opens the releases page',
        UpdateErrorCause.noPublicKey,
        'https://github.com/connordodge/open_memex/releasesx/tag/v1.4.2',
        _releasesPage,
      ),
      (
        'download from GitHub with an http link opens the releases page',
        UpdateErrorCause.noPublicKey,
        'http://github.com/connordodge/open_memex/releases/tag/v1.4.2',
        _releasesPage,
      ),
      (
        'download from GitHub with a dot dot segment in the link opens the releases page',
        UpdateErrorCause.noPublicKey,
        '$_releasesPage/../../../attacker/repo/releases',
        _releasesPage,
      ),
      (
        'download from GitHub with a dot dot segment after a page in the link opens the releases page',
        UpdateErrorCause.noPublicKey,
        '$_releasesPage/tag/v1.4.2/..',
        _releasesPage,
      ),
      (
        'download from GitHub with a dot segment in the link opens the releases page',
        UpdateErrorCause.noPublicKey,
        '$_releasesPage/./tag/v1.4.2',
        _releasesPage,
      ),
      (
        'download from GitHub with an encoded dot dot segment in the link opens the releases page',
        UpdateErrorCause.noPublicKey,
        '$_releasesPage/%2e%2e/%2e%2e/x/y',
        _releasesPage,
      ),
      (
        'download from GitHub with an upper case encoded dot in the link opens the releases page',
        UpdateErrorCause.noPublicKey,
        '$_releasesPage/tag/%2E%2E/v1.4.2',
        _releasesPage,
      ),
      (
        'download from GitHub with an encoded slash in the link opens the releases page',
        UpdateErrorCause.noPublicKey,
        '$_releasesPage/tag%2f..%2fv1.4.2',
        _releasesPage,
      ),
      (
        'download from GitHub with an upper case encoded slash in the link opens the releases page',
        UpdateErrorCause.noPublicKey,
        '$_releasesPage/tag%2Fv1.4.2',
        _releasesPage,
      ),
      (
        'download from GitHub with an encoded backslash in the link opens the releases page',
        UpdateErrorCause.noPublicKey,
        '$_releasesPage/tag%5Cv1.4.2',
        _releasesPage,
      ),
      (
        'download from GitHub with a backslash in the link opens the releases page',
        UpdateErrorCause.noPublicKey,
        '$_releasesPage/tag\\..\\v1.4.2',
        _releasesPage,
      ),
      (
        'download from GitHub with no page below releases in the link opens the releases page',
        UpdateErrorCause.noPublicKey,
        '$_releasesPage/',
        _releasesPage,
      ),
      (
        'download from GitHub with only a query below releases in the link opens the releases page',
        UpdateErrorCause.noPublicKey,
        '$_releasesPage/?tab=1',
        _releasesPage,
      ),
      (
        'download from GitHub with only a fragment below releases in the link opens the releases page',
        UpdateErrorCause.noPublicKey,
        '$_releasesPage/#top',
        _releasesPage,
      ),
      (
        'download from GitHub with dots only in the query opens the link as written',
        UpdateErrorCause.noPublicKey,
        '$tag?from=..#a/../b',
        '$tag?from=..#a/../b',
      ),
      (
        'download from GitHub with a download link opens the link as written',
        UpdateErrorCause.folderNotWritable,
        '$_releasesPage/download/v1.4.2/Open-Memex-1.4.2.dmg',
        '$_releasesPage/download/v1.4.2/Open-Memex-1.4.2.dmg',
      ),
      (
        'download from GitHub with an empty link opens the releases page',
        UpdateErrorCause.folderNotWritable,
        '',
        _releasesPage,
      ),
    ]) {
      testWidgets(name, (tester) async {
        final item = AppcastItem(
          version: '91',
          shortVersionString: '1.4.2',
          url:
              'https://github.com/connordodge/open_memex/releases/download/'
              'v1.4.2/Open-Memex-1.4.2-arm64.dmg',
          link: link,
        );
        final h = await _open(
          tester,
          state: UpdateError(
            cause,
            item: item,
            folder: ['', 'Applications'].join('/'),
          ),
        );

        await tester.tap(_k('update-modal-download-github'));
        await _frames(tester);

        expect(h.fakes.urlOpener.opened, [opened]);
      });
    }

    testWidgets('download from GitHub with no item opens the releases page', (
      tester,
    ) async {
      final h = await _open(
        tester,
        state: const UpdateError(UpdateErrorCause.noPublicKey),
      );

      await tester.tap(_k('update-modal-download-github'));
      await _frames(tester);

      expect(h.fakes.urlOpener.opened, [_releasesPage]);
    });
  });

  // ---------------------------------------------------------------- agents

  group('agent line', () {
    Override agents(_Wi38Agents notifier) =>
        agentActivityAsyncProvider.overrideWith(() => notifier);

    testWidgets('ready shows the agent line when a connected agent is listed', (
      tester,
    ) async {
      final notifier = _Wi38Agents(() => _wi38View(agents: 1));
      await _open(
        tester,
        state: UpdateReady(_wi38Item(), dmgPath: '/updater/i.dmg'),
        overrides: [agents(notifier)],
      );

      expect(_inModal(find.text(_agentLine)), findsOneWidget);
      expect(
        _body(tester),
        'Version 1.4.2 is downloaded. Relaunch to apply it.',
      );
    });

    testWidgets('ready hides the agent line with no connected agent', (
      tester,
    ) async {
      final notifier = _Wi38Agents(() => _wi38View(agents: 0));
      await _open(
        tester,
        state: UpdateReady(_wi38Item(), dmgPath: '/updater/j.dmg'),
        overrides: [agents(notifier)],
      );

      expect(_title(tester), 'Update ready');
      expect(find.text(_agentLine), findsNothing);
    });

    testWidgets('ready hides the agent line while the agent view is loading', (
      tester,
    ) async {
      final pending = Completer<AgentActivityView>();
      final notifier = _Wi38Agents(() => pending.future);
      await _open(
        tester,
        state: UpdateReady(_wi38Item(), dmgPath: '/updater/k.dmg'),
        overrides: [agents(notifier)],
      );

      expect(_title(tester), 'Update ready');
      expect(find.text(_agentLine), findsNothing);

      pending.complete(_wi38View(agents: 2));
      await _frames(tester);
      expect(_inModal(find.text(_agentLine)), findsOneWidget);
    });

    testWidgets(
      'ready hides the agent line while the agent view reloads with an old connected agent',
      (tester) async {
        final notifier = _Wi38Agents(() => _wi38View(agents: 1));
        await _open(
          tester,
          state: UpdateReady(_wi38Item(), dmgPath: '/updater/l.dmg'),
          overrides: [agents(notifier)],
        );
        expect(_inModal(find.text(_agentLine)), findsOneWidget);

        notifier.reload();
        await tester.pump();

        expect(find.text(_agentLine), findsNothing);
      },
    );

    testWidgets(
      'the agent line appears when an agent connects while the modal is open',
      (tester) async {
        final notifier = _Wi38Agents(() => _wi38View(agents: 0));
        await _open(
          tester,
          state: UpdateReady(_wi38Item(), dmgPath: '/updater/m.dmg'),
          overrides: [agents(notifier)],
        );
        expect(_title(tester), 'Update ready');
        expect(find.text(_agentLine), findsNothing);

        notifier.push(_wi38View(agents: 1));
        await tester.pump();
        expect(_inModal(find.text(_agentLine)), findsOneWidget);

        notifier.push(_wi38View(agents: 0));
        await tester.pump();
        expect(find.text(_agentLine), findsNothing);
      },
    );

    testWidgets('the agent line never shows outside ready', (tester) async {
      final notifier = _Wi38Agents(() => _wi38View(agents: 1));
      final controller = FakeUpdateController(UpdateAvailable(_wi38Item()));
      await _open(
        tester,
        controller: controller,
        overrides: [agents(notifier)],
      );
      expect(_modal, findsOneWidget);

      for (final state in <UpdateState>[
        UpdateAvailable(_wi38Item()),
        UpdateDownloading(_wi38Item(), progress: 0.5),
        UpdateVerifying(_wi38Item()),
        const UpdateUpToDate(),
        UpdateError(UpdateErrorCause.downloadFailed, item: _wi38Item()),
      ]) {
        controller.emit(state);
        await tester.pump();
        expect(_modal, findsOneWidget);
        expect(find.text(_agentLine), findsNothing, reason: '$state');
      }
    });
  });

  // ---------------------------------------------------------------- dedupe

  group('one modal', () {
    testWidgets('opening the modal while it is open shows one modal', (
      tester,
    ) async {
      final h = await _open(tester, state: const UpdateChecking());
      expect(_modal, findsOneWidget);

      unawaited(openUpdateModal(h.context, h.container.read));
      await _frames(tester);
      expect(_modal, findsOneWidget);

      unawaited(openUpdateModal(h.context, h.container.read));
      unawaited(openUpdateModal(h.context, h.container.read));
      await _frames(tester);
      expect(_modal, findsOneWidget);

      await tester.tap(_k('update-modal-close'));
      await _frames(tester);
      expect(_modal, findsNothing);
      expect(h.context.mounted, isTrue, reason: 'one close, one modal');
    });

    testWidgets('the modal opens again after it closed', (tester) async {
      final h = await _open(tester, state: const UpdateUpToDate());
      await tester.tap(_k('update-modal-close'));
      await _frames(tester);
      expect(_modal, findsNothing);

      unawaited(openUpdateModal(h.context, h.container.read));
      await _frames(tester);
      expect(_modal, findsOneWidget);
    });
  });

  // ---------------------------------------------------------------- presses

  group('presses', () {
    testWidgets('two install presses in the same frame call install once', (
      tester,
    ) async {
      final controller = _Wi38HeldController(UpdateAvailable(_wi38Item()));
      await _open(tester, controller: controller);

      await tester.tap(_k('update-modal-install'));
      await tester.tap(_k('update-modal-install'));
      await tester.pump();

      expect(controller.calls, ['install']);
      controller.hold.complete();
      await _frames(tester);
    });

    testWidgets('two relaunch presses in the same frame call relaunch once', (
      tester,
    ) async {
      final controller = _Wi38HeldController(
        UpdateReady(_wi38Item(), dmgPath: '/updater/n.dmg'),
      );
      await _open(tester, controller: controller);

      await tester.tap(_k('update-modal-relaunch'));
      await tester.tap(_k('update-modal-relaunch'));
      await tester.pump();

      expect(controller.calls, ['relaunch']);
      controller.hold.complete();
      await _frames(tester);
    });

    testWidgets('two try again presses in the same frame call tryAgain once', (
      tester,
    ) async {
      final controller = _Wi38HeldController(
        UpdateError(UpdateErrorCause.badSignature, item: _wi38Item()),
      );
      await _open(tester, controller: controller);

      await tester.tap(_k('update-modal-try-again'));
      await tester.tap(_k('update-modal-try-again'));
      await tester.pump();

      expect(controller.calls, ['tryAgain']);
      controller.hold.complete();
      await _frames(tester);
    });

    testWidgets('try again works again once the previous try again finished', (
      tester,
    ) async {
      final controller = _Wi38HeldController(
        const UpdateError(UpdateErrorCause.offline),
      );
      await _open(tester, controller: controller);

      await tester.tap(_k('update-modal-try-again'));
      await tester.pump();
      controller.hold.complete();
      await _frames(tester);
      controller.hold = Completer<void>()..complete();

      await tester.tap(_k('update-modal-try-again'));
      await _frames(tester);

      expect(controller.calls, ['tryAgain', 'tryAgain']);
    });

    testWidgets(
      'two later presses in the same frame call later once and close only the modal',
      (tester) async {
        final h = await _open(
          tester,
          state: UpdateDownloading(_wi38Item(), progress: 0.6),
        );

        await tester.tap(_k('update-modal-later'));
        await tester.tap(_k('update-modal-later'), warnIfMissed: false);
        await tester.pump();
        await _frames(tester);

        expect(h.controller!.calls, ['later']);
        expect(_modal, findsNothing);
        expect(h.context.mounted, isTrue, reason: 'the page under it stays');
      },
    );

    testWidgets('two close presses in the same frame close only the modal', (
      tester,
    ) async {
      final h = await _open(tester, state: const UpdateUpToDate());

      await tester.tap(_k('update-modal-close'));
      await tester.tap(_k('update-modal-close'), warnIfMissed: false);
      await tester.pump();
      await _frames(tester);

      expect(_modal, findsNothing);
      expect(h.context.mounted, isTrue, reason: 'the page under it stays');
    });

    testWidgets('a held enter key on install calls install once', (
      tester,
    ) async {
      final h = await _open(tester, state: UpdateAvailable(_wi38Item()));

      Focus.of(
        tester.element(
          find.descendant(
            of: _k('update-modal-install'),
            matching: find.byType(OmButton),
          ),
        ),
      ).requestFocus();
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      for (var i = 0; i < 3; i++) {
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.enter);
        await tester.pump();
      }
      await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
      await _frames(tester);

      expect(h.controller!.calls, ['install']);
    });
  });

  // ---------------------------------------------------------------- keys

  group('keys', () {
    testWidgets('every modal key sits on the element D17 names', (
      tester,
    ) async {
      final controller = FakeUpdateController(
        UpdateAvailable(_wi38Item(notes: 'notes 38')),
      );
      await _open(tester, controller: controller);

      expect(_modal, findsOneWidget);
      expect(tester.widget(_modal), isA<Container>());
      expect(tester.widget(_k('update-modal-title')), isA<Text>());
      expect(tester.widget(_k('update-modal-body')), isA<Text>());
      expect(tester.widget(_k('update-modal-notes')), isA<ConstrainedBox>());
      expect(tester.widget(_k('update-modal-later')), isA<DialogButton>());
      expect(tester.widget(_k('update-modal-install')), isA<DialogButton>());
      expect(
        find.descendant(of: _modal, matching: _k('update-modal-title')),
        findsOneWidget,
      );

      controller.emit(UpdateDownloading(_wi38Item(), progress: 0.1));
      await tester.pump();
      expect(
        tester.widget(_k('update-modal-progress')),
        isA<ProgressIndicator>(),
      );
      expect(tester.widget<Text>(_k('update-modal-body')).data, '10%');

      controller.emit(UpdateReady(_wi38Item(), dmgPath: '/updater/o.dmg'));
      await tester.pump();
      expect(tester.widget(_k('update-modal-relaunch')), isA<DialogButton>());

      controller.emit(const UpdateError(UpdateErrorCause.offline));
      await tester.pump();
      expect(tester.widget(_k('update-modal-close')), isA<DialogButton>());
      expect(tester.widget(_k('update-modal-try-again')), isA<DialogButton>());

      controller.emit(
        UpdateError(UpdateErrorCause.noPublicKey, item: _wi38Item()),
      );
      await tester.pump();
      expect(
        tester.widget(_k('update-modal-download-github')),
        isA<DialogButton>(),
      );
      for (final k in _actions(tester)) {
        expect(find.descendant(of: _modal, matching: _k(k)), findsOneWidget);
      }
    });
  });

  // ------------------------------------------------------- verify pins (#38)

  group('verify pins', () {
    testWidgets(
      'download from GitHub pressed twice in the same frame opens once',
      (tester) async {
        final opener = _Wi38HeldOpener();
        await _open(
          tester,
          state: const UpdateError(UpdateErrorCause.noPublicKey),
          overrides: [urlOpenerProvider.overrideWithValue(opener)],
        );

        await tester.tap(_k('update-modal-download-github'));
        await tester.tap(_k('update-modal-download-github'));
        await tester.pump();

        expect(opener.opened, [_releasesPage]);
        opener.hold.complete();
        await _frames(tester);
      },
    );

    testWidgets('empty release notes show no notes box', (tester) async {
      await _open(tester, state: UpdateAvailable(_wi38Item(notes: '')));

      expect(_title(tester), 'Update available');
      expect(_k('update-modal-notes'), findsNothing);
    });

    testWidgets('ready hides the agent line when the agent view failed', (
      tester,
    ) async {
      final notifier = _Wi38Agents(() => throw StateError('agents are down'));
      await _open(
        tester,
        state: UpdateReady(_wi38Item(), dmgPath: '/updater/p.dmg'),
        overrides: [agentActivityAsyncProvider.overrideWith(() => notifier)],
      );

      expect(_title(tester), 'Update ready');
      expect(find.text(_agentLine), findsNothing);
    });

    testWidgets(
      'a relaunch cancelled after the modal was dismissed pops no page under it',
      (tester) async {
        final controller = _Wi38LateRelaunch(
          UpdateReady(_wi38Item(), dmgPath: '/updater/q.dmg'),
          outcome: RelaunchOutcome.cancelled,
        );
        final h = await pumpUpdaterHarness(tester, controller: controller);
        unawaited(
          Navigator.of(h.context).push<void>(
            MaterialPageRoute<void>(
              builder: (_) => const Scaffold(key: Key('wi38-page-under')),
            ),
          ),
        );
        await _frames(tester);
        final under = find.byKey(const Key('wi38-page-under'));
        expect(under, findsOneWidget);
        final navigator = tester.state<NavigatorState>(
          find.byType(Navigator).first,
        );
        unawaited(openUpdateModal(h.context, h.container.read));
        await _frames(tester);

        await tester.tap(_k('update-modal-relaunch'));
        await tester.pump();
        navigator.pop();
        await tester.pump();
        expect(_modal, findsOneWidget, reason: 'still fading out');

        controller.hold.complete();
        await tester.pump();
        await _frames(tester);
        await _frames(tester);

        expect(_modal, findsNothing);
        expect(under, findsOneWidget, reason: 'only the modal was popped');
      },
    );

    testWidgets(
      'a relaunch asking to quit after the modal is gone answers no',
      (tester) async {
        final controller = _Wi38LateRelaunch(
          UpdateReady(_wi38Item(), dmgPath: '/updater/r.dmg'),
          ask: true,
        );
        await _open(
          tester,
          controller: controller,
          overrides: [
            hasUnsentHostedTextProvider.overrideWithValue(true),
            unsentHostedTextProvider.overrideWithValue(
              UnsentHostedText(
                serverName: 'nas',
                vaultName: 'seed',
                notes: [
                  UnsentHostedNote(
                    title: 'Draft 38b',
                    since: DateTime.utc(2026, 3, 8, 9, 30),
                  ),
                ],
              ),
            ),
          ],
        );

        await tester.tap(_k('update-modal-relaunch'));
        await tester.pump();
        await tester.tap(_k('update-modal-later'));
        await _frames(tester);
        expect(_modal, findsNothing);

        controller.hold.complete();
        await _frames(tester);

        expect(controller.confirmQuitAnswers, [false]);
        expect(_k('leave-confirm'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'later on update available keeps showing it while the modal fades out',
      (tester) async {
        final controller = _Wi38LaterGoesIdle(
          UpdateAvailable(_wi38Item(notes: 'Fixes.')),
        );
        await _open(tester, controller: controller);

        await tester.tap(_k('update-modal-later'));
        expect(controller.calls, ['later']);
        expect(controller.current, isA<UpdateIdle>());
        for (var i = 0; i < 4; i++) {
          await tester.pump(const Duration(milliseconds: 30));
          expect(_modal, findsOneWidget, reason: 'still fading, frame $i');
          expect(find.text('Checking for updates'), findsNothing);
          expect(_title(tester), 'Update available');
          expect(_k('update-modal-install'), findsOneWidget);
        }
        await _frames(tester);

        expect(_modal, findsNothing);
      },
    );

    testWidgets(
      'later on update ready keeps showing it while the modal fades out',
      (tester) async {
        final controller = _Wi38LaterGoesIdle(
          UpdateReady(_wi38Item(), dmgPath: '/updater/s.dmg'),
        );
        await _open(tester, controller: controller);

        await tester.tap(_k('update-modal-later'));
        await tester.pump(const Duration(milliseconds: 30));

        expect(find.text('Checking for updates'), findsNothing);
        expect(_title(tester), 'Update ready');
      },
    );

    testWidgets(
      'a relaunch cancelled after an escape dismiss pops no page and throws nothing',
      (tester) async {
        final controller = _Wi38LateRelaunch(
          UpdateReady(_wi38Item(), dmgPath: '/updater/t.dmg'),
          ask: true,
        );
        final h = await pumpUpdaterHarness(tester, controller: controller);
        unawaited(
          Navigator.of(h.context).push<void>(
            MaterialPageRoute<void>(
              builder: (_) => const Scaffold(key: Key('wi38-esc-page-under')),
            ),
          ),
        );
        await _frames(tester);
        final under = find.byKey(const Key('wi38-esc-page-under'));
        expect(under, findsOneWidget);
        unawaited(openUpdateModal(h.context, h.container.read));
        await _frames(tester);

        await tester.tap(_k('update-modal-relaunch'));
        await tester.pump();
        expect(controller.calls, ['relaunch']);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await _frames(tester);
        await _frames(tester);
        expect(_modal, findsNothing, reason: 'escape dismissed the modal');
        expect(under, findsOneWidget);

        controller.hold.complete();
        await _frames(tester);
        await _frames(tester);

        expect(controller.confirmQuitAnswers, [false]);
        expect(tester.takeException(), isNull);
        expect(under, findsOneWidget, reason: 'only the modal was popped');
        expect(_k('leave-confirm'), findsNothing);
      },
    );
  });

  // ---------------------------------------------------------------- busy

  group('busy actions', () {
    bool enabled(WidgetTester tester, String key) =>
        tester.widget<DialogButton>(_k(key)).onPressed != null;

    for (final (name, state, key, others) in [
      (
        'install shows disabled while it runs and enabled once it finished',
        UpdateAvailable(_wi38Item()),
        'update-modal-install',
        ['update-modal-later'],
      ),
      (
        'try again shows disabled while it runs and enabled once it finished',
        UpdateError(UpdateErrorCause.badSignature, item: _wi38Item()),
        'update-modal-try-again',
        ['update-modal-close'],
      ),
      (
        'relaunch shows disabled while it runs and enabled once it finished',
        UpdateReady(_wi38Item(), dmgPath: '/updater/u.dmg'),
        'update-modal-relaunch',
        ['update-modal-later'],
      ),
    ]) {
      testWidgets(name, (tester) async {
        final controller = _Wi38HeldController(state);
        await _open(tester, controller: controller);
        expect(enabled(tester, key), isTrue, reason: 'idle');

        await tester.tap(_k(key));
        await tester.pump();

        expect(enabled(tester, key), isFalse, reason: 'in flight');
        for (final other in others) {
          expect(enabled(tester, other), isTrue, reason: '$other stays on');
        }

        controller.hold.complete();
        await _frames(tester);

        expect(enabled(tester, key), isTrue, reason: 'finished');
      });
    }

    testWidgets(
      'download from GitHub shows disabled while it opens and enabled once it did',
      (tester) async {
        final opener = _Wi38HeldOpener();
        await _open(
          tester,
          state: const UpdateError(UpdateErrorCause.noPublicKey),
          overrides: [urlOpenerProvider.overrideWithValue(opener)],
        );
        expect(enabled(tester, 'update-modal-download-github'), isTrue);

        await tester.tap(_k('update-modal-download-github'));
        await tester.pump();

        expect(enabled(tester, 'update-modal-download-github'), isFalse);
        expect(enabled(tester, 'update-modal-close'), isTrue);

        opener.hold.complete();
        await _frames(tester);

        expect(enabled(tester, 'update-modal-download-github'), isTrue);
      },
    );

    testWidgets('close and later still close a modal while an action runs', (
      tester,
    ) async {
      final controller = _Wi38HeldController(UpdateAvailable(_wi38Item()));
      await _open(tester, controller: controller);

      await tester.tap(_k('update-modal-install'));
      await tester.pump();
      await tester.tap(_k('update-modal-later'));
      await _frames(tester);

      expect(controller.calls, ['install', 'later']);
      expect(_modal, findsNothing);
      controller.hold.complete();
      await _frames(tester);
      expect(tester.takeException(), isNull);
    });
  });
}
