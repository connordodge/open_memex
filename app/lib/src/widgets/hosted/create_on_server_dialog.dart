import 'package:flutter/widgets.dart';

/// Shows "create vault on a server" (board A7). Starts on [serverId], or the
/// first saved server. "connect to a vault server…" calls [onConnect];
/// "update token" calls [onUpdateToken] with the server's id.
Future<void> showCreateOnServerDialog(
  BuildContext context, {
  String? serverId,
  VoidCallback? onConnect,
  void Function(String serverId)? onUpdateToken,
}) => throw UnimplementedError();
