// WI #259 (F7) AC8: the Feedback providers read through VaultAccess.feedback,
// stamped with the vault (D14a), re-read on every vaultRevisionProvider bump
// and return empty below V6 (vaultV6ReadyProvider, D6). A write through the
// seam (feedbackActionsProvider) bumps the revision once, after the write
// returns.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/db/feedback_reads.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/feedback_state.dart';
import 'package:open_memex_app/src/state/vault_access_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/vault_access/local/local_vault_access.dart';
import 'package:open_memex_app/src/vault_access/vault_scoped.dart';

import '../support/fake_clock.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/feedback_cli_fakes.dart';
import '../support/feedback_seeds.dart';
import '../support/topics_access_doubles.dart';
import '../support/vault_access_shapes.dart';

const _vaultA = LocalVaultRef('/tmp/om-259-vault-a');
const _hosted = HostedVaultRef('server-1', 'seed');

ProviderContainer _container({
  required VaultRef? vault,
  VaultDb? db,
  MemexCli? cli,
  AccessDoubles? doubles,
  List<Override> extra = const [],
}) {
  final c = ProviderContainer(
    overrides: [
      currentVaultProvider.overrideWith((_) => vault),
      vaultDbProvider.overrideWithValue(db),
      memexCliProvider.overrideWithValue(cli),
      clockProvider.overrideWithValue(FakeClock()),
      if (doubles != null) doubles.override,
      ...extra,
    ],
  );
  addTearDown(c.dispose);
  return c;
}

FakeVaultDb _v6() {
  final db = FakeVaultDb.v6();
  addTearDown(db.close);
  return db;
}

FakeVaultDb _v5() {
  final db = FakeVaultDb.v5Only();
  addTearDown(db.close);
  return db;
}

void _bump(ProviderContainer c) =>
    c.read(vaultRevisionProvider.notifier).state++;

List<String> _ids(List<FeedbackRow> rows) => [for (final r in rows) r.id];

/// A feedback double that answers canned rows without a database, to stand
/// in for the hosted composite (a hosted vault has no database).
class _Wi259CannedFeedback extends LocalFeedbackAccess {
  _Wi259CannedFeedback() : super(vaultPath: '/unused/wi259');

  int reads = 0;

  @override
  Future<List<FeedbackRow>> feedbackForNote(String noteId) async {
    reads++;
    return [
      FeedbackRow(
        id: 'hosted-$noteId',
        kind: FeedbackKind.comment,
        source: FeedbackSource.person,
        status: FeedbackStatus.open,
        createdAt: 1,
        updatedAt: 1,
      ),
    ];
  }
}

void main() {
  group('providers', () {
    test(
      'feedbackForNoteProvider yields the note rows newest first stamped with the current vault',
      () async {
        final db = _v6();
        db.seedFeedback('fb-old', noteId: 'N1', createdAt: 1000);
        db.seedFeedback('fb-new', noteId: 'N1', createdAt: 2000);
        db.seedFeedback('fb-other', noteId: 'N2', createdAt: 3000);
        final c = _container(vault: _vaultA, db: db);

        final scoped = await c.read(feedbackForNoteProvider('N1').future);

        expect(scoped.vault, _vaultA);
        expect(_ids(scoped.value), ['fb-new', 'fb-old']);
      },
    );

    test(
      'feedbackWithoutNoteProvider yields the no-note rows and the deleted note tag corrections',
      () async {
        final db = _v6();
        db.seedFeedback('fb-none', createdAt: 1000);
        db.seedFeedback('fb-noted', noteId: 'N1', createdAt: 2000);
        final tag = db.seedTagCorrection(noteTitle: 'Gone', createdAt: 3000);
        final c = _container(vault: _vaultA, db: db);

        final scoped = await c.read(feedbackWithoutNoteProvider.future);

        expect(scoped.vault, _vaultA);
        expect(_ids(scoped.value), ['tag-$tag', 'fb-none']);
      },
    );

    test(
      'guideRevisionsProvider yields the guide revisions newest first stamped with the current vault',
      () async {
        final db = _v6();
        db.seedGuideRevision('rev-old', createdAt: 1000);
        db.seedGuideRevision('rev-new', createdAt: 2000);
        final c = _container(vault: _vaultA, db: db);

        final scoped = await c.read(guideRevisionsProvider.future);

        expect(scoped.vault, _vaultA);
        expect(scoped.value.map((r) => r.id).toList(), ['rev-new', 'rev-old']);
      },
    );

    test(
      'filingProvider yields the Filing of the date through the CLI stamped with the current vault',
      () async {
        final cli = feedbackSampleCli();
        final c = _container(vault: _vaultA, db: _v6(), cli: cli);

        final scoped = await c.read(filingProvider('2026-11-05').future);

        expect(scoped.vault, _vaultA);
        expect(vaultAccessShape(scoped.value), filingShape);
        expect(cli.callsFor('filing').single.flag('date'), '2026-11-05');
      },
    );

    test('the providers re-read after a vault revision bump', () async {
      final db = _v6();
      final cli = feedbackSampleCli();
      final c = _container(vault: _vaultA, db: db, cli: cli);
      expect(
        (await c.read(feedbackForNoteProvider('N1').future)).value,
        isEmpty,
      );
      expect((await c.read(feedbackWithoutNoteProvider.future)).value, isEmpty);
      expect((await c.read(guideRevisionsProvider.future)).value, isEmpty);
      await c.read(filingProvider('2026-11-05').future);

      db.seedFeedback('fb-1', noteId: 'N1');
      db.seedFeedback('fb-2');
      db.seedGuideRevision('rev-1');
      _bump(c);

      expect(_ids((await c.read(feedbackForNoteProvider('N1').future)).value), [
        'fb-1',
      ]);
      expect(_ids((await c.read(feedbackWithoutNoteProvider.future)).value), [
        'fb-2',
      ]);
      expect(
        (await c.read(guideRevisionsProvider.future)).value.single.id,
        'rev-1',
      );
      await c.read(filingProvider('2026-11-05').future);
      expect(cli.callsFor('filing'), hasLength(2));
    });

    test(
      'the providers are empty and stamped below V6 without reaching the feedback access, then read the rows once the vault migrates to V6',
      () async {
        final db = _v5();
        final doubles = AccessDoubles();
        final cli = feedbackSampleCli();
        final c = _container(
          vault: _vaultA,
          db: db,
          cli: cli,
          doubles: doubles,
        );

        final forNote = await c.read(feedbackForNoteProvider('N1').future);
        final without = await c.read(feedbackWithoutNoteProvider.future);
        final revisions = await c.read(guideRevisionsProvider.future);
        final filing = await c.read(filingProvider('2026-11-05').future);

        expect(forNote.value, isEmpty);
        expect(without.value, isEmpty);
        expect(revisions.value, isEmpty);
        expect(filing.value, isNull);
        for (final vault in [
          forNote.vault,
          without.vault,
          revisions.vault,
          filing.vault,
        ]) {
          expect(vault, _vaultA, reason: 'empty results are stamped too');
        }
        expect(
          doubles.feedback[_vaultA.path]?.calls ?? const [],
          isEmpty,
          reason: 'the V6 gate runs first',
        );
        expect(cli.callsFor('filing'), isEmpty);

        db.migrateToV6();
        db.seedFeedback('fb-1', noteId: 'N1');
        db.seedFeedback('fb-2');
        db.seedGuideRevision('rev-1');
        _bump(c);

        expect(
          _ids((await c.read(feedbackForNoteProvider('N1').future)).value),
          ['fb-1'],
        );
        expect(_ids((await c.read(feedbackWithoutNoteProvider.future)).value), [
          'fb-2',
        ]);
        expect(
          (await c.read(guideRevisionsProvider.future)).value.single.id,
          'rev-1',
        );
        expect(
          (await c.read(filingProvider('2026-11-05').future)).value,
          isNotNull,
        );
        expect(cli.callsFor('filing'), hasLength(1));
        expect(doubles.feedbackAt(_vaultA.path).calls, isNotEmpty);
      },
    );

    test(
      'the providers are empty and stamped with no vault when none is open, then read once a vault opens',
      () async {
        final db = _v6();
        db.seedFeedback('fb-1', noteId: 'N1');
        final c = _container(vault: null, db: db, cli: feedbackSampleCli());

        final forNote = await c.read(feedbackForNoteProvider('N1').future);
        final without = await c.read(feedbackWithoutNoteProvider.future);
        final revisions = await c.read(guideRevisionsProvider.future);
        final filing = await c.read(filingProvider('2026-11-05').future);

        expect(forNote.value, isEmpty);
        expect(without.value, isEmpty);
        expect(revisions.value, isEmpty);
        expect(filing.value, isNull);
        for (final vault in [
          forNote.vault,
          without.vault,
          revisions.vault,
          filing.vault,
        ]) {
          expect(vault, isNull);
        }

        c.read(currentVaultProvider.notifier).state = _vaultA;
        final opened = await c.read(feedbackForNoteProvider('N1').future);

        expect(opened.vault, _vaultA);
        expect(_ids(opened.value), ['fb-1']);
      },
    );

    test(
      'a hosted vault reads through its access without a local database',
      () async {
        final canned = _Wi259CannedFeedback();
        final c = _container(
          vault: _hosted,
          extra: [
            vaultAccessProvider.overrideWith(
              (_) => LocalVaultAccess(
                vaultPath: '/unused/wi259',
                feedback: canned,
              ),
            ),
          ],
        );

        final scoped = await c.read(feedbackForNoteProvider('N1').future);

        expect(scoped.vault, _hosted);
        expect(_ids(scoped.value), ['hosted-N1']);
        expect(canned.reads, 1);
      },
    );

    test('feedbackForNoteProvider keeps one read per note id', () async {
      final db = _v6();
      db.seedFeedback('fb-1', noteId: 'N1');
      db.seedFeedback('fb-2', noteId: 'N2');
      final c = _container(vault: _vaultA, db: db);

      final one = await c.read(feedbackForNoteProvider('N1').future);
      final two = await c.read(feedbackForNoteProvider('N2').future);

      expect(_ids(one.value), ['fb-1']);
      expect(_ids(two.value), ['fb-2']);
    });

    test(
      'the providers switch to the other vault rows and never show the previous vault rows',
      () async {
        final dbA = _v6();
        dbA.seedFeedback('from-a', noteId: 'N1');
        final dbB = _v6();
        dbB.seedFeedback('from-b', noteId: 'N1');
        const vaultB = LocalVaultRef('/tmp/om-259-vault-b');
        final c = _container(
          vault: _vaultA,
          extra: [
            vaultDbProvider.overrideWith(
              (ref) => ref.watch(currentVaultProvider) == _vaultA ? dbA : dbB,
            ),
          ],
        );
        final first = await c.read(feedbackForNoteProvider('N1').future);
        expect(_ids(first.value), ['from-a']);

        c.read(currentVaultProvider.notifier).state = vaultB;
        final second = await c.read(feedbackForNoteProvider('N1').future);

        expect(second.vault, vaultB);
        expect(_ids(second.value), ['from-b']);
        expect(
          currentVaultData(
            c.read(feedbackForNoteProvider('N1')),
            vaultB,
          )?.value,
          isNotNull,
        );
      },
    );
  });

  group('writes through the seam', () {
    /// Every write of [FeedbackActions] with the CLI subcommand it runs.
    final writes =
        <(String, String, Future<Object?> Function(FeedbackActions))>[
          (
            'fileBlock',
            'excerpt add',
            (a) => a.fileBlock(
              topicNoteId: 'T1',
              date: '2026-11-05',
              blockId: 'b1',
              note: 'n',
            ),
          ),
          (
            'moveBlock',
            'excerpt move',
            (a) => a.moveBlock(
              fromTopicNoteId: 'A1',
              toTopicNoteId: 'C1',
              date: '2026-11-05',
              blockId: 'b1',
            ),
          ),
          (
            'removeBlock',
            'excerpt remove-block',
            (a) => a.removeBlock(
              topicNoteId: 'T1',
              date: '2026-11-05',
              blockId: 'b1',
            ),
          ),
          (
            'addComment',
            'feedback add',
            (a) => a.addComment(
              noteId: 'N1',
              date: '2026-11-05',
              changeId: 'C1',
              text: 't',
            ),
          ),
          (
            'editComment',
            'feedback edit',
            (a) => a.editComment(id: 'F1', text: 't'),
          ),
          ('deleteComment', 'feedback rm', (a) => a.deleteComment(id: 'F1')),
          ('restoreGuide', 'guide restore', (a) => a.restoreGuide('R1')),
        ];

    test(
      'every write runs its CLI command through the access and bumps the revision exactly once',
      () async {
        for (final (name, sub, call) in writes) {
          final cli = feedbackSampleCli();
          final c = _container(vault: _vaultA, db: _v6(), cli: cli);
          final bumps = <int>[];
          c.listen(vaultRevisionProvider, (_, n) => bumps.add(n));

          await call(c.read(feedbackActionsProvider));

          expect(cli.callsFor(sub), hasLength(1), reason: name);
          expect(bumps, [1], reason: '$name: one bump');
          expect(c.read(vaultRevisionProvider), 1, reason: name);
        }
      },
    );

    test('every write returns the result of the access call', () async {
      final cli = feedbackSampleCli();
      final c = _container(vault: _vaultA, db: _v6(), cli: cli);
      final actions = c.read(feedbackActionsProvider);

      expect(
        vaultAccessShape(
          await actions.fileBlock(
            topicNoteId: 'T1',
            date: '2026-11-05',
            blockId: 'b',
          ),
        ),
        {
          'ExcerptEditResult': ['V', 'T1', 4],
        },
      );
      expect(
        vaultAccessShape(
          await actions.removeBlock(
            topicNoteId: 'T1',
            date: '2026-11-05',
            blockId: 'b',
          ),
        ),
        {
          'ExcerptEditResult': ['V', 'T1', 5],
        },
      );
      expect(
        vaultAccessShape(
          await actions.moveBlock(
            fromTopicNoteId: 'A1',
            toTopicNoteId: 'C1',
            date: '2026-11-05',
            blockId: 'b',
          ),
        ),
        {
          'ExcerptMoveResult': ['V', 'A1', 2, 'C1', 3],
        },
      );
      expect(
        (await actions.addComment(
          noteId: 'N1',
          date: '2026-11-05',
          changeId: 'C',
          text: 't',
        )).id,
        'FA',
      );
      expect((await actions.editComment(id: 'F', text: 't')).id, 'FE');
      expect(vaultAccessShape(await actions.deleteComment(id: 'F')), {
        'FeedbackRemoveResult': ['V', 'FR'],
      });
      expect(vaultAccessShape(await actions.restoreGuide('R1')), {
        'GuideRestoreResult': ['V', 'G', 9],
      });
    });

    test(
      'a write does not bump the revision until the write returns',
      () async {
        final doubles = AccessDoubles(
          configureFeedback: (_, f) => f.gate('addComment'),
        );
        final cli = feedbackSampleCli();
        final c = _container(
          vault: _vaultA,
          db: _v6(),
          cli: cli,
          doubles: doubles,
        );
        final bumps = <int>[];
        c.listen(vaultRevisionProvider, (_, n) => bumps.add(n));

        final pending = c
            .read(feedbackActionsProvider)
            .addComment(
              noteId: 'N1',
              date: '2026-11-05',
              changeId: 'C1',
              text: 't',
            );
        await pumpEventQueue();

        expect(doubles.feedback, contains(_vaultA.path));
        final feedback = doubles.feedbackAt(_vaultA.path);
        expect(feedback.callsTo('addComment'), hasLength(1));
        expect(bumps, isEmpty, reason: 'the write is still in flight');
        expect(cli.callsFor('feedback add'), isEmpty);

        feedback.gates['addComment']!.single.complete();
        await pending;

        expect(cli.callsFor('feedback add'), hasLength(1));
        expect(bumps, [1]);
      },
    );

    test(
      'a failed write rethrows its MemexException and bumps the revision once so reads refresh',
      () async {
        final cli = feedbackSampleCli()
          ..on(
            'feedback edit',
            (_) => FakeMemexCli.error('feedback_handled', 'already handled'),
          );
        final c = _container(vault: _vaultA, db: _v6(), cli: cli);
        final bumps = <int>[];
        c.listen(vaultRevisionProvider, (_, n) => bumps.add(n));

        await expectLater(
          c.read(feedbackActionsProvider).editComment(id: 'F1', text: 't'),
          throwsA(
            isA<MemexException>().having(
              (e) => e.code,
              'code',
              'feedback_handled',
            ),
          ),
        );

        expect(bumps, [1]);
      },
    );

    test(
      'a write with no CLI throws StateError and does not bump the revision',
      () async {
        final c = _container(vault: _vaultA, db: _v6());
        final bumps = <int>[];
        c.listen(vaultRevisionProvider, (_, n) => bumps.add(n));

        await expectLater(
          () => c
              .read(feedbackActionsProvider)
              .addComment(
                noteId: 'N1',
                date: '2026-11-05',
                changeId: 'C1',
                text: 't',
              ),
          throwsA(isA<StateError>()),
        );

        expect(bumps, isEmpty);
      },
    );

    test(
      'a write with no open vault throws StateError and does not bump the revision',
      () async {
        final c = _container(vault: null);
        final bumps = <int>[];
        c.listen(vaultRevisionProvider, (_, n) => bumps.add(n));

        await expectLater(
          () => c.read(feedbackActionsProvider).deleteComment(id: 'F1'),
          throwsA(isA<StateError>()),
        );

        expect(bumps, isEmpty);
      },
    );

    test(
      'a comment written through the seam shows in the provider after the bump',
      () async {
        final db = _v6();
        final cli = feedbackSampleCli()
          ..on('feedback add', (call) {
            db.seedFeedback(
              'FA',
              noteId: call.flag('note-id'),
              text: call.flag('text'),
              createdAt: 5000,
            );
            return FakeMemexCli.ok(
              '{"id":"FA","kind":"comment","source":"person","note_id":"N1",'
              '"day":"2026-11-05","agent_change_id":"C1","text":"mine",'
              '"correction":null,"status":"open","reply":null,'
              '"created_at":5000,"updated_at":5000,"handled_at":null}\n',
            );
          });
        final c = _container(vault: _vaultA, db: db, cli: cli);
        c.listen(feedbackForNoteProvider('N1'), (_, _) {});
        expect(
          (await c.read(feedbackForNoteProvider('N1').future)).value,
          isEmpty,
        );

        await c
            .read(feedbackActionsProvider)
            .addComment(
              noteId: 'N1',
              date: '2026-11-05',
              changeId: 'C1',
              text: 'mine',
            );

        final rows = (await c.read(feedbackForNoteProvider('N1').future)).value;
        expect(_ids(rows), ['FA']);
        expect(rows.single.text, 'mine');
      },
    );
  });
}
