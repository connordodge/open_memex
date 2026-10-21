// WI #81 (V1), AC 2 and AC 3, ruling D10b: the local `VaultDb._snippet`
// (through `VaultDb.listNotes`) never splits a surrogate pair. A first line
// over 120 UTF-16 units is cut to 117 units, or to 116 when unit 116 is a
// high surrogate; every other snippet is unchanged.
//
// The cases in `test/fixtures/api_v1/notes/snippet_cases.json` are shared
// with the Rust read `app_reads::notes::snippet`
// (crates/memex-core/tests/app_reads_notes.rs), so the two languages agree.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db.dart';

import '../support/api_fixtures.dart';
import '../support/fake_vault_db.dart';

const _notesDir = '$apiV1FixturesDir/notes';

/// One shared snippet case.
typedef _Wi81SnippetCase = ({String name, String contentMd, String snippet});

List<_Wi81SnippetCase> _snippetCases() {
  final json =
      jsonDecode(File('$_notesDir/snippet_cases.json').readAsStringSync())
          as Map<String, Object?>;
  return [
    for (final c in json['cases']! as List<Object?>)
      (
        name: (c! as Map<String, Object?>)['name']! as String,
        contentMd: (c as Map<String, Object?>)['content_md']! as String,
        snippet: c['snippet']! as String,
      ),
  ];
}

/// The snippet `VaultDb.listNotes` gives a note holding [content].
String _listedSnippet(String content) {
  final db = FakeVaultDb.v5();
  addTearDown(db.close);
  db.db.execute(
    'INSERT INTO notes (id, title, content_md, version, created_at, updated_at) '
    "VALUES ('wi81-note', 'Wi81', ?, 1, 1, 1)",
    [content],
  );
  return db.listNotes().single.snippet;
}

bool _isHighSurrogate(int unit) => unit >= 0xD800 && unit <= 0xDBFF;

bool _hasLoneSurrogate(String s) {
  for (var i = 0; i < s.length; i++) {
    final u = s.codeUnitAt(i);
    if (_isHighSurrogate(u)) {
      if (i + 1 >= s.length) return true;
      final next = s.codeUnitAt(i + 1);
      if (next < 0xDC00 || next > 0xDFFF) return true;
      i++;
    } else if (u >= 0xDC00 && u <= 0xDFFF) {
      return true;
    }
  }
  return false;
}

void main() {
  test('local listNotes gives every shared snippet case its snippet', () {
    final cases = _snippetCases();
    expect(cases.length, greaterThanOrEqualTo(20));
    final drift = <String>[
      for (final c in cases)
        if (_listedSnippet(c.contentMd) != c.snippet)
          '${c.name}: want ${jsonEncode(c.snippet)}, '
              'got ${jsonEncode(_listedSnippet(c.contentMd))}',
    ];
    expect(drift, isEmpty);
  });

  test('a cut that would split a surrogate pair backs off to 116 units', () {
    final line = '${'g' * 116}\u{1F3B2}${'i' * 10}';
    expect(_isHighSurrogate(line.codeUnitAt(116)), isTrue);
    final snippet = _listedSnippet('$line\n');
    expect(snippet, '${'g' * 116}…');
    expect(snippet.length, 117);
    expect(_hasLoneSurrogate(snippet), isFalse);
  });

  test('61 emoji back off to 58 whole emoji', () {
    final snippet = _listedSnippet('\u{1F3B2}' * 61);
    expect(snippet, '${'\u{1F3B2}' * 58}…');
    expect(_hasLoneSurrogate(snippet), isFalse);
  });

  test('a surrogate pair fully before the cut keeps the 117 unit cut', () {
    // The pair is units 115-116: the 117-unit cut lands right after it.
    final snippet = _listedSnippet('${'j' * 115}\u{1F3B2}${'k' * 10}\n');
    expect(snippet, '${'j' * 115}\u{1F3B2}…');
    expect(snippet.length, 118);
    // A pair at the start never moves the cut either.
    expect(_listedSnippet('\u{1F3B2}${'l' * 130}'), '\u{1F3B2}${'l' * 115}…');
  });

  test('cuts without a surrogate at unit 116 are unchanged', () {
    expect(_listedSnippet('${'b' * 121}\n'), '${'b' * 117}…');
    expect(_listedSnippet('${'a' * 120}\n'), 'a' * 120);
    expect(_listedSnippet('${'d' * 116} ${'e' * 10}'), '${'d' * 116}…');
    expect(_listedSnippet('# Player Loop\n\nExplore.\n'), 'Player Loop');
  });

  test('local listNotes on the seed equals the parsed list_notes fixture', () {
    final db = seededFakeVaultDb();
    addTearDown(db.close);
    for (final (file, limit) in [
      ('list_notes.json', 200),
      ('list_notes_limit_3.json', 3),
    ]) {
      final fixture =
          jsonDecode(File('$_notesDir/$file').readAsStringSync())
              as Map<String, Object?>;
      final want = [
        for (final n in fixture['notes']! as List<Object?>)
          {
            'id': (n! as Map<String, Object?>)['id'],
            'title': (n as Map<String, Object?>)['title'],
            'snippet': n['snippet'],
            'version': n['version'],
            'updated_at': n['updated_at'],
          },
      ];
      final got = [
        for (final n in db.listNotes(limit: limit))
          {
            'id': n.id,
            'title': n.title,
            'snippet': n.snippet,
            'version': n.version,
            'updated_at': n.updatedAt,
          },
      ];
      expect(got, want, reason: file);
    }
  });

  test('the seed Pacing Notes snippet is the backed off cut', () {
    final db = seededFakeVaultDb();
    addTearDown(db.close);
    final pacing = db
        .listNotes(limit: 1000000)
        .singleWhere((n) => n.title == 'Pacing Notes');
    final line = db.getNote(pacing.id)!.contentMd.split('\n').first;
    expect(_isHighSurrogate(line.codeUnitAt(116)), isTrue);
    expect(pacing.snippet, '${line.substring(0, 116).trim()}…');
    expect(pacing.snippet.endsWith('a die…'), isTrue);
    expect(_hasLoneSurrogate(pacing.snippet), isFalse);
  });

  test('VaultDb listNotes still orders by updated_at and honours limit', () {
    final db = FakeVaultDb.v5();
    addTearDown(db.close);
    for (final (id, at) in [('n1', 10), ('n2', 30), ('n3', 20)]) {
      db.db.execute(
        'INSERT INTO notes (id, title, content_md, version, created_at, updated_at) '
        'VALUES (?, ?, ?, 1, ?, ?)',
        [id, 'T $id', 'Body $id', at, at],
      );
    }
    expect(db.listNotes(limit: 2).map((n) => n.id).toList(), ['n2', 'n3']);
    expect(db.listNotes().map((n) => n.snippet).toList(), [
      'Body n2',
      'Body n3',
      'Body n1',
    ]);
    // The type the snippet lives on is unchanged.
    expect(db.listNotes().first, isA<NoteListItem>());
  });
}
