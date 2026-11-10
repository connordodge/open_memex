import 'package:flutter/widgets.dart';

/// The vault picker's content (Spec #357 TD1): the one body the full-screen
/// picker (`VaultPickerScreen`) and the vault picker modal both show. It
/// reads `currentVaultProvider`; with no vault open it is the full-screen
/// picker of before.
///
/// Skeleton (#362 red): draws nothing yet.
class VaultPickerBody extends StatelessWidget {
  const VaultPickerBody({super.key});

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
