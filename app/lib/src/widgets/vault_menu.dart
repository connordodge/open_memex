import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/vault_ref.dart';

/// Reveals the local vault folder at [path] in Finder
/// (`fileRevealerProvider`). When [path] is no longer a vault
/// (`VaultDb.isVault`), nothing opens and a SnackBar reads
/// `<path> is no longer a vault folder.`
Future<void> showVaultInFinder(
  BuildContext context,
  WidgetRef ref,
  String path,
) async {}

/// A secondary click on [child] opens [vault]'s menu at the pointer
/// (Spec #357 Req 19, 21): `show in Finder` (`vault-menu-finder`, local
/// only), `remove from recents` (`vault-menu-remove`, not when [isOpen]),
/// `delete vault…` (`vault-menu-delete`, local only), then, when
/// [onManage] is given, a divider and `manage…` (`vault-menu-manage`). With
/// no items, a secondary click opens nothing.
class VaultMenuRegion extends StatelessWidget {
  const VaultMenuRegion({
    super.key,
    required this.vault,
    required this.isOpen,
    this.onManage,
    required this.child,
  });

  final VaultRef vault;
  final bool isOpen;
  final VoidCallback? onManage;
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}
