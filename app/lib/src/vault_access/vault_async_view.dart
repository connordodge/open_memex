import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Key of the hosted first-load loading state (A12 `loader2` spinner plus a
/// centred fg2 "loading…" line).
const vaultAsyncLoadingKey = Key('vault-async-loading');

/// Renders an async vault read (D13, D14a, Req 33):
///
/// - [value] has data (first load done, or a reload in progress): [builder]
///   with that data. A reload keeps the previous value on screen, with no
///   spinner.
/// - No data yet on a local vault: [builder] with [empty], so the reader
///   shows today's empty state (no spinner).
/// - No data yet on a hosted vault (`vaultIsHostedProvider`): the loading
///   state, keyed [vaultAsyncLoadingKey], in place of the list or body.
///
/// Load errors are not shown here; hosted errors surface through the
/// connection banners.
class VaultAsyncView<T> extends ConsumerWidget {
  const VaultAsyncView({
    super.key,
    required this.value,
    required this.empty,
    required this.builder,
  });

  final AsyncValue<T> value;
  final T empty;
  final Widget Function(BuildContext context, T data) builder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // RED SKELETON (#70 test author): placeholder; the implementer writes it.
    return const SizedBox.shrink();
  }
}
