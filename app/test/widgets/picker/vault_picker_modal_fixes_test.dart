// WI #362 fix round 1 (review findings F1-F6; Spec #357 Req 9, 10, 13, TD1):
// contracts the modal's fixes added. Covers: a recent naming the open
// vault's folder by another spelling (symlink, trailing slash, case
// variant) gets no row, so no delete that skips the close-then-delete; a
// flow that re-opens the vault already open closes the modal; remove
// server does nothing while an open from the modal runs; an open error's
// SnackBar shows inside the modal card, above the scrim; a hosted RECENT row
// opened from the modal (failure on the row, success closes the modal).
// Seams: test/support/wi362_modal.dart.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/screens/workspace.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:path/path.dart' as p;

import '../../support/fake_memex_cli.dart';
import '../../support/fake_vault_server.dart';
import '../../support/font_fetch_hold.dart';
import '../../support/hosted_harness.dart';
import '../../support/vault_folders.dart';
import '../../support/wi362_modal.dart';

const _removeConfirm = Key('remove-server-confirm');

/// `memex vault check` fails with a plain error (not a refusal).
FutureOr<MemexResult> _failedCheck(FakeCliCall call) =>
    FakeMemexCli.error('internal', 'boom 362');

void main() {
  holdFontFetches();

  group('alias rows of the open vault', () {
    for (final (name, alias) in <(String, VaultRef Function(String))>[
      (
        'a recent that is a symlink to the open vault gets no row of its own',
        (open) {
          final link = p.join(createPlainFolder('om362_link_').path, 'alias');
          Link(link).createSync(open);
          return LocalVaultRef(link);
        },
      ),
      (
        'a recent naming the open vault with a trailing slash gets no row of its own',
        (open) => LocalVaultRef('$open/'),
      ),
      (
        'a recent naming the open vault with a dot segment gets no row of its own',
        (open) => LocalVaultRef(p.join(open, '.')),
      ),
      (
        'a recent naming the open vault in another case gets no row of its own',
        (open) => LocalVaultRef(open.toUpperCase()),
      ),
    ]) {
      testWidgets(name, (tester) async {
        final env = await wi362PumpLocal(
          tester,
          aliases: (open) => [alias(open)],
        );
        // The setting really holds the alias beside the other recents.
        expect(env.settings.recentRefs, hasLength(4));
        await wi362OpenModal(tester, env);

        // [open, work-notes, seed]: the alias is the same vault as the open
        // row, so it has no row (no delete that skips the close).
        expect(wi362KeyInModal('recent-row-0'), findsOneWidget);
        expect(wi362KeyInModal('recent-row-open-tag-0'), findsOneWidget);
        expect(wi362KeyInModal('recent-row-1'), findsOneWidget);
        expect(wi362KeyInModal('recent-row-2'), findsOneWidget);
        expect(wi362KeyInModal('recent-row-3'), findsNothing);
        expect(find.text('OPEN'), findsOneWidget);
        expect(wi362KeyInModal('recent-row-delete-3'), findsNothing);
      });
    }

    testWidgets(
      'a recent of another vault whose name only starts like the open one keeps its row',
      (tester) async {
        final env = await wi362PumpLocal(
          tester,
          aliases: (open) => [LocalVaultRef('${open}2')],
        );
        await wi362OpenModal(tester, env);

        expect(wi362KeyInModal('recent-row-3'), findsOneWidget);
        expect(wi362KeyInModal('recent-row-open-tag-3'), findsNothing);
      },
    );
  });

  group('a flow that opens the vault already open', () {
    testWidgets(
      'open local vault choosing the open vault closes the modal and keeps it open',
      (tester) async {
        final env = await wi362PumpLocal(tester);
        env.files.directories.add(env.openPath);
        await wi362OpenModal(tester, env);

        await wi362Tap(tester, wi362KeyInModal('vault-picker-open'));

        expect(env.guardCalls, [false], reason: 'the guard is asked once');
        expect(env.files.calls, isNotEmpty, reason: 'the chooser ran');
        expect(env.current, LocalVaultRef(env.openPath!));
        expect(wi362Modal, findsNothing, reason: 'the modal closed');
        expect(env.modalDone, isTrue);
        expect(find.byType(Workspace), findsOneWidget);
      },
    );

    for (final (name, key, hook) in <(String, String, String)>[
      (
        'a hosted open flow that reopens the open hosted vault closes the modal',
        'vault-picker-open-on-server',
        'open',
      ),
      (
        'a hosted create flow that reopens the open hosted vault closes the modal',
        'vault-picker-create-on-server',
        'create',
      ),
    ]) {
      testWidgets(name, (tester) async {
        final env = await wi362PumpHosted(tester);
        Future<void> reopen() async {
          await env.controller.openVault(seedHostedRef);
        }

        if (hook == 'open') {
          env.actions.onOpenOnServer = reopen;
        } else {
          env.actions.onCreateOnServer = reopen;
        }
        await wi362OpenModal(tester, env);
        expect(wi362Modal, findsOneWidget);

        await wi362Tap(tester, wi362KeyInModal(key));

        expect(env.guardCalls, [false], reason: 'the guard is asked once');
        expect(env.current, seedHostedRef, reason: 'the same vault stays');
        expect(wi362Modal, findsNothing, reason: 'the modal closed');
        expect(env.modalDone, isTrue);
        expect(find.byType(Workspace), findsOneWidget);
      });
    }

    testWidgets(
      'a hosted flow that opens nothing keeps the modal while the hosted vault stays open',
      (tester) async {
        final env = await wi362PumpHosted(tester);
        await wi362OpenModal(tester, env);

        await wi362Tap(tester, wi362KeyInModal('vault-picker-open-on-server'));

        expect(env.actions.calls, ['openOnServer']);
        expect(wi362Modal, findsOneWidget, reason: 'nothing opened: it stays');
        expect(env.modalDone, isFalse);
        expect(env.current, seedHostedRef);
      },
    );
  });

  group('remove server during an open', () {
    testWidgets(
      'remove server does nothing while an open from the modal runs and works again after',
      (tester) async {
        final env = await wi362PumpLocal(tester);
        await wi362OpenModal(tester, env);
        final remove = wi362KeyInModal('server-row-remove-$fakeServerId');
        await tester.ensureVisible(remove);
        await tester.pump();
        // The seed row's open waits on the leave guard: an open is running.
        env.guardHold = Completer<bool>();
        await tester.tap(wi362KeyInModal('recent-row-2'));
        await tester.pump();
        expect(env.guardCalls, hasLength(1), reason: 'the open started');

        await tester.tap(remove);
        await wi362Settle(tester);

        expect(find.byKey(_removeConfirm), findsNothing, reason: 'no confirm');
        expect(env.settings.savedServers, hasLength(1), reason: 'kept');
        expect(wi362Modal, findsOneWidget);

        // The open ends (stay): the removal is possible again.
        env.guardHold!.complete(false);
        env.guardHold = null;
        await wi362Settle(tester);
        await wi362Tap(tester, remove);
        expect(find.byKey(_removeConfirm), findsOneWidget);
      },
    );
  });

  group('errors above the scrim', () {
    testWidgets(
      'an open error from the modal shows its SnackBar inside the modal card',
      (tester) async {
        final env = await wi362PumpLocal(tester);
        final plain = createPlainFolder('om362_snack_');
        env.files.directories.add(plain.path);
        await wi362OpenModal(tester, env);

        await wi362Tap(tester, wi362KeyInModal('vault-picker-open'));

        final snack = find.byType(SnackBar);
        expect(snack, findsOneWidget, reason: 'one SnackBar, not two');
        expect(
          wi362InModal(snack),
          findsOneWidget,
          reason: 'inside the card, above the scrim',
        );
        expect(
          wi362InModal(find.textContaining('does not look like a vault')),
          findsOneWidget,
        );
        expect(wi362Modal, findsOneWidget, reason: 'the modal stays');
      },
    );

    testWidgets(
      'a failed RECENT open from the modal shows its SnackBar inside the modal card',
      (tester) async {
        final env = await wi362PumpLocal(tester);
        env.check = _failedCheck;
        await wi362OpenModal(tester, env);

        await wi362Tap(tester, wi362KeyInModal('recent-row-1'));

        expect(find.byType(SnackBar), findsOneWidget);
        expect(wi362InModal(find.byType(SnackBar)), findsOneWidget);
      },
    );

    testWidgets(
      'the modal rows still take taps while the error SnackBar shows',
      (tester) async {
        final env = await wi362PumpLocal(tester);
        env.check = _failedCheck;
        await wi362OpenModal(tester, env);
        await wi362Tap(tester, wi362KeyInModal('recent-row-1'));
        expect(wi362InModal(find.byType(SnackBar)), findsOneWidget);
        final checks = env.h.cli!.callsFor('vault check').length;

        await wi362Tap(tester, wi362KeyInModal('recent-row-1'));

        expect(
          env.h.cli!.callsFor('vault check'),
          hasLength(checks + 1),
          reason: 'the tap reached the row through the see-through scaffold',
        );
      },
    );
  });

  group('a hosted RECENT row from the modal', () {
    testWidgets(
      'a hosted RECENT row that cannot reach its server shows it on the row and keeps the modal',
      (tester) async {
        final env = await wi362PumpLocal(tester);
        final before = wi362Snapshot(env);
        env.h.first.server.failure = FakeServerFailure.refused;
        await wi362OpenModal(tester, env);

        await wi362Tap(tester, wi362KeyInModal('recent-row-2'));

        expect(env.guardCalls, [false], reason: 'asked once, before the open');
        expect(
          wi362InModal(find.textContaining("can't reach")),
          findsOneWidget,
          reason: 'the row shows the failure (D19)',
        );
        expect(wi362KeyInModal('recent-row-retry-2'), findsOneWidget);
        expect(find.byType(SnackBar), findsNothing, reason: 'row only');
        expect(wi362Modal, findsOneWidget);
        expect(env.modalDone, isFalse);
        expect(env.current, LocalVaultRef(env.openPath!));
        expect(wi362Snapshot(env), before);
      },
    );

    testWidgets(
      'a hosted RECENT row opened from the modal switches the vault clears the selected note and closes the modal',
      (tester) async {
        final env = await wi362PumpLocal(tester);
        expect(env.c.read(selectedNoteIdProvider), '01M362');
        await wi362OpenModal(tester, env);

        await wi362Tap(tester, wi362KeyInModal('recent-row-2'));
        await wi362Settle(tester, rounds: 12);

        expect(env.guardCalls, [false], reason: 'asked once');
        expect(env.current, seedHostedRef);
        expect(env.c.read(selectedNoteIdProvider), isNot('01M362'));
        expect(wi362Modal, findsNothing, reason: 'the modal closed');
        expect(env.modalDone, isTrue);
        expect(find.byType(Workspace), findsOneWidget);
        expect(find.byType(SnackBar), findsNothing);
      },
    );
  });
}
