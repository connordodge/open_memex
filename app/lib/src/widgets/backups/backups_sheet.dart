// WI #321 (A0, D19): the Backups sheet's entry point. The signature is
// frozen; the body is the stub A4 (#325) replaces.
import 'package:flutter/widgets.dart';

import '../../state/vault_ref.dart';

/// Opens the Backups sheet for [vault] (the setup-sheet pattern: a 620-wide
/// panel). Completes when the sheet closes. Stub: completes at once.
Future<void> showBackupsSheet(BuildContext context, VaultRef vault) async {}
