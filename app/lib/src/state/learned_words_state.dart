// WI #432 (Spec #392 req 13, 13b, 15, 18; D4, D5b, D24): the learned-words
// state behind E1's seam (`learned_words_seam.dart`).
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../memex_cli.dart';
import '../vault_access/errors.dart';
import '../vault_access/vault_scoped.dart';
import '../vault_access/words_access.dart';
import 'learned_words_seam.dart';
import 'spelling_service.dart';
import 'vault_access_state.dart';
import 'vault_state.dart';

/// The `word_key` of [word]: Dart `toLowerCase()`, as `learned_words` keys it.
String learnedWordKey(String word) => word.toLowerCase();

/// How many learned-word reads have started, in any container. Only its
/// order matters: a change recorded when it was `n` is superseded by a read
/// numbered above `n`, which started after the write had returned.
int _readsStarted = 0;

/// One `VaultAccess.words.list()` result and its start number.
class _WordsRead {
  const _WordsRead(this.number, this.words);

  final int number;
  final List<LearnedWord> words;
}

/// The open vault's learned words, read on vault open and again on every
/// `vaultRevisionProvider` change, stamped with the vault they were read for
/// (D14a). Empty with no vault access.
final _learnedWordsReadProvider = FutureProvider<VaultScoped<_WordsRead>>((
  ref,
) async {
  ref.watch(vaultRevisionProvider);
  final vault = ref.watch(currentVaultProvider);
  final access = ref.watch(vaultAccessProvider);
  final number = ++_readsStarted;
  if (access == null) return VaultScoped(vault, _WordsRead(number, const []));
  return VaultScoped(vault, _WordsRead(number, await access.words.list()));
});

/// A learn or unlearn that succeeded, and [_readsStarted] when it did.
class _Change {
  const _Change({required this.learned, required this.after});

  final bool learned;
  final int after;
}

/// This vault's successful learns and unlearns by `word_key`, applied on top
/// of the last read until a read that started after them lands (D5b). A
/// vault switch clears them.
class _LearnedWordChanges extends Notifier<Map<String, _Change>> {
  @override
  Map<String, _Change> build() {
    ref.watch(currentVaultProvider);
    return const {};
  }

  void record(String word, {required bool learned}) => state = {
    ...state,
    learnedWordKey(word): _Change(learned: learned, after: _readsStarted),
  };
}

final _learnedWordChangesProvider =
    NotifierProvider<_LearnedWordChanges, Map<String, _Change>>(
      _LearnedWordChanges.new,
    );

/// The last read of the current vault, or null when there is none yet (a
/// read left over from another vault is none).
_WordsRead? _currentRead(Ref ref) => currentVaultData(
  ref.watch(_learnedWordsReadProvider),
  ref.watch(currentVaultProvider),
)?.value;

/// The changes the last read [read] does not reflect yet.
Iterable<MapEntry<String, _Change>> _pending(Ref ref, _WordsRead? read) {
  final since = read?.number ?? 0;
  return ref
      .watch(_learnedWordChangesProvider)
      .entries
      .where((e) => e.value.after >= since);
}

/// `learnedWordKeysProvider`'s value: the `word_key` of every word of the
/// last read of the open vault, plus the keys learned and minus the keys
/// unlearned since it started. Empty with no vault, and never the previous
/// vault's keys while a switched-to vault's first read is pending.
final learnedWordKeysStateProvider = Provider<Set<String>>((ref) {
  final read = _currentRead(ref);
  final keys = {
    for (final w in read?.words ?? const []) learnedWordKey(w.word),
  };
  for (final MapEntry(:key, :value) in _pending(ref, read)) {
    value.learned ? keys.add(key) : keys.remove(key);
  }
  return keys;
});

/// The open vault's learned words as written, sorted by `word_key`: the last
/// read minus the words unlearned since it started. A word learned since
/// shows once the re-read its write bumped lands.
final learnedWordsProvider = Provider<List<LearnedWord>>((ref) {
  final read = _currentRead(ref);
  final unlearned = {
    for (final MapEntry(:key, :value) in _pending(ref, read))
      if (!value.learned) key,
  };
  return [
    for (final w in read?.words ?? const <LearnedWord>[])
      if (!unlearned.contains(learnedWordKey(w.word))) w,
  ]..sort((a, b) => learnedWordKey(a.word).compareTo(learnedWordKey(b.word)));
});

/// `learnedWordsActionsProvider`'s value (req 13b, 18).
///
/// [learn] writes the word to the vault first (`VaultAccess.words.learn`).
/// On success, `changed: false` included (the word may have come from
/// another Mac), it adds the key at once, calls `SpellingService.learn` and
/// returns true. On any failure it returns false with no native call and no
/// key, and [lastError] says why. [unlearn] mirrors it with
/// `SpellingService.unlearn`, removing the key.
///
/// Every write that ran bumps `vaultRevisionProvider` exactly once when it
/// returns, failed or not. With no vault open or `canWrite` false no write
/// runs and nothing is bumped.
class LearnedWordsState implements LearnedWordsActions {
  LearnedWordsState(this._ref);

  final Ref _ref;

  /// Why the last [learn] or [unlearn] returned false; null after a success.
  Object? lastError;

  /// [lastError]'s message, as the vault settings dialog shows it; null when
  /// there is none. A hosted outage reads as the L17 copy `guardVaultWrite`
  /// shows (Req 50): `couldn't reach <server>. try again.`, or
  /// `couldn't confirm with <server> — check before trying again` when the
  /// write may have committed.
  String? get lastErrorMessage => switch (lastError) {
    null => null,
    final MemexException e => e.message,
    final StateError e => e.message,
    // The same strings as errors.dart's `_unreachableMessage`.
    final VaultUnreachableException e =>
      e.mayHaveCommitted
          ? "couldn't confirm with ${e.serverName} — check before trying again"
          : "couldn't reach ${e.serverName}. try again.",
    final e => '$e',
  };

  @override
  Future<bool> learn(String word) => _write(word, learned: true);

  @override
  Future<bool> unlearn(String word) => _write(word, learned: false);

  Future<bool> _write(String word, {required bool learned}) async {
    final access = _ref.read(vaultAccessProvider);
    if (access == null) {
      lastError = StateError('No vault is open.');
      return false;
    }
    if (!access.canWrite) {
      lastError = StateError('The memex CLI is not available.');
      return false;
    }
    final vault = _ref.read(currentVaultProvider);
    try {
      try {
        if (learned) {
          await access.words.learn(word);
        } else {
          await access.words.unlearn(word);
        }
      } on Object catch (e) {
        lastError = e;
        return false;
      }
      lastError = null;
      if (_ref.read(currentVaultProvider) == vault) {
        _ref
            .read(_learnedWordChangesProvider.notifier)
            .record(word, learned: learned);
      }
      final spelling = _ref.read(spellingServiceProvider);
      if (learned) {
        await spelling.learn(word);
      } else {
        await spelling.unlearn(word);
      }
      return true;
    } finally {
      _ref.read(vaultRevisionProvider.notifier).state++;
    }
  }
}
