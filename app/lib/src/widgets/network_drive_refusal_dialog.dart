import 'package:flutter/widgets.dart';

/// What the person chose in the network-drive refusal (board A9 state 1).
/// #105 binds [setUpServer] and [connectServer] to the set-up sheet and the
/// connect dialog; until then they only close the dialog.
enum NetworkDriveRefusalChoice { cancel, setUpServer, connectServer }

/// Shows the network-drive refusal for the folder at [path] under [eyebrow]
/// ("OPEN LOCAL VAULT", or "CREATE NEW VAULT" in the create flow) and
/// completes with the choice that closed it.
Future<NetworkDriveRefusalChoice?> showNetworkDriveRefusalDialog(
  BuildContext context, {
  required String path,
  required String eyebrow,
}) async {
  throw UnimplementedError('#92: network-drive refusal');
}
