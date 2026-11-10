// WI #321 (A0, D19, D20): the `memex backup` / `memex restore` runner seam.
// The interface and the provider are frozen; `CliBackupRunner`'s body and the
// provider's wiring are the stubs A1 (#322) replaces.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../memex_cli.dart';
import '../state/backup_models.dart';

/// Runs `memex backup` and `memex restore` and classifies the outcome. Fakes
/// implement it (`FakeBackupRunner`). Methods take named, required
/// parameters and no defaults, so a fake sees every argument.
abstract class BackupRunner {
  /// `memex backup --vault <vaultPath> --dest <destination> --keep <keep>`,
  /// plus `--if-changed` when [ifChanged]. Never throws for a CLI failure or
  /// a spawn failure: those are results.
  Future<BackupRunResult> backup({
    required String vaultPath,
    required String destination,
    required int keep,
    required bool ifChanged,
  });

  /// `memex restore --from <from> --to <to>`. Never throws for a CLI failure
  /// or a spawn failure.
  Future<RestoreRunResult> restore({required String from, required String to});
}

/// [BackupRunner] over [MemexCli] (A1 fills it): always passes `--keep`;
/// exit 2 is "too old" whatever stderr says; a `ProcessException` is "binary
/// not found"; any other failure is the C1 code and raw C1 message. A null
/// [cli] (no `memex` configured) answers binary not found.
class CliBackupRunner implements BackupRunner {
  const CliBackupRunner(this.cli);

  final MemexCli? cli;

  // Stub: a sealed result has no neutral value.
  @override
  Future<BackupRunResult> backup({
    required String vaultPath,
    required String destination,
    required int keep,
    required bool ifChanged,
  }) => throw UnimplementedError('A1 (#322) fills CliBackupRunner.backup');

  @override
  Future<RestoreRunResult> restore({
    required String from,
    required String to,
  }) => throw UnimplementedError('A1 (#322) fills CliBackupRunner.restore');
}

/// The runner over the configured `memex` (`memexCliProvider`). Stub: A1
/// wires `CliBackupRunner(ref.watch(memexCliProvider))`.
final backupRunnerProvider = Provider<BackupRunner>(
  (ref) => const CliBackupRunner(null),
);
