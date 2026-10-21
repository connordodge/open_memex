import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../state/hosted_connection_state.dart';
import '../state/hosted_identity.dart';
import '../state/vault_state.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';
import 'atoms.dart';

/// Copy of the outdated-vault banner (WI #18, AC13).
const vaultSchemaOutdatedMessage =
    'This vault needs a newer memex. Update the memex binary, then reopen the vault.';

/// The workspace's banner slot. For a local vault: an inline banner shown when
/// the open vault is still below schema V5 after the open call (no `memex`
/// binary configured, or one too old to migrate it), nothing otherwise,
/// including while the open call runs. For a hosted vault: one banner at a
/// time from its server's connection status (can't reach, token rejected) or
/// the vault being gone from the server (A11, Req 50, 52, 53a).
///
/// Also bumps `vaultRevisionProvider` once when the open hosted vault's
/// server goes from unreachable to connected, so views that could not load
/// read again.
class VaultSchemaBanner extends ConsumerWidget {
  const VaultSchemaBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vault = ref.watch(currentVaultProvider);
    if (vault is HostedVaultRef) return _hostedBanner(ref, vault);
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

  Widget _hostedBanner(WidgetRef ref, HostedVaultRef vault) {
    final serverId = vault.serverId;
    ref.listen(hostedConnectionStatusProvider(serverId), (previous, next) {
      if (previous == HostedConnectionStatus.unreachable &&
          next == HostedConnectionStatus.connected) {
        ref.read(vaultRevisionProvider.notifier).state++;
      }
    });
    final status = ref.watch(hostedConnectionStatusProvider(serverId));
    final server = ref.watch(hostedServerNameProvider(serverId));
    switch (status) {
      case HostedConnectionStatus.unreachable:
        return _HostedBanner(
          key: const Key('hosted-banner-unreachable'),
          warn: true,
          icon: LucideIcons.wifiOff,
          text: 'can\'t reach $server — retrying…',
          buttonKey: const Key('hosted-banner-retry'),
          buttonLabel: 'retry now',
          onButton: () {
            final client = ref.read(hostedClientForServerProvider(serverId));
            if (client != null) unawaited(client.probeServer());
          },
        );
      case HostedConnectionStatus.tokenRejected:
        return _HostedBanner(
          key: const Key('hosted-banner-unauthorized'),
          warn: false,
          icon: LucideIcons.keyRound,
          text: '$server rejected the access token',
          buttonKey: const Key('hosted-banner-update-token'),
          buttonLabel: 'update token',
          onButton: () => ref.read(hostedUpdateTokenProvider)(serverId),
        );
      case HostedConnectionStatus.connected ||
          HostedConnectionStatus.incompatible ||
          null:
        if (!ref.watch(hostedVaultGoneProvider(vault))) {
          return const SizedBox.shrink();
        }
        return _HostedBanner(
          key: const Key('hosted-banner-vault-gone'),
          warn: false,
          icon: LucideIcons.folderX,
          text: '${vault.vaultName} is no longer on $server',
        );
    }
  }
}

/// One hosted banner: 36 px (a 35 px row plus the 1 px bottom border), warn
/// or danger ink on its tinted fill, icon, one line of text, an optional
/// small button at the right.
class _HostedBanner extends StatelessWidget {
  const _HostedBanner({
    super.key,
    required this.warn,
    required this.icon,
    required this.text,
    this.buttonKey,
    this.buttonLabel,
    this.onButton,
  });

  final bool warn;
  final IconData icon;
  final String text;
  final Key? buttonKey;
  final String? buttonLabel;
  final VoidCallback? onButton;

  @override
  Widget build(BuildContext context) {
    final ink = warn ? OmColors.warn : OmColors.danger;
    return Container(
      height: 36,
      padding: const EdgeInsets.only(left: 12, right: 8),
      decoration: BoxDecoration(
        color: warn ? OmColors.warnBg : OmColors.dangerBg,
        border: Border(bottom: BorderSide(color: OmColors.line1, width: 1)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 14, color: ink),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: OmType.sans(size: 12, color: ink, height: 16.8 / 12),
            ),
          ),
          if (buttonLabel != null)
            OmButton(
              key: buttonKey,
              label: buttonLabel,
              kind: OmButtonKind.secondary,
              size: 24,
              dense: true,
              onPressed: onButton,
            ),
        ],
      ),
    );
  }
}
