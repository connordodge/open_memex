import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../state/settings.dart';

/// The HTTP client the connect and edit-server dialogs probe a vault server
/// with (through `HostedClient.probeServer`). Tests override it with
/// `FakeVaultServer.client`.
final connectServerHttpClientProvider = Provider<http.Client>((ref) {
  final client = http.Client();
  ref.onDispose(client.close);
  return client;
});

/// Shows "connect to a vault server" (boards A4/A5), or the edit-server
/// dialog for [edit] (A5 state 6). Returns the saved server, or null when
/// the dialog was cancelled. "how do I set one up?" calls [onSetUp].
Future<SavedServer?> showConnectServerDialog(
  BuildContext context, {
  SavedServer? edit,
  VoidCallback? onSetUp,
}) => throw UnimplementedError();
