// WI #27 (A9) AC1: the pure excerpt render function (contracts C4 render
// rule, D13). Same fixtures as the #9 Rust test.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/excerpt_render.dart';
import 'package:open_memex_app/src/editor/segments.dart';

import '../support/daily_seed.dart';
import '../support/fake_vault_db.dart';

const _dailyId = 'daily-2026-09-05';

/// The C4 render fixture: daily note `2026-09-05` with blocks (ord, id, text)
/// (0, b7k2m9, `Fixed the jump arc.`), (1, c3d4e5, `- tried coyote time`),
/// (2, f6g7h8, `Sleep was bad.`).
FakeVaultDb _fixtureDb() {
  final db = FakeVaultDb.v5();
  addTearDown(db.close);
  db.seedDailyNote('2026-09-05', id: _dailyId);
  db.seedBlock(_dailyId, 'b7k2m9', ord: 0, text: 'Fixed the jump arc.');
  db.seedBlock(_dailyId, 'c3d4e5', ord: 1, text: '- tried coyote time');
  db.seedBlock(_dailyId, 'f6g7h8', ord: 2, text: 'Sleep was bad.');
  return db;
}

/// Parse [token] with #20's parser (D13: one parser) and render it.
RenderedExcerpt _render(FakeVaultDb db, String token) {
  final parsed = parseTransclusions(token);
  expect(parsed, hasLength(1), reason: 'fixture token must parse: $token');
  final t = parsed.single;
  return renderExcerpt(db, date: t.date, from: t.from, to: t.to);
}

void main() {
  group('renderExcerpt C4 fixtures (AC1)', () {
    test('X1 a single block token renders that block text', () {
      final r = _render(_fixtureDb(), '![[2026-09-05#^b7k2m9]]');
      expect(r.text, 'Fixed the jump arc.');
      expect(r.removed, isFalse);
      expect(r.date, '2026-09-05');
    });

    test('X2 a range token renders both blocks joined with a newline', () {
      final r = _render(_fixtureDb(), '![[2026-09-05#^b7k2m9..^c3d4e5]]');
      expect(r.text, 'Fixed the jump arc.\n- tried coyote time');
      expect(r.removed, isFalse);
    });

    test('X3 a missing single block renders the removed stub', () {
      final r = _render(_fixtureDb(), '![[2026-09-05#^zzzzzz]]');
      expect(r.text, 'removed from 2026-09-05');
      expect(r.removed, isTrue);
      expect(r.date, '2026-09-05');
    });

    test('X4 a range with a missing end block renders the removed stub', () {
      final r = _render(_fixtureDb(), '![[2026-09-05#^b7k2m9..^zzzzzz]]');
      expect(r.text, 'removed from 2026-09-05');
      expect(r.removed, isTrue);
    });

    test(
      'X5 a token whose date has no daily note renders the removed stub',
      () {
        final r = _render(_fixtureDb(), '![[2026-09-06#^b7k2m9]]');
        expect(r.text, 'removed from 2026-09-06');
        expect(r.removed, isTrue);
        expect(r.date, '2026-09-06');
      },
    );
  });

  group('renderExcerpt edges (AC1)', () {
    test('a range with a missing start block renders the removed stub', () {
      final r = _render(_fixtureDb(), '![[2026-09-05#^zzzzzz..^c3d4e5]]');
      expect(r.text, 'removed from 2026-09-05');
      expect(r.removed, isTrue);
    });

    test('a reversed range renders the blocks in ord order', () {
      final r = _render(_fixtureDb(), '![[2026-09-05#^f6g7h8..^b7k2m9]]');
      expect(
        r.text,
        'Fixed the jump arc.\n- tried coyote time\nSleep was bad.',
      );
      expect(r.removed, isFalse);
    });

    test('a range over all three blocks includes both endpoints', () {
      final r = _render(_fixtureDb(), '![[2026-09-05#^b7k2m9..^f6g7h8]]');
      expect(
        r.text,
        'Fixed the jump arc.\n- tried coyote time\nSleep was bad.',
      );
    });

    test('a range of the two last blocks leaves out the first block', () {
      final r = _render(_fixtureDb(), '![[2026-09-05#^c3d4e5..^f6g7h8]]');
      expect(r.text, '- tried coyote time\nSleep was bad.');
    });

    test('a single block in the middle renders only that block', () {
      final r = _render(_fixtureDb(), '![[2026-09-05#^c3d4e5]]');
      expect(r.text, '- tried coyote time');
    });

    test('a range whose endpoints are the same block renders one block', () {
      final r = _render(_fixtureDb(), '![[2026-09-05#^c3d4e5..^c3d4e5]]');
      expect(r.text, '- tried coyote time');
      expect(r.removed, isFalse);
    });

    test('blocks of another daily note are never included', () {
      final db = _fixtureDb();
      db.seedDailyNote('2026-09-04', id: 'daily-2026-09-04');
      db.seedBlock('daily-2026-09-04', 'a1a1a1', ord: 0, text: 'Other day 0');
      db.seedBlock('daily-2026-09-04', 'a2a2a2', ord: 1, text: 'Other day 1');
      final r = _render(db, '![[2026-09-05#^b7k2m9..^c3d4e5]]');
      expect(r.text, 'Fixed the jump arc.\n- tried coyote time');
    });

    test(
      'an endpoint id that only exists on another day renders the removed stub',
      () {
        final db = _fixtureDb();
        db.seedDailyNote('2026-09-04', id: 'daily-2026-09-04');
        db.seedBlock('daily-2026-09-04', 'q9q9q9', ord: 5, text: 'Elsewhere');
        final r = _render(db, '![[2026-09-05#^b7k2m9..^q9q9q9]]');
        expect(r.text, 'removed from 2026-09-05');
        expect(r.removed, isTrue);
      },
    );

    test(
      'a note titled with the date that is not role daily renders the removed stub',
      () {
        final db = FakeVaultDb.v5();
        addTearDown(db.close);
        db.seedNote(id: 'plain-0907', title: '2026-09-07', role: 'topic');
        db.seedBlock('plain-0907', 'b7k2m9', ord: 0, text: 'Not a daily block');
        final r = _render(db, '![[2026-09-07#^b7k2m9]]');
        expect(r.text, 'removed from 2026-09-07');
        expect(r.removed, isTrue);
      },
    );

    test('multi-byte block text renders unchanged', () {
      final db = FakeVaultDb.v5();
      addTearDown(db.close);
      db.seedDailyNote('2026-09-08', id: 'daily-2026-09-08');
      db.seedBlock('daily-2026-09-08', 'e1e1e1', ord: 0, text: 'Café crème ☕');
      db.seedBlock('daily-2026-09-08', 'e2e2e2', ord: 1, text: 'naïve 🎉 jump');
      final r = _render(db, '![[2026-09-08#^e1e1e1..^e2e2e2]]');
      expect(r.text, 'Café crème ☕\nnaïve 🎉 jump');
    });

    test('a vault below V5 renders the removed stub without throwing', () {
      final db = FakeVaultDb.v4();
      addTearDown(db.close);
      final r = _render(db, '![[2026-09-05#^b7k2m9]]');
      expect(r.text, 'removed from 2026-09-05');
      expect(r.removed, isTrue);
    });
  });
}
