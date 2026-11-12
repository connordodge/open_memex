// WI #434 (Spec #392 req 23): the shared fake [SpellingService]. Every
// #392 app WI (E2-E6, W3) drives spelling through it; no test reaches the
// real `NSSpellChecker`.
//
// - Scripted issues per paragraph text ([scriptIssues]) or per word
//   ([misspell], [flagGrammar]); scripted guesses per word ([scriptGuesses]).
// - A fake macOS dictionary: [learned] (filled by `learn`, emptied by
//   `unlearn` and [resetDictionary]) and the words ignored per document tag.
//   `check` drops spelling issues for learned or ignored words, as the real
//   checker does.
// - Every call is recorded in [calls]; [count] and [callsFor] read them.
// - [emitMenuToggle] and [emitCheckDocumentNow] stand in for the native
//   side's `menuToggle(item)` and `checkDocumentNow()`.
// - Completer mode ([holdReplies]): `check` replies wait in [held] until the
//   test completes them, in any order.
import 'dart:async';

import 'package:open_memex_app/src/editor/spell_issues.dart';
import 'package:open_memex_app/src/state/spelling_service.dart';

/// One call the fake received: the method name as requirement 22 spells it
/// and its arguments under requirement 22's names.
class SpellingCall {
  const SpellingCall(this.method, this.args);

  final String method;
  final Map<String, Object?> args;

  @override
  String toString() => '$method($args)';
}

/// A `check` held in completer mode. Complete it with [reply] (the scripted
/// result by default) or [replyNull] (what an unavailable channel gives).
class HeldCheck {
  HeldCheck._(this.call, this._scripted);

  final SpellingCall call;
  final List<SpellIssue> _scripted;
  final _completer = Completer<SpellCheckReply?>();

  int get requestId => call.args['requestId']! as int;
  String get text => call.args['text']! as String;
  bool get isCompleted => _completer.isCompleted;

  /// Answers with [issues], or with what the fake would have answered.
  void reply([List<SpellIssue>? issues]) => _completer.complete(
    SpellCheckReply(requestId: requestId, issues: issues ?? _scripted),
  );

  void replyNull() => _completer.complete(null);
}

class FakeSpellingService implements SpellingService {
  FakeSpellingService({this.available = true});

  /// Settable: false makes every call answer as a missing channel does
  /// (null, an empty list, nothing). Calls are still recorded.
  @override
  bool available;

  // ------------------------------------------------------------- scripting

  final Map<String, List<SpellIssue>> _issuesByText = {};
  final Map<String, List<String>> _misspelled = {};
  final Map<String, ({String? description, List<String> corrections})>
  _grammarPhrases = {};
  final Map<String, List<String>> _guessesByWord = {};

  /// `check` of exactly [text] answers [issues] (offsets into [text]).
  void scriptIssues(String text, List<SpellIssue> issues) =>
      _issuesByText[text] = List.of(issues);

  /// Every whole-word occurrence of [word] (case-sensitive) in any checked
  /// text is a spelling issue with [corrections]. Also scripts [corrections]
  /// as the guesses for [word] unless guesses are already scripted.
  void misspell(String word, {List<String> corrections = const []}) {
    _misspelled[word] = List.of(corrections);
    _guessesByWord.putIfAbsent(word, () => List.of(corrections));
  }

  /// Every occurrence of [phrase] in any checked text is a grammar issue.
  void flagGrammar(
    String phrase, {
    String? description,
    List<String> corrections = const [],
  }) => _grammarPhrases[phrase] = (
    description: description,
    corrections: List.of(corrections),
  );

  /// `guesses` for [word] answer [guesses].
  void scriptGuesses(String word, List<String> guesses) =>
      _guessesByWord[word] = List.of(guesses);

  // ------------------------------------------------- fake macOS dictionary

  /// Words taught to the fake macOS dictionary (`learn`), as given.
  final Set<String> learned = {};

  /// Words ignored per document tag (`ignore`), until `closeDocumentTags`.
  final Map<int, Set<String>> ignoredByTag = {};

  /// The document tag handed out per note id.
  final Map<String, int> tags = {};
  int _nextTag = 1;

  /// Forgets every learned word, as a Mac whose dictionary never saw them.
  void resetDictionary() => learned.clear();

  // ---------------------------------------------------------------- calls

  final List<SpellingCall> calls = [];

  /// The calls to [method], in order.
  List<SpellingCall> callsFor(String method) => [
    for (final c in calls)
      if (c.method == method) c,
  ];

  /// How many times [method] was called.
  int count(String method) => callsFor(method).length;

  /// The arguments of the last `setMenuState`, or null.
  ({bool checkSpelling, bool checkGrammar})? get lastMenuState {
    final sent = callsFor('setMenuState');
    if (sent.isEmpty) return null;
    final args = sent.last.args;
    return (
      checkSpelling: args['checkSpelling']! as bool,
      checkGrammar: args['checkGrammar']! as bool,
    );
  }

  void clearCalls() => calls.clear();

  // ------------------------------------------------------------ completer

  /// While true, each `check` waits in [held] until the test replies.
  bool holdReplies = false;

  final List<HeldCheck> held = [];

  /// Replies to every held check not yet answered, oldest first, with the
  /// scripted results.
  void releaseHeld() {
    for (final h in held) {
      if (!h.isCompleted) h.reply();
    }
  }

  // ------------------------------------------------------- native events

  final _toggles = StreamController<SpellingMenuItem>.broadcast(sync: true);
  final _checkNow = StreamController<void>.broadcast(sync: true);

  /// The native side's `menuToggle(item)`.
  void emitMenuToggle(SpellingMenuItem item) => _toggles.add(item);

  /// The native side's `checkDocumentNow()`.
  void emitCheckDocumentNow() => _checkNow.add(null);

  @override
  Stream<SpellingMenuItem> get menuToggles => _toggles.stream;

  @override
  Stream<void> get checkDocumentNowRequests => _checkNow.stream;

  // -------------------------------------------------------------- service

  /// The issues the fake checker finds in [text] for [documentTag]: the
  /// scripted ones, minus the kinds not asked for, minus spelling issues
  /// for learned or ignored words.
  List<SpellIssue> issuesFor(
    String text, {
    required int documentTag,
    bool spelling = true,
    bool grammar = true,
  }) {
    final found = <SpellIssue>[
      ...?_issuesByText[text],
      for (final e in _misspelled.entries)
        for (final m in RegExp(
          '(?<![\\p{L}\\p{N}])${RegExp.escape(e.key)}(?![\\p{L}\\p{N}])',
          unicode: true,
        ).allMatches(text))
          SpellIssue(
            kind: SpellIssueKind.spelling,
            start: m.start,
            length: m.end - m.start,
            corrections: e.value,
          ),
      for (final e in _grammarPhrases.entries)
        for (final m in e.key.allMatches(text))
          SpellIssue(
            kind: SpellIssueKind.grammar,
            start: m.start,
            length: m.end - m.start,
            description: e.value.description,
            corrections: e.value.corrections,
          ),
    ]..sort((a, b) => a.start.compareTo(b.start));
    final learnedKeys = {for (final w in learned) w.toLowerCase()};
    final ignored = ignoredByTag[documentTag] ?? const <String>{};
    return [
      for (final i in found)
        if (i.kind == SpellIssueKind.spelling
            ? spelling &&
                  !learnedKeys.contains(_word(text, i).toLowerCase()) &&
                  !ignored.contains(_word(text, i))
            : grammar)
          i,
    ];
  }

  static String _word(String text, SpellIssue i) =>
      text.substring(i.start, i.start + i.length);

  @override
  Future<SpellCheckReply?> check({
    required int requestId,
    required String text,
    required int documentTag,
    required bool spelling,
    required bool grammar,
  }) {
    final call = SpellingCall('check', {
      'requestId': requestId,
      'text': text,
      'documentTag': documentTag,
      'spelling': spelling,
      'grammar': grammar,
    });
    calls.add(call);
    if (!available) return Future.value();
    if (holdReplies) {
      // The scripted answer is taken when the call is made, as the native
      // checker reads its dictionary then.
      final h = HeldCheck._(
        call,
        issuesFor(
          text,
          documentTag: documentTag,
          spelling: spelling,
          grammar: grammar,
        ),
      );
      held.add(h);
      return h._completer.future;
    }
    return Future.value(
      SpellCheckReply(
        requestId: requestId,
        issues: issuesFor(
          text,
          documentTag: documentTag,
          spelling: spelling,
          grammar: grammar,
        ),
      ),
    );
  }

  @override
  Future<List<String>> guesses({
    required String text,
    required int start,
    required int length,
    required int documentTag,
  }) {
    calls.add(
      SpellingCall('guesses', {
        'text': text,
        'start': start,
        'length': length,
        'documentTag': documentTag,
      }),
    );
    if (!available) return Future.value(const <String>[]);
    final word = text.substring(start, start + length);
    return Future.value(List.of(_guessesByWord[word] ?? const <String>[]));
  }

  @override
  Future<void> learn(String word) async {
    calls.add(SpellingCall('learn', {'word': word}));
    if (available) learned.add(word);
  }

  @override
  Future<void> unlearn(String word) async {
    calls.add(SpellingCall('unlearn', {'word': word}));
    if (available) learned.remove(word);
  }

  @override
  Future<void> ignore(String word, int documentTag) async {
    calls.add(
      SpellingCall('ignore', {'word': word, 'documentTag': documentTag}),
    );
    if (available) ignoredByTag.putIfAbsent(documentTag, () => {}).add(word);
  }

  @override
  Future<int?> documentTag(String noteId) async {
    calls.add(SpellingCall('documentTag', {'noteId': noteId}));
    if (!available) return null;
    return tags.putIfAbsent(noteId, () => _nextTag++);
  }

  @override
  Future<void> closeDocumentTags() async {
    calls.add(const SpellingCall('closeDocumentTags', {}));
    if (!available) return;
    tags.clear();
    ignoredByTag.clear();
  }

  @override
  Future<void> setMenuState({
    required bool checkSpelling,
    required bool checkGrammar,
  }) async {
    calls.add(
      SpellingCall('setMenuState', {
        'checkSpelling': checkSpelling,
        'checkGrammar': checkGrammar,
      }),
    );
  }
}
