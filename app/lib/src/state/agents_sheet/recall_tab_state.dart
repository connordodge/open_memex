// The Semantic recall tab's state (WI #413; Spec #394 req 9, 13, 36, 43;
// D5a, D14, D31).
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../agents_sheet/recall/embeddings_status.dart';
import '../../cli/embeddings_cli.dart';
import '../../vault_access/agents_access.dart';
import '../../vault_access/errors.dart';
import '../../vault_access/hosted/embeddings.dart';
import '../agent_activity.dart';
import '../clock.dart';
import '../settings.dart';
import '../vault_state.dart';
import 'agents_sheet_state.dart';

/// How often the shown tab re-reads, and the least time between two reads
/// a revision change may start (Spec #394 req 13, D5a).
const recallReadInterval = Duration(seconds: 10);

/// The open sheet's embeddings status read: null until the first read
/// answers (and while a Retry runs), then the last answer.
///
/// Sheet-scoped (auto-dispose). It reads only while the Semantic recall tab
/// is shown (`agentsSheetTabProvider` is [AgentsTab.recall]): once when it is
/// shown; then on a [recallReadInterval] tick counted from the last read's
/// start, and on a `vaultRevisionProvider` change when that long has passed
/// since the last read started (sooner changes, even during a read, are left
/// to the tick). A read in flight is never stacked: a tick, a re-show, or a
/// change that late during it gives exactly one follow-up read after it. Hiding the tab stops the tick and drops a pending
/// follow-up; showing it again reads again. A tick re-read keeps the last
/// answer until the new one lands. Local vaults read through `EmbeddingsCli`,
/// hosted ones through `hostedEmbeddingsApiProvider`; a thrown read is an
/// [EmbeddingsStatusError]. Time and timers come from `clockProvider`.
final recallStatusProvider =
    AutoDisposeNotifierProvider<RecallStatusNotifier, EmbeddingsStatusResult?>(
      RecallStatusNotifier.new,
    );

class RecallStatusNotifier
    extends AutoDisposeNotifier<EmbeddingsStatusResult?> {
  // Bumped by every build: a read started by an earlier build drops its
  // answer.
  int _generation = 0;
  bool _disposed = false;
  bool _shown = false;
  bool _inFlight = false;
  bool _followUp = false;
  DateTime? _lastStart;
  Timer? _tick;

  @override
  EmbeddingsStatusResult? build() {
    _generation++;
    _disposed = false;
    _shown = false;
    _inFlight = false;
    _followUp = false;
    _lastStart = null;
    _tick = null;
    ref.onDispose(() {
      _disposed = true;
      _tick?.cancel();
      _tick = null;
    });
    // A located binary or a switched vault reads again.
    ref.watch(settingsProvider.select((s) => s.memexBinaryPath));
    final vault = ref.watch(currentVaultProvider);
    if (vault is HostedVaultRef) ref.watch(hostedEmbeddingsApiProvider);
    ref.listen<AgentsTab>(
      agentsSheetTabProvider,
      (_, tab) => _setShown(tab == AgentsTab.recall),
    );
    ref.listen<int>(vaultRevisionProvider, (_, _) => _onRevision());
    _setShown(ref.read(agentsSheetTabProvider) == AgentsTab.recall);
    return null;
  }

  /// Reads again now (the state is null meanwhile): the error's Retry. Does
  /// nothing while a read is in flight, so two presses in one frame run one
  /// read.
  void retry() {
    if (_inFlight || !_shown) return;
    state = null;
    _read();
  }

  void _setShown(bool shown) {
    if (shown == _shown) return;
    _shown = shown;
    if (!shown) {
      _tick?.cancel();
      _tick = null;
      _followUp = false;
      return;
    }
    _request();
  }

  /// A revision change reads (or, during a read, queues one follow-up) only
  /// when [recallReadInterval] has passed since the last read started. A
  /// sooner change, in flight or not, is left to the tick armed at that
  /// start, so changes never start reads less than 10 s apart.
  void _onRevision() {
    if (!_shown) return;
    final last = _lastStart;
    final now = ref.read(clockProvider).now();
    if (last != null && now.difference(last) < recallReadInterval) return;
    _request();
  }

  void _onTick() {
    _tick = null;
    _request();
  }

  /// Reads now, or once after the read in flight.
  void _request() {
    if (!_shown) return;
    if (_inFlight) {
      _followUp = true;
      return;
    }
    _read();
  }

  void _read() {
    final generation = _generation;
    final clock = ref.read(clockProvider);
    _inFlight = true;
    _followUp = false;
    _lastStart = clock.now();
    _tick?.cancel();
    _tick = clock.after(recallReadInterval, _onTick);
    unawaited(
      _fetch().then((result) {
        if (_disposed || generation != _generation) return;
        _inFlight = false;
        state = result;
        if (_followUp && _shown) _read();
        _followUp = false;
      }),
    );
  }

  Future<EmbeddingsStatusResult> _fetch() async {
    try {
      final vault = ref.read(currentVaultProvider);
      switch (vault) {
        case HostedVaultRef():
          final api = ref.read(hostedEmbeddingsApiProvider);
          if (api == null) {
            // Not const: each read's error is a new instance, so a
            // dismissed one never hides the next read's (identity check).
            return EmbeddingsStatusError(
              'The vault server is not connected. Try again.',
            );
          }
          return await api.status();
        case LocalVaultRef(:final path):
          return await EmbeddingsCli(
            ref.read(memexCliProvider),
          ).status(vaultPath: path);
        case null:
          return EmbeddingsStatusError('No vault is open.');
      }
    } on VaultUnreachableException catch (e) {
      return EmbeddingsStatusError(
        "Couldn't reach ${e.serverName}. Try again.",
      );
    } on Object catch (e) {
      return EmbeddingsStatusError('$e');
    }
  }
}

/// The connected agents of a local vault for the Semantic recall tab, or
/// null while #390's activity is loading or unknown (D14, D31: branch on
/// `isLoading`, never render from the value alone). An empty list is
/// "no agent connected".
List<AgentPresence>? recallConnectedAgents(
  AsyncValue<AgentActivityView> activity,
) {
  if (activity.isLoading || activity.hasError) return null;
  final view = activity.valueOrNull;
  if (view == null || !view.available) return null;
  return [for (final a in view.connected) a.presence];
}

/// Whether a local vault's agents use semantic recall: true when a
/// connected agent reports `embeddings: true`, false when agents are
/// connected and none does, null when none is connected or activity is
/// unknown.
bool? recallAgentsUseIt(List<AgentPresence>? agents) {
  if (agents == null || agents.isEmpty) return null;
  return agents.any((a) => a.embeddings);
}

/// The Semantic recall tab chip's 6 px dot (Spec #394 req 9): true draws it
/// in accent (on), false in fg2 (off), null draws none (unknown).
///
/// Local: from the connected agents ([recallAgentsUseIt]); it never reads
/// the embeddings status. Hosted: `server_embeddings` of the last answered
/// read ([recallStatusProvider]), null before the first answer, on an older
/// server and on an error; it keeps the last answer after the tab is left.
final recallTabDotProvider = Provider.autoDispose<bool?>((ref) {
  final vault = ref.watch(currentVaultProvider);
  if (vault is HostedVaultRef) {
    final result = ref.watch(recallStatusProvider);
    return result is EmbeddingsStatusOk
        ? result.status.serverEmbeddings == true
        : null;
  }
  return recallAgentsUseIt(
    recallConnectedAgents(ref.watch(agentActivityAsyncProvider)),
  );
});
