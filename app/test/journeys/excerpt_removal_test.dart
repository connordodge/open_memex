// WI #27 (A9) robot journey (Spec TS4): excerpt card removal calls the remove
// path. FakeMemexCli's `excerpt rm` handler (ExcerptCliFakes) stands in for
// the server: it deletes the token line from the topic note in FakeVaultDb
// and answers the C2.4 shape with the note's new version.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/vault_state.dart';

import '../robots/segmented_editor_robot.dart';
import '../support/excerpt_cli_fakes.dart';

void main() {
  group('excerpt removal journey (AC5, AC6)', () {
    testWidgets(
      'excerpt card removal calls the remove path and the card disappears',
      (tester) async {
        final vault = seedSegmentedVault();
        final r = await launchSegmented(tester, vault: vault);
        await r.open(fixtureTopicId);
        expect(
          r.textIn(r.card(1), 'Fixed the jump arc.\n- tried coyote time'),
          findsWidgets,
        );

        await r.tapRemove(1);

        expect(r.excerptRms, hasLength(1));
        expect(r.excerptRms.single.args, [
          'excerpt',
          'rm',
          '--vault',
          r.h.vaultPath,
          '--topic-note-id',
          fixtureTopicId,
          '--date',
          '2026-09-05',
          '--block-ids',
          'b7k2m9,c3d4e5',
        ]);
        expect(r.allCards, findsNothing);
        expect(r.cardRemove(1), findsNothing);
        expect(r.inlineError, findsNothing);
        // The server removed the token line; the editor shows the same body.
        await r.toggleSource();
        expect(r.sourceText, 'Intro line\nOutro line\n');
      },
    );

    testWidgets(
      'after removing an excerpt the next edit saves against the version excerpt rm returned',
      (tester) async {
        // Seeded at version 4; the fake server answers version 6 so the
        // editor must take the returned version, not guess it.
        final vault = seedSegmentedVault(topicVersion: 4, rmVersion: 6);
        final r = await launchSegmented(tester, vault: vault);
        await r.open(fixtureTopicId);
        await r.tapRemove(1);
        expect(r.allCards, findsNothing);

        await r.typeInSegment(0, '${r.segmentText(0)}more words\n');
        await r.waitForSave();

        expect(r.updates, hasLength(1));
        final update = r.updates.single;
        expect(update.flag('expected-version'), '6');
        expect(update.stdinBody, isNot(contains('![[')));
        expect(update.stdinBody, contains('more words'));
        expect(update.stdinBody, contains('Outro line'));
        // The fake update accepted it (no version conflict).
        final stored = vault.db.db.select(
          'SELECT version, content_md FROM notes WHERE id = ?',
          [fixtureTopicId],
        ).single;
        expect(stored['version'], 7);
        expect(stored['content_md'], update.stdinBody);
      },
    );

    testWidgets('removing an excerpt bumps the vault revision', (tester) async {
      final r = await launchSegmented(tester, vault: seedSegmentedVault());
      await r.open(fixtureTopicId);
      final before = r.h.read(vaultRevisionProvider);

      await r.tapRemove(1);

      expect(r.h.read(vaultRevisionProvider), greaterThan(before));
    });

    testWidgets(
      'a failed excerpt removal keeps the card and shows a dismissible inline error',
      (tester) async {
        final vault = seedSegmentedVault();
        vault.cli.onExcerptRmFails('invalid_date', 'invalid date: 2026-09-05');
        final r = await launchSegmented(tester, vault: vault);
        await r.open(fixtureTopicId);
        final revision = r.h.read(vaultRevisionProvider);

        await r.tapRemove(1);

        expect(r.card(1), findsOneWidget);
        expect(r.inlineError, findsOneWidget);
        expect(
          find.descendant(
            of: r.inlineError,
            matching: find.textContaining('invalid date: 2026-09-05'),
          ),
          findsOneWidget,
        );
        expect(r.h.read(vaultRevisionProvider), revision);

        await tester.tap(
          find.descendant(of: r.inlineError, matching: r.inlineErrorDismiss),
        );
        await r.waitForSave();
        expect(r.inlineError, findsNothing);
        expect(r.card(1), findsOneWidget);
        expect(r.updates, isEmpty);
      },
    );
  });
}
