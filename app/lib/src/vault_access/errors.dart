import 'package:flutter/material.dart';

/// A vault write or read that could not reach the vault server (Req 50, L17):
/// connection refused or no response within 10 s. Only the hosted
/// implementation throws it; local writes keep today's exceptions.
class VaultUnreachableException implements Exception {
  const VaultUnreachableException({
    required this.serverName,
    required this.mayHaveCommitted,
  });

  /// The saved vault server's name, as the snackbars show it (e.g. `nas`).
  final String serverName;

  /// True when the request timed out after it was sent, so the server may
  /// have committed the write; false when it was refused or never sent.
  final bool mayHaveCommitted;

  @override
  String toString() =>
      'VaultUnreachableException($serverName, '
      'mayHaveCommitted: $mayHaveCommitted)';
}

/// Runs [write] once and returns its result (Req 50, L17). Writes are never
/// queued or retried.
///
/// - [VaultUnreachableException] with `mayHaveCommitted: false` shows the
///   snackbar `couldn't reach <server>. try again.` and returns null.
/// - `mayHaveCommitted: true` shows
///   `couldn't confirm with <server> — check before trying again` and
///   returns null.
/// - Any other exception (e.g. `MemexException`) reaches the caller
///   unchanged, with no snackbar (Req 33).
///
/// The messenger is looked up from [context] before [write] runs.
Future<T?> guardVaultWrite<T>(
  BuildContext context,
  Future<T> Function() write,
) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    return await write();
  } on VaultUnreachableException catch (e) {
    messenger?.showSnackBar(
      SnackBar(
        content: Text(_unreachableMessage(e)),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      ),
    );
    return null;
  }
}

/// The L17 snackbar copy for [e] (Req 50): names only the server.
String _unreachableMessage(VaultUnreachableException e) => e.mayHaveCommitted
    ? "couldn't confirm with ${e.serverName} — check before trying again"
    : "couldn't reach ${e.serverName}. try again.";
