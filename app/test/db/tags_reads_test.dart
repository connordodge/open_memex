// WI #249 (A3): Note.footerTags, Note.visibleTags and TagsReads against a real
// schema (the app schema fixture, at V6, and FakeVaultDb.v5Only for V5).
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/db/tags_reads.dart';

import '../support/fake_vault_db.dart';
import '../support/tags_seed.dart';
import '../support/vault_access_shapes.dart';

const _a = '01J9V6000000000000000000A1';
const _b = '01J9V6000000000000000000B2';
const _c = '01J9V6000000000000000000C3';
const _d = '01J9V6000000000000000000D4';

FakeVaultDb _v6() {
  final db = FakeVaultDb.v6();
  addTearDown(db.close);
  return db;
}

Note _note(List<String> tags) => Note(
  id: _a,
  title: 'Plan',
  contentMd: '',
  frontmatter: '{}',
  version: 1,
  createdAt: 1,
  updatedAt: 1,
  tags: tags,
);

void main() {
  group('Note.footerTags', () {
    test(
      'getNote on a V6 vault returns tags and footerTags holding only non-body non-system tags',
      () {
        final db = _v6();
        db.seedNote(id: _a, title: 'Plan');
        db.seedNote(id: _b, title: 'Other');
        db.seedTag(_a, 'written', origin: 'body', firstLine: 'a #written line');
        db.seedTag(_a, 'by-agent', origin: 'agent');
        db.seedTag(_a, 'by-person', origin: 'person');
        db.seedTag(_a, 'inbox', origin: 'agent');
        db.seedTag(_a, 'agent-authored', origin: 'agent');
        db.seedTag(_b, 'someone-elses', origin: 'person');

        final note = db.getNote(_a)!;

        expect(note.tags, [
          'agent-authored',
          'by-agent',
          'by-person',
          'inbox',
          'written',
        ]);
        expect(note.footerTags, ['by-agent', 'by-person']);
      },
    );

    test('getNote footerTags drop a system tag whatever its origin', () {
      final db = _v6();
      db.seedNote(id: _a, title: 'Plan');
      db.seedTag(_a, 'inbox', origin: 'person');
      db.seedTag(_a, 'agent-authored', origin: 'person');
      db.seedTag(_a, 'kept', origin: 'person');

      expect(db.getNote(_a)!.footerTags, ['kept']);

      db.seedNote(id: _b, title: 'Written system tag');
      db.seedTag(_b, 'inbox', origin: 'body', firstLine: '#inbox');
      db.seedTag(_b, 'kept', origin: 'agent');
      expect(db.getNote(_b)!.footerTags, ['kept']);
    });

    test('getNote footerTags are ordered by tag whatever the insert order', () {
      final db = _v6();
      db.seedNote(id: _a, title: 'Plan');
      for (final tag in ['zeta', 'mid', 'alpha']) {
        db.seedTag(_a, tag, origin: 'agent');
      }

      expect(db.getNote(_a)!.footerTags, ['alpha', 'mid', 'zeta']);
    });

    test(
      'getNote on a V5 vault returns empty footerTags without throwing and reads them once the same handle migrates',
      () {
        final db = FakeVaultDb.v5Only();
        addTearDown(db.close);
        db.seedNote(id: _a, title: 'Plan', tags: ['work', 'inbox']);

        final v5 = db.getNote(_a)!;
        expect(v5.tags, ['inbox', 'work']);
        expect(v5.footerTags, isEmpty);

        // The V6 tables without the tags columns: still safe.
        db.migrateToV6(tagColumns: false);
        final partial = db.getNote(_a)!;
        expect(partial.tags, ['inbox', 'work']);
        expect(partial.footerTags, isEmpty);

        // The CLI migrates while the app holds this handle: never a cached no.
        db.migrateToV6();
        expect(db.getNote(_a)!.footerTags, ['work']);
      },
    );
  });

  group('Note.visibleTags', () {
    test(
      'visibleTags excludes inbox and agent-authored and keeps the rest',
      () {
        final note = _note([
          'agent-authored',
          'Inbox',
          'inbox',
          'work',
          'zeta',
        ]);

        expect(note.visibleTags, ['Inbox', 'work', 'zeta']);
        expect(note.footerTags, isEmpty, reason: 'optional, defaults to empty');
      },
    );
  });

  group('TagsReads.allTags', () {
    test(
      'allTags returns alphabetical rows with note counts and system against a real schema',
      () {
        final db = _v6();
        db.seedNote(id: _a, title: 'A');
        db.seedNote(id: _b, title: 'B');
        db.seedNote(id: _c, title: 'C');
        // Inserted out of order, with every origin counted.
        db.seedTag(_a, 'work', origin: 'body', firstLine: '#work');
        db.seedTag(_b, 'work', origin: 'person');
        db.seedTag(_c, 'inbox', origin: 'agent');
        db.seedTag(_b, 'inbox', origin: 'person');
        db.seedTag(_a, 'inbox', origin: 'body', firstLine: '#inbox');
        db.seedTag(_c, 'alpha', origin: 'agent');
        db.seedTag(_c, 'agent-authored', origin: 'agent');

        expect(vaultAccessShape(db.allTags()), [
          vaultAccessShape(
            const TagRow(tag: 'agent-authored', noteCount: 1, system: true),
          ),
          vaultAccessShape(
            const TagRow(tag: 'alpha', noteCount: 1, system: false),
          ),
          vaultAccessShape(
            const TagRow(tag: 'inbox', noteCount: 3, system: true),
          ),
          vaultAccessShape(
            const TagRow(tag: 'work', noteCount: 2, system: false),
          ),
        ]);
      },
    );
  });

  group('TagsReads.allTags ordering', () {
    test('allTags orders ignoring case and breaks a tie by exact tag', () {
      final db = _v6();
      db.seedNote(id: _a, title: 'A');
      db.seedNote(id: _b, title: 'B');
      for (final t in ['b', 'A', 'C', 'work']) {
        db.seedTag(_a, t);
      }
      db.seedTag(_b, 'Work');

      expect(db.allTags().map((r) => r.tag), ['A', 'b', 'C', 'Work', 'work']);
    });
  });

  group('TagsReads.notesForTag', () {
    test('notesForTag reads a role that is not a string as no role', () {
      final db = _v6();
      db.seedNote(id: _a, title: 'Num', frontmatter: '{"role":7}');
      db.seedNote(id: _b, title: 'Null', frontmatter: '{"role":null}');
      db.seedNote(id: _c, title: 'Flag', frontmatter: '{"role":true}');
      for (final id in [_a, _b, _c]) {
        db.seedTag(id, 'work');
      }

      expect(db.notesForTag('work'), hasLength(3));
      expect(db.notesForTag('work').map((r) => r.role), everyElement(isNull));
    });

    test(
      'notesForTag returns most recently updated first with first_line and a null first_line for a footer-only tag',
      () {
        final db = _v6();
        db.seedNote(id: _a, title: 'Oldest', updatedAt: 1000);
        db.seedNote(id: _b, title: 'Newest', updatedAt: 3000);
        db.seedNote(id: _c, title: 'Middle', updatedAt: 2000);
        db.seedTag(_a, 'work', origin: 'body', firstLine: 'old #work line');
        db.seedTag(_b, 'work', origin: 'agent');
        db.seedTag(_c, 'work', origin: 'body', firstLine: 'mid #work line');

        expect(vaultAccessShape(db.notesForTag('work')), [
          vaultAccessShape(
            const TagNoteRow(
              noteId: _b,
              title: 'Newest',
              role: null,
              firstLine: null,
              updatedAt: 3000,
            ),
          ),
          vaultAccessShape(
            const TagNoteRow(
              noteId: _c,
              title: 'Middle',
              role: null,
              firstLine: 'mid #work line',
              updatedAt: 2000,
            ),
          ),
          vaultAccessShape(
            const TagNoteRow(
              noteId: _a,
              title: 'Oldest',
              role: null,
              firstLine: 'old #work line',
              updatedAt: 1000,
            ),
          ),
        ]);
      },
    );

    test(
      'notesForTag carries the role and reads invalid frontmatter as no role',
      () {
        final db = _v6();
        db.seedNote(id: _a, title: 'Topic', role: 'topic', updatedAt: 4000);
        db.seedNote(id: _b, title: 'Daily', role: 'daily', updatedAt: 3000);
        db.seedNote(id: _c, title: 'Plain', updatedAt: 2000);
        db.seedNote(
          id: _d,
          title: 'Broken',
          frontmatter: 'not json {',
          updatedAt: 1000,
        );
        for (final id in [_a, _b, _c, _d]) {
          db.seedTag(id, 'work');
        }

        expect(
          [
            for (final r in db.notesForTag('work')) [r.title, r.role],
          ],
          [
            ['Topic', 'topic'],
            ['Daily', 'daily'],
            ['Plain', null],
            ['Broken', null],
          ],
        );
      },
    );

    test('notesForTag matches the exact tag only', () {
      final db = _v6();
      db.seedNote(id: _a, title: 'Exact');
      db.seedNote(id: _b, title: 'Longer');
      db.seedNote(id: _c, title: 'Cased');
      db.seedTag(_a, 'work');
      db.seedTag(_b, 'work-log');
      db.seedTag(_c, 'Work');

      expect(db.notesForTag('work').map((r) => r.noteId), [_a]);
      expect(db.notesForTag('Work').map((r) => r.noteId), [_c]);
      expect(db.notesForTag('wor%'), isEmpty);
      expect(db.notesForTag("work' OR '1'='1"), isEmpty);
      expect(db.notesForTag('none'), isEmpty);
    });
  });

  group('below V6', () {
    test(
      'allTags and notesForTag are empty below V6 and read the rows once the same handle migrates',
      () {
        final db = FakeVaultDb.v5Only();
        addTearDown(db.close);
        db.seedNote(id: _a, title: 'Plan', tags: ['work']);

        expect(db.allTags(), isEmpty);
        expect(db.notesForTag('work'), isEmpty);

        // The V6 tables without the tags columns: not ready either.
        db.migrateToV6(tagColumns: false);
        expect(db.allTags(), isEmpty);
        expect(db.notesForTag('work'), isEmpty);

        db.migrateToV6();
        expect(db.allTags().map((r) => r.tag), ['work']);
        expect(db.notesForTag('work').map((r) => r.noteId), [_a]);
      },
    );
  });
}
