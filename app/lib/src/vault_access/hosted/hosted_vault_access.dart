import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../vault_access.dart';
import 'hosted_client.dart';

/// The HTTP client every hosted vault request goes through (D17): a real
/// client, closed when the provider is disposed. Tests override it with a
/// fake vault server's client; no test reaches the network.
final hostedHttpClientProvider = Provider<http.Client>((ref) {
  final client = http.Client();
  ref.onDispose(client.close);
  return client;
});

/// The [VaultAccess] of one hosted vault (D13, D19): V1–V5's hosted domain
/// classes and #94's hosted revision, all over [client] for [vaultName].
/// `vaultAccessProvider` gives it for a `HostedVaultRef` and disposes it when
/// the open vault changes; a disposed composite sends no request.
class HostedVaultAccess implements VaultAccess {
  HostedVaultAccess({required HostedClient client, required String vaultName}) {
    throw UnimplementedError('#96');
  }

  @override
  NotesAccess get notes => throw UnimplementedError('#96');

  @override
  DailyAccess get daily => throw UnimplementedError('#96');

  @override
  TopicsAccess get topics => throw UnimplementedError('#96');

  @override
  CanvasAccess get canvas => throw UnimplementedError('#96');

  @override
  GraphAccess get graph => throw UnimplementedError('#96');

  @override
  Future<String> revision() => throw UnimplementedError('#96');

  @override
  Future<int> schemaVersion() => throw UnimplementedError('#96');

  @override
  bool get canWrite => throw UnimplementedError('#96');
}
