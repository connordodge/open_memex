// WI #348 (Spec #347, Req 12, 13, 15, 16, 17): the delete flow. `delete`
// re-checks the folder, moves it to the Trash through the seam and, only on
// success, forgets the vault, its recorded row outcome and its backup
// settings. Every failure leaves the app's state and the folder as they were.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/backup_models.dart';
import 'package:open_memex_app/src/state/settings.dart';
import 'package:open_memex_app/src/state/vault_delete.dart';
import 'package:open_memex_app/src/state/vault_open_controller.dart';
import 'package:open_memex_app/src/state/vault_open_hosted.dart';
import 'package:open_memex_app/src/state/vault_ref.dart';
import 'package:open_memex_app/src/state/vault_trash.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_vault_trash.dart';
import '../support/token_store_fakes.dart';

const _backupsKey = 'memex.vault_backups';

/// The recorded outcome both vaults start with, so a change is visible.
const _failed = RecentRowFailed(VaultOpenFailure('could not open'));

/// A temp folder holding two vaults (a space, `@` and `~` in the name) and a
/// backup destination with a `.memex.zip` in it.
class _Rig {
  _Rig._(this.root, this.settings, this.trash, this.container);

  final Directory root;
  final SettingsController settings;
  final FakeVaultTrash trash;
  final ProviderContainer container;

  String get vault => p.join(root.path, 'My Vaults', 'alpha @home~1');
  String get other => p.join(root.path, 'My Vaults', 'bravo');
  String get dest => p.join(root.path, 'Backups');
  File get zip => File(p.join(dest, 'alpha-2026-11-01.memex.zip'));

  VaultDeleter get deleter => container.read(vaultDeleterProvider);

  static Future<_Rig> create({bool lastIsVault = true}) async {
    final root = await Directory.systemTemp.createTemp('memex_348_');
    SharedPreferences.setMockInitialValues({'memex.binary_path': 'fake-memex'});
    final settings = await SettingsController.load(
      tokenStore: FakeTokenStore(),
    );
    final trash = FakeVaultTrash();
    final container = ProviderContainer(
      overrides: [
        settingsProvider.overrideWith((_) => settings),
        vaultTrashProvider.overrideWithValue(trash),
      ],
    );
    final rig = _Rig._(root, settings, trash, container);
    for (final dir in [rig.vault, rig.other]) {
      await Directory(dir).create(recursive: true);
      await File(p.join(dir, 'manifest.json')).writeAsString('{"v":1}');
      await File(p.join(dir, 'memex.db')).writeAsString('db');
      await File(p.join(dir, 'notes.md')).writeAsString('# note');
    }
    await Directory(rig.dest).create(recursive: true);
    await rig.zip.writeAsString('zip bytes');
    // The last vault is the one remembered last.
    final order = lastIsVault ? [rig.other, rig.vault] : [rig.vault, rig.other];
    for (final path in order) {
      await settings.rememberVault(path);
    }
    await settings.setVaultBackup(
      rig.vault,
      VaultBackupSettings(enabled: true, destination: rig.dest, keep: 14),
    );
    await settings.setVaultBackup(
      rig.other,
      VaultBackupSettings(enabled: true, destination: rig.dest, keep: 30),
    );
    for (final path in [rig.vault, rig.other]) {
      container
              .read(recentRowOutcomeProvider(LocalVaultRef(path)).notifier)
              .state =
          _failed;
    }
    return rig;
  }

  RecentRowOutcome? outcome(String path) =>
      container.read(recentRowOutcomeProvider(LocalVaultRef(path)));

  /// Everything a failed delete must leave alone: the settings state, every
  /// stored preference and both recorded outcomes.
  Future<Map<String, Object?>> snapshot() async {
    final prefs = await SharedPreferences.getInstance();
    final s = settings.state;
    return {
      'recentRefs': s.recentRefs,
      'lastVaultRef': s.lastVaultRef,
      'vaultBackups': s.vaultBackups,
      'prefs': {for (final k in prefs.getKeys()) k: prefs.get(k)},
      'outcomeVault': outcome(vault),
      'outcomeOther': outcome(other),
    };
  }

  Future<void> dispose() async {
    container.dispose();
    // The prefs store is in memory; nothing to flush before the folder goes.
    if (await root.exists()) await root.delete(recursive: true);
  }

  /// The folder and every file in it are still there.
  Future<void> expectVaultIntact() async {
    for (final f in ['manifest.json', 'memex.db', 'notes.md']) {
      expect(File(p.join(vault, f)).existsSync(), isTrue, reason: f);
    }
  }
}

Future<void> _withRig(
  Future<void> Function(_Rig rig) body, {
  bool lastIsVault = true,
}) async {
  final rig = await _Rig.create(lastIsVault: lastIsVault);
  try {
    await body(rig);
  } finally {
    await rig.dispose();
  }
}

Matcher _failedWith(String message) =>
    isA<VaultDeleteFailed>().having((f) => f.message, 'message', message);

void main() {
  group('delete of a path that is not a vault (AC7)', () {
    final cases = <(String, Future<void> Function(_Rig))>[
      (
        'delete of a vault whose folder is gone fails and changes nothing',
        (rig) => Directory(rig.vault).delete(recursive: true),
      ),
      (
        'delete of a folder with no manifest.json fails and changes nothing',
        (rig) => File(p.join(rig.vault, 'manifest.json')).delete(),
      ),
      (
        'delete of a folder with no memex.db fails and changes nothing',
        (rig) => File(p.join(rig.vault, 'memex.db')).delete(),
      ),
    ];
    for (final (name, breakVault) in cases) {
      test(name, () async {
        await _withRig((rig) async {
          await breakVault(rig);
          final before = await rig.snapshot();

          final result = await rig.deleter.delete(rig.vault);

          expect(
            result,
            _failedWith(
              '${rig.vault} is no longer a vault folder. nothing was deleted.',
            ),
          );
          expect(rig.trash.calls, isEmpty);
          expect(await rig.snapshot(), before);
        });
      });
    }
  });

  group('delete when the Trash call succeeds (AC8)', () {
    test('delete on Trashed returns VaultDeleted', () async {
      await _withRig((rig) async {
        final result = await rig.deleter.delete(rig.vault);
        expect(result, isA<VaultDeleted>());
        expect(rig.trash.calls, [rig.vault]);
      });
    });

    test(
      'delete on Trashed drops the vault from the recents and keeps the others',
      () async {
        await _withRig((rig) async {
          expect(
            rig.settings.state.recentRefs,
            contains(LocalVaultRef(rig.vault)),
          );
          await rig.deleter.delete(rig.vault);
          expect(rig.settings.state.recentRefs, [LocalVaultRef(rig.other)]);
          // And the stored recents agree: a fresh load shows the same.
          final reloaded = await SettingsController.load(
            tokenStore: FakeTokenStore(),
          );
          expect(reloaded.state.recentRefs, [LocalVaultRef(rig.other)]);
        });
      },
    );

    test(
      'delete on Trashed clears the last vault when it was this vault',
      () async {
        await _withRig((rig) async {
          expect(rig.settings.state.lastVaultRef, LocalVaultRef(rig.vault));
          await rig.deleter.delete(rig.vault);
          expect(rig.settings.state.lastVaultRef, isNull);
          final reloaded = await SettingsController.load(
            tokenStore: FakeTokenStore(),
          );
          expect(reloaded.state.lastVaultRef, isNull);
        });
      },
    );

    test(
      'delete on Trashed keeps the last vault when it was another',
      () async {
        await _withRig(lastIsVault: false, (rig) async {
          expect(rig.settings.state.lastVaultRef, LocalVaultRef(rig.other));
          await rig.deleter.delete(rig.vault);
          expect(rig.settings.state.lastVaultRef, LocalVaultRef(rig.other));
          expect(rig.settings.state.recentRefs, [LocalVaultRef(rig.other)]);
        });
      },
    );

    test(
      'delete on Trashed clears the recorded row outcome for that vault only',
      () async {
        await _withRig((rig) async {
          expect(rig.outcome(rig.vault), same(_failed));
          await rig.deleter.delete(rig.vault);
          expect(rig.outcome(rig.vault), isNull);
          expect(rig.outcome(rig.other), same(_failed));
        });
      },
    );

    test(
      'delete on Trashed removes the vault backup settings from state and prefs only for that vault',
      () async {
        await _withRig((rig) async {
          final otherSettings = rig.settings.state.vaultBackups[rig.other];
          expect(rig.settings.state.vaultBackups, hasLength(2));

          await rig.deleter.delete(rig.vault);

          expect(rig.settings.state.vaultBackups, {rig.other: otherSettings});
          final prefs = await SharedPreferences.getInstance();
          final stored =
              jsonDecode(prefs.getString(_backupsKey)!) as Map<String, Object?>;
          expect(stored.keys, [rig.other]);
          final reloaded = await SettingsController.load(
            tokenStore: FakeTokenStore(),
          );
          expect(reloaded.state.vaultBackups, {rig.other: otherSettings});
        });
      },
    );

    test(
      'delete moves nothing itself: only the Trash call removes files',
      () async {
        await _withRig((rig) async {
          expect(await rig.deleter.delete(rig.vault), isA<VaultDeleted>());
          // The fake trash removes nothing, so anything missing here would
          // have been deleted by the flow itself.
          await rig.expectVaultIntact();
          expect(Directory(rig.other).existsSync(), isTrue);
        });
      },
    );

    test(
      'delete keeps a backup zip in the backup destination unchanged',
      () async {
        await _withRig((rig) async {
          final before = await rig.zip.readAsBytes();
          final result = await rig.deleter.delete(rig.vault);
          expect(result, isA<VaultDeleted>());
          expect(rig.zip.existsSync(), isTrue);
          expect(await rig.zip.readAsBytes(), before);
          expect(rig.zip.path.endsWith('.memex.zip'), isTrue);
          expect(Directory(rig.dest).listSync().map((e) => e.path), [
            rig.zip.path,
          ]);
        });
      },
    );

    test(
      'delete waits for the Trash call before it forgets anything',
      () async {
        await _withRig((rig) async {
          final hold = Completer<TrashResult>();
          rig.trash.hold(hold);
          final before = await rig.snapshot();

          var done = false;
          final future = rig.deleter.delete(rig.vault).then((r) {
            done = true;
            return r;
          });
          await pumpEventQueue();

          expect(rig.trash.calls, [rig.vault]);
          expect(done, isFalse);
          expect(await rig.snapshot(), before);

          hold.complete(const Trashed());
          expect(await future, isA<VaultDeleted>());
          expect(rig.settings.state.recentRefs, [LocalVaultRef(rig.other)]);
          expect(rig.outcome(rig.vault), isNull);
        });
      },
    );
  });

  group('delete when the Trash call fails (AC9, AC10)', () {
    final cases = <(String, TrashResult, String Function(_Rig))>[
      (
        'delete on TrashNoTrash fails with the no-trash message and changes nothing',
        const TrashNoTrash(),
        (rig) =>
            "this drive has no trash, so alpha @home~1 can't be moved there. "
            'nothing was deleted.',
      ),
      (
        'delete on TrashPermission fails with the not-allowed message and changes nothing',
        const TrashPermission(),
        (rig) =>
            "open memex isn't allowed to move ${rig.vault}. "
            'nothing was deleted.',
      ),
      (
        'delete on TrashNotFound fails with the no-longer-a-vault message and changes nothing',
        const TrashNotFound(),
        (rig) =>
            '${rig.vault} is no longer a vault folder. nothing was deleted.',
      ),
      (
        'delete on TrashFailed fails with the could-not-move message and changes nothing',
        TrashFailed(['disk', 'busy'].join(' ')),
        (rig) =>
            "couldn't move alpha @home~1 to the trash: disk busy. "
            'nothing was deleted.',
      ),
    ];
    for (final (name, trashResult, message) in cases) {
      test(name, () async {
        await _withRig((rig) async {
          rig.trash.answer(trashResult);
          final before = await rig.snapshot();
          final zipBefore = await rig.zip.readAsBytes();

          final result = await rig.deleter.delete(rig.vault);

          expect(result, _failedWith(message(rig)));
          expect(rig.trash.calls, [rig.vault]);
          expect(await rig.snapshot(), before);
          // Nothing was deleted outside the Trash call.
          await rig.expectVaultIntact();
          expect(await rig.zip.readAsBytes(), zipBefore);
          expect(Directory(rig.other).existsSync(), isTrue);
        });
      });
    }
  });

  group('vaultDeleteMessage (AC9)', () {
    const path = '/Users/test/My Vaults/alpha @home~1';

    test('vaultDeleteMessage is null for Trashed', () {
      expect(vaultDeleteMessage(const Trashed(), path), isNull);
    });

    test(
      'vaultDeleteMessage for TrashNoTrash names the folder, not the path',
      () {
        expect(
          vaultDeleteMessage(const TrashNoTrash(), path),
          "this drive has no trash, so alpha @home~1 can't be moved there. "
          'nothing was deleted.',
        );
      },
    );

    test('vaultDeleteMessage for TrashPermission names the full path', () {
      expect(
        vaultDeleteMessage(const TrashPermission(), path),
        "open memex isn't allowed to move $path. nothing was deleted.",
      );
    });

    test('vaultDeleteMessage for TrashNotFound names the full path', () {
      expect(
        vaultDeleteMessage(const TrashNotFound(), path),
        '$path is no longer a vault folder. nothing was deleted.',
      );
    });

    test(
      'vaultDeleteMessage for TrashFailed names the folder and the reason',
      () {
        expect(
          vaultDeleteMessage(TrashFailed(['no', 'space'].join(' ')), path),
          "couldn't move alpha @home~1 to the trash: no space. "
          'nothing was deleted.',
        );
      },
    );

    test('vaultDeleteMessage uses the last path segment as the name', () {
      expect(
        vaultDeleteMessage(const TrashNoTrash(), '/Volumes/NAS share/bravo'),
        "this drive has no trash, so bravo can't be moved there. "
        'nothing was deleted.',
      );
    });
  });
}
