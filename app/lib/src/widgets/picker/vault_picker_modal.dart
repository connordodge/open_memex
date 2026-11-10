import 'package:flutter/widgets.dart';

/// Shows the vault picker as a centred modal over the open vault (Spec #357
/// Req 5, 6, 6a, design A1/A2): the picker body in a dialog keyed
/// `vault-picker-modal`, with the header's `esc` hint and the × close button
/// (`vault-picker-modal-close`). Esc, × and a scrim click close it with
/// nothing changed, and it closes whenever `currentVaultProvider` changes
/// while it shows. Completes when it has closed.
///
/// Skeleton (#362 red): shows nothing yet.
Future<void> showVaultPickerModal(BuildContext context) => Future.value();
