import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../agents_sheet/tools/tool_catalog.dart';
import '../../cli/tools_cli.dart';
import '../../vault_access/errors.dart';
import '../../vault_access/hosted/tools.dart';
import '../settings.dart';
import '../vault_state.dart';

/// The open sheet's tool list read (Spec #394 req 13; ruling L412-1).
///
/// Sheet-scoped: it loads once when the sheet opens (the shell watches
/// [toolsTabBadgeProvider], which watches this), is kept while the sheet is
/// open whichever tab shows, and reads again on the next open. It reads
/// through `ToolsCli` for a local vault and `hostedToolsApiProvider` for a
/// hosted one, chosen from `currentVaultProvider` (L412-2). Loading is
/// `AsyncLoading`; every outcome, a thrown read included (as a
/// [ToolCatalogError]), is data.
final toolsTabProvider =
    AutoDisposeAsyncNotifierProvider<ToolsTabNotifier, ToolCatalogResult>(
      ToolsTabNotifier.new,
    );

class ToolsTabNotifier extends AutoDisposeAsyncNotifier<ToolCatalogResult> {
  // Bumped by every build and every retry: a retry that finds it changed
  // (the sheet's inputs changed and rebuilt the read) or the notifier
  // disposed drops its answer.
  int _generation = 0;
  bool _disposed = false;

  @override
  Future<ToolCatalogResult> build() {
    _generation++;
    _disposed = false;
    ref.onDispose(() => _disposed = true);
    // A located binary or a switched vault reads again.
    ref.watch(settingsProvider.select((s) => s.memexBinaryPath));
    final vault = ref.watch(currentVaultProvider);
    if (vault is HostedVaultRef) ref.watch(hostedToolsApiProvider);
    return _read(vault);
  }

  /// Reads the list again (the state is loading meanwhile). Does nothing
  /// while a read is in flight, so two presses in one frame run one read.
  Future<void> retry() async {
    if (state.isLoading) return;
    final generation = ++_generation;
    state = const AsyncLoading();
    final result = await _read(ref.read(currentVaultProvider));
    if (_disposed || generation != _generation) return;
    state = AsyncData(result);
  }

  Future<ToolCatalogResult> _read(VaultRef? vault) async {
    try {
      if (vault is HostedVaultRef) {
        final api = ref.read(hostedToolsApiProvider);
        if (api == null) {
          return const ToolCatalogError(
            'The vault server is not connected. Try again.',
          );
        }
        return await api.list();
      }
      return await ToolsCli(ref.read(memexCliProvider)).list();
    } on VaultUnreachableException catch (e) {
      return ToolCatalogError("Couldn't reach ${e.serverName}. Try again.");
    } on Object catch (e) {
      return ToolCatalogError('$e');
    }
  }
}

/// The Tools tab chip's suffix, such as `37 tools`, or null for none
/// (Spec #394 req 9): `<n> tools` once the list has loaded, null while it
/// loads or when it is unavailable or errored.
final toolsTabBadgeProvider = Provider.autoDispose<String?>((ref) {
  final result = ref.watch(toolsTabProvider);
  if (result.isLoading) return null;
  final value = result.valueOrNull;
  if (value is! ToolCatalogOk) return null;
  return '${value.catalog.tools.length} tools';
});
