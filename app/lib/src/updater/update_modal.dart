import 'package:flutter/widgets.dart';

import '../widgets/hosted/leave_confirm_dialog.dart' show ProviderReader;

// Stub (A0 #32): the signature is frozen (D17). A4 #38 fills it.

/// Opens the update modal over [context] at the controller's current state,
/// reading providers through [read]. A request while the modal is already
/// open opens no second one (req 18).
Future<void> openUpdateModal(BuildContext context, ProviderReader read) async {}
