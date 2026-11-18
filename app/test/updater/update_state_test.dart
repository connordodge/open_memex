// WI #32 (Spec #31 req 15, TD3, D1): the update states and the error causes.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/updater/update_ports.dart';
import 'package:open_memex_app/src/updater/update_state.dart';

import '../support/updater_fakes.dart';

/// Req 15's error table: each cause and where **try again** goes.
const _tryAgain = {
  UpdateErrorCause.offline: UpdateRetryTarget.checking,
  UpdateErrorCause.feedUnreadable: UpdateRetryTarget.checking,
  UpdateErrorCause.noAppcast: UpdateRetryTarget.checking,
  UpdateErrorCause.failureRecorded: UpdateRetryTarget.checking,
  UpdateErrorCause.badSignature: UpdateRetryTarget.downloading,
  UpdateErrorCause.noSignature: UpdateRetryTarget.downloading,
  UpdateErrorCause.downloadFailed: UpdateRetryTarget.downloading,
  UpdateErrorCause.noPublicKey: UpdateRetryTarget.none,
  UpdateErrorCause.folderNotWritable: UpdateRetryTarget.none,
  UpdateErrorCause.diskImage: UpdateRetryTarget.none,
};

String _describe(UpdateState state) => switch (state) {
  UpdateIdle() => 'idle',
  UpdateChecking() => 'checking',
  UpdateUpToDate() => 'up to date',
  UpdateAvailable(:final item) => 'available ${item.shortVersionString}',
  UpdateDownloading(:final item, :final progress) =>
    'downloading ${item.shortVersionString} $progress',
  UpdateVerifying(:final item) => 'verifying ${item.shortVersionString}',
  UpdateReady(:final item, :final dmgPath) =>
    'ready ${item.shortVersionString} $dmgPath',
  UpdateError(:final cause) => 'error ${cause.name}',
};

void main() {
  test(
    'UpdateErrorCause has one value per req 15 cause with its try again target',
    () {
      expect(UpdateErrorCause.values, hasLength(10));
      expect(UpdateErrorCause.values.toSet(), _tryAgain.keys.toSet());
      for (final cause in UpdateErrorCause.values) {
        expect(cause.tryAgain, _tryAgain[cause], reason: cause.name);
      }
    },
  );

  test(
    'only the offline, feed unreadable and no Appcast causes are check failures',
    () {
      const check = {
        UpdateErrorCause.offline,
        UpdateErrorCause.feedUnreadable,
        UpdateErrorCause.noAppcast,
      };
      for (final cause in UpdateErrorCause.values) {
        expect(cause.isCheckFailure, check.contains(cause), reason: cause.name);
      }
    },
  );

  test(
    'only the no public key and folder not writable causes offer download from GitHub',
    () {
      const github = {
        UpdateErrorCause.noPublicKey,
        UpdateErrorCause.folderNotWritable,
      };
      for (final cause in UpdateErrorCause.values) {
        expect(
          cause.offersGitHubDownload,
          github.contains(cause),
          reason: cause.name,
        );
      }
    },
  );

  test('every update state keeps the values it was built with', () {
    final version = ['1', '3', '0'].join('.');
    final item = testAppcastItem(shortVersionString: version);
    final progress = 3 / 4;
    final dmg = '/updater-test/${DateTime(2026).year}.dmg';

    final states = <UpdateState>[
      const UpdateIdle(),
      const UpdateChecking(),
      const UpdateUpToDate(),
      UpdateAvailable(item),
      UpdateDownloading(item, progress: progress),
      UpdateDownloading(item),
      UpdateVerifying(item),
      UpdateReady(item, dmgPath: dmg),
      UpdateError(
        UpdateErrorCause.values[UpdateErrorCause.values.length - 3],
        item: item,
        folder: '/Applications',
      ),
    ];

    expect(states.map(_describe), [
      'idle',
      'checking',
      'up to date',
      'available 1.3.0',
      'downloading 1.3.0 0.75',
      'downloading 1.3.0 null',
      'verifying 1.3.0',
      'ready 1.3.0 /updater-test/2026.dmg',
      'error folderNotWritable',
    ]);

    final error = states.last as UpdateError;
    expect(error.item, same(item));
    expect(error.folder, '/Applications');
    expect(error.reason, isNull);
    final recorded = UpdateError(
      UpdateErrorCause.failureRecorded,
      reason: ['the new app', 'couldn', 't be copied'].join(),
    );
    expect(recorded.reason, 'the new appcouldnt be copied');
    expect(recorded.item, isNull);
    expect(recorded.folder, isNull);
  });

  test('UpdateFailure carries its cause, folder and reason', () {
    final folder = ['', 'Applications'].join('/');
    final failure = UpdateFailure(
      UpdateErrorCause.folderNotWritable,
      folder: folder,
    );
    expect(failure, isA<Exception>());
    expect(failure.cause, UpdateErrorCause.folderNotWritable);
    expect(failure.folder, '/Applications');
    expect(failure.reason, isNull);

    final recorded = UpdateFailure(
      UpdateErrorCause.failureRecorded,
      reason: 'x' * 3,
    );
    expect(recorded.reason, 'xxx');
    expect(recorded.folder, isNull);
  });
}
