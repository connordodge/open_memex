// WI #103 (H9, Req 51, board A9 states 3 and 4, pack 103): while hosted text
// couldn't reach the server, closing the window, quitting and switching vault
// show the A9 leave confirm; with none they go ahead with no dialog. Close
// and quit come through the app-exit seam (a FakeAppExitHost here), switching
// through #69's `leaveVaultGuardProvider` (sidebar vault pills and the vaults
// header "+ new", i.e. switch vault).
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:open_memex_app/src/screens/vault_picker.dart';
import 'package:open_memex_app/src/screens/workspace.dart';
import 'package:open_memex_app/src/state/app_exit.dart';
import 'package:open_memex_app/src/state/settings.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/unsent_hosted_text.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/widgets/atoms.dart';
import 'package:open_memex_app/src/widgets/sidebar.dart';
import 'package:path/path.dart' as p;

import '../support/app_exit_fakes.dart';
import '../support/app_harness.dart';
import '../support/fake_clock.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/poll_fakes.dart';
import '../support/vault_folders.dart';

const _confirm = Key('leave-confirm');
const _cancel = Key('leave-confirm-cancel');
const _proceed = Key('leave-confirm-proceed');
Key _row(int n) => Key('leave-confirm-note-$n');

/// The board A9 sample: vault "memex" on server "nas", one note.
final _boardSample = UnsentHostedText(
  serverName: 'nas',
  vaultName: 'memex',
  notes: [UnsentHostedNote(title: 'hosted vault plan', since: _at(14, 32))],
);

DateTime _at(int hour, int minute) => DateTime(2026, 10, 20, hour, minute);

/// [n] unsent notes titled "note 0" … with since-times a minute apart.
UnsentHostedText _manyNotes(int n) => UnsentHostedText(
  serverName: 'nas',
  vaultName: 'memex',
  notes: [
    for (var i = 0; i < n; i++)
      UnsentHostedNote(title: 'note $i', since: _at(10, i)),
  ],
);

/// The vaults header action ("+ new", drawn upper case): switch vault.
Finder _switchVaultAction() => find.descendant(
  of: find.ancestor(
    of: find.text('VAULTS'),
    matching: find.byType(PanelHeader),
  ),
  matching: find.text('+ NEW'),
);

/// The sidebar pill for the vault folder at [path].
Finder _pill(String path) => find.descendant(
  of: find.byType(Sidebar),
  matching: find.text(p.basename(path)),
);

Finder _inConfirm(Finder f) =>
    find.descendant(of: find.byKey(_confirm), matching: f);

/// The [OmButton] under Key [k] (the key may sit on the button itself).
Finder _buttonAt(Key k) => find
    .descendant(
      of: find.byKey(k),
      matching: find.byType(OmButton),
      matchRoot: true,
    )
    .first;

OmButton _button(WidgetTester tester, Key k) =>
    tester.widget<OmButton>(_buttonAt(k));

String _question(String server, String verb) =>
    "unsaved changes couldn't reach $server. $verb anyway?";

/// Pump frames, let any async settings write land, pump again.
Future<void> _settle(WidgetTester tester) async {
  await pumpFrames(tester);
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await pumpFrames(tester);
}

/// Put a second vault folder in the recents (so it has a sidebar pill) with
/// the open vault still first and last. Returns the second vault's path.
Future<String> _addSecondVault(WidgetTester tester, WorkspaceHarness h) async {
  final other = createVaultFolder('om103_pill_');
  final settings = h.read(settingsProvider.notifier);
  await tester.runAsync(() async {
    await settings.rememberVault(other.path);
    await settings.rememberVault(h.vaultPath);
  });
  await pumpFrames(tester);
  expect(_pill(other.path), findsOneWidget);
  return other.path;
}

/// The workspace with a [FakeAppExitHost], a second vault in the recents,
/// and the unsent-text seam reporting [unsent] (null: the default seam).
Future<(WorkspaceHarness, FakeAppExitHost, String)> _pump(
  WidgetTester tester, {
  UnsentHostedText? unsent,
}) async {
  final exit = FakeAppExitHost();
  final h = await pumpWorkspace(
    tester,
    overrides: [
      appExitHostProvider.overrideWithValue(exit),
      if (unsent != null) ...unsentTextOverrides(unsent),
    ],
  );
  final other = await _addSecondVault(tester, h);
  return (h, exit, other);
}

/// How the person tries to leave.
enum _Via { close, quit, pill, switchVault }

/// Start leaving [via] and pump until any confirm is up.
Future<void> _leave(
  WidgetTester tester,
  _Via via,
  FakeAppExitHost exit,
  String other,
) async {
  switch (via) {
    case _Via.close:
      unawaited(exit.requestClose());
    case _Via.quit:
      unawaited(exit.requestQuit());
    case _Via.pill:
      await tester.tap(_pill(other));
    case _Via.switchVault:
      await tester.tap(_switchVaultAction());
  }
  await _settle(tester);
}

/// The live workspace (today's daily note open) with a [FakeAppExitHost],
/// unsent text reported by the seam, a second vault in the recents and
/// [typed] in the editor, not yet saved.
Future<(LiveRobot, String)> _liveWithTypedText(
  WidgetTester tester,
  String typed,
) async {
  final db = FakeVaultDb.v5()
    ..seedLiveDaily(blocks: const [SeedBlock('p-morning', 'Morning pages')]);
  final clock = FakeClock(DateTime(2026, 10, 3, 9));
  final cli = FakeMemexCli()..onUpdateServer(db, clock: clock);
  final r = await pumpLiveWorkspace(
    tester,
    db: db,
    cli: cli,
    clock: clock,
    overrides: [
      appExitHostProvider.overrideWithValue(FakeAppExitHost()),
      ...unsentTextOverrides(_boardSample),
    ],
  );
  final other = await _addSecondVault(tester, r.h);
  await r.type(typed);
  expect(r.bodyText, typed);
  return (r, other);
}

void main() {
  group('no unsent hosted text (AC1)', () {
    testWidgets(
      'with no unsent hosted text the close seam answers true with no dialog',
      (tester) async {
        final (_, exit, other) = await _pump(tester);

        await _leave(tester, _Via.close, exit, other);

        expect(find.byKey(_confirm), findsNothing);
        expect(exit.closeAnswers, [true]);
      },
    );

    testWidgets(
      'with no unsent hosted text a quit request answers exit with no dialog',
      (tester) async {
        final (_, exit, other) = await _pump(tester);

        await _leave(tester, _Via.quit, exit, other);

        expect(find.byKey(_confirm), findsNothing);
        expect(exit.quitAnswers, [AppExitResponse.exit]);
      },
    );

    testWidgets(
      'with no unsent hosted text a vault pill switches with no dialog',
      (tester) async {
        final (h, exit, other) = await _pump(tester);

        await _leave(tester, _Via.pill, exit, other);

        expect(find.byKey(_confirm), findsNothing);
        expect(h.read(currentVaultProvider), LocalVaultRef(other));
        expect(h.read(settingsProvider).lastVault, other);
        expect(find.byType(Workspace), findsOneWidget);
      },
    );

    testWidgets(
      'with no unsent hosted text switch vault opens the picker with no dialog',
      (tester) async {
        final (h, exit, other) = await _pump(tester);

        await _leave(tester, _Via.switchVault, exit, other);

        expect(find.byKey(_confirm), findsNothing);
        expect(h.read(currentVaultProvider), isNull);
        expect(find.byType(VaultPickerScreen), findsOneWidget);
      },
    );
  });

  group('close with unsent text (AC2)', () {
    testWidgets(
      'close with unsent text shows the close confirm with cancel and close anyway',
      (tester) async {
        final (_, exit, other) = await _pump(tester, unsent: _boardSample);

        await _leave(tester, _Via.close, exit, other);

        expect(find.byKey(_confirm), findsOneWidget);
        expect(
          _inConfirm(find.text(_question('nas', 'close'))),
          findsOneWidget,
        );
        expect(_button(tester, _cancel).label, 'cancel');
        expect(_button(tester, _cancel).kind, OmButtonKind.ghost);
        expect(_button(tester, _proceed).label, 'close anyway');
        expect(_button(tester, _proceed).kind, OmButtonKind.danger);
        // Nothing is answered until the person chooses.
        expect(exit.closeAnswers, isEmpty);
      },
    );

    testWidgets(
      'cancel on the close confirm answers false and the window stays',
      (tester) async {
        final (h, exit, other) = await _pump(tester, unsent: _boardSample);
        await _leave(tester, _Via.close, exit, other);

        await tester.tap(find.byKey(_cancel));
        await _settle(tester);

        expect(exit.closeAnswers, [false]);
        expect(find.byKey(_confirm), findsNothing);
        expect(find.byType(Workspace), findsOneWidget);
        expect(h.read(currentVaultProvider), LocalVaultRef(h.vaultPath));
      },
    );

    testWidgets('close anyway on the close confirm answers true', (
      tester,
    ) async {
      final (_, exit, other) = await _pump(tester, unsent: _boardSample);
      await _leave(tester, _Via.close, exit, other);

      await tester.tap(find.byKey(_proceed));
      await _settle(tester);

      expect(exit.closeAnswers, [true]);
      expect(find.byKey(_confirm), findsNothing);
    });

    testWidgets('dismissing the close confirm without a choice answers false', (
      tester,
    ) async {
      final (_, exit, other) = await _pump(tester, unsent: _boardSample);
      await _leave(tester, _Via.close, exit, other);

      Navigator.of(tester.element(find.byKey(_confirm))).pop();
      await _settle(tester);

      expect(exit.closeAnswers, [false]);
      expect(find.byKey(_confirm), findsNothing);
    });
  });

  group('quit with unsent text (AC3)', () {
    final homelab = UnsentHostedText(
      serverName: 'homelab',
      vaultName: 'notes',
      notes: [UnsentHostedNote(title: 'reading list', since: _at(8, 15))],
    );

    testWidgets(
      'quit with unsent text shows the quit confirm with cancel and quit anyway',
      (tester) async {
        final (_, exit, other) = await _pump(tester, unsent: homelab);

        await _leave(tester, _Via.quit, exit, other);

        expect(find.byKey(_confirm), findsOneWidget);
        expect(
          _inConfirm(find.text(_question('homelab', 'quit'))),
          findsOneWidget,
        );
        expect(_button(tester, _cancel).label, 'cancel');
        expect(_button(tester, _cancel).kind, OmButtonKind.ghost);
        expect(_button(tester, _proceed).label, 'quit anyway');
        expect(_button(tester, _proceed).kind, OmButtonKind.danger);
        expect(exit.quitAnswers, isEmpty);
      },
    );

    testWidgets('cancel on the quit confirm answers cancel', (tester) async {
      final (h, exit, other) = await _pump(tester, unsent: homelab);
      await _leave(tester, _Via.quit, exit, other);

      await tester.tap(find.byKey(_cancel));
      await _settle(tester);

      expect(exit.quitAnswers, [AppExitResponse.cancel]);
      expect(find.byKey(_confirm), findsNothing);
      expect(find.byType(Workspace), findsOneWidget);
      expect(h.read(currentVaultProvider), LocalVaultRef(h.vaultPath));
    });

    testWidgets('quit anyway on the quit confirm answers exit', (tester) async {
      final (_, exit, other) = await _pump(tester, unsent: homelab);
      await _leave(tester, _Via.quit, exit, other);

      await tester.tap(find.byKey(_proceed));
      await _settle(tester);

      expect(exit.quitAnswers, [AppExitResponse.exit]);
      expect(find.byKey(_confirm), findsNothing);
    });

    testWidgets('dismissing the quit confirm without a choice answers cancel', (
      tester,
    ) async {
      final (_, exit, other) = await _pump(tester, unsent: homelab);
      await _leave(tester, _Via.quit, exit, other);

      Navigator.of(tester.element(find.byKey(_confirm))).pop();
      await _settle(tester);

      expect(exit.quitAnswers, [AppExitResponse.cancel]);
    });
  });

  group('switch vault with unsent text (AC4)', () {
    const typed = 'Morning pages\nunsent words for the server\n';

    for (final (name, via) in [
      (
        'a vault pill with unsent text shows the switch confirm with cancel and switch anyway',
        _Via.pill,
      ),
      (
        'switch vault with unsent text shows the switch confirm with cancel and switch anyway',
        _Via.switchVault,
      ),
    ]) {
      testWidgets(name, (tester) async {
        final (h, exit, other) = await _pump(tester, unsent: _boardSample);

        await _leave(tester, via, exit, other);

        expect(find.byKey(_confirm), findsOneWidget);
        expect(
          _inConfirm(find.text(_question('nas', 'switch'))),
          findsOneWidget,
        );
        expect(_button(tester, _cancel).label, 'cancel');
        expect(_button(tester, _cancel).kind, OmButtonKind.ghost);
        expect(_button(tester, _proceed).label, 'switch anyway');
        expect(_button(tester, _proceed).kind, OmButtonKind.danger);
        // The vault doesn't change while the confirm is up.
        expect(h.read(currentVaultProvider), LocalVaultRef(h.vaultPath));
      });
    }

    for (final (name, via) in [
      (
        'cancel on the pill switch confirm keeps the current vault, its tabs and its editor text',
        _Via.pill,
      ),
      (
        'cancel on the switch vault confirm keeps the current vault, its tabs and its editor text',
        _Via.switchVault,
      ),
    ]) {
      testWidgets(name, (tester) async {
        final (r, other) = await _liveWithTypedText(tester, typed);
        final h = r.h;
        final tabsBefore = List<WorkspaceTab>.of(h.read(tabsProvider).tabs);
        final activeBefore = h.read(tabsProvider).activeIndex;
        expect(tabsBefore, isNotEmpty);

        await _leave(
          tester,
          via,
          h.read(appExitHostProvider) as FakeAppExitHost,
          other,
        );
        expect(find.byKey(_confirm), findsOneWidget);
        await tester.tap(find.byKey(_cancel));
        await _settle(tester);

        expect(find.byKey(_confirm), findsNothing);
        expect(h.read(currentVaultProvider), LocalVaultRef(h.vaultPath));
        expect(h.read(settingsProvider).lastVault, h.vaultPath);
        expect(h.read(tabsProvider).tabs, tabsBefore);
        expect(h.read(tabsProvider).activeIndex, activeBefore);
        expect(find.byType(Workspace), findsOneWidget);
        expect(r.bodyText, typed);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('switch anyway on the pill switch confirm opens that vault', (
      tester,
    ) async {
      final (h, exit, other) = await _pump(tester, unsent: _boardSample);
      await _leave(tester, _Via.pill, exit, other);

      await tester.tap(find.byKey(_proceed));
      await _settle(tester);

      expect(find.byKey(_confirm), findsNothing);
      expect(h.read(currentVaultProvider), LocalVaultRef(other));
      expect(h.read(settingsProvider).lastVault, other);
      expect(find.byType(Workspace), findsOneWidget);
    });

    testWidgets('switch anyway on the switch vault confirm opens the picker', (
      tester,
    ) async {
      final (h, exit, other) = await _pump(tester, unsent: _boardSample);
      await _leave(tester, _Via.switchVault, exit, other);

      await tester.tap(find.byKey(_proceed));
      await _settle(tester);

      expect(find.byKey(_confirm), findsNothing);
      expect(h.read(currentVaultProvider), isNull);
      expect(h.read(settingsProvider).lastVault, isNull);
      expect(find.byType(VaultPickerScreen), findsOneWidget);
    });
  });

  group('confirm content (AC5)', () {
    final twoNotes = UnsentHostedText(
      serverName: 'nas',
      vaultName: 'memex',
      notes: [
        UnsentHostedNote(title: 'hosted vault plan', since: _at(14, 32)),
        UnsentHostedNote(title: 'trip notes', since: _at(9, 5)),
      ],
    );

    for (final (name, via) in [
      (
        'the close confirm shows the eyebrow vault and server with the warn ring dot and one row per unsent note',
        _Via.close,
      ),
      (
        'the quit confirm shows the eyebrow vault and server with the warn ring dot and one row per unsent note',
        _Via.quit,
      ),
      (
        'the switch confirm shows the eyebrow vault and server with the warn ring dot and one row per unsent note',
        _Via.pill,
      ),
    ]) {
      testWidgets(name, (tester) async {
        final (_, exit, other) = await _pump(tester, unsent: twoNotes);

        await _leave(tester, via, exit, other);

        expect(_inConfirm(find.text('MEMEX · NAS')), findsOneWidget);
        final dots = _inConfirm(find.byType(StatusDot));
        expect(dots, findsOneWidget);
        expect(tester.widget<StatusDot>(dots).state, StatusDotState.cantReach);

        for (final (n, title, since) in [
          (0, 'hosted vault plan', 'unsaved since 14:32'),
          (1, 'trip notes', 'unsaved since 09:05'),
        ]) {
          final row = find.byKey(_row(n));
          expect(row, findsOneWidget, reason: 'row $n');
          expect(
            find.descendant(of: find.byKey(_confirm), matching: row),
            findsOneWidget,
          );
          expect(
            find.descendant(of: row, matching: find.text(title)),
            findsOneWidget,
          );
          expect(
            find.descendant(of: row, matching: find.text(since)),
            findsOneWidget,
          );
          expect(
            find.descendant(
              of: row,
              matching: find.byIcon(LucideIcons.fileText),
            ),
            findsOneWidget,
          );
        }
        expect(find.byKey(_row(2)), findsNothing);
      });
    }

    testWidgets(
      'unsaved since shows the since time as 24 hour HH:MM in local time',
      (tester) async {
        final utcStamp = DateTime.utc(2026, 10, 20, 13, 5);
        final local = utcStamp.toLocal();
        String two(int v) => v.toString().padLeft(2, '0');
        final (_, exit, other) = await _pump(
          tester,
          unsent: UnsentHostedText(
            serverName: 'nas',
            vaultName: 'memex',
            notes: [
              UnsentHostedNote(title: 'evening', since: _at(21, 7)),
              UnsentHostedNote(title: 'midnight', since: _at(0, 0)),
              UnsentHostedNote(title: 'stamped in utc', since: utcStamp),
            ],
          ),
        );

        await _leave(tester, _Via.close, exit, other);

        for (final (n, since) in [
          (0, 'unsaved since 21:07'),
          (1, 'unsaved since 00:00'),
          (2, 'unsaved since ${two(local.hour)}:${two(local.minute)}'),
        ]) {
          expect(
            find.descendant(
              of: find.byKey(_row(n)),
              matching: find.text(since),
            ),
            findsOneWidget,
            reason: 'row $n',
          );
        }
      },
    );

    testWidgets(
      'the confirm is 472 wide with rows 6 apart, actions 20 below the rows, right aligned and 8 apart',
      (tester) async {
        final (_, exit, other) = await _pump(tester, unsent: twoNotes);
        await _leave(tester, _Via.close, exit, other);

        final dialog = tester.getRect(find.byKey(_confirm));
        final row0 = tester.getRect(find.byKey(_row(0)));
        final row1 = tester.getRect(find.byKey(_row(1)));
        final cancel = tester.getRect(_buttonAt(_cancel));
        final proceed = tester.getRect(_buttonAt(_proceed));

        expect(dialog.width, moreOrLessEquals(472, epsilon: 0.5));
        expect(row1.top - row0.bottom, moreOrLessEquals(6, epsilon: 0.5));
        expect(row0.width, row1.width);
        expect(cancel.height, moreOrLessEquals(30, epsilon: 0.5));
        expect(proceed.height, moreOrLessEquals(30, epsilon: 0.5));
        expect(cancel.top - row1.bottom, moreOrLessEquals(20, epsilon: 0.5));
        expect(proceed.left - cancel.right, moreOrLessEquals(8, epsilon: 0.5));
        // Right-aligned inside the 24 px padding (plus the 1 px border).
        expect(dialog.right - proceed.right, inInclusiveRange(23.5, 25.5));
        expect(cancel.top, proceed.top);
      },
    );

    testWidgets('the eyebrow warn ring dot sits 7 right of the eyebrow text', (
      tester,
    ) async {
      final (_, exit, other) = await _pump(tester, unsent: _boardSample);
      await _leave(tester, _Via.close, exit, other);

      final text = tester.getRect(_inConfirm(find.text('MEMEX · NAS')));
      final dot = tester.getRect(_inConfirm(find.byType(StatusDot)));

      expect(dot.left - text.right, moreOrLessEquals(7, epsilon: 0.5));
      expect(dot.center.dy, moreOrLessEquals(text.center.dy, epsilon: 1));
      expect(dot.size, const Size(6, 6));
      // The question sits below the eyebrow.
      final question = tester.getRect(
        _inConfirm(find.text(_question('nas', 'close'))),
      );
      expect(question.top, greaterThan(text.bottom));
    });

    testWidgets('with 4 unsent notes every row shows without scrolling', (
      tester,
    ) async {
      final (_, exit, other) = await _pump(tester, unsent: _manyNotes(4));
      await _leave(tester, _Via.close, exit, other);

      for (var n = 0; n < 4; n++) {
        expect(find.byKey(_row(n)).hitTestable(), findsOneWidget, reason: '$n');
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'with more than 4 unsent notes the rows scroll inside the confirm',
      (tester) async {
        final (_, exit, other) = await _pump(tester, unsent: _manyNotes(8));
        await _leave(tester, _Via.close, exit, other);

        final dialog = tester.getRect(find.byKey(_confirm));
        expect(find.byKey(_row(0)).hitTestable(), findsOneWidget);
        expect(find.byKey(_row(7)).hitTestable(), findsNothing);
        // The actions stay inside the dialog, below the list.
        expect(
          tester.getRect(_buttonAt(_proceed)).bottom,
          lessThanOrEqualTo(dialog.bottom),
        );

        final list = _inConfirm(find.byType(Scrollable));
        expect(list, findsOneWidget);
        await tester.drag(list, const Offset(0, -400));
        await pumpFrames(tester);

        expect(find.byKey(_row(7)).hitTestable(), findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(_row(7)),
            matching: find.text('unsaved since 10:07'),
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'a long note title stays on one line and keeps the unsaved since label in the row',
      (tester) async {
        final title = 'a very long hosted note title ' * 12;
        final (_, exit, other) = await _pump(
          tester,
          unsent: UnsentHostedText(
            serverName: 'nas',
            vaultName: 'memex',
            notes: [UnsentHostedNote(title: title, since: _at(14, 32))],
          ),
        );
        await _leave(tester, _Via.close, exit, other);

        expect(tester.takeException(), isNull);
        final row = tester.getRect(find.byKey(_row(0)));
        final since = tester.getRect(
          find.descendant(
            of: find.byKey(_row(0)),
            matching: find.text('unsaved since 14:32'),
          ),
        );
        expect(since.right, lessThanOrEqualTo(row.right));
        expect(row.width, lessThanOrEqualTo(472));
        final titleText = tester.widget<Text>(
          find.descendant(of: find.byKey(_row(0)), matching: find.text(title)),
        );
        expect(titleText.maxLines, 1);
        expect(titleText.overflow, TextOverflow.ellipsis);
      },
    );
  });

  group('unsent seam read at request time', () {
    testWidgets(
      'close asks only while the unsent seam is true when the request arrives',
      (tester) async {
        final unsentNow = StateProvider<bool>((_) => false);
        final exit = FakeAppExitHost();
        await pumpWorkspace(
          tester,
          overrides: [
            appExitHostProvider.overrideWithValue(exit),
            hasUnsentHostedTextProvider.overrideWith(
              (ref) => ref.watch(unsentNow),
            ),
            unsentHostedTextProvider.overrideWithValue(_boardSample),
          ],
        );
        final container = ProviderScope.containerOf(
          tester.element(find.byType(Workspace)),
        );

        // Text fails to reach the server: the close asks.
        container.read(unsentNow.notifier).state = true;
        await pumpFrames(tester);
        unawaited(exit.requestClose());
        await _settle(tester);
        expect(find.byKey(_confirm), findsOneWidget);
        await tester.tap(find.byKey(_cancel));
        await _settle(tester);
        expect(exit.closeAnswers, [false]);

        // The text reaches the server: the next close goes ahead.
        container.read(unsentNow.notifier).state = false;
        await pumpFrames(tester);
        unawaited(exit.requestClose());
        await _settle(tester);
        expect(find.byKey(_confirm), findsNothing);
        expect(exit.closeAnswers, [false, true]);
      },
    );
  });

  group('stacked leave requests (verify)', () {
    for (final (name, first) in [
      (
        'with the close confirm up a second close or quit answers no and opens no second dialog',
        _Via.close,
      ),
      (
        'with the quit confirm up a second close or quit answers no and opens no second dialog',
        _Via.quit,
      ),
      (
        'with the switch confirm up a close or quit answers no and opens no second dialog',
        _Via.pill,
      ),
    ]) {
      testWidgets(name, (tester) async {
        final (h, exit, other) = await _pump(tester, unsent: _boardSample);
        await _leave(tester, first, exit, other);
        expect(find.byKey(_confirm), findsOneWidget);

        unawaited(exit.requestClose());
        await _settle(tester);
        expect(find.byKey(_confirm), findsOneWidget);
        expect(exit.closeAnswers, [false]);

        unawaited(exit.requestQuit());
        await _settle(tester);
        expect(find.byKey(_confirm), findsOneWidget);
        expect(exit.quitAnswers, [AppExitResponse.cancel]);

        // The first confirm still answers for its own request.
        await tester.tap(find.byKey(_cancel));
        await _settle(tester);
        expect(find.byKey(_confirm), findsNothing);
        switch (first) {
          case _Via.close:
            expect(exit.closeAnswers, [false, false]);
            expect(exit.quitAnswers, [AppExitResponse.cancel]);
          case _Via.quit:
            expect(exit.closeAnswers, [false]);
            expect(exit.quitAnswers, [
              AppExitResponse.cancel,
              AppExitResponse.cancel,
            ]);
          case _Via.pill || _Via.switchVault:
            expect(exit.closeAnswers, [false]);
            expect(exit.quitAnswers, [AppExitResponse.cancel]);
        }
        expect(h.read(currentVaultProvider), LocalVaultRef(h.vaultPath));
      });
    }

    testWidgets('after a cancelled close confirm the next close asks again', (
      tester,
    ) async {
      final (_, exit, other) = await _pump(tester, unsent: _boardSample);
      await _leave(tester, _Via.close, exit, other);
      await tester.tap(find.byKey(_cancel));
      await _settle(tester);
      expect(exit.closeAnswers, [false]);

      await _leave(tester, _Via.close, exit, other);

      expect(find.byKey(_confirm), findsOneWidget);
      expect(exit.closeAnswers, [false]);
      await tester.tap(find.byKey(_proceed));
      await _settle(tester);
      expect(exit.closeAnswers, [false, true]);
    });
  });

  group('quit after an allowed close (verify)', () {
    testWidgets(
      'after close anyway a quit answers exit with no dialog even with unsent text',
      (tester) async {
        final (_, exit, other) = await _pump(tester, unsent: _boardSample);
        await _leave(tester, _Via.close, exit, other);
        await tester.tap(find.byKey(_proceed));
        await _settle(tester);
        expect(exit.closeAnswers, [true]);

        await _leave(tester, _Via.quit, exit, other);

        expect(find.byKey(_confirm), findsNothing);
        expect(exit.quitAnswers, [AppExitResponse.exit]);
      },
    );

    testWidgets(
      'after a close with no unsent text a quit answers exit with no dialog once text is unsent',
      (tester) async {
        final unsentNow = StateProvider<bool>((_) => false);
        final exit = FakeAppExitHost();
        await pumpWorkspace(
          tester,
          overrides: [
            appExitHostProvider.overrideWithValue(exit),
            hasUnsentHostedTextProvider.overrideWith(
              (ref) => ref.watch(unsentNow),
            ),
            unsentHostedTextProvider.overrideWithValue(_boardSample),
          ],
        );
        final container = ProviderScope.containerOf(
          tester.element(find.byType(Workspace)),
        );
        unawaited(exit.requestClose());
        await _settle(tester);
        expect(exit.closeAnswers, [true]);

        container.read(unsentNow.notifier).state = true;
        await pumpFrames(tester);
        unawaited(exit.requestQuit());
        await _settle(tester);

        expect(find.byKey(_confirm), findsNothing);
        expect(exit.quitAnswers, [AppExitResponse.exit]);
      },
    );

    testWidgets('after a cancelled close a quit still shows the quit confirm', (
      tester,
    ) async {
      final (_, exit, other) = await _pump(tester, unsent: _boardSample);
      await _leave(tester, _Via.close, exit, other);
      await tester.tap(find.byKey(_cancel));
      await _settle(tester);
      expect(exit.closeAnswers, [false]);

      await _leave(tester, _Via.quit, exit, other);

      expect(_inConfirm(find.text(_question('nas', 'quit'))), findsOneWidget);
      expect(exit.quitAnswers, isEmpty);
      await tester.tap(find.byKey(_cancel));
      await _settle(tester);
      expect(exit.quitAnswers, [AppExitResponse.cancel]);
    });
  });

  group('row list boundary and spacing (verify)', () {
    testWidgets(
      'with exactly 5 unsent notes the rows scroll in a 156 high box',
      (tester) async {
        final (_, exit, other) = await _pump(tester, unsent: _manyNotes(5));
        await _leave(tester, _Via.close, exit, other);

        final list = _inConfirm(find.byType(Scrollable));
        expect(list, findsOneWidget);
        final box = tester.getRect(list);
        expect(box.height, moreOrLessEquals(156, epsilon: 0.5));
        expect(
          tester.getRect(find.byKey(_row(0))).top,
          moreOrLessEquals(box.top, epsilon: 0.5),
        );
        expect(
          tester.getRect(find.byKey(_row(4))).bottom,
          greaterThan(box.bottom),
        );
        // The actions sit 20 below the scroll box.
        expect(
          tester.getRect(_buttonAt(_cancel)).top - box.bottom,
          moreOrLessEquals(20, epsilon: 0.5),
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('with exactly 4 unsent notes the rows do not scroll', (
      tester,
    ) async {
      final (_, exit, other) = await _pump(tester, unsent: _manyNotes(4));
      await _leave(tester, _Via.close, exit, other);

      expect(_inConfirm(find.byType(Scrollable)), findsNothing);
      for (var n = 1; n < 4; n++) {
        expect(
          tester.getRect(find.byKey(_row(n))).top -
              tester.getRect(find.byKey(_row(n - 1))).bottom,
          moreOrLessEquals(6, epsilon: 0.5),
          reason: 'gap above row $n',
        );
      }
      expect(
        tester.getRect(_buttonAt(_cancel)).top -
            tester.getRect(find.byKey(_row(3))).bottom,
        moreOrLessEquals(20, epsilon: 0.5),
      );
    });

    testWidgets(
      'the question sits 16 below the eyebrow and the first row 16 below the question',
      (tester) async {
        final (_, exit, other) = await _pump(tester, unsent: _boardSample);
        await _leave(tester, _Via.close, exit, other);

        final eyebrow = tester.getRect(_inConfirm(find.text('MEMEX · NAS')));
        final question = tester.getRect(
          _inConfirm(find.text(_question('nas', 'close'))),
        );
        final row0 = tester.getRect(find.byKey(_row(0)));

        expect(
          question.top - eyebrow.bottom,
          moreOrLessEquals(16, epsilon: 0.5),
        );
        expect(row0.top - question.bottom, moreOrLessEquals(16, epsilon: 0.5));
        // Row height 34.5 and dialog height 204 come from the real fonts'
        // line heights; the test font measures differently, so only the
        // fixed gaps are pinned here.
      },
    );
  });
}
