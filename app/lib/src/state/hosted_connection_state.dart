import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A saved vault server's last connection outcome (D17, lead ruling on #77).
/// `HostedClient`'s response hook is the only writer.
enum HostedConnectionStatus {
  /// The server answered with anything but a 401, C1 errors included.
  connected,

  /// Connection refused, host lookup failed, network unreachable, no
  /// response within 10 s, or the connection dropped (req 50).
  unreachable,

  /// The server answered 401: the access token was rejected.
  tokenRejected,

  /// `probeServer()` found no memex vault server (notMemex) or an
  /// `api_version` this app can't use (apiMismatch).
  incompatible,
}

/// The connection status of each saved vault server, keyed by saved-server
/// id. Null until a request to that server has an outcome (the picker shows
/// "checking").
final hostedConnectionStatusProvider =
    StateProvider.family<HostedConnectionStatus?, String>((ref, serverId) {
      throw UnimplementedError();
    });

/// The caller's current UTC offset, read once per request so a DST change
/// between two requests changes the `X-Memex-UTC-Offset` header (req 59).
/// The default reads `clockProvider`'s `now().timeZoneOffset` on each call.
final utcOffsetProvider = Provider<Duration Function()>((ref) {
  throw UnimplementedError();
});
