// WI #321 (A0, D19): the stub A3 (#324) fills. A3 replaces it and deletes
// this whole file (a TEST-CHANGE in its PR). One file per filler, so no two
// fillers edit the same file or its imports.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/backup_controller.dart';
import 'package:open_memex_app/src/state/backup_models.dart';
import 'package:open_memex_app/src/state/vault_ref.dart';

import '../support/backup_harness.dart';

void main() {
  group('stubs filled by A3 (#324)', () {
    test('LiveBackupController stub reads off and starts nothing', () async {
      final h = await createBackupContainer();
      final controller = h.read(backupControllerProvider.notifier);
      expect(controller, isA<LiveBackupController>());
      const local = LocalVaultRef('/v');
      const hosted = HostedVaultRef('s1', 'seed');
      expect(controller.viewStateOf(local).mode, BackupSheetMode.off);
      await controller.backUpNow(local);
      await controller.backUpNow(hosted);
      controller.openSheet(local);
      controller.closeSheet(local);
      expect(h.runner.calls, isEmpty);
      expect(h.hostedApi.calls, isEmpty);
      expect(h.read(backupInFlightProvider), isEmpty);
      expect(h.read(backupControllerProvider), isEmpty);
    });
  });
}
