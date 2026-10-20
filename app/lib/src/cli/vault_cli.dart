import '../memex_cli.dart';

/// What `memex vault check --vault <path>` found (D19, #75's exit-code
/// contract).
enum VaultCheckStatus {
  /// Exit 0: the folder is safe to open.
  safe,

  /// Exit 1 with the C1 code `network_filesystem`: the folder is on a
  /// network drive.
  networkFilesystem,

  /// Exit 2 (clap usage error): the installed `memex` predates `vault check`.
  memexTooOld,

  /// The `memex` binary could not be started (`ProcessException`).
  binaryNotFound,

  /// Any other failure.
  failed,
}

/// The result of [VaultCli.checkVault].
class VaultCheckResult {
  const VaultCheckResult(this.status, {this.error});

  final VaultCheckStatus status;

  /// For [VaultCheckStatus.failed]: the CLI failure, parsed once by
  /// [MemexException.fromCliFailure].
  final MemexException? error;
}

/// `memex vault check` wrapper (D19, D21).
extension VaultCli on MemexCli {
  /// Runs `memex vault check --vault <vaultPath>` and classifies the result.
  /// Never throws for a CLI failure or a spawn failure.
  Future<VaultCheckResult> checkVault(String vaultPath) async {
    throw UnimplementedError('#92: memex vault check');
  }
}
