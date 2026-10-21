import 'package:flutter_riverpod/flutter_riverpod.dart';

/// One read of the open vault's opaque revision (D9).
typedef RevisionReader = Future<String> Function();

/// The revision-reader seam (WI #79, D15): the open vault's
/// `VaultAccess.revision` (`vaultAccessProvider`), or null when there is no
/// vault access to poll. The revision poller reads only through it.
final revisionReaderProvider = Provider<RevisionReader?>(
  (ref) => throw UnimplementedError(),
);

/// The vault-wide revision poller (WI #79, D15). Watching it starts polling
/// the open vault's revision on `clockProvider`; `Workspace.build` watches
/// it first.
final revisionPollerProvider = Provider.autoDispose<void>(
  (ref) => throw UnimplementedError(),
);
