import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/picker_actions.dart';
import '../../state/settings.dart';
import '../../state/vault_open_controller.dart';
import 'connect_server_dialog.dart';
import 'create_on_server_dialog.dart';
import 'open_on_server_dialog.dart';
import 'setup_sheet.dart';

/// The app's picker actions (#105): the seam #97 left, bound to #98's
/// connect and edit-server dialogs, #99's open and create on a server
/// dialogs and #100's set-up sheet. The app root installs it
/// (`appRootOverrides` in main.dart).
class AppPickerActions extends PickerActions {
  const AppPickerActions();

  /// The connect dialog. Its "how do I set one up?" opens the set-up sheet
  /// over it; the sheet's "connect to a vault server…" closes the sheet,
  /// which is back on this dialog.
  @override
  Future<SavedServer?> connect(BuildContext context) => showConnectServerDialog(
    context,
    onSetUp: () => showSetUpVaultServerSheet(context),
  );

  /// The edit-server dialog for the saved server [serverId]; nothing when
  /// no saved server has that id. A save hands the new access token to the
  /// open hosted vault on that server (`serverTokenChanged`).
  @override
  Future<void> editServer(BuildContext context, String serverId) async {
    final container = ProviderScope.containerOf(context, listen: false);
    SavedServer? server;
    for (final s in container.read(settingsProvider).savedServers) {
      if (s.id == serverId) server = s;
    }
    if (server == null) return;
    final saved = await showConnectServerDialog(context, edit: server);
    if (saved == null) return;
    await container
        .read(vaultOpenControllerProvider)
        .serverTokenChanged(serverId);
  }

  /// "open vault on a server": its "connect to a vault server…" is
  /// [connect], its "update token" is [editServer].
  @override
  Future<void> openOnServer(BuildContext context) => showOpenOnServerDialog(
    context,
    onConnect: () => connect(context),
    onUpdateToken: (id) => editServer(context, id),
  );

  /// "create vault on a server": its "connect to a vault server…" is
  /// [connect], its "update token" is [editServer].
  @override
  Future<void> createOnServer(BuildContext context) => showCreateOnServerDialog(
    context,
    onConnect: () => connect(context),
    onUpdateToken: (id) => editServer(context, id),
  );

  /// The set-up sheet; its "connect to a vault server…" opens [connect].
  @override
  Future<void> setUp(BuildContext context) async {
    if (!await showSetUpVaultServerSheet(context)) return;
    if (context.mounted) await connect(context);
  }
}

/// Opens the edit-server dialog for [serverId] over whatever the app shows,
/// through [navigatorKey] (the update-token seams carry no BuildContext).
/// Does nothing while the app has no navigator.
void editServerFromAnywhere(
  GlobalKey<NavigatorState> navigatorKey,
  PickerActions actions,
  String serverId,
) {
  final context = navigatorKey.currentState?.overlay?.context;
  if (context == null) return;
  unawaited(actions.editServer(context, serverId));
}
