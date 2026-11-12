// WI #436 (Spec #392 req 12): spelling state that lives for the app
// session, outside any one note editor: the document tag per note id, the
// Ignore Spelling / Ignore Grammar sets and the check results cache. Nothing
// here is persisted.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../editor/spell_issues.dart';
import 'spelling_service.dart';
import 'vault_state.dart';

/// The most check results [SpellSession] keeps; the least recently used go
/// first.
const spellResultCacheSize = 4000;

/// The app session's spelling state. It outlives every note editor (a tab
/// switch or a Source-mode switch disposes the editor, never this).
class SpellSession {
  SpellSession(this._service);

  final SpellingService _service;

  /// Bumped by [reset]: a tag answer from before it is dropped.
  int _epoch = 0;

  final _tags = <String, Future<int?>>{};
  final _knownTags = <String, int>{};
  final _ignoredSpelling = <String, Set<String>>{};
  final _ignoredGrammar = <String, Set<(String, String?)>>{};

  /// Insertion order is use order: the first key is the least recently used.
  final _results = <(String, String, bool), List<SpellIssue>>{};
  int _lastRequestId = 0;

  /// [noteId]'s document tag. `SpellingService.documentTag` is called once
  /// per note id for the session, also when several callers ask before the
  /// first answer arrives; every caller gets that answer. A null answer (no
  /// channel) is not kept, so a later ask tries again.
  Future<int?> documentTag(String noteId) {
    final known = _tags[noteId];
    if (known != null) return known;
    final epoch = _epoch;
    late final Future<int?> asked;
    asked = _service.documentTag(noteId).then((tag) {
      if (epoch == _epoch) {
        if (tag == null) {
          if (identical(_tags[noteId], asked)) _tags.remove(noteId);
        } else {
          _knownTags[noteId] = tag;
        }
      }
      return tag;
    });
    return _tags[noteId] = asked;
  }

  /// [noteId]'s document tag once [documentTag] has answered it, else null.
  int? knownTag(String noteId) => _knownTags[noteId];

  /// Ignore Spelling: [word] (as flagged) is ignored in [noteId] only.
  void ignoreSpelling(String noteId, String word) =>
      _ignoredSpelling.putIfAbsent(noteId, () => {}).add(word);

  /// Whether [word] was ignored in [noteId] this session.
  bool isSpellingIgnored(String noteId, String word) =>
      _ignoredSpelling[noteId]?.contains(word) ?? false;

  /// Ignore Grammar: grammar results in [noteId] whose flagged [text] and
  /// [description] both match are suppressed for the session.
  void ignoreGrammar(String noteId, String text, String? description) =>
      _ignoredGrammar.putIfAbsent(noteId, () => {}).add((text, description));

  /// Whether a grammar result in [noteId] flagging [text] with
  /// [description] was ignored this session.
  bool isGrammarIgnored(String noteId, String text, String? description) =>
      _ignoredGrammar[noteId]?.contains((text, description)) ?? false;

  /// A new request id, larger than every one handed out before.
  int nextRequestId() => ++_lastRequestId;

  /// The issues a check of paragraph [text] in [noteId] found (offsets into
  /// [text]), with grammar asked for or not, or null when none is cached.
  List<SpellIssue>? cachedResult(
    String noteId,
    String text, {
    required bool grammar,
  }) {
    final key = (noteId, text, grammar);
    final hit = _results.remove(key);
    if (hit != null) _results[key] = hit;
    return hit;
  }

  /// Caches [issues] as the result of checking [text] in [noteId].
  void cacheResult(
    String noteId,
    String text, {
    required bool grammar,
    required List<SpellIssue> issues,
  }) {
    final key = (noteId, text, grammar);
    _results.remove(key);
    _results[key] = List.unmodifiable(issues);
    while (_results.length > spellResultCacheSize) {
      _results.remove(_results.keys.first);
    }
  }

  /// Forgets every tag, ignore and result: the vault closed, and its tags
  /// with it (`closeDocumentTags`).
  void reset() {
    _epoch++;
    _tags.clear();
    _knownTags.clear();
    _ignoredSpelling.clear();
    _ignoredGrammar.clear();
    _results.clear();
  }
}

/// The app's one [SpellSession]. A vault close or switch resets it, as
/// `spellingMenuSyncProvider` closes the document tags then.
final spellSessionProvider = Provider<SpellSession>((ref) {
  final session = SpellSession(ref.watch(spellingServiceProvider));
  ref.listen<VaultRef?>(currentVaultProvider, (previous, _) {
    if (previous != null) session.reset();
  });
  return session;
});
