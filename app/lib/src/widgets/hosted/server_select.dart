import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

/// The HTTP client the open and create "on a server" dialogs send their
/// `HostedClient` requests with. Tests override it with a fake vault
/// server's client.
final serverDialogHttpClientProvider = Provider<http.Client>(
  (ref) => throw UnimplementedError(),
);
