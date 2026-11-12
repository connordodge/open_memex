// WI #434 (Spec #392): the learned-words seam W3 (#432) fills, so the editor
// WIs can be written against it first.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'learned_words_state.dart';

/// The vault's learned `word_key`s (Unicode lowercase). Filled by W3's
/// `learnedWordKeysStateProvider`: empty with no vault open.
final learnedWordKeysProvider = Provider<Set<String>>(
  (ref) => ref.watch(learnedWordKeysStateProvider),
);

/// Learn and unlearn a word. True means the vault write succeeded and the
/// native call ran.
abstract interface class LearnedWordsActions {
  Future<bool> learn(String word);

  Future<bool> unlearn(String word);
}

/// The learned-words actions: W3's [LearnedWordsState]. With no vault open
/// or no CLI it returns false and calls nothing.
final learnedWordsActionsProvider = Provider<LearnedWordsActions>(
  LearnedWordsState.new,
);
