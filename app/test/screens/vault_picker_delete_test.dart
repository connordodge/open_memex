// WI #350 (Spec #347 req 1–6, 12, 15, 18, 20, 21): the delete button on the
// vault picker's local recent rows, the row re-check after the delete dialog
// closes, the picker journey with the fake Trash, and the README line.
// Seams: test/support/vault_picker_harness.dart (mock prefs, fake servers,
// recording open controller, `trash:` as `vaultTrashProvider`),
// FakeVaultTrash, and real temp vault folders. Never a real Trash or vault.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:open_memex_app/src/state/backup_models.dart';
import 'package:open_memex_app/src/state/settings.dart';
import 'package:open_memex_app/src/state/vault_open_hosted.dart';
import 'package:open_memex_app/src/state/vault_ref.dart';
import 'package:open_memex_app/src/state/vault_trash.dart';
import 'package:open_memex_app/src/widgets/picker/delete_vault_dialog.dart';
import 'package:open_memex_app/src/widgets/picker/server_row.dart';
import 'package:path/path.dart' as p;

import '../support/fake_vault_server.dart';
import '../support/fake_vault_trash.dart';
import '../support/font_fetch_hold.dart';
import '../support/vault_folders.dart';
import '../support/vault_picker_harness.dart';
import '../support/wi349_keyboard.dart';

Finder _key(String k) => find.byKey(Key(k));

/// The delete-vault dialog, wherever it is in the tree.
Finder get _dialog => find.byType(DeleteVaultDialog);

/// Saves backup settings for [path] (built from run-time values).
Future<VaultBackupSettings> _seedBackups(
  WidgetTester tester,
  Wi97Picker env,
  String path, {
  int keep = 7,
}) async {
  final settings = VaultBackupSettings(
    enabled: true,
    destination: p.join(Directory.systemTemp.path, 'om350_dest_$keep'),
    keep: keep,
  );
  await tester.runAsync(
    () => env.container
        .read(settingsProvider.notifier)
        .setVaultBackup(path, settings),
  );
  await wi97Settle(tester);
  return settings;
}

/// A trash that removes the folder from disk before answering
/// [TrashNotFound]: the folder went away during the move.
class _Wi350GoneTrash implements VaultTrash {
  final List<String> calls = [];

  @override
  Future<TrashResult> trash(String path) async {
    calls.add(path);
    deleteFolderQuietly(Directory(path));
    return const TrashNotFound();
  }
}

void main() {
  holdFontFetches();

  group('row', () {
    testWidgets(
      'a local vault row shows the trash delete button before the x with its tooltip and semantic label',
      (tester) async {
        final handle = tester.ensureSemantics();
        final vault = createVaultFolder('om350_row_');
        final name = p.basename(vault.path);
        await pumpVaultPicker(
          tester,
          recents: [LocalVaultRef(vault.path)],
          trash: FakeVaultTrash(),
        );

        final delete = _key('recent-row-delete-0');
        final x = _key('recent-row-remove-0');
        expect(delete, findsOneWidget);
        expect(x, findsOneWidget);
        expect(wi97Inside('recent-row-0', delete), findsOneWidget);

        final button = tester.widget<PickerRowIconButton>(delete);
        expect(button.icon, LucideIcons.trash);
        expect(button.tooltip, 'delete vault');
        expect(button.semanticLabel, 'delete vault $name');
        expect(
          wi97Inside('recent-row-0', find.byTooltip('delete vault')),
          findsOneWidget,
        );

        // Before the x, in the same line.
        final d = tester.getRect(delete);
        final r = tester.getRect(x);
        expect(d.right, lessThanOrEqualTo(r.left));
        expect((d.center.dy - r.center.dy).abs(), lessThan(1));

        expect(
          wi349NodeLabelled(tester, delete, 'delete vault $name'),
          isSemantics(
            label: 'delete vault $name',
            isButton: true,
            hasTapAction: true,
          ),
        );
        expect(
          wi349NodeLabelled(tester, x, 'remove from recents'),
          isSemantics(label: 'remove from recents', isButton: true),
        );
        handle.dispose();
      },
    );

    testWidgets(
      'the delete key carries the row index and a missing folder row before it has none',
      (tester) async {
        final missing = p.join(
          createPlainFolder('om350_gone_').path,
          'not-here',
        );
        final vault = createVaultFolder('om350_second_');
        final trash = FakeVaultTrash();
        await pumpVaultPicker(
          tester,
          recents: [LocalVaultRef(missing), LocalVaultRef(vault.path)],
          trash: trash,
        );

        expect(_key('recent-row-delete-0'), findsNothing);
        expect(_key('recent-row-delete-1'), findsOneWidget);
        expect(
          wi97Inside('recent-row-1', _key('recent-row-delete-1')),
          findsOneWidget,
        );

        await tester.tap(_key('recent-row-delete-1'));
        await wi97Settle(tester);
        expect(_dialog, findsOneWidget);
        expect(
          find.descendant(
            of: _dialog,
            matching: find.text('move ${p.basename(vault.path)} to the trash?'),
          ),
          findsOneWidget,
        );
        expect(
          trash.calls,
          isEmpty,
          reason: 'opening the dialog moves nothing',
        );
      },
    );

    testWidgets(
      'the delete button also shows on a local vault row while the memex binary is missing',
      (tester) async {
        final vault = createVaultFolder('om350_nobin_');
        await pumpVaultPicker(
          tester,
          binary: false,
          recents: [LocalVaultRef(vault.path)],
          trash: FakeVaultTrash(),
        );

        expect(
          wi97Inside('recent-row-0', find.text('needs the memex binary')),
          findsOneWidget,
        );
        expect(_key('recent-row-delete-0'), findsOneWidget);
        expect(_key('recent-row-remove-0'), findsOneWidget);
        expect(
          tester.getRect(_key('recent-row-delete-0')).right,
          lessThanOrEqualTo(tester.getRect(_key('recent-row-remove-0')).left),
        );

        await tester.tap(_key('recent-row-delete-0'));
        await wi97Settle(tester);
        expect(
          _dialog,
          findsOneWidget,
          reason: 'moving to the Trash needs no memex binary',
        );
      },
    );

    testWidgets('a missing folder row shows only the x', (tester) async {
      final missing = p.join(createPlainFolder('om350_miss_').path, 'gone');
      final vault = createVaultFolder('om350_beside_');
      await pumpVaultPicker(
        tester,
        recents: [LocalVaultRef(missing), LocalVaultRef(vault.path)],
        trash: FakeVaultTrash(),
      );
      // The vault beside it has one, so the missing row's absence is real.
      expect(_key('recent-row-delete-1'), findsOneWidget);

      expect(
        wi97Inside('recent-row-0', find.byIcon(LucideIcons.folderX)),
        findsOneWidget,
      );
      expect(_key('recent-row-remove-0'), findsOneWidget);
      expect(_key('recent-row-delete-0'), findsNothing);
      expect(
        wi97Inside('recent-row-0', find.byIcon(LucideIcons.trash)),
        findsNothing,
      );
    });

    testWidgets(
      'a folder without memex.db is not a vault and its row shows only the x',
      (tester) async {
        final half = createPlainFolder('om350_half_');
        File(p.join(half.path, 'manifest.json')).writeAsStringSync('{}');
        final vault = createVaultFolder('om350_whole_');
        await pumpVaultPicker(
          tester,
          recents: [LocalVaultRef(half.path), LocalVaultRef(vault.path)],
          trash: FakeVaultTrash(),
        );

        expect(_key('recent-row-remove-0'), findsOneWidget);
        expect(_key('recent-row-delete-0'), findsNothing);
        expect(_key('recent-row-delete-1'), findsOneWidget);
      },
    );

    testWidgets(
      'an opening local row shows neither the delete button nor the x',
      (tester) async {
        final vault = createVaultFolder('om350_opening_');
        final ref = LocalVaultRef(vault.path);
        final env = await pumpVaultPicker(
          tester,
          recents: [ref],
          recorded: {ref: const RecentRowOpening()},
          trash: FakeVaultTrash(),
        );

        expect(
          wi97Inside(
            'recent-row-0',
            find.byKey(const Key('recent-row-opening')),
          ),
          findsOneWidget,
        );
        expect(_key('recent-row-delete-0'), findsNothing);
        expect(_key('recent-row-remove-0'), findsNothing);

        // When the open ends the row is a plain local row again, with both.
        env.container.read(recentRowOutcomeProvider(ref).notifier).state = null;
        await wi97Settle(tester);
        expect(_key('recent-row-delete-0'), findsOneWidget);
        expect(_key('recent-row-remove-0'), findsOneWidget);
      },
    );

    testWidgets(
      'a hosted row shows no delete button and keeps its x and remove from recents',
      (tester) async {
        const gone = HostedVaultRef(fakeServerId, 'memex');
        const ok = HostedVaultRef(fakeServerId, 'work');
        final vault = createVaultFolder('om350_local_');
        await pumpVaultPicker(
          tester,
          recents: [gone, ok, LocalVaultRef(vault.path)],
          recorded: {
            gone: const RecentRowFailed(
              HostedVaultGone(
                gone,
                fakeServerName,
                'memex is no longer on nas',
              ),
            ),
          },
          trash: FakeVaultTrash(),
        );

        for (final i in [0, 1]) {
          expect(_key('recent-row-delete-$i'), findsNothing);
          expect(
            wi97Inside('recent-row-$i', find.byIcon(LucideIcons.trash)),
            findsNothing,
          );
          expect(_key('recent-row-remove-$i'), findsOneWidget);
        }
        expect(_key('recent-row-remove-from-recents-0'), findsOneWidget);
        // The local vault row after them has one.
        expect(_key('recent-row-delete-2'), findsOneWidget);
      },
    );

    testWidgets('the x only forgets the row and never calls the trash', (
      tester,
    ) async {
      final vault = createVaultFolder('om350_x_');
      final trash = FakeVaultTrash();
      final env = await pumpVaultPicker(
        tester,
        recents: [LocalVaultRef(vault.path)],
        trash: trash,
      );
      final backups = await _seedBackups(tester, env, vault.path);
      expect(_key('recent-row-delete-0'), findsOneWidget);

      await tester.tap(_key('recent-row-remove-0'));
      await wi97Settle(tester);

      expect(env.settings.recentRefs, isEmpty);
      expect(trash.calls, isEmpty);
      expect(_dialog, findsNothing, reason: 'the x asks nothing');
      expect(vault.existsSync(), isTrue);
      expect(File(p.join(vault.path, 'manifest.json')).existsSync(), isTrue);
      expect(File(p.join(vault.path, 'memex.db')).existsSync(), isTrue);
      expect(env.settings.vaultBackups[vault.path]?.keep, backups.keep);
    });

    testWidgets(
      'Tab reaches the row delete button and Enter opens the dialog',
      (tester) async {
        final vault = createVaultFolder('om350_tab_');
        final trash = FakeVaultTrash();
        final env = await pumpVaultPicker(
          tester,
          recents: [LocalVaultRef(vault.path)],
          trash: trash,
        );
        final delete = _key('recent-row-delete-0');
        expect(delete, findsOneWidget);
        expect(_dialog, findsNothing);

        await wi349TabTo(tester, delete);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await wi97Settle(tester);

        expect(_dialog, findsOneWidget);
        expect(find.text('DELETE VAULT'), findsOneWidget);
        expect(trash.calls, isEmpty);
        expect(
          env.opener.opened,
          isEmpty,
          reason: 'Enter on delete opens nothing',
        );
        expect(env.settings.recentRefs, [LocalVaultRef(vault.path)]);
      },
    );

    testWidgets(
      'at 1.3x text and a 720 px window the row with both buttons lays out with no overflow',
      (tester) async {
        tester.platformDispatcher.textScaleFactorTestValue = 1.3;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final parent = createPlainFolder('om350_wide_');
        final path = p.join(
          parent.path,
          'a-vault-with-a-rather-long-folder-name-for-the-row',
        );
        initVaultFolder(path);
        await pumpVaultPicker(
          tester,
          binary: false,
          size: const Size(720, 800),
          recents: [LocalVaultRef(path)],
          trash: FakeVaultTrash(),
        );

        expect(tester.takeException(), isNull);
        final row = tester.getRect(_key('recent-row-0'));
        for (final k in ['recent-row-delete-0', 'recent-row-remove-0']) {
          expect(_key(k), findsOneWidget);
          final r = tester.getRect(_key(k));
          expect(
            row.contains(r.topLeft) && row.contains(r.bottomRight),
            isTrue,
            reason: '$k inside its row',
          );
          expect(r.right, lessThanOrEqualTo(720));
        }
      },
    );
  });

  group('row after the dialog', () {
    for (final (name, gone) in [
      (
        'after a not a vault failure whose folder is gone closing the dialog shows the missing row with no delete button',
        'before',
      ),
      (
        'after a not found failure whose folder is gone closing the dialog shows the missing row with no delete button',
        'during',
      ),
    ]) {
      testWidgets(name, (tester) async {
        final vault = createVaultFolder('om350_after_');
        final goneTrash = _Wi350GoneTrash();
        final fake = FakeVaultTrash();
        final env = await pumpVaultPicker(
          tester,
          recents: [LocalVaultRef(vault.path)],
          trash: gone == 'during' ? goneTrash : fake,
        );

        expect(_key('recent-row-delete-0'), findsOneWidget);
        await tester.tap(_key('recent-row-delete-0'));
        await wi97Settle(tester);
        expect(_dialog, findsOneWidget);

        if (gone == 'before') deleteFolderQuietly(vault);
        await tester.tap(_key('delete-vault-confirm'));
        await wi97Settle(tester);

        final message =
            '${vault.path} is no longer a vault folder. nothing was deleted.';
        expect(
          find.descendant(of: _dialog, matching: find.text(message)),
          findsOneWidget,
        );
        if (gone == 'before') {
          expect(fake.calls, isEmpty, reason: 'nothing is moved');
        } else {
          expect(goneTrash.calls, [vault.path]);
        }

        await tester.tap(_key('delete-vault-cancel'));
        await wi97Settle(tester);

        expect(_dialog, findsNothing);
        expect(env.settings.recentRefs, [LocalVaultRef(vault.path)]);
        expect(_key('recent-row-0'), findsOneWidget);
        expect(
          wi97Inside('recent-row-0', find.byIcon(LucideIcons.folderX)),
          findsOneWidget,
        );
        expect(_key('recent-row-delete-0'), findsNothing);
        expect(_key('recent-row-remove-0'), findsOneWidget);
      });
    }

    testWidgets(
      'after a failure whose folder is still a vault closing the dialog keeps the row and its delete button',
      (tester) async {
        final vault = createVaultFolder('om350_kept_');
        final trash = FakeVaultTrash()..answer(const TrashPermission());
        final env = await pumpVaultPicker(
          tester,
          recents: [LocalVaultRef(vault.path)],
          trash: trash,
        );

        expect(_key('recent-row-delete-0'), findsOneWidget);
        await tester.tap(_key('recent-row-delete-0'));
        await wi97Settle(tester);
        await tester.tap(_key('delete-vault-confirm'));
        await wi97Settle(tester);
        expect(_dialog, findsOneWidget);
        await tester.tap(_key('delete-vault-cancel'));
        await wi97Settle(tester);

        expect(_dialog, findsNothing);
        expect(env.settings.recentRefs, [LocalVaultRef(vault.path)]);
        expect(
          wi97Inside('recent-row-0', find.byIcon(LucideIcons.folder)),
          findsOneWidget,
        );
        expect(_key('recent-row-delete-0'), findsOneWidget);
        expect(trash.calls, [vault.path]);
      },
    );
  });

  group('journey', () {
    testWidgets(
      'picker journey with the fake trash deletes a temp local vault from the recents',
      (tester) async {
        final vault = createVaultFolder('om350_journey_');
        final other = createVaultFolder('om350_other_');
        final trash = FakeVaultTrash();
        final env = await pumpVaultPicker(
          tester,
          recents: [LocalVaultRef(vault.path), LocalVaultRef(other.path)],
          trash: trash,
        );
        await _seedBackups(tester, env, vault.path, keep: 5);
        final otherBackups = await _seedBackups(
          tester,
          env,
          other.path,
          keep: 9,
        );
        expect(env.settings.vaultBackups[vault.path], isNotNull);

        expect(_key('recent-row-delete-0'), findsOneWidget);
        await tester.tap(_key('recent-row-delete-0'));
        await wi97Settle(tester);
        expect(_dialog, findsOneWidget);
        await tester.tap(_key('delete-vault-confirm'));
        await wi97Settle(tester);

        expect(_dialog, findsNothing);
        expect(trash.calls, [vault.path]);
        expect(env.settings.recentRefs, [LocalVaultRef(other.path)]);
        expect(env.settings.vaultBackups.containsKey(vault.path), isFalse);
        expect(env.settings.vaultBackups[other.path]?.keep, otherBackups.keep);
        expect(find.text(p.basename(vault.path)), findsNothing);
        expect(find.text(p.basename(other.path)), findsOneWidget);
        expect(
          _key('recent-row-delete-0'),
          findsOneWidget,
          reason: 'the other vault is now row 0',
        );
      },
    );
  });

  group('docs', () {
    test(
      'the README app section says how to delete a local vault and that a hosted vault is removed from its vault root',
      () {
        final readme = File(p.join('..', 'README.md')).readAsLinesSync();
        final start = readme.indexWhere(
          (l) => l.startsWith('- **Flutter macOS app** (`app/`)'),
        );
        expect(start, isNot(-1), reason: 'the app bullet is in the README');
        final block = <String>[readme[start]];
        for (var i = start + 1; i < readme.length; i++) {
          final l = readme[i];
          if (l.startsWith('- ') || l.startsWith('#') || l.trim().isEmpty) {
            break;
          }
          block.add(l);
        }
        final text = block.join('\n');
        final lower = text.toLowerCase().replaceAll('\u2019', "'");
        for (final phrase in [
          'vault picker',
          'delete button',
          'to the trash',
          "finder's put back",
          'backups are kept',
          'hosted vault',
          "can't be deleted from the app",
          "vault server's vault root",
        ]) {
          expect(lower, contains(phrase), reason: 'the app section: "$phrase"');
        }
        expect(text, contains('Trash'), reason: 'the macOS Trash, capitalised');
        expect(text, contains('](docs/hosted-vault.md'));
      },
    );
  });
}
