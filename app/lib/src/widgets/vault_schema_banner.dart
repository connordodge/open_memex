import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/vault_state.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';

/// Copy of the outdated-vault banner (WI #18, AC13).
const vaultSchemaOutdatedMessage =
    'This vault needs a newer memex. Update the memex binary, then reopen the vault.';

/// Inline banner shown when the open vault is still below schema V5 after the
/// open call (no `memex` binary configured, or one too old to migrate it).
/// Renders nothing otherwise, including while the open call runs.
class VaultSchemaBanner extends ConsumerWidget {
  const VaultSchemaBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final outdated =
        ref.watch(vaultOpenProvider).valueOrNull?.schemaOutdated ?? false;
    if (!outdated) return const SizedBox.shrink();
    return Container(
      key: const Key('vault-schema-outdated'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: OmColors.warnBg,
        border: Border(bottom: BorderSide(color: OmColors.line1, width: 1)),
      ),
      child: Text(
        vaultSchemaOutdatedMessage,
        style: OmType.sans(size: 12, color: OmColors.warn),
      ),
    );
  }
}
