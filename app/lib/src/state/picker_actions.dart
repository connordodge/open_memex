import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'settings.dart';

/// The vault picker's hosted actions (WI #97): the dialogs and sheet other
/// WIs build (#98 connect/edit, #99 open/create on a server, #100 set-up).
/// The default does nothing; #105 binds it.
class PickerActions {
  const PickerActions();

  /// Opens the connect dialog. Completes with the saved server, or null when
  /// the person cancelled. The default saves nothing and completes null.
  Future<SavedServer?> connect(BuildContext context) =>
      throw UnimplementedError();

  /// Opens the edit dialog for the saved server [serverId] (also a recent
  /// row's "update token"). The default does nothing; #105 binds it to
  /// #98's `showConnectServerDialog(context, edit: server)`.
  Future<void> editServer(BuildContext context, String serverId) =>
      throw UnimplementedError();

  /// Opens the "open vault on a server" flow. The default does nothing.
  Future<void> openOnServer(BuildContext context) => throw UnimplementedError();

  /// Opens the "create vault on a server" flow. The default does nothing.
  Future<void> createOnServer(BuildContext context) =>
      throw UnimplementedError();

  /// Opens the "how do I set one up?" sheet. The default does nothing.
  Future<void> setUp(BuildContext context) => throw UnimplementedError();
}

/// The picker-actions seam. Tests override it with a recording fake.
final pickerActionsProvider = Provider<PickerActions>(
  (_) => const PickerActions(),
);
