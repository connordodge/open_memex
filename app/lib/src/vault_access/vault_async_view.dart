import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../state/vault_access_state.dart';
import '../state/vault_state.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';
import 'vault_scoped.dart';

/// Key of the hosted first-load loading state (A12 `loader2` spinner plus a
/// centred fg2 "loading…" line).
const vaultAsyncLoadingKey = Key('vault-async-loading');

/// Renders an async vault read (D13, D14a, Req 33). [value] comes from a
/// reader provider that stamps each result with the vault it was loaded for
/// ([VaultScoped]); data stamped with a vault other than
/// `currentVaultProvider`'s counts as no data, so a vault switch never shows
/// the previous vault's rows.
///
/// - [value] has data for the current vault (first load done, or a reload
///   in progress): [builder] with that data. A same-vault reload keeps the
///   previous value on screen, with no spinner.
/// - No current-vault data yet on a local vault: [builder] with [empty], so
///   the reader shows today's empty state (no spinner).
/// - No current-vault data yet on a hosted vault (`vaultIsHostedProvider`):
///   the loading state, keyed [vaultAsyncLoadingKey], in place of the list
///   or body.
///
/// Load errors are not shown here; hosted errors surface through the
/// connection banners. A load error with no current-vault value renders
/// [empty] on either kind of vault, never the loading state.
class VaultAsyncView<T> extends ConsumerWidget {
  const VaultAsyncView({
    super.key,
    required this.value,
    required this.empty,
    required this.builder,
  });

  final AsyncValue<VaultScoped<T>> value;
  final T empty;
  final Widget Function(BuildContext context, T data) builder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = currentVaultData(value, ref.watch(currentVaultProvider));
    if (current != null) return builder(context, current.value);
    if (!value.hasError && ref.watch(vaultIsHostedProvider)) {
      return const _VaultLoading(key: vaultAsyncLoadingKey);
    }
    return builder(context, empty);
  }
}

/// The hosted first-load state (design pack 70): the A12 "opening" spinner
/// (Lucide `loader2`, 16 px, fg2, one turn a second) over a 13 px fg2
/// "loading…" line, centred both ways.
class _VaultLoading extends StatefulWidget {
  const _VaultLoading({super.key});

  @override
  State<_VaultLoading> createState() => _VaultLoadingState();
}

class _VaultLoadingState extends State<_VaultLoading>
    with SingleTickerProviderStateMixin {
  late final AnimationController _turn = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  )..repeat();

  @override
  void dispose() {
    _turn.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          RotationTransition(
            turns: _turn,
            child: const Icon(
              LucideIcons.loader2,
              size: 16,
              color: OmColors.fg2,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'loading…',
            textAlign: TextAlign.center,
            style: OmType.sans(size: 13, color: OmColors.fg2),
          ),
        ],
      ),
    );
  }
}
