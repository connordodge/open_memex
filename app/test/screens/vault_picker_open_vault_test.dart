// WI #362 (Spec #357 Req 4, 8-14, 26, 34, TD1, TD2; design pack 362, boards
// A1, A3, A5): the picker body with a vault open, inside the vault picker
// modal over the whole app. Covers: the open vault first in RECENT with the
// OPEN tag and no x, a click on it only closes the modal; any other row
// goes through the leave guard once (stay, switch, every failure, a
// same-frame double press); each of the five flows asks the guard once
// before its first dialog (stay starts nothing, cancel keeps everything, a
// failure keeps the vault, success closes the modal); deleting a vault that
// isn't open keeps the modal, deleting the open one ends on the full-screen
// picker; remove server disabled (with its tooltip) on the open hosted
// vault's server only. Also the full-screen picker with no vault open (the
// shared body, no OPEN row) and the GLOSSARY entry.
// Seams: test/support/wi362_modal.dart and vault_picker_harness.dart.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/screens/vault_picker.dart';
import 'package:open_memex_app/src/screens/workspace.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/widgets/picker/delete_vault_dialog.dart';
import 'package:open_memex_app/src/widgets/picker/vault_picker_body.dart';

import '../support/fake_memex_cli.dart';
import '../support/fake_vault_server.dart';
import '../support/font_fetch_hold.dart';
import '../support/hosted_harness.dart';
import '../support/vault_folders.dart';
import '../support/vault_picker_harness.dart';
import '../support/wi362_modal.dart';

/// The text of the RECENT row [i] in the modal shows [name].
void _expectRow(int i, String name) => expect(
  find.descendant(
    of: wi362KeyInModal('recent-row-$i'),
    matching: find.text(name),
  ),
  findsOneWidget,
  reason: 'recent-row-$i is $name',
);

/// Opens the modal and checks it shows.
Future<void> _open(WidgetTester tester, Wi362Env env) async {
  await wi362OpenModal(tester, env);
  expect(wi362Modal, findsOneWidget, reason: 'the vault picker modal shows');
}

/// The modal is still showing, with the open vault unchanged.
void _expectStays(Wi362Env env, String before) {
  expect(wi362Modal, findsOneWidget, reason: 'the modal stays');
  expect(env.modalDone, isFalse);
  expect(find.byType(Workspace), findsOneWidget);
  expect(wi362Snapshot(env), before, reason: 'nothing changed');
}

const _removeConfirm = Key('remove-server-confirm');

void main() {
  holdFontFetches();

  group('the open row', () {
    testWidgets(
      'the open vault is the first RECENT row with the OPEN tag and no remove button',
      (tester) async {
        final env = await wi362PumpLocal(tester);
        final recentsBefore = env.settings.recentRefs;
        await _open(tester, env);

        _expectRow(0, 'memex');
        expect(wi362KeyInModal('recent-row-open-tag-0'), findsOneWidget);
        expect(wi362KeyInModal('recent-row-remove-0'), findsNothing);
        expect(wi362KeyInModal('recent-row-finder-0'), findsOneWidget);
        expect(wi362KeyInModal('recent-row-delete-0'), findsOneWidget);
        // The others follow in recents order, as normal rows.
        _expectRow(1, 'work-notes');
        _expectRow(2, 'seed');
        for (final i in [1, 2]) {
          expect(wi362KeyInModal('recent-row-open-tag-$i'), findsNothing);
          expect(wi362KeyInModal('recent-row-remove-$i'), findsOneWidget);
        }
        expect(wi362KeyInModal('recent-row-3'), findsNothing);
        expect(find.text('OPEN'), findsOneWidget);
        expect(env.settings.recentRefs, recentsBefore, reason: 'no reorder');
      },
    );

    testWidgets(
      'the open hosted vault is the first RECENT row with the OPEN tag and no buttons',
      (tester) async {
        final env = await wi362PumpHosted(tester);
        await _open(tester, env);

        _expectRow(0, 'seed');
        expect(wi362KeyInModal('recent-row-open-tag-0'), findsOneWidget);
        for (final k in ['remove', 'finder', 'delete']) {
          expect(wi362KeyInModal('recent-row-$k-0'), findsNothing, reason: k);
        }
        _expectRow(1, 'work');
        expect(wi362KeyInModal('recent-row-remove-1'), findsOneWidget);
      },
    );

    for (final (name, hosted) in [
      (
        'clicking the open row closes the modal and changes nothing else',
        false,
      ),
      (
        'clicking the open hosted row closes the modal and changes nothing else',
        true,
      ),
    ]) {
      testWidgets(name, (tester) async {
        final env = hosted
            ? await wi362PumpHosted(tester)
            : await wi362PumpLocal(tester);
        final before = wi362Snapshot(env);
        final requests = [
          for (final s in env.h.servers) s.server.requests.length,
        ];
        await _open(tester, env);

        await wi362Tap(tester, wi362KeyInModal('recent-row-0'));

        expect(wi362Modal, findsNothing, reason: 'the modal closed');
        expect(env.modalDone, isTrue);
        expect(find.byType(Workspace), findsOneWidget);
        expect(wi362Snapshot(env), before);
        expect(env.guardCalls, isEmpty, reason: 'no leave, no guard');
        expect(env.h.cli?.callsFor('vault check') ?? const [], isEmpty);
        if (hosted) {
          // No reopen: nothing beyond the picker's own server probes.
          for (var i = 0; i < env.h.servers.length; i++) {
            final opens = [
              for (final r in env.h.servers[i].server.requests.skip(
                requests[i],
              ))
                if (r.url.path.startsWith('/vaults/')) r,
            ];
            expect(opens, isEmpty, reason: 'no vault request');
          }
        }
      });
    }

    testWidgets('the open local row shows its folder in Finder', (
      tester,
    ) async {
      final env = await wi362PumpLocal(tester);
      final before = wi362Snapshot(env);
      await _open(tester, env);

      await wi362Tap(tester, wi362KeyInModal('recent-row-finder-0'));

      expect(env.revealer.paths, [env.openPath]);
      _expectStays(env, before);
    });
  });

  group('another RECENT row', () {
    testWidgets(
      'another RECENT row asks the guard once and stay keeps the vault and the modal',
      (tester) async {
        final env = await wi362PumpLocal(tester);
        final before = wi362Snapshot(env);
        env.allow = false;
        await _open(tester, env);

        await wi362Tap(tester, wi362KeyInModal('recent-row-1'));

        expect(env.guardCalls, [false], reason: 'asked once, before the open');
        expect(env.h.cli!.callsFor('vault check'), isEmpty);
        _expectStays(env, before);
      },
    );

    testWidgets(
      'another RECENT row switches the vault clears the selected note and closes the modal',
      (tester) async {
        final env = await wi362PumpLocal(tester);
        expect(env.c.read(selectedNoteIdProvider), '01M362');
        final selections = <String?>[];
        env.c.listen(selectedNoteIdProvider, (_, n) => selections.add(n));
        await _open(tester, env);

        await wi362Tap(tester, wi362KeyInModal('recent-row-1'));

        expect(env.guardCalls, [false]);
        expect(env.current, LocalVaultRef(env.otherPath!));
        // Cleared on the switch; the new workspace may then select its own
        // note (its today tab), never the old one.
        expect(selections, isNotEmpty);
        expect(
          selections.first,
          isNull,
          reason: 'the selected note is cleared',
        );
        expect(env.c.read(selectedNoteIdProvider), isNot('01M362'));
        expect(env.settings.lastVaultRef, LocalVaultRef(env.otherPath!));
        expect(env.settings.recentRefs.first, LocalVaultRef(env.otherPath!));
        expect(wi362Modal, findsNothing);
        expect(env.modalDone, isTrue);
        expect(find.byType(Workspace), findsOneWidget);
      },
    );

    for (final (name, answer, check)
        in <
          (
            String,
            FutureOr<MemexResult> Function(FakeCliCall),
            void Function(WidgetTester),
          )
        >[
          (
            'a refused open from the modal keeps the modal and the open vault and shows the refusal',
            (_) =>
                FakeMemexCli.error('network_filesystem', 'on a network drive'),
            (tester) => expect(
              find.byKey(const Key('network-drive-refusal')),
              findsOneWidget,
            ),
          ),
          (
            'a failed open from the modal keeps the modal and the open vault and shows the error',
            (_) => FakeMemexCli.error('internal', 'boom 362'),
            (tester) => expect(
              find.descendant(
                of: find.byType(SnackBar),
                matching: find.textContaining('Could not open'),
              ),
              findsOneWidget,
            ),
          ),
          (
            'a binary not found open from the modal keeps the modal and shows the binary not found card',
            (_) =>
                throw const ProcessException('fake-memex', ['vault', 'check']),
            (tester) => expect(
              wi362InModal(find.text('memex binary not found')),
              findsOneWidget,
            ),
          ),
        ]) {
      testWidgets(name, (tester) async {
        final env = await wi362PumpLocal(tester);
        final before = wi362Snapshot(env);
        env.check = answer;
        await _open(tester, env);
        expect(wi362InModal(find.text('memex binary not found')), findsNothing);

        await wi362Tap(tester, wi362KeyInModal('recent-row-1'));

        expect(env.guardCalls, [false]);
        expect(env.h.cli!.callsFor('vault check'), hasLength(1));
        check(tester);
        _expectStays(env, before);
      });
    }

    testWidgets(
      'two presses in the same frame on another RECENT row start one open',
      (tester) async {
        final env = await wi362PumpLocal(tester);
        await _open(tester, env);
        final row = wi362KeyInModal('recent-row-1');
        await tester.ensureVisible(row);
        await tester.pump();
        env.guardHold = Completer<bool>();

        await tester.tap(row);
        await tester.tap(row);
        await tester.pump();

        expect(env.guardCalls, hasLength(1), reason: 'one open started');
        env.guardHold!.complete(true);
        await wi362Settle(tester);
        expect(env.guardCalls, hasLength(1));
        expect(env.h.cli!.callsFor('vault check'), hasLength(1));
        expect(env.current, LocalVaultRef(env.otherPath!));
      },
    );
  });

  group('the five flows', () {
    // (name, button key, what shows once the flow started, how to cancel it)
    final flows =
        <
          (
            String,
            String,
            String,
            bool Function(Wi362Env) started,
            Future<void> Function(WidgetTester) cancel,
          )
        >[
          (
            'create local vault in the modal asks the guard once and stay starts nothing',
            'create local vault in the modal cancelled keeps the vault and the modal',
            'vault-picker-create',
            (env) => find.text('CREATE NEW VAULT').evaluate().isNotEmpty,
            (tester) => wi362Tap(tester, find.text('cancel')),
          ),
          (
            'open local vault in the modal asks the guard once and stay starts nothing',
            'open local vault in the modal cancelled keeps the vault and the modal',
            'vault-picker-open',
            (env) => env.files.calls.any((c) => c.method == 'getDirectoryPath'),
            (tester) async {},
          ),
          (
            'open vault on a server in the modal asks the guard once and stay starts nothing',
            'open vault on a server in the modal cancelled keeps the vault and the modal',
            'vault-picker-open-on-server',
            (env) => env.actions.calls.contains('openOnServer'),
            (tester) async {},
          ),
          (
            'create vault on a server in the modal asks the guard once and stay starts nothing',
            'create vault on a server in the modal cancelled keeps the vault and the modal',
            'vault-picker-create-on-server',
            (env) => env.actions.calls.contains('createOnServer'),
            (tester) async {},
          ),
          (
            'restore from backup in the modal asks the guard once and stay starts nothing',
            'restore from backup in the modal cancelled keeps the vault and the modal',
            'vault-picker-restore',
            (env) => env.files.calls.any((c) => c.method == 'pickFiles'),
            (tester) async {},
          ),
        ];

    for (final (stayName, cancelName, key, started, cancel) in flows) {
      testWidgets(stayName, (tester) async {
        final env = await wi362PumpLocal(tester);
        final before = wi362Snapshot(env);
        env.allow = false;
        await _open(tester, env);

        await wi362Tap(tester, wi362KeyInModal(key));

        expect(env.guardCalls, [false], reason: 'asked once, first');
        expect(started(env), isFalse, reason: 'stay starts nothing');
        expect(env.files.calls, isEmpty);
        expect(env.actions.calls, isEmpty);
        _expectStays(env, before);
      });

      testWidgets(cancelName, (tester) async {
        final env = await wi362PumpLocal(tester);
        final before = wi362Snapshot(env);
        await _open(tester, env);

        await wi362Tap(tester, wi362KeyInModal(key));
        expect(env.guardCalls, [
          false,
        ], reason: 'asked once, before the first dialog');
        expect(started(env), isTrue, reason: 'the flow started');

        await cancel(tester);

        expect(find.text('CREATE NEW VAULT'), findsNothing);
        expect(env.guardCalls, hasLength(1));
        _expectStays(env, before);
      });
    }

    testWidgets(
      'open vault on a server with no saved server asks the guard before connect',
      (tester) async {
        final env = await wi362PumpLocal(tester, servers: const []);
        final before = wi362Snapshot(env);
        env.allow = false;
        await _open(tester, env);

        await wi362Tap(tester, wi362KeyInModal('vault-picker-open-on-server'));
        expect(env.guardCalls, [false]);
        expect(env.actions.calls, isEmpty, reason: 'stay: no connect dialog');

        env.allow = true;
        await wi362Tap(tester, wi362KeyInModal('vault-picker-open-on-server'));
        expect(env.guardCalls, [false, false]);
        // The connect was cancelled (the fake answers null): nothing more.
        expect(env.actions.calls, ['connect']);
        _expectStays(env, before);
      },
    );

    testWidgets(
      'a failed open local vault from the modal keeps the vault and shows the error',
      (tester) async {
        final env = await wi362PumpLocal(tester);
        final before = wi362Snapshot(env);
        final plain = createPlainFolder('om362_plain_');
        env.files.directories.add(plain.path);
        await _open(tester, env);

        await wi362Tap(tester, wi362KeyInModal('vault-picker-open'));

        expect(env.guardCalls, [false]);
        expect(
          find.descendant(
            of: find.byType(SnackBar),
            matching: find.textContaining('does not look like a vault'),
          ),
          findsOneWidget,
        );
        _expectStays(env, before);
      },
    );

    testWidgets(
      'open local vault from the modal opens the chosen vault and closes the modal',
      (tester) async {
        final env = await wi362PumpLocal(tester);
        env.files.directories.add(env.otherPath);
        await _open(tester, env);

        await wi362Tap(tester, wi362KeyInModal('vault-picker-open'));

        expect(env.guardCalls, [false], reason: 'the guard is asked once');
        expect(env.current, LocalVaultRef(env.otherPath!));
        expect(env.settings.lastVaultRef, LocalVaultRef(env.otherPath!));
        expect(wi362Modal, findsNothing);
        expect(env.modalDone, isTrue);
        expect(find.byType(Workspace), findsOneWidget);
      },
    );
  });

  group('delete', () {
    testWidgets(
      'deleting a vault that is not open from the modal keeps the modal and the open vault',
      (tester) async {
        final env = await wi362PumpLocal(tester);
        await _open(tester, env);
        _expectRow(1, 'work-notes');

        await wi362Tap(tester, wi362KeyInModal('recent-row-delete-1'));
        expect(find.byType(DeleteVaultDialog), findsOneWidget);
        expect(
          find.byKey(const Key('delete-vault-open-line')),
          findsNothing,
          reason: 'not the open vault',
        );
        await wi362Tap(tester, find.byKey(const Key('delete-vault-confirm')));
        await wi362Settle(tester);

        expect(env.trash.calls, [env.otherPath]);
        expect(find.byType(DeleteVaultDialog), findsNothing);
        expect(wi362Modal, findsOneWidget, reason: 'the modal stays');
        expect(wi362InModal(find.text('work-notes')), findsNothing);
        _expectRow(0, 'memex');
        expect(env.current, LocalVaultRef(env.openPath!));
        expect(env.settings.lastVaultRef, LocalVaultRef(env.openPath!));
        expect(
          env.settings.recentRefs,
          isNot(contains(LocalVaultRef(env.otherPath!))),
        );
        expect(env.guardCalls, isEmpty, reason: 'the open vault is not left');
      },
    );

    testWidgets(
      'deleting the open vault from its row closes the modal and shows the full screen picker',
      (tester) async {
        final env = await wi362PumpLocal(tester);
        await _open(tester, env);

        await wi362Tap(tester, wi362KeyInModal('recent-row-delete-0'));
        expect(find.byType(DeleteVaultDialog), findsOneWidget);
        expect(find.byKey(const Key('delete-vault-open-line')), findsOneWidget);
        await wi362Tap(tester, find.byKey(const Key('delete-vault-confirm')));
        await wi362Settle(tester, rounds: 12);

        expect(env.trash.calls, [env.openPath]);
        expect(env.current, isNull);
        expect(wi362Modal, findsNothing, reason: 'the modal closed');
        expect(env.modalDone, isTrue);
        expect(find.byType(DeleteVaultDialog), findsNothing);
        expect(find.byType(VaultPickerScreen), findsOneWidget);
        expect(
          env.settings.recentRefs,
          isNot(contains(LocalVaultRef(env.openPath!))),
        );
        expect(env.settings.lastVaultRef, isNull);
      },
    );
  });

  group('servers', () {
    const tip = 'seed is open on this server. switch to another vault first.';

    testWidgets(
      'remove server is disabled on the open hosted vault server with its tooltip',
      (tester) async {
        final handle = tester.ensureSemantics();
        final env = await wi362PumpHosted(tester);
        await _open(tester, env);
        final remove = wi362KeyInModal('server-row-remove-$fakeServerId');
        expect(remove, findsOneWidget);

        final buttons = wi362ButtonNodesIn(tester, remove);
        expect(buttons, hasLength(1), reason: 'reads as one button');
        expect(
          buttons.single,
          isSemantics(isButton: true, hasEnabledState: true, isEnabled: false),
        );
        expect(await wi362TooltipShows(tester, remove, tip), isTrue);

        await tester.tap(remove, warnIfMissed: false);
        await wi362Settle(tester);
        expect(find.byKey(_removeConfirm), findsNothing);
        expect(env.settings.savedServers, hasLength(2));
        expect(wi362Modal, findsOneWidget);
        handle.dispose();
      },
    );

    testWidgets(
      'edit server on the open hosted vault server still opens the edit dialog',
      (tester) async {
        final env = await wi362PumpHosted(tester);
        await _open(tester, env);

        await wi362Tap(
          tester,
          wi362KeyInModal('server-row-edit-$fakeServerId'),
        );

        expect(env.actions.calls, ['editServer $fakeServerId']);
        expect(wi362Modal, findsOneWidget);
      },
    );

    testWidgets(
      'remove server on another server than the open hosted vault still removes it',
      (tester) async {
        final handle = tester.ensureSemantics();
        final env = await wi362PumpHosted(tester);
        await _open(tester, env);
        final remove = wi362KeyInModal('server-row-remove-srv-studio');
        expect(
          wi362ButtonNodesIn(tester, remove).single,
          isNot(isSemantics(hasEnabledState: true, isEnabled: false)),
        );
        expect(await wi362TooltipShows(tester, remove, tip), isFalse);
        expect(
          await wi362TooltipShows(tester, remove, 'remove server'),
          isTrue,
        );

        await wi362Tap(tester, remove);
        expect(find.byKey(_removeConfirm), findsOneWidget);
        await wi362Tap(tester, find.byKey(_removeConfirm));

        expect(
          [for (final s in env.settings.savedServers) s.id],
          [fakeServerId],
        );
        expect(env.current, seedHostedRef);
        expect(wi362Modal, findsOneWidget);
        handle.dispose();
      },
    );

    testWidgets('with a local vault open every remove server is enabled', (
      tester,
    ) async {
      final env = await wi362PumpLocal(tester);
      await _open(tester, env);

      await wi362Tap(
        tester,
        wi362KeyInModal('server-row-remove-$fakeServerId'),
      );

      expect(find.byKey(_removeConfirm), findsOneWidget);
    });
  });

  group('full screen picker', () {
    testWidgets(
      'the full screen picker shows the shared picker body with no OPEN row',
      (tester) async {
        final vault = createVaultFolder('om362_fs_');
        await pumpVaultPicker(tester, recents: [LocalVaultRef(vault.path)]);

        expect(
          find.descendant(
            of: find.byType(VaultPickerScreen),
            matching: find.byType(VaultPickerBody),
          ),
          findsOneWidget,
          reason: 'the one shared picker body (TD1)',
        );
        expect(find.byKey(const Key('recent-row-open-tag-0')), findsNothing);
        expect(find.byKey(const Key('recent-row-remove-0')), findsOneWidget);
        expect(wi362Close, findsNothing);
        expect(wi362Modal, findsNothing);
        expect(find.text('open memex'), findsOneWidget, reason: 'A3 brand row');
      },
    );
  });

  test(
    'GLOSSARY.md has the Vault picker entry under Vault management before Backups',
    () {
      final glossary = File('../GLOSSARY.md').readAsStringSync();
      const section = '## Vault management (#355)';
      const entry =
          '**Vault picker**:\n'
          'The one place that lists the person\'s vaults and offers opening, '
          'creating, restoring and deleting them: full screen when no vault is '
          'open, and over the workspace when opened from the sidebar\'s VAULTS '
          'header.\n'
          '_Avoid_: vault manager, vault switcher, vaults screen';

      expect(section.allMatches(glossary), hasLength(1));
      expect('**Vault picker**:'.allMatches(glossary), hasLength(1));
      final at = glossary.indexOf(section);
      final entryAt = glossary.indexOf(entry);
      final backups = glossary.indexOf('## Backups (#315)');
      expect(entryAt, greaterThan(at), reason: 'the entry is in the section');
      expect(backups, greaterThan(entryAt), reason: 'before Backups');
      // Nothing but the entry between the section heading and the next
      // section (#391's Echoes sits between it and Backups, D25).
      final next = glossary.indexOf('\n## ', at + section.length);
      final between = glossary.substring(at + section.length, next).trim();
      expect(between, entry);
    },
  );
}
