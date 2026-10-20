import '../../memex_cli.dart';

/// The CLI a local write runs through. With no `memex` CLI configured
/// (`VaultAccess.canWrite` false) it throws [StateError] before anything
/// runs.
MemexCli requireLocalCli(MemexCli? cli) {
  if (cli == null) {
    throw StateError('The memex CLI is not available.');
  }
  return cli;
}
