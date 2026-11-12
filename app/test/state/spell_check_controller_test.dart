// WI #436 (Spec #392 req 8, 12): the pure parts of the spell-check
// scheduler. `shiftSpellIssues` keeps issues on their words while the person
// types (req 8); `SpellSession` holds the session's document tags and Ignore
// sets (req 12). The scheduling itself is covered by
// test/widgets/editor/spell_check_scheduling_test.dart.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/spell_issues.dart';
import 'package:open_memex_app/src/state/spell_check_controller.dart';
import 'package:open_memex_app/src/state/spell_session_state.dart';
import 'package:open_memex_app/src/state/spelling_service.dart';
import 'package:open_memex_app/src/state/vault_state.dart';

import '../support/fake_spelling_service.dart';

/// Built from run-time values (not const), so the constructor runs.
SpellIssue _spelling(int start, int length, [List<String>? corrections]) =>
    SpellIssue(
      kind: SpellIssueKind.spelling,
      start: start,
      length: length,
      corrections: corrections ?? ['fix$start'],
    );

SpellIssue _grammar(int start, int length, String description) => SpellIssue(
  kind: SpellIssueKind.grammar,
  start: start,
  length: length,
  description: description,
  corrections: [description.toLowerCase()],
);

/// A [SpellingService] whose `documentTag` answers only when the test
/// completes it, counting the calls per note id.
class _Wi436HeldTagService extends FakeSpellingService {
  final pending = <String, Completer<int?>>{};

  @override
  Future<int?> documentTag(String noteId) {
    calls.add(SpellingCall('documentTag', {'noteId': noteId}));
    return (pending[noteId] = Completer<int?>()).future;
  }
}

List<(int, int)> _issueSpans(List<SpellIssue> issues) => [
  for (final i in issues) (i.start, i.length),
];

/// A [SpellIssueSink] over a map.
class _Wi436MapSink implements SpellIssueSink {
  final issues = <TextEditingController, List<SpellIssue>>{};

  @override
  List<SpellIssue> issuesOf(TextEditingController field) =>
      issues[field] ?? const [];

  @override
  void setIssues(TextEditingController field, List<SpellIssue> value) =>
      issues[field] = value;

  @override
  void forget(TextEditingController field) => issues.remove(field);
}

/// A field host with no geometry whose focus the test flips.
class _Wi436FocusHost implements SpellFieldHost {
  bool focused = true;

  @override
  SpellFieldLine line(TextEditingController field) =>
      (line: field.text, base: 0, atSegmentStart: true);

  @override
  RenderEditable? editable() => null;

  @override
  RenderBox? viewportBox() => null;

  @override
  bool revealed(TextEditingController field) => true;

  @override
  ValueListenable<bool>? revealGate(TextEditingController field) => null;

  @override
  bool hasFocus(TextEditingController field) => focused;
}

ProviderContainer _container(SpellingService service) {
  final c = ProviderContainer(
    overrides: [spellingServiceProvider.overrideWithValue(service)],
  );
  addTearDown(c.dispose);
  return c;
}

void main() {
  group('shiftSpellIssues (AC5)', () {
    // 'one teh two dgo' : teh at 4..7, dgo at 12..15.
    final teh = _spelling(4, 3);
    final dgo = _spelling(12, 3);

    test('an insertion before an issue shifts it by the inserted length', () {
      // 'big one teh two dgo': 4 code units inserted at 0.
      expect(
        shiftSpellIssues([teh, dgo], start: 0, end: 0, insertedLength: 4),
        [
          _spelling(8, 3, ['fix4']),
          _spelling(16, 3, ['fix12']),
        ],
      );
    });

    test('a deletion before an issue shifts it back by the deleted length', () {
      // 'teh two dgo': 'one ' (0..4) deleted.
      expect(
        shiftSpellIssues([teh, dgo], start: 0, end: 4, insertedLength: 0),
        [
          _spelling(0, 3, ['fix4']),
          _spelling(8, 3, ['fix12']),
        ],
      );
    });

    test(
      'a replacement between two issues keeps the earlier one and shifts the later one by the length change',
      () {
        // 'two' (8..11) becomes 'three': +2.
        expect(
          shiftSpellIssues([teh, dgo], start: 8, end: 11, insertedLength: 5),
          [
            teh,
            _spelling(14, 3, ['fix12']),
          ],
        );
      },
    );

    test('an edit after every issue changes nothing', () {
      expect(
        shiftSpellIssues([teh, dgo], start: 15, end: 15, insertedLength: 3),
        [teh, dgo],
      );
    });

    test('an insertion inside a flagged range drops that issue only', () {
      // 'te|h': one code unit typed at 6.
      expect(
        shiftSpellIssues([teh, dgo], start: 6, end: 6, insertedLength: 1),
        [
          _spelling(13, 3, ['fix12']),
        ],
      );
    });

    test('an edit overlapping the start of an issue drops it', () {
      // '...one t' (2..5) replaced by 'x'.
      expect(
        shiftSpellIssues([teh, dgo], start: 2, end: 5, insertedLength: 1),
        [
          _spelling(10, 3, ['fix12']),
        ],
      );
    });

    test('an edit overlapping the end of an issue drops it', () {
      // 'h tw' (6..10) deleted.
      expect(
        shiftSpellIssues([teh, dgo], start: 6, end: 10, insertedLength: 0),
        [
          _spelling(8, 3, ['fix12']),
        ],
      );
    });

    test('an edit covering several issues drops them all', () {
      expect(
        shiftSpellIssues([teh, dgo], start: 3, end: 15, insertedLength: 2),
        isEmpty,
      );
    });

    test(
      'a shifted grammar issue keeps its kind, description and corrections',
      () {
        final g = _grammar(8, 7, 'Agreement');
        expect(shiftSpellIssues([g], start: 0, end: 0, insertedLength: 3), [
          _grammar(11, 7, 'Agreement'),
        ]);
      },
    );

    test('no issues stay no issues', () {
      expect(
        shiftSpellIssues(const [], start: 0, end: 0, insertedLength: 1),
        isEmpty,
      );
    });

    // Lead ruling Q2 (#436): an edit that touches an issue's edge drops it
    // only when the inserted character next to the flagged range extends the
    // word. 'one teh two dgo': teh 4..7, dgo 12..15.
    List<SpellIssue> edge(
      int start,
      int end,
      String inserted, [
      List<SpellIssue>? issues,
    ]) => shiftSpellIssues(
      issues ?? [teh, dgo],
      start: start,
      end: end,
      insertedLength: inserted.length,
      insertedText: inserted,
    );

    test('a word character typed at an issue start drops it', () {
      expect(edge(4, 4, 'x'), [
        _spelling(13, 3, ['fix12']),
      ]);
    });

    test('a non-word character typed at an issue start moves it', () {
      expect(edge(4, 4, ' '), [
        _spelling(5, 3, ['fix4']),
        _spelling(13, 3, ['fix12']),
      ]);
    });

    test('a word character typed at an issue end drops it', () {
      expect(edge(7, 7, 's'), [
        _spelling(13, 3, ['fix12']),
      ]);
    });

    test('a non-word character typed at an issue end keeps it', () {
      expect(edge(7, 7, ','), [
        teh,
        _spelling(13, 3, ['fix12']),
      ]);
    });

    for (final (name, text) in [
      ('an ASCII apostrophe', "'"),
      ('a typographic apostrophe', '\u2019'),
      ('a combining mark', '\u0301'),
      ('a digit', '2'),
      ('a letter outside the BMP', '\u{10400}'),
      ('an accented letter', '\u00e9'),
    ]) {
      test('$name typed at an issue end drops it', () {
        expect(edge(7, 7, text), [
          _spelling(12 + text.length, 3, ['fix12']),
        ]);
      });

      test('$name typed at an issue start drops it', () {
        expect(edge(4, 4, text), [
          _spelling(12 + text.length, 3, ['fix12']),
        ]);
      });
    }

    for (final (name, text) in [
      ('a hyphen', '-'),
      ('a period', '.'),
      ('a tab', '\t'),
      ('a newline', '\n'),
      ('an emoji', '\u{1F600}'),
    ]) {
      test('$name typed at an issue end keeps it', () {
        expect(edge(7, 7, text).first, teh);
      });

      test('$name typed at an issue start moves it', () {
        expect(edge(4, 4, text).first, _spelling(4 + text.length, 3, ['fix4']));
      });
    }

    test('only the character next to the issue decides at its start', () {
      // 'x ' ends with a space: the issue moves. ' x' ends with a word
      // character: the issue is dropped.
      expect(edge(4, 4, 'x ').first, _spelling(6, 3, ['fix4']));
      expect(edge(4, 4, ' x').map((i) => i.start), [14]);
    });

    test('only the character next to the issue decides at its end', () {
      // 'x ' starts with a word character: dropped. ' x' starts with a
      // space: kept.
      expect(edge(7, 7, 'x ').map((i) => i.start), [14]);
      expect(edge(7, 7, ' x').first, teh);
    });

    test(
      'a replacement that ends at an issue start and adds a word character drops it',
      () {
        // The space before teh (3..4) replaced by 'x': 'onexteh'.
        expect(edge(3, 4, 'x'), [
          _spelling(12, 3, ['fix12']),
        ]);
      },
    );

    test(
      'a replacement that ends at an issue start and adds a non-word character keeps it where it was',
      () {
        expect(edge(3, 4, '-'), [
          teh,
          _spelling(12, 3, ['fix12']),
        ]);
      },
    );

    test(
      'a replacement that starts at an issue end and adds a word character drops it',
      () {
        // The space after teh (7..8) replaced by 's': 'tehstwo'.
        expect(edge(7, 8, 's'), [
          _spelling(12, 3, ['fix12']),
        ]);
      },
    );

    test(
      'a replacement that starts at an issue end and adds a non-word character keeps it',
      () {
        expect(edge(7, 8, ','), [
          teh,
          _spelling(12, 3, ['fix12']),
        ]);
      },
    );

    test('a deletion at an issue edge keeps and moves it as before', () {
      // Nothing is inserted, so no word is extended.
      expect(
        shiftSpellIssues(
          [teh, dgo],
          start: 7,
          end: 8,
          insertedLength: 0,
          insertedText: '',
        ),
        [
          teh,
          _spelling(11, 3, ['fix12']),
        ],
      );
      expect(
        shiftSpellIssues(
          [teh, dgo],
          start: 3,
          end: 4,
          insertedLength: 0,
          insertedText: '',
        ),
        [
          _spelling(3, 3, ['fix4']),
          _spelling(11, 3, ['fix12']),
        ],
      );
    });

    test(
      'without the inserted text an edit at an edge never drops an issue',
      () {
        expect(
          shiftSpellIssues([teh, dgo], start: 7, end: 7, insertedLength: 1),
          [
            teh,
            _spelling(13, 3, ['fix12']),
          ],
        );
        expect(
          shiftSpellIssues([teh, dgo], start: 4, end: 4, insertedLength: 1),
          [
            _spelling(5, 3, ['fix4']),
            _spelling(13, 3, ['fix12']),
          ],
        );
      },
    );

    test('a grammar issue is dropped at an edge by the same rule', () {
      final g = _grammar(4, 7, 'Agreement');
      expect(edge(11, 11, 's', [g]), isEmpty);
      expect(edge(4, 4, 'x', [g]), isEmpty);
      expect(edge(11, 11, '.', [g]), [g]);
      expect(edge(4, 4, ' ', [g]), [_grammar(5, 7, 'Agreement')]);
    });

    test('an edge edit leaves an issue away from the edit alone', () {
      // Typing a word character at the end of teh does not touch dgo's
      // start edge (12) and keeps the shift.
      expect(edge(7, 7, 's').single.start, 13);
      expect(edge(12, 12, 'x').map((i) => i.start), [4]);
    });
  });

  group('SpellSession document tags (AC11)', () {
    test(
      'documentTag is called once per note id and every later ask gets the same tag',
      () async {
        final fake = FakeSpellingService();
        final session = _container(fake).read(spellSessionProvider);

        final first = await session.documentTag('note-a');
        final again = await session.documentTag('note-a');
        final other = await session.documentTag('note-b');

        expect(first, isNotNull);
        expect(first, fake.tags['note-a']);
        expect(again, first);
        expect(other, fake.tags['note-b']);
        expect(other, isNot(first));
        expect(
          [for (final c in fake.callsFor('documentTag')) c.args['noteId']],
          ['note-a', 'note-b'],
        );
      },
    );

    test(
      'documentTag asked twice before the first answer still calls the service once',
      () async {
        final held = _Wi436HeldTagService();
        final session = _container(held).read(spellSessionProvider);

        final a = session.documentTag('note-a');
        final b = session.documentTag('note-a');
        await Future<void>.delayed(Duration.zero);
        expect(held.count('documentTag'), 1);

        held.pending['note-a']!.complete(41);
        expect(await a, 41);
        expect(await b, 41);
        expect(held.count('documentTag'), 1);
      },
    );

    test('the session is one app-level object for the container', () {
      final c = _container(FakeSpellingService());
      expect(
        identical(c.read(spellSessionProvider), c.read(spellSessionProvider)),
        isTrue,
      );
    });
  });

  group('SpellSession ignore sets (AC10)', () {
    test('an ignored spelling word is ignored in its own note only', () {
      final session = _container(
        FakeSpellingService(),
      ).read(spellSessionProvider);
      expect(session.isSpellingIgnored('note-a', 'teh'), isFalse);

      session.ignoreSpelling('note-a', 'teh');

      expect(session.isSpellingIgnored('note-a', 'teh'), isTrue);
      expect(session.isSpellingIgnored('note-b', 'teh'), isFalse);
      expect(session.isSpellingIgnored('note-a', 'dgo'), isFalse);
    });

    test(
      'an ignored grammar entry matches only the same note, flagged text and description',
      () {
        final session = _container(
          FakeSpellingService(),
        ).read(spellSessionProvider);
        expect(
          session.isGrammarIgnored('note-a', 'He go', 'Agreement'),
          isFalse,
        );

        session.ignoreGrammar('note-a', 'He go', 'Agreement');

        expect(
          session.isGrammarIgnored('note-a', 'He go', 'Agreement'),
          isTrue,
        );
        expect(
          session.isGrammarIgnored('note-b', 'He go', 'Agreement'),
          isFalse,
        );
        expect(
          session.isGrammarIgnored('note-a', 'She go', 'Agreement'),
          isFalse,
        );
        expect(session.isGrammarIgnored('note-a', 'He go', 'Tense'), isFalse);
        expect(session.isGrammarIgnored('note-a', 'He go', null), isFalse);
      },
    );

    test(
      'an ignored grammar entry with no description matches a result with none',
      () {
        final session = _container(
          FakeSpellingService(),
        ).read(spellSessionProvider);
        session.ignoreGrammar('note-a', 'He go', null);
        expect(session.isGrammarIgnored('note-a', 'He go', null), isTrue);
        expect(
          session.isGrammarIgnored('note-a', 'He go', 'Agreement'),
          isFalse,
        );
      },
    );

    test('ignoring calls nothing on the service', () {
      final fake = FakeSpellingService();
      final session = _container(fake).read(spellSessionProvider);
      session.ignoreSpelling('note-a', 'teh');
      session.ignoreGrammar('note-a', 'He go', 'Agreement');
      expect(fake.calls, isEmpty);
    });
  });

  group('SpellSession tags, cache and reset', () {
    test(
      'a null documentTag answer is not kept so a later ask asks again',
      () async {
        final fake = FakeSpellingService(available: false);
        final session = _container(fake).read(spellSessionProvider);

        expect(await session.documentTag('note-a'), isNull);
        expect(session.knownTag('note-a'), isNull);
        fake.available = true;
        final tag = await session.documentTag('note-a');

        expect(tag, isNotNull);
        expect(session.knownTag('note-a'), tag);
        expect(fake.count('documentTag'), 2);
        expect(await session.documentTag('note-a'), tag);
        expect(fake.count('documentTag'), 2);
      },
    );

    test('knownTag is null until the answer arrives', () async {
      final held = _Wi436HeldTagService();
      final session = _container(held).read(spellSessionProvider);
      final ask = session.documentTag('note-a');
      await Future<void>.delayed(Duration.zero);
      expect(session.knownTag('note-a'), isNull);
      held.pending['note-a']!.complete(7);
      await ask;
      expect(session.knownTag('note-a'), 7);
    });

    test('request ids only grow', () {
      final session = _container(
        FakeSpellingService(),
      ).read(spellSessionProvider);
      final ids = [for (var i = 0; i < 4; i++) session.nextRequestId()];
      expect([...ids]..sort(), ids);
      expect(ids.toSet(), hasLength(4));
    });

    test('a cached result is found by note, text and grammar flag only', () {
      final session = _container(
        FakeSpellingService(),
      ).read(spellSessionProvider);
      session.cacheResult(
        'n',
        'teh',
        grammar: false,
        issues: [_spelling(0, 3)],
      );

      expect(session.cachedResult('n', 'teh', grammar: false), [
        _spelling(0, 3),
      ]);
      expect(session.cachedResult('n', 'teh', grammar: true), isNull);
      expect(session.cachedResult('m', 'teh', grammar: false), isNull);
      expect(session.cachedResult('n', 'dgo', grammar: false), isNull);
    });

    test('the cache keeps the newest 4000 results and drops the oldest', () {
      final session = _container(
        FakeSpellingService(),
      ).read(spellSessionProvider);
      for (var i = 0; i < spellResultCacheSize; i++) {
        session.cacheResult('n', 'p$i', grammar: false, issues: const []);
      }
      expect(session.cachedResult('n', 'p0', grammar: false), isNotNull);
      session.cacheResult('n', 'extra', grammar: false, issues: const []);

      expect(spellResultCacheSize, 4000);
      // p0 was just used, so p1 is the least recently used and goes.
      expect(session.cachedResult('n', 'p1', grammar: false), isNull);
      expect(session.cachedResult('n', 'p0', grammar: false), isNotNull);
      expect(session.cachedResult('n', 'p2', grammar: false), isNotNull);
      expect(session.cachedResult('n', 'extra', grammar: false), isNotNull);
      expect(
        session.cachedResult(
          'n',
          'p${spellResultCacheSize - 1}',
          grammar: false,
        ),
        isNotNull,
      );
    });

    test(
      'caching a text again replaces its result and makes it the newest',
      () {
        final session = _container(
          FakeSpellingService(),
        ).read(spellSessionProvider);
        for (var i = 0; i < spellResultCacheSize; i++) {
          session.cacheResult('n', 'p$i', grammar: false, issues: const []);
        }
        session.cacheResult(
          'n',
          'p0',
          grammar: false,
          issues: [_spelling(0, 1)],
        );
        session.cacheResult('n', 'extra', grammar: false, issues: const []);

        expect(session.cachedResult('n', 'p0', grammar: false), [
          _spelling(0, 1),
        ]);
        expect(session.cachedResult('n', 'p1', grammar: false), isNull);
      },
    );

    test('a cached result cannot be changed by its caller', () {
      final session = _container(
        FakeSpellingService(),
      ).read(spellSessionProvider);
      final issues = [_spelling(0, 3)];
      session.cacheResult('n', 'teh', grammar: false, issues: issues);
      issues.clear();
      expect(session.cachedResult('n', 'teh', grammar: false), hasLength(1));
      expect(
        () => session.cachedResult('n', 'teh', grammar: false)!.clear(),
        throwsUnsupportedError,
      );
    });

    test('reset forgets tags, ignores and results', () async {
      final fake = FakeSpellingService();
      final session = _container(fake).read(spellSessionProvider);
      await session.documentTag('n');
      session.ignoreSpelling('n', 'teh');
      session.ignoreGrammar('n', 'He go', 'A');
      session.cacheResult(
        'n',
        'teh',
        grammar: false,
        issues: [_spelling(0, 3)],
      );

      session.reset();

      expect(session.knownTag('n'), isNull);
      expect(session.isSpellingIgnored('n', 'teh'), isFalse);
      expect(session.isGrammarIgnored('n', 'He go', 'A'), isFalse);
      expect(session.cachedResult('n', 'teh', grammar: false), isNull);
      await session.documentTag('n');
      expect(fake.count('documentTag'), 2);
    });

    test('a tag answer that arrives after a reset is not kept', () async {
      final held = _Wi436HeldTagService();
      final session = _container(held).read(spellSessionProvider);
      final ask = session.documentTag('n');
      await Future<void>.delayed(Duration.zero);

      session.reset();
      held.pending['n']!.complete(9);
      await ask;

      expect(session.knownTag('n'), isNull);
    });

    test(
      'the session resets when the open vault changes away from a vault',
      () {
        final c = _container(FakeSpellingService());
        final session = c.read(spellSessionProvider);
        session.ignoreSpelling('n', 'teh');

        // Opening the first vault is not a change away from one.
        c.read(currentVaultProvider.notifier).state = const LocalVaultRef('/a');
        expect(session.isSpellingIgnored('n', 'teh'), isTrue);

        c.read(currentVaultProvider.notifier).state = const LocalVaultRef('/b');
        expect(session.isSpellingIgnored('n', 'teh'), isFalse);

        session.ignoreSpelling('n', 'dgo');
        c.read(currentVaultProvider.notifier).state = null;
        expect(session.isSpellingIgnored('n', 'dgo'), isFalse);
      },
    );
  });

  group('spellFooterStart (AC14)', () {
    const marker = '<!-- memex:topics -->';

    test('a body with no marker has no footer', () {
      expect(spellFooterStart('Just teh text.\n'), isNull);
      expect(spellFooterStart('', role: 'topic'), isNull);
    });

    test('the footer starts at the marker line', () {
      const body = 'Body teh.\n\n$marker\n[[Foo~about]]\n#tag\n';
      expect(spellFooterStart(body), body.indexOf(marker));
      expect(spellFooterStart(body, role: 'topic'), body.indexOf(marker));
      expect(spellFooterStart(body, role: 'daily'), body.indexOf(marker));
    });

    test('a marker on the first line starts the footer at 0', () {
      const body = '$marker\n[[Foo~about]]\n';
      expect(spellFooterStart(body), 0);
    });

    test('a guide note has no footer', () {
      expect(spellFooterStart('Body.\n\n$marker\n', role: 'guide'), isNull);
    });

    test('a marker in the middle of a line is body text', () {
      expect(spellFooterStart('see $marker here\n'), isNull);
    });

    test('a marker inside fenced code is body text except in a daily note', () {
      const body = '```\n$marker\n```\nafter\n';
      expect(spellFooterStart(body), isNull);
      expect(spellFooterStart(body, role: 'topic'), isNull);
      expect(spellFooterStart(body, role: 'daily'), body.indexOf(marker));
    });

    test('stray text below the marker still lies in the footer', () {
      const body = 'Body.\n\n$marker\nStray teh line.\n';
      expect(spellFooterStart(body), body.indexOf(marker));
    });

    test(
      'a repeated marker line below the first leaves the first as the start',
      () {
        const body = 'a\n\n$marker\nstray\n$marker\n';
        expect(spellFooterStart(body), body.indexOf(marker));
      },
    );
  });

  group('SpellCheckController focus (review r1)', () {
    // 'Good teh word.': teh at 5..8, the caret touching its end.
    Future<
      ({
        SpellCheckController checker,
        _Wi436MapSink sink,
        _Wi436FocusHost host,
        TextEditingController field,
        FakeSpellingService service,
      })
    >
    open(WidgetTester tester) async {
      final service = FakeSpellingService()..misspell('teh');
      final container = _container(service);
      final sink = _Wi436MapSink();
      final checker = SpellCheckController(
        noteId: 'note-focus',
        sink: sink,
        session: () => container.read(spellSessionProvider),
        service: () => service,
        flags: (spelling: true, grammar: true),
      );
      addTearDown(checker.dispose);
      final host = _Wi436FocusHost();
      final field = TextEditingController(text: 'Good teh word.')
        ..selection = const TextSelection.collapsed(offset: 8);
      checker.addField(field, host);
      final done = checker.checkAll();
      await tester.pump();
      await done;
      await tester.pump();
      return (
        checker: checker,
        sink: sink,
        host: host,
        field: field,
        service: service,
      );
    }

    testWidgets(
      'a word held under the caret is published when the field reports that focus left',
      (tester) async {
        final o = await open(tester);
        expect(o.service.count('check'), 1);
        expect(o.sink.issuesOf(o.field), isEmpty, reason: 'held under caret');

        o.host.focused = false;
        o.checker.focusChanged(o.field);
        expect(_issueSpans(o.sink.issuesOf(o.field)), [(5, 3)]);
        expect(o.service.count('check'), 1, reason: 'no new check');
      },
    );

    testWidgets(
      'a published word stays when the field gets focus back with the caret on it',
      (tester) async {
        final o = await open(tester);
        o.host.focused = false;
        o.checker.focusChanged(o.field);
        o.host.focused = true;
        o.checker.focusChanged(o.field);
        expect(_issueSpans(o.sink.issuesOf(o.field)), [(5, 3)]);
      },
    );

    testWidgets(
      'a word under the caret of a focused field stays held after a focus report',
      (tester) async {
        final o = await open(tester);
        o.checker.focusChanged(o.field);
        expect(o.sink.issuesOf(o.field), isEmpty);
      },
    );

    testWidgets(
      'a focus report for a field the checker does not know changes nothing',
      (tester) async {
        final o = await open(tester);
        o.host.focused = false;
        o.checker.focusChanged(TextEditingController(text: 'other'));
        expect(
          o.sink.issuesOf(o.field),
          isEmpty,
          reason: 'this field is unreported',
        );
        expect(o.service.count('check'), 1);
      },
    );
  });
}
