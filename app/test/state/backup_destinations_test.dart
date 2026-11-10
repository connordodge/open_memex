// WI #323 (A2, D22): provider-folder discovery and destination picking, all
// through the CloudFolderProbe seam (FakeCloudFolderProbe in every test of the
// logic; the real IoCloudFolderProbe only ever sees a temp folder). Nothing
// here touches the real `~/Library`.
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/backup_destinations.dart';
import 'package:open_memex_app/src/state/backup_models.dart';
import 'package:open_memex_app/src/state/backup_settings_state.dart';
import 'package:open_memex_app/src/state/settings.dart';
import 'package:path/path.dart' as p;

import '../support/backup_fakes.dart';
import '../support/backup_harness.dart';

const _vault = '/Users/test/My Vaults/alpha @home~1';
const _folderName = 'Open Memex Backups';

BackupDestinationOption _choose() =>
    const BackupDestinationOption(label: 'choose folder…');

BackupDestinationOption _icloud(FakeCloudFolderProbe probe) =>
    BackupDestinationOption(
      provider: BackupProvider.icloud,
      label: 'iCloud Drive',
      path: p.posix.join(probe.icloudFolder, _folderName),
    );

/// A fake with every provider of the "full" discovery AC: iCloud, two Google
/// Drive accounts and two OneDrive names, seeded in a scrambled order.
FakeCloudFolderProbe _fullProbe({String home = fakeHome}) =>
    FakeCloudFolderProbe(home: home)
      ..seedOneDrive('Work Org')
      ..seedGoogleDrive('zoe@example.com')
      ..seedIcloud()
      ..seedOneDrive('Personal')
      ..seedGoogleDrive('connor+tag@example.com');

Future<List<BackupDestinationOption>> _discover(FakeCloudFolderProbe probe) =>
    discoverBackupDestinations(probe);

/// The first discovered row, which must be a provider (not Choose folder).
Future<BackupDestinationOption> _firstProvider(
  FakeCloudFolderProbe probe,
) async {
  final options = await _discover(probe);
  expect(options.length, greaterThan(1));
  return options.first;
}

void main() {
  group('discoverBackupDestinations', () {
    test('discovery with no providers lists only Choose folder', () async {
      final probe = FakeCloudFolderProbe();
      expect(await _discover(probe), [_choose()]);
      final choose = (await _discover(probe)).single;
      expect(choose.provider, isNull);
      expect(choose.path, isNull);
      expect(choose.label, 'choose folder…');
    });

    test(
      'discovery with iCloud only lists iCloud then Choose folder',
      () async {
        final probe = FakeCloudFolderProbe()..seedIcloud();
        expect(await _discover(probe), [
          BackupDestinationOption(
            provider: BackupProvider.icloud,
            label: 'iCloud Drive',
            path:
                '$fakeHome/Library/Mobile Documents/com~apple~CloudDocs/'
                'Open Memex Backups',
          ),
          _choose(),
        ]);
      },
    );

    test(
      'discovery lists iCloud then Google by account then OneDrive by name then Choose folder',
      () async {
        final probe = _fullProbe();
        expect(await _discover(probe), [
          BackupDestinationOption(
            provider: BackupProvider.icloud,
            label: 'iCloud Drive',
            path:
                '$fakeHome/Library/Mobile Documents/com~apple~CloudDocs/'
                '$_folderName',
          ),
          BackupDestinationOption(
            provider: BackupProvider.googleDrive,
            label: 'connor+tag@example.com',
            path:
                '$fakeHome/Library/CloudStorage/'
                'GoogleDrive-connor+tag@example.com/My Drive/$_folderName',
          ),
          BackupDestinationOption(
            provider: BackupProvider.googleDrive,
            label: 'zoe@example.com',
            path:
                '$fakeHome/Library/CloudStorage/GoogleDrive-zoe@example.com/'
                'My Drive/$_folderName',
          ),
          BackupDestinationOption(
            provider: BackupProvider.oneDrive,
            label: 'Personal',
            path:
                '$fakeHome/Library/CloudStorage/OneDrive-Personal/$_folderName',
          ),
          BackupDestinationOption(
            provider: BackupProvider.oneDrive,
            label: 'Work Org',
            path:
                '$fakeHome/Library/CloudStorage/OneDrive-Work Org/$_folderName',
          ),
          _choose(),
        ]);
      },
    );

    test(
      'discovery keeps each provider contiguous so the per provider index is stable',
      () async {
        final options = await _discover(_fullProbe());
        final providers = [for (final o in options) o.provider];
        expect(providers, [
          BackupProvider.icloud,
          BackupProvider.googleDrive,
          BackupProvider.googleDrive,
          BackupProvider.oneDrive,
          BackupProvider.oneDrive,
          null,
        ]);
      },
    );

    test(
      'discovery orders accounts and names by text whatever order they were found in',
      () async {
        final probe = FakeCloudFolderProbe()
          ..seedGoogleDrive('b@example.com')
          ..seedGoogleDrive('c@example.com')
          ..seedGoogleDrive('a@example.com')
          ..seedOneDrive('Beta')
          ..seedOneDrive('Gamma')
          ..seedOneDrive('Alpha');
        final labels = [for (final o in await _discover(probe)) o.label];
        expect(labels, [
          'a@example.com',
          'b@example.com',
          'c@example.com',
          'Alpha',
          'Beta',
          'Gamma',
          'choose folder…',
        ]);
      },
    );

    test(
      'a GoogleDrive account folder without My Drive is not listed',
      () async {
        final probe = FakeCloudFolderProbe()
          ..seedGoogleDrive('with@example.com')
          ..addDirectory(
            '$fakeHome/Library/CloudStorage/GoogleDrive-without@example.com',
          )
          ..addDirectory(
            '$fakeHome/Library/CloudStorage/GoogleDrive-other@example.com/'
            'Shared drives',
          )
          // My Drive as a plain file is not a folder either.
          ..addFile(
            '$fakeHome/Library/CloudStorage/GoogleDrive-file@example.com/'
            'My Drive',
          );
        final options = await _discover(probe);
        expect(
          [for (final o in options) o.label],
          ['with@example.com', 'choose folder…'],
        );
      },
    );

    test('a label keeps hyphens after the provider prefix', () async {
      final probe = FakeCloudFolderProbe()
        ..seedGoogleDrive('a-b@example.com')
        ..seedOneDrive('Work-Org-2');
      expect(
        [for (final o in await _discover(probe)) o.label],
        ['a-b@example.com', 'Work-Org-2', 'choose folder…'],
      );
    });

    test('discovery ignores entries that are not provider folders', () async {
      final probe = FakeCloudFolderProbe()
        ..seedOneDrive('Personal')
        ..addDirectory('$fakeHome/Library/CloudStorage/Dropbox')
        ..addDirectory('$fakeHome/Library/CloudStorage/OneDrive')
        ..addDirectory('$fakeHome/Library/CloudStorage/Box-Box')
        ..addDirectory('$fakeHome/Library/CloudStorage/GoogleDriveBackup')
        // A file named like a OneDrive folder is not a folder.
        ..addFile('$fakeHome/Library/CloudStorage/OneDrive-NotAFolder');
      final options = await _discover(probe);
      expect(
        [for (final o in options) o.label],
        ['Personal', 'choose folder…'],
      );
    });

    test('iCloud is not listed when its folder is a file', () async {
      final probe = FakeCloudFolderProbe()..addFile(_icloudPath(fakeHome));
      expect(
        [for (final o in await _discover(probe)) o.label],
        ['choose folder…'],
      );
    });

    test(
      'discovery follows a provider folder that is a symbolic link',
      () async {
        final probe = FakeCloudFolderProbe()
          ..addDirectory('/Volumes/Big Disk/Drive')
          ..addSymlink(
            '$fakeHome/Library/CloudStorage/GoogleDrive-link@example.com/'
                'My Drive',
            '/Volumes/Big Disk/Drive',
          );
        final options = await _discover(probe);
        expect(
          [for (final o in options) o.label],
          ['link@example.com', 'choose folder…'],
        );
        expect(
          options.first.path,
          '$fakeHome/Library/CloudStorage/GoogleDrive-link@example.com/'
          'My Drive/$_folderName',
        );
      },
    );

    test(
      'discovery uses the probe home and works with a space in it',
      () async {
        const home = '/Users/jane doe';
        final probe = _fullProbe(home: home);
        final options = await _discover(probe);
        expect(options.length, 6);
        expect(
          options.first.path,
          '$home/Library/Mobile Documents/com~apple~CloudDocs/$_folderName',
        );
        expect(probe.calls, isNotEmpty);
        expect(probe.calls.first, 'home');
        // Nothing is created or resolved just by looking.
        expect(
          probe.calls.where(
            (c) =>
                c.startsWith('createDirectory') ||
                c.startsWith('resolveSymbolicLinks'),
          ),
          isEmpty,
        );
        expect(probe.createdDirectories, isEmpty);
      },
    );

    test(
      'discovery treats a missing CloudStorage folder as no providers',
      () async {
        // Only iCloud is installed: there is no ~/Library/CloudStorage at all,
        // and listing it fails with a FileSystemException.
        final probe = FakeCloudFolderProbe()..seedIcloud();
        await expectLater(
          probe.listNames('$fakeHome/Library/CloudStorage'),
          throwsA(isA<FileSystemException>()),
        );
        final options = await _discover(probe);
        expect(
          [for (final o in options) o.provider],
          [BackupProvider.icloud, null],
        );
      },
    );
  });

  group('resolveBackupDestinationProvider', () {
    Future<BackupDestinationResolution> resolve(
      BackupHarness h,
      BackupDestinationOption option, {
      String? pickedFolder,
    }) => h
        .read(resolveBackupDestinationProvider)
        .resolve(option, pickedFolder: pickedFolder);

    /// Nothing was saved: the vault still reads the defaults and the settings
    /// hold no entry at all.
    void expectNothingSaved(BackupHarness h) {
      expect(
        h.read(vaultBackupSettingsProvider(_vault)),
        VaultBackupSettings(),
      );
      expect(h.read(settingsProvider).vaultBackups, isEmpty);
    }

    test(
      'picking a provider creates its Open Memex Backups folder once and resolves the path',
      () async {
        final probe = FakeCloudFolderProbe()
          ..seedGoogleDrive('a b@example.com');
        final h = await createBackupContainer(probe: probe);
        final option = await _firstProvider(probe);
        final folder =
            '${probe.googleDriveFolder('a b@example.com')}/$_folderName';
        expect(option.path, folder);

        final result = await resolve(h, option);

        expect(result, isA<BackupDestinationResolved>());
        expect((result as BackupDestinationResolved).path, folder);
        expect(probe.createdDirectories, [folder]);
        expect(await probe.isDirectory(folder), isTrue);
        // Resolving saves nothing: A4 saves, so a cancelled pick stores none.
        expectNothingSaved(h);
        expect(h.cli.calls, isEmpty);
      },
    );

    test(
      'the resolved provider path is stored through saveVaultBackupSettingsProvider and read back',
      () async {
        final probe = FakeCloudFolderProbe()..seedIcloud();
        final h = await createBackupContainer(probe: probe);
        final option = _icloud(probe);

        final result = await resolve(h, option);
        final path = (result as BackupDestinationResolved).path;
        expect(path, option.path);
        final before = h.read(vaultBackupSettingsProvider(_vault));
        await h.read(saveVaultBackupSettingsProvider)(
          _vault,
          before.copyWith(destination: path),
        );

        final stored = h.read(vaultBackupSettingsProvider(_vault));
        expect(stored, VaultBackupSettings(destination: option.path));
        expect(stored.enabled, isFalse);
        expect(stored.keep, 30);
        expect(stored.automatic, isTrue);
      },
    );

    test(
      'picking a provider whose folder exists does not create it again',
      () async {
        final probe = FakeCloudFolderProbe()..seedIcloud();
        final h = await createBackupContainer(probe: probe);
        final option = _icloud(probe);
        probe.addDirectory(option.path!);

        final result = await resolve(h, option);

        expect(result, isA<BackupDestinationResolved>());
        expect((result as BackupDestinationResolved).path, option.path);
        expect(
          probe.calls.where((c) => c.startsWith('createDirectory')),
          isEmpty,
        );
        expect(probe.createdDirectories, isEmpty);
      },
    );

    test(
      'picking the same provider twice creates the folder only once',
      () async {
        final probe = FakeCloudFolderProbe()..seedIcloud();
        final h = await createBackupContainer(probe: probe);
        final option = _icloud(probe);
        final first = await resolve(h, option);
        final second = await resolve(h, option);
        expect((first as BackupDestinationResolved).path, option.path);
        expect((second as BackupDestinationResolved).path, option.path);
        expect(probe.calls.where((c) => c.startsWith('createDirectory')), [
          'createDirectory ${option.path}',
        ]);
        expect(probe.createdDirectories, [option.path]);
      },
    );

    test(
      'picking a provider resolves symbolic links in the path it answers',
      () async {
        final probe = FakeCloudFolderProbe()
          ..addDirectory('/Volumes/Big Disk/Drive')
          ..addSymlink(
            '$fakeHome/Library/CloudStorage/GoogleDrive-link@example.com/'
                'My Drive',
            '/Volumes/Big Disk/Drive',
          );
        final h = await createBackupContainer(probe: probe);
        final option = await _firstProvider(probe);

        final result = await resolve(h, option);

        const resolved = '/Volumes/Big Disk/Drive/$_folderName';
        expect((result as BackupDestinationResolved).path, resolved);
        expect(probe.createdDirectories, [resolved]);
      },
    );

    test(
      'a failed folder creation gives backup_destination_unavailable and saves nothing',
      () async {
        final probe = FakeCloudFolderProbe()..seedGoogleDrive('a@example.com');
        final option = await _firstProvider(probe);
        probe.denyCreate(option.path!);
        final h = await createBackupContainer(probe: probe);

        final result = await resolve(h, option);

        expect(result, isA<BackupDestinationUnavailable>());
        final unavailable = result as BackupDestinationUnavailable;
        expect(unavailable.code, 'backup_destination_unavailable');
        expect(unavailable.code, backupDestinationUnavailableCode);
        expect(unavailable.message, isNotEmpty);
        expect(probe.createdDirectories, isEmpty);
        expectNothingSaved(h);
      },
    );

    test(
      'a failed folder creation leaves the destination the vault already had',
      () async {
        final probe = FakeCloudFolderProbe()..seedIcloud();
        final option = _icloud(probe);
        probe.denyCreate(option.path!);
        final h = await createBackupContainer(probe: probe);
        final before = VaultBackupSettings(
          enabled: true,
          destination: '/Volumes/NAS share/Open Memex Backups',
          keep: 12,
          automatic: false,
        );
        await h.read(saveVaultBackupSettingsProvider)(_vault, before);

        final result = await resolve(h, option);

        expect(result, isA<BackupDestinationUnavailable>());
        expect(h.read(vaultBackupSettingsProvider(_vault)), before);
      },
    );

    test(
      'a file in the way of the new destination gives backup_destination_unavailable',
      () async {
        final probe = FakeCloudFolderProbe()..seedIcloud();
        final option = _icloud(probe);
        probe.addFile(option.path!);
        final h = await createBackupContainer(probe: probe);

        final result = await resolve(h, option);

        expect(
          result,
          isA<BackupDestinationUnavailable>().having(
            (r) => r.code,
            'code',
            'backup_destination_unavailable',
          ),
        );
      },
    );

    test(
      'a provider folder that cannot be resolved after creation gives backup_destination_unavailable',
      () async {
        final probe = _Wi323ResolveFailsProbe()..seedIcloud();
        final h = await createBackupContainer(probe: probe);

        final result = await resolve(h, _icloud(probe));

        expect(
          result,
          isA<BackupDestinationUnavailable>().having(
            (r) => r.code,
            'code',
            'backup_destination_unavailable',
          ),
        );
        expectNothingSaved(h);
      },
    );

    test(
      'Choose folder resolves the picked folder with nothing appended',
      () async {
        final probe = FakeCloudFolderProbe()
          ..addDirectory('/Volumes/NAS share')
          ..addSymlink('/Users/test/nas link', '/Volumes/NAS share');
        final h = await createBackupContainer(probe: probe);

        final result = await resolve(
          h,
          _choose(),
          pickedFolder: '/Users/test/nas link',
        );

        expect(result, isA<BackupDestinationResolved>());
        expect(
          (result as BackupDestinationResolved).path,
          '/Volumes/NAS share',
        );
        // Nothing was created, and nothing was appended.
        expect(probe.createdDirectories, isEmpty);
        expect(
          probe.calls.where((c) => c.startsWith('createDirectory')),
          isEmpty,
        );
        expect(await probe.listNames('/Volumes/NAS share'), isEmpty);
        expectNothingSaved(h);
      },
    );

    test(
      'Choose folder stores the picked folder resolved through saveVaultBackupSettingsProvider',
      () async {
        final probe = FakeCloudFolderProbe()
          ..addDirectory('/Volumes/NAS share')
          ..addSymlink('/Users/test/nas link', '/Volumes/NAS share');
        final h = await createBackupContainer(probe: probe);

        final result = await resolve(
          h,
          _choose(),
          pickedFolder: '/Users/test/nas link',
        );
        final path = (result as BackupDestinationResolved).path;
        await h.read(saveVaultBackupSettingsProvider)(
          _vault,
          h
              .read(vaultBackupSettingsProvider(_vault))
              .copyWith(destination: path),
        );

        expect(
          h.read(vaultBackupSettingsProvider(_vault)).destination,
          '/Volumes/NAS share',
        );
      },
    );

    test(
      'Choose folder keeps a picked folder that has no symbolic link as it is',
      () async {
        final probe = FakeCloudFolderProbe()
          ..addDirectory('/Volumes/Big Disk/x y');
        final h = await createBackupContainer(probe: probe);
        final result = await resolve(
          h,
          _choose(),
          pickedFolder: '/Volumes/Big Disk/x y',
        );
        expect(
          (result as BackupDestinationResolved).path,
          '/Volumes/Big Disk/x y',
        );
      },
    );

    test(
      'Choose folder with a folder that cannot be resolved gives backup_destination_unavailable',
      () async {
        final probe = FakeCloudFolderProbe();
        final h = await createBackupContainer(probe: probe);
        final result = await resolve(
          h,
          _choose(),
          pickedFolder: '/Volumes/Gone',
        );
        expect(
          result,
          isA<BackupDestinationUnavailable>().having(
            (r) => r.code,
            'code',
            'backup_destination_unavailable',
          ),
        );
        expect((result as BackupDestinationUnavailable).message, isNotEmpty);
        expectNothingSaved(h);
      },
    );

    test(
      'saving a resolved destination changes only that destination of that vault and deletes nothing',
      () async {
        final probe = FakeCloudFolderProbe()..seedIcloud();
        final h = await createBackupContainer(probe: probe);
        final mine = VaultBackupSettings(
          enabled: true,
          destination: '/Volumes/NAS share/Open Memex Backups',
          keep: 12,
          automatic: false,
        );
        final other = VaultBackupSettings(keep: 99, destination: '/other');
        await h.read(saveVaultBackupSettingsProvider)(_vault, mine);
        await h.read(saveVaultBackupSettingsProvider)('/other vault', other);
        probe.addDirectory('/Volumes/NAS share/Open Memex Backups');
        probe.addFile('/Volumes/NAS share/Open Memex Backups/x.memex.zip');

        final result = await resolve(h, _icloud(probe));
        await h.read(saveVaultBackupSettingsProvider)(
          _vault,
          mine.copyWith(
            destination: (result as BackupDestinationResolved).path,
          ),
        );

        final after = h.read(vaultBackupSettingsProvider(_vault));
        expect(after.destination, _icloud(probe).path);
        expect(after.enabled, isTrue);
        expect(after.keep, 12);
        expect(after.automatic, isFalse);
        expect(h.read(vaultBackupSettingsProvider('/other vault')), other);
        // Changing the destination runs no CLI call and deletes nothing.
        expect(h.cli.calls, isEmpty);
        expect(h.runner.calls, isEmpty);
        expect(await probe.listNames('/Volumes/NAS share/Open Memex Backups'), [
          'x.memex.zip',
        ]);
      },
    );
  });

  group('cloudFolderProbeProvider and IoCloudFolderProbe', () {
    late Directory root;

    setUp(() async {
      // A folder name with a space, `~` and `@`, as the real ones have.
      final base = await Directory.systemTemp.createTemp('probe');
      root = await Directory(p.join(base.path, 'My Drive~x@y')).create();
      addTearDown(() => base.delete(recursive: true));
    });

    test('IoCloudFolderProbe home is an absolute folder', () async {
      // The provider's default is the real probe.
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final probe = container.read(cloudFolderProbeProvider);
      expect(probe, isA<IoCloudFolderProbe>());
      final home = await probe.home();
      expect(home, isNotEmpty);
      expect(p.isAbsolute(home), isTrue);
      expect(home, Platform.environment['HOME'] ?? home);
    });

    test(
      'IoCloudFolderProbe isDirectory is true only for a folder or a link to one',
      () async {
        const probe = IoCloudFolderProbe();
        final dir = await Directory(p.join(root.path, 'a dir')).create();
        final file = await File(p.join(root.path, 'a file')).create();
        final link = await Link(p.join(root.path, 'a link')).create(dir.path);
        expect(await probe.isDirectory(dir.path), isTrue);
        expect(await probe.isDirectory(link.path), isTrue);
        expect(await probe.isDirectory(file.path), isFalse);
        expect(await probe.isDirectory(p.join(root.path, 'missing')), isFalse);
      },
    );

    test('IoCloudFolderProbe listNames returns names not paths', () async {
      const probe = IoCloudFolderProbe();
      await Directory(p.join(root.path, 'GoogleDrive-a@b.com')).create();
      await File(p.join(root.path, 'a file')).create();
      expect(
        await probe.listNames(root.path),
        unorderedEquals(['GoogleDrive-a@b.com', 'a file']),
      );
    });

    test(
      'IoCloudFolderProbe listNames fails with a FileSystemException for a missing folder or a file',
      () async {
        const probe = IoCloudFolderProbe();
        final file = await File(p.join(root.path, 'a file')).create();
        await expectLater(
          probe.listNames(p.join(root.path, 'missing')),
          throwsA(isA<FileSystemException>()),
        );
        await expectLater(
          probe.listNames(file.path),
          throwsA(isA<FileSystemException>()),
        );
      },
    );

    test(
      'IoCloudFolderProbe createDirectory makes parents and is idempotent',
      () async {
        const probe = IoCloudFolderProbe();
        final target = p.join(root.path, 'a b', 'c~d', _folderName);
        await probe.createDirectory(target);
        expect(Directory(target).existsSync(), isTrue);
        await probe.createDirectory(target);
        expect(Directory(target).existsSync(), isTrue);
      },
    );

    test(
      'IoCloudFolderProbe createDirectory fails with a FileSystemException when a file is in the way',
      () async {
        const probe = IoCloudFolderProbe();
        final file = await File(p.join(root.path, 'in the way')).create();
        await expectLater(
          probe.createDirectory(file.path),
          throwsA(isA<FileSystemException>()),
        );
        await expectLater(
          probe.createDirectory(p.join(file.path, 'below')),
          throwsA(isA<FileSystemException>()),
        );
      },
    );

    test(
      'IoCloudFolderProbe resolveSymbolicLinks resolves a link and fails for a missing path',
      () async {
        const probe = IoCloudFolderProbe();
        final dir = await Directory(p.join(root.path, 'real dir')).create();
        final link = await Link(p.join(root.path, 'link')).create(dir.path);
        expect(
          await probe.resolveSymbolicLinks(link.path),
          await dir.resolveSymbolicLinks(),
        );
        await expectLater(
          probe.resolveSymbolicLinks(p.join(root.path, 'missing')),
          throwsA(isA<FileSystemException>()),
        );
      },
    );
  });
}

/// The iCloud folder under [home] (the fake's layout).
String _icloudPath(String home) =>
    p.posix.join(home, 'Library', 'Mobile Documents', 'com~apple~CloudDocs');

/// A probe whose `resolveSymbolicLinks` always fails, for a path that was just
/// created (a folder removed or refused between the two calls).
class _Wi323ResolveFailsProbe extends FakeCloudFolderProbe {
  @override
  Future<String> resolveSymbolicLinks(String path) async =>
      throw FileSystemException('Cannot resolve', path);
}
