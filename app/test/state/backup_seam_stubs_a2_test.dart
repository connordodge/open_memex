// WI #321 (A0, D19): the stubs A2 (#323) fills. A2 replaces each stub and
// deletes this whole file (a TEST-CHANGE in its PR). One file per filler, so
// no two fillers edit the same file or its imports.
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/backup_destinations.dart';
import 'package:open_memex_app/src/state/backup_models.dart';
import 'package:open_memex_app/src/state/backup_settings_state.dart';

import '../support/backup_fakes.dart';

/// Run-time values, so the constructor really runs.
VaultBackupSettings _settings() => VaultBackupSettings(
  enabled: true,
  destination: '/Volumes/NAS share/Open Memex Backups',
  keep: 45,
  automatic: false,
);

void main() {
  group('stubs filled by A2 (#323)', () {
    test(
      'IoCloudFolderProbe stub returns neutral values and touches nothing',
      () async {
        const probe = IoCloudFolderProbe();
        expect(await probe.home(), '');
        expect(await probe.isDirectory('/'), isFalse);
        expect(await probe.listNames('/'), isEmpty);
        await probe.createDirectory('/no-such-parent/never-created');
        expect(Directory('/no-such-parent').existsSync(), isFalse);
        expect(await probe.resolveSymbolicLinks('/'), '');
      },
    );

    test('cloudFolderProbeProvider declares an IoCloudFolderProbe stub', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(
        container.read(cloudFolderProbeProvider),
        isA<IoCloudFolderProbe>(),
      );
    });

    test('discoverBackupDestinations stub lists nothing', () async {
      final probe = FakeCloudFolderProbe()..seedIcloud();
      expect(await discoverBackupDestinations(probe), isEmpty);
    });

    test(
      'vault backup settings stubs read the defaults and save nothing',
      () async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final before = container.read(
          vaultBackupSettingsProvider('/some vault'),
        );
        expect(before.enabled, isFalse);
        expect(before.destination, isNull);
        await container.read(saveVaultBackupSettingsProvider)(
          '/some vault',
          _settings(),
        );
        final after = container.read(
          vaultBackupSettingsProvider('/some vault'),
        );
        expect(after.enabled, isFalse);
        expect(after.destination, isNull);
      },
    );
  });
}
