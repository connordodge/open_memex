import 'package:flutter/widgets.dart';

import 'vault_ref.dart';

/// What opening or creating a vault gave (D12). Data only; #92 and #96 add
/// their own variants.
sealed class VaultOpenOutcome {
  const VaultOpenOutcome();
}

/// The vault is open: `currentVaultProvider` holds [vault].
final class VaultOpened extends VaultOpenOutcome {
  const VaultOpened(this.vault);

  final VaultRef vault;
}

/// Opening or creating failed and nothing changed. [message] is the copy the
/// person sees.
class VaultOpenFailure extends VaultOpenOutcome {
  const VaultOpenFailure(this.message);

  final String message;
}

/// Asked before the current vault is left (switch vault, a vault pill).
/// Completes true to go ahead, false to stay.
typedef LeaveVaultGuard = Future<bool> Function(BuildContext context);
