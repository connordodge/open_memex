// WI #434 (Spec #392 req 22, 23; D17): the spelling seam. The issue models,
// `MethodChannelSpellingService` over a mocked `open_memex/spelling` channel
// (all result and error mapping is Dart; Swift is a pass-through), the
// production provider, and the learned-words seam defaults.
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/spell_issues.dart';
import 'package:open_memex_app/src/state/learned_words_seam.dart';
import 'package:open_memex_app/src/state/spelling_service.dart';

import '../support/fake_spelling_service.dart';

const _channel = MethodChannel(spellingChannelName);
const _codec = StandardMethodCodec();

TestDefaultBinaryMessenger get _messenger =>
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

/// Answers the spelling channel with [reply] (by method name) and records
/// every call. Removed after the test.
List<MethodCall> _mockChannel(
  FutureOr<Object?> Function(MethodCall call) reply,
) {
  final calls = <MethodCall>[];
  _messenger.setMockMethodCallHandler(_channel, (call) async {
    calls.add(call);
    return reply(call);
  });
  addTearDown(() => _messenger.setMockMethodCallHandler(_channel, null));
  return calls;
}

/// No handler at all: every call throws MissingPluginException.
void _noChannel() => _messenger.setMockMethodCallHandler(_channel, null);

/// Sends a native-to-Dart call on the spelling channel, as
/// `SpellingMenuController` does, and waits for Dart to answer it.
Future<void> _fromNative(String method, [Object? args]) async {
  final done = Completer<void>();
  await _messenger.handlePlatformMessage(
    spellingChannelName,
    _codec.encodeMethodCall(MethodCall(method, args)),
    (_) => done.complete(),
  );
  await done.future.timeout(const Duration(seconds: 1), onTimeout: () {});
  await pumpEventQueue();
}

Map<String, Object?> _args(MethodCall c) =>
    Map<String, Object?>.from(c.arguments as Map);

const _spellingResult = {
  'kind': 'spelling',
  'start': 0,
  'length': 3,
  'corrections': ['the', 'tech'],
};

const _grammarResult = {
  'kind': 'grammar',
  'start': 4,
  'length': 9,
  'description': 'Possible agreement error.',
  'corrections': ['cats are'],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SpellIssue', () {
    test(
      'SpellIssue has value equality over kind start length description and corrections',
      () {
        // Run-time values, so the constructor runs (not only const instances).
        final start = int.parse('4');
        final words = 'cat,cot'.split(',');
        SpellIssue make({
          SpellIssueKind kind = SpellIssueKind.grammar,
          int? at,
          int length = 3,
          String? description = 'Agreement.',
          List<String>? corrections,
        }) => SpellIssue(
          kind: kind,
          start: at ?? start,
          length: length,
          description: description,
          corrections: corrections ?? List.of(words),
        );

        final a = make();
        final b = make();
        expect(a, b);
        expect(a.hashCode, b.hashCode);
        expect(a.kind, SpellIssueKind.grammar);
        expect(a.start, 4);
        expect(a.length, 3);
        expect(a.description, 'Agreement.');
        expect(a.corrections, ['cat', 'cot']);

        final different = <String, SpellIssue>{
          'kind': make(kind: SpellIssueKind.spelling),
          'start': make(at: 5),
          'length': make(length: 4),
          'description': make(description: 'Other.'),
          'null description': make(description: null),
          'corrections': make(corrections: ['cat']),
          'correction order': make(corrections: ['cot', 'cat']),
        };
        for (final e in different.entries) {
          expect(a == e.value, isFalse, reason: e.key);
        }
        expect(a == Object(), isFalse);
      },
    );

    test('a SpellIssue without corrections has none and no description', () {
      final i = SpellIssue(
        kind: SpellIssueKind.spelling,
        start: int.parse('0'),
        length: 2,
      );
      expect(i.corrections, isEmpty);
      expect(i.description, isNull);
      expect(i, SpellIssue(kind: SpellIssueKind.spelling, start: 0, length: 2));
    });

    test('SpellCheckReply carries its request id and issues', () {
      final issue = SpellIssue(
        kind: SpellIssueKind.spelling,
        start: int.parse('1'),
        length: 2,
      );
      final r = SpellCheckReply(requestId: int.parse('9'), issues: [issue]);
      expect(r.requestId, 9);
      expect(r.issues, [issue]);
    });
  });

  group('MethodChannelSpellingService check (AC5, AC6)', () {
    test(
      'check sends requestId text documentTag spelling and grammar and decodes a spelling and a grammar result',
      () async {
        final calls = _mockChannel(
          (call) => {
            'requestId': (call.arguments as Map)['requestId'],
            'results': [_spellingResult, _grammarResult],
          },
        );
        final service = MethodChannelSpellingService();
        const text = 'teh cats is here';

        final reply = await service.check(
          requestId: 7,
          text: text,
          documentTag: 3,
          spelling: true,
          grammar: false,
        );
        await service.check(
          requestId: 8,
          text: text,
          documentTag: 4,
          spelling: false,
          grammar: true,
        );

        expect(calls.map((c) => c.method), ['check', 'check']);
        expect(_args(calls[0]), {
          'requestId': 7,
          'text': text,
          'documentTag': 3,
          'spelling': true,
          'grammar': false,
        });
        expect(_args(calls[1]), {
          'requestId': 8,
          'text': text,
          'documentTag': 4,
          'spelling': false,
          'grammar': true,
        });

        expect(reply, isNotNull);
        expect(reply!.requestId, 7);
        expect(reply.issues, const [
          SpellIssue(
            kind: SpellIssueKind.spelling,
            start: 0,
            length: 3,
            corrections: ['the', 'tech'],
          ),
          SpellIssue(
            kind: SpellIssueKind.grammar,
            start: 4,
            length: 9,
            description: 'Possible agreement error.',
            corrections: ['cats are'],
          ),
        ]);
        expect(service.available, isTrue);
      },
    );

    test('check keeps the request id the reply carries', () async {
      _mockChannel((_) => {'requestId': 12, 'results': <Object?>[]});
      final reply = await MethodChannelSpellingService().check(
        requestId: 11,
        text: 'fine',
        documentTag: 1,
        spelling: true,
        grammar: true,
      );
      expect(reply, isNotNull);
      expect(reply!.requestId, 12);
      expect(reply.issues, isEmpty);
    });

    test(
      'check drops malformed result entries and keeps the well formed ones',
      () async {
        final results = <Object?>[
          _spellingResult,
          'not a map',
          null,
          {'kind': 'style', 'start': 0, 'length': 3},
          {'start': 0, 'length': 3},
          {'kind': 'spelling', 'start': '0', 'length': 3},
          {'kind': 'spelling', 'length': 3},
          {'kind': 'spelling', 'start': 0},
          {'kind': 'grammar', 'start': 4, 'length': 'nine'},
          {'kind': 'grammar', 'start': 4, 'length': 9, 'description': 5},
          {'kind': 'spelling', 'start': 0, 'length': 3, 'corrections': 'the'},
          {'kind': 'grammar', 'start': 4, 'length': 9},
        ];
        _mockChannel((_) => {'requestId': 1, 'results': results});
        final reply = await MethodChannelSpellingService().check(
          requestId: 1,
          text: 'teh cats is here',
          documentTag: 1,
          spelling: true,
          grammar: true,
        );
        expect(reply, isNotNull);
        expect(reply!.issues, const [
          SpellIssue(
            kind: SpellIssueKind.spelling,
            start: 0,
            length: 3,
            corrections: ['the', 'tech'],
          ),
          SpellIssue(kind: SpellIssueKind.grammar, start: 4, length: 9),
        ]);
      },
    );

    test('check keeps only string corrections inside a result entry', () async {
      _mockChannel(
        (_) => {
          'requestId': 1,
          'results': [
            {
              'kind': 'spelling',
              'start': 0,
              'length': 3,
              'corrections': ['the', 7, null, 'tech', true],
            },
          ],
        },
      );
      final reply = await MethodChannelSpellingService().check(
        requestId: 1,
        text: 'teh',
        documentTag: 1,
        spelling: true,
        grammar: true,
      );
      expect(reply, isNotNull);
      expect(reply!.issues, const [
        SpellIssue(
          kind: SpellIssueKind.spelling,
          start: 0,
          length: 3,
          corrections: ['the', 'tech'],
        ),
      ]);
    });

    test('check answers null for a reply that is not a result map', () async {
      Object? answer;
      _mockChannel((_) => answer);
      final service = MethodChannelSpellingService();
      Future<SpellCheckReply?> ask() => service.check(
        requestId: 2,
        text: 'x',
        documentTag: 1,
        spelling: true,
        grammar: true,
      );
      // A well formed reply first, so a stub that never decodes fails here.
      answer = {'requestId': 2, 'results': <Object?>[]};
      expect(await ask(), isNotNull);
      for (final bad in <Object?>[
        null,
        'oops',
        {'results': <Object?>[]},
        {'requestId': 2},
        {'requestId': 2, 'results': 'none'},
      ]) {
        answer = bad;
        expect(await ask(), isNull, reason: '$bad');
      }
      expect(service.available, isTrue);
    });

    test(
      'offsets after an emoji and a combining accent pass through unchanged as UTF-16 code units',
      () async {
        // U+1F600 is two UTF-16 code units; e + U+0301 is two code units and
        // one grapheme. The flagged word starts after both.
        const text = 'Café \u{1F600} été teh word';
        final start = text.indexOf('teh');
        expect(start, 13);
        // The emoji is one rune but two code units.
        expect(text.runes.length, text.length - 1);
        final calls = _mockChannel(
          (call) => call.method == 'check'
              ? {
                  'requestId': 5,
                  'results': [
                    {
                      'kind': 'spelling',
                      'start': start,
                      'length': 3,
                      'corrections': ['the'],
                    },
                  ],
                }
              : ['the', 'ten'],
        );
        final service = MethodChannelSpellingService();
        final reply = await service.check(
          requestId: 5,
          text: text,
          documentTag: 2,
          spelling: true,
          grammar: true,
        );
        final issue = reply!.issues.single;
        expect(issue.start, 13);
        expect(issue.length, 3);
        expect(text.substring(issue.start, issue.start + issue.length), 'teh');

        final guesses = await service.guesses(
          text: text,
          start: issue.start,
          length: issue.length,
          documentTag: 2,
        );
        expect(guesses, ['the', 'ten']);
        expect(_args(calls.last), {
          'text': text,
          'start': 13,
          'length': 3,
          'documentTag': 2,
        });
      },
    );
  });

  group('MethodChannelSpellingService methods (AC7)', () {
    test(
      'guesses learn unlearn ignore documentTag closeDocumentTags and setMenuState use the requirement 22 names and arguments',
      () async {
        final calls = _mockChannel(
          (call) => switch (call.method) {
            'guesses' => ['the', 'tea'],
            'documentTag' => 42,
            _ => null,
          },
        );
        final s = MethodChannelSpellingService();

        expect(
          await s.guesses(text: 'teh cat', start: 0, length: 3, documentTag: 6),
          ['the', 'tea'],
        );
        await s.learn('Zettel');
        await s.unlearn('Zettel');
        await s.ignore('Memex', 6);
        expect(await s.documentTag('topic-1'), 42);
        await s.closeDocumentTags();
        await s.setMenuState(checkSpelling: true, checkGrammar: false);
        await s.setMenuState(checkSpelling: false, checkGrammar: true);

        expect(calls.map((c) => c.method), [
          'guesses',
          'learn',
          'unlearn',
          'ignore',
          'documentTag',
          'closeDocumentTags',
          'setMenuState',
          'setMenuState',
        ]);
        expect(_args(calls[0]), {
          'text': 'teh cat',
          'start': 0,
          'length': 3,
          'documentTag': 6,
        });
        expect(_args(calls[1]), {'word': 'Zettel'});
        expect(_args(calls[2]), {'word': 'Zettel'});
        expect(_args(calls[3]), {'word': 'Memex', 'documentTag': 6});
        expect(_args(calls[4]), {'noteId': 'topic-1'});
        expect(calls[5].arguments, isNull);
        expect(_args(calls[6]), {'checkSpelling': true, 'checkGrammar': false});
        expect(_args(calls[7]), {'checkSpelling': false, 'checkGrammar': true});
        expect(s.available, isTrue);
      },
    );

    test(
      'guesses keeps only string entries and answers an empty list for a non list reply',
      () async {
        Object? answer = ['the', 3, null, 'tea'];
        _mockChannel((_) => answer);
        final s = MethodChannelSpellingService();
        Future<List<String>> ask() =>
            s.guesses(text: 'teh', start: 0, length: 3, documentTag: 1);
        expect(await ask(), ['the', 'tea']);
        answer = null;
        expect(await ask(), isEmpty);
        answer = 'the';
        expect(await ask(), isEmpty);
      },
    );

    test('documentTag answers null for a reply that is not an int', () async {
      Object? answer = 7;
      _mockChannel((_) => answer);
      final s = MethodChannelSpellingService();
      expect(await s.documentTag('n'), 7);
      answer = null;
      expect(await s.documentTag('n'), isNull);
      answer = '7';
      expect(await s.documentTag('n'), isNull);
    });
  });

  group('missing channel (AC8)', () {
    test(
      'a MissingPluginException turns available off and check answers null without throwing',
      () async {
        _noChannel();
        final s = MethodChannelSpellingService();
        expect(s.available, isTrue);
        final reply = await s.check(
          requestId: 1,
          text: 'teh',
          documentTag: 1,
          spelling: true,
          grammar: true,
        );
        expect(reply, isNull);
        expect(s.available, isFalse);
        // Later calls keep answering quietly.
        expect(
          await s.check(
            requestId: 2,
            text: 'teh',
            documentTag: 1,
            spelling: true,
            grammar: true,
          ),
          isNull,
        );
        expect(s.available, isFalse);
      },
    );

    // One case per public method: each catches MissingPluginException itself.
    final cases = <(String, Future<Object?> Function(SpellingService))>[
      (
        'guesses after a missing channel answers an empty list',
        (s) => s.guesses(text: 'teh', start: 0, length: 3, documentTag: 1),
      ),
      ('learn after a missing channel completes quietly', (s) => s.learn('w')),
      (
        'unlearn after a missing channel completes quietly',
        (s) => s.unlearn('w'),
      ),
      (
        'ignore after a missing channel completes quietly',
        (s) => s.ignore('w', 1),
      ),
      (
        'documentTag after a missing channel answers null',
        (s) => s.documentTag('n'),
      ),
      (
        'closeDocumentTags after a missing channel completes quietly',
        (s) => s.closeDocumentTags(),
      ),
      (
        'setMenuState after a missing channel completes quietly',
        (s) => s.setMenuState(checkSpelling: true, checkGrammar: true),
      ),
    ];
    for (final (name, call) in cases) {
      test(name, () async {
        _noChannel();
        final s = MethodChannelSpellingService();
        expect(s.available, isTrue);
        final result = await call(s);
        expect(s.available, isFalse);
        if (result is List) expect(result, isEmpty);
        if (name.startsWith('documentTag')) expect(result, isNull);
      });
    }
  });

  group('native error reply (review r1)', () {
    /// Answers every call with a native `FlutterError`, which reaches Dart as
    /// a PlatformException.
    List<MethodCall> nativeError() => _mockChannel(
      (_) => throw PlatformException(code: 'bad_arguments', message: 'nope'),
    );

    test(
      'a native error reply makes check answer null and keeps the service available',
      () async {
        final calls = nativeError();
        final s = MethodChannelSpellingService();
        final reply = await s.check(
          requestId: 1,
          text: 'teh',
          documentTag: 1,
          spelling: true,
          grammar: true,
        );
        expect(reply, isNull);
        expect(calls.map((c) => c.method), ['check']);
        expect(s.available, isTrue);
      },
    );

    final cases = <(String, Future<Object?> Function(SpellingService))>[
      (
        'a native error reply makes guesses answer an empty list',
        (s) => s.guesses(text: 'teh', start: 0, length: 3, documentTag: 1),
      ),
      (
        'a native error reply makes learn complete quietly',
        (s) => s.learn('w'),
      ),
      (
        'a native error reply makes unlearn complete quietly',
        (s) => s.unlearn('w'),
      ),
      (
        'a native error reply makes ignore complete quietly',
        (s) => s.ignore('w', 1),
      ),
      (
        'a native error reply makes documentTag answer null',
        (s) => s.documentTag('n'),
      ),
      (
        'a native error reply makes closeDocumentTags complete quietly',
        (s) => s.closeDocumentTags(),
      ),
      (
        'a native error reply makes setMenuState complete quietly',
        (s) => s.setMenuState(checkSpelling: true, checkGrammar: true),
      ),
    ];
    for (final (name, call) in cases) {
      test(name, () async {
        final calls = nativeError();
        final s = MethodChannelSpellingService();
        final result = await call(s);
        expect(calls, hasLength(1));
        expect(s.available, isTrue);
        if (result is List) expect(result, isEmpty);
        if (name.contains('documentTag')) expect(result, isNull);
      });
    }

    test(
      'a native error reply does not stop later calls from succeeding',
      () async {
        var fail = true;
        _mockChannel((call) {
          if (fail) {
            throw PlatformException(code: 'bad_arguments');
          }
          return 5;
        });
        final s = MethodChannelSpellingService();
        expect(await s.documentTag('n'), isNull);
        fail = false;
        expect(await s.documentTag('n'), 5);
        expect(s.available, isTrue);
      },
    );
  });

  group('native to Dart (AC9)', () {
    test(
      'a native checkDocumentNow call emits exactly one checkDocumentNowRequests event',
      () async {
        final s = MethodChannelSpellingService();
        var events = 0;
        final sub = s.checkDocumentNowRequests.listen((_) => events++);
        addTearDown(sub.cancel);
        await _fromNative('checkDocumentNow');
        expect(events, 1);
        await _fromNative('checkDocumentNow');
        expect(events, 2);
      },
    );

    test(
      'a native menuToggle emits its item and an unknown item emits nothing',
      () async {
        final s = MethodChannelSpellingService();
        final items = <SpellingMenuItem>[];
        final sub = s.menuToggles.listen(items.add);
        addTearDown(sub.cancel);
        await _fromNative('menuToggle', {'item': 'checkSpelling'});
        await _fromNative('menuToggle', {'item': 'checkGrammar'});
        await _fromNative('menuToggle', {'item': 'showGuessPanel'});
        await _fromNative('menuToggle', 'checkSpelling');
        await _fromNative('menuToggle');
        expect(items, [
          SpellingMenuItem.checkSpelling,
          SpellingMenuItem.checkGrammar,
        ]);
      },
    );

    test(
      'a native menuToggle emits no checkDocumentNowRequests event',
      () async {
        final s = MethodChannelSpellingService();
        var events = 0;
        final items = <SpellingMenuItem>[];
        final a = s.checkDocumentNowRequests.listen((_) => events++);
        final b = s.menuToggles.listen(items.add);
        addTearDown(a.cancel);
        addTearDown(b.cancel);
        await _fromNative('menuToggle', {'item': 'checkGrammar'});
        await _fromNative('checkDocumentNow');
        expect(items, [SpellingMenuItem.checkGrammar]);
        expect(events, 1);
      },
    );
  });

  group('production provider', () {
    test(
      'spellingServiceProvider is the method channel service by default',
      () async {
        final calls = _mockChannel((_) => null);
        final c = ProviderContainer();
        addTearDown(c.dispose);
        final s = c.read(spellingServiceProvider);
        expect(s, isA<MethodChannelSpellingService>());
        await s.setMenuState(checkSpelling: false, checkGrammar: true);
        expect(calls.map((c) => c.method), ['setMenuState']);
      },
    );
  });

  group('learned words seam (AC11)', () {
    test(
      'by default the learned word keys are empty and learn and unlearn return false with zero spelling calls',
      () async {
        final fake = FakeSpellingService();
        final c = ProviderContainer(
          overrides: [spellingServiceProvider.overrideWithValue(fake)],
        );
        addTearDown(c.dispose);
        expect(c.read(learnedWordKeysProvider), isEmpty);
        final actions = c.read(learnedWordsActionsProvider);
        expect(await actions.learn('Zettel'), isFalse);
        expect(await actions.unlearn('Zettel'), isFalse);
        expect(fake.calls, isEmpty);
        expect(fake.learned, isEmpty);
      },
    );
  });
}
