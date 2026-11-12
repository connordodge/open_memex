// WI #434 (Spec #392 req 22, 23): the Dart side of the `open_memex/spelling`
// channel, behind the [SpellingService] seam.
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../editor/spell_issues.dart';

/// The spelling method channel's name (macOS `SpellingMenuController`).
const spellingChannelName = 'open_memex/spelling';

/// A Spelling submenu toggle the native side reports.
enum SpellingMenuItem { checkSpelling, checkGrammar }

/// A `check` reply: the request id it answers and the issues found.
class SpellCheckReply {
  const SpellCheckReply({required this.requestId, required this.issues});

  final int requestId;
  final List<SpellIssue> issues;
}

/// The spelling seam (req 23). Dart reaches the channel only through it.
abstract interface class SpellingService {
  /// False once the channel turned out to be missing.
  bool get available;

  Future<SpellCheckReply?> check({
    required int requestId,
    required String text,
    required int documentTag,
    required bool spelling,
    required bool grammar,
  });

  Future<List<String>> guesses({
    required String text,
    required int start,
    required int length,
    required int documentTag,
  });

  Future<void> learn(String word);

  Future<void> unlearn(String word);

  Future<void> ignore(String word, int documentTag);

  Future<int?> documentTag(String noteId);

  Future<void> closeDocumentTags();

  Future<void> setMenuState({
    required bool checkSpelling,
    required bool checkGrammar,
  });

  /// Native `menuToggle(item)` calls.
  Stream<SpellingMenuItem> get menuToggles;

  /// Native `checkDocumentNow()` calls.
  Stream<void> get checkDocumentNowRequests;
}

/// [SpellingService] over the `open_memex/spelling` method channel. Swift is
/// a thin pass-through (D17): every argument map and every reply decode is
/// here.
///
/// Dart to native, arguments keyed by requirement 22's names: `check`
/// `{requestId, text, documentTag, spelling, grammar}`, `guesses`
/// `{text, start, length, documentTag}`, `learn` and `unlearn` `{word}`,
/// `ignore` `{word, documentTag}`, `documentTag` `{noteId}`,
/// `closeDocumentTags` (no arguments) and `setMenuState`
/// `{checkSpelling, checkGrammar}`. Native to Dart: `menuToggle`
/// `{item: 'checkSpelling' | 'checkGrammar'}` and `checkDocumentNow()`.
///
/// A `check` reply is `{requestId, results: [{kind, start, length,
/// description?, corrections?}]}`; offsets are UTF-16 code units and pass
/// through unchanged, and a malformed entry is dropped.
///
/// A [MissingPluginException] from any call turns [available] off and that
/// call answers null, an empty list or nothing; no error escapes (req 23).
/// A [PlatformException] (a native `FlutterError`) makes that call answer the
/// same way but leaves [available] on.
class MethodChannelSpellingService implements SpellingService {
  MethodChannelSpellingService() {
    _channel.setMethodCallHandler(_onNativeCall);
  }

  static const _channel = MethodChannel(spellingChannelName);

  final _menuToggles = StreamController<SpellingMenuItem>.broadcast();
  final _checkDocumentNow = StreamController<void>.broadcast();

  bool _available = true;

  @override
  bool get available => _available;

  /// Invokes [method] with [arguments]; null when the channel is missing or
  /// the native side answers with an error.
  Future<Object?> _invoke(String method, Object? arguments) async {
    try {
      return await _channel.invokeMethod<Object?>(method, arguments);
    } on MissingPluginException {
      _available = false;
      return null;
    } on PlatformException {
      return null;
    }
  }

  Future<Object?> _onNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'menuToggle':
        if (call.arguments case {'item': final String name}) {
          final item = SpellingMenuItem.values.asNameMap()[name];
          if (item != null) _menuToggles.add(item);
        }
      case 'checkDocumentNow':
        _checkDocumentNow.add(null);
    }
    return null;
  }

  @override
  Future<SpellCheckReply?> check({
    required int requestId,
    required String text,
    required int documentTag,
    required bool spelling,
    required bool grammar,
  }) async {
    final reply = await _invoke('check', {
      'requestId': requestId,
      'text': text,
      'documentTag': documentTag,
      'spelling': spelling,
      'grammar': grammar,
    });
    if (reply case {'requestId': final int id, 'results': final List results}) {
      return SpellCheckReply(
        requestId: id,
        issues: List.unmodifiable([for (final r in results) ?_decodeIssue(r)]),
      );
    }
    return null;
  }

  /// One `check` result entry, or null when it is malformed.
  static SpellIssue? _decodeIssue(Object? entry) {
    if (entry is! Map) return null;
    final kind = SpellIssueKind.values.asNameMap()[entry['kind']];
    final start = entry['start'];
    final length = entry['length'];
    final description = entry['description'];
    final corrections = entry['corrections'] ?? const <Object?>[];
    if (kind == null ||
        start is! int ||
        length is! int ||
        description is! String? ||
        corrections is! List) {
      return null;
    }
    return SpellIssue(
      kind: kind,
      start: start,
      length: length,
      description: description,
      corrections: List.unmodifiable(corrections.whereType<String>()),
    );
  }

  @override
  Future<List<String>> guesses({
    required String text,
    required int start,
    required int length,
    required int documentTag,
  }) async {
    final reply = await _invoke('guesses', {
      'text': text,
      'start': start,
      'length': length,
      'documentTag': documentTag,
    });
    if (reply is! List) return const <String>[];
    return List.unmodifiable(reply.whereType<String>());
  }

  @override
  Future<void> learn(String word) => _invoke('learn', {'word': word});

  @override
  Future<void> unlearn(String word) => _invoke('unlearn', {'word': word});

  @override
  Future<void> ignore(String word, int documentTag) =>
      _invoke('ignore', {'word': word, 'documentTag': documentTag});

  @override
  Future<int?> documentTag(String noteId) async {
    final reply = await _invoke('documentTag', {'noteId': noteId});
    return reply is int ? reply : null;
  }

  @override
  Future<void> closeDocumentTags() => _invoke('closeDocumentTags', null);

  @override
  Future<void> setMenuState({
    required bool checkSpelling,
    required bool checkGrammar,
  }) => _invoke('setMenuState', {
    'checkSpelling': checkSpelling,
    'checkGrammar': checkGrammar,
  });

  @override
  Stream<SpellingMenuItem> get menuToggles => _menuToggles.stream;

  @override
  Stream<void> get checkDocumentNowRequests => _checkDocumentNow.stream;
}

/// The app's spelling seam: the method channel in production.
final spellingServiceProvider = Provider<SpellingService>(
  (ref) => MethodChannelSpellingService(),
);
