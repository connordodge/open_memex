// WI #253 (A5): the × on a footer tag. It shows on hover or keyboard focus in a
// permanently reserved slot, removes through `memex tag rm`, and the tag stays
// until the write returns. Writes are held on a Completer in the fake CLI, so
// nothing here waits on wall-clock time.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/state/editor_controller.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/vault_access_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/vault_access/errors.dart';
import 'package:open_memex_app/src/vault_access/local/local_vault_access.dart';

import '../robots/segmented_editor_robot.dart';
import '../support/app_harness.dart';
import '../support/fake_memex_cli.dart';
import '../support/note_footer_harness.dart';
import '../support/tags_seed.dart';

const _tags = ['memex', 'pricing'];
const _unreachableCopy =
    "Couldn't remove #pricing. The vault server didn't answer.";

final String _body = footerBody(footerPerson, tags: _tags);

/// A note with footer tags `memex` and `pricing` and their footer text.
FooterVault _vault({String? body}) =>
    seedFooterVault(body: body ?? _body, footerTags: _tags);

/// A `tag rm` that waits for the returned Completer, then acts on the vault.
Completer<void> _holdWrites(FooterVault vault) {
  final gate = Completer<void>();
  vault.cli.on('tag rm', (call) async {
    await gate.future;
    return applyTagRm(vault.db, call);
  });
  return gate;
}

List<FakeCliCall> _removals(SegmentedEditorRobot r) =>
    r.h.cli.callsFor('tag rm');

/// Clicks the × of [tag] and lets the write and the re-read finish.
Future<void> _remove(WidgetTester tester, TestGesture mouse, String tag) async {
  await clickX(tester, mouse, tag);
  await pumpFrames(tester);
}

/// Reads of a note, failing on demand: the local access with `getNote`
/// throwing while [failing] holds, as a hosted read does when the server drops
/// after the write.
class _FlakyNotes extends LocalNotesAccess {
  _FlakyNotes(this.failing, {required super.vaultPath, super.db, super.cli});

  final bool Function() failing;

  @override
  Future<Note?> getNote(String id) async {
    if (failing()) {
      throw const VaultUnreachableException(
        serverName: 'nas',
        mayHaveCommitted: false,
      );
    }
    return super.getNote(id);
  }
}

void main() {
  group('when the x shows', () {
    testWidgets('the x appears on hover and not at rest', (tester) async {
      await launchFooterNote(tester, _vault());
      final mouse = await addMouse(tester);

      // The slot is always there; the glyph isn't.
      expect(footerRemove('pricing'), findsOneWidget);
      expect(footerXShown(tester, 'pricing'), isFalse);
      expect(footerXShown(tester, 'memex'), isFalse);

      await hover(tester, mouse, footerTag('pricing'));

      expect(footerXShown(tester, 'pricing'), isTrue);
      expect(footerXShown(tester, 'memex'), isFalse, reason: 'only that tag');

      await mouse.moveTo(tester.getCenter(footerLabel('TAGS')));
      await pumpFrames(tester);

      expect(footerXShown(tester, 'pricing'), isFalse);
    });

    testWidgets('hovering the slot itself keeps the x showing', (tester) async {
      await launchFooterNote(tester, _vault());
      final mouse = await addMouse(tester);

      await hover(tester, mouse, footerRemove('pricing'));

      expect(footerXShown(tester, 'pricing'), isTrue);
    });

    testWidgets('the x appears on keyboard focus and not otherwise', (
      tester,
    ) async {
      await launchFooterNote(tester, _vault());

      expect(await shiftTabToX(tester, 'pricing'), isTrue);

      expect(footerXShown(tester, 'pricing'), isTrue);
      expect(footerXShown(tester, 'memex'), isFalse);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await pumpFrames(tester);

      expect(xHasFocus(tester, 'pricing'), isFalse);
      expect(footerXShown(tester, 'pricing'), isFalse);
    });

    testWidgets('hover and focus turn the name accentSoft and underlined', (
      tester,
    ) async {
      await launchFooterNote(tester, _vault());
      final mouse = await addMouse(tester);
      expect(colorOf(tester, footerTagName('pricing')), OmColors.fg2);
      expect(
        effectiveStyle(tester, footerTagName('pricing')).decoration ??
            TextDecoration.none,
        TextDecoration.none,
      );

      await hover(tester, mouse, footerTag('pricing'));

      expect(colorOf(tester, footerTagName('pricing')), OmColors.accentSoft);
      expect(
        effectiveStyle(tester, footerTagName('pricing')).decoration,
        TextDecoration.underline,
      );

      await mouse.moveTo(tester.getCenter(footerLabel('TAGS')));
      await pumpFrames(tester);
      expect(colorOf(tester, footerTagName('pricing')), OmColors.fg2);

      expect(await shiftTabToX(tester, 'pricing'), isTrue);
      expect(colorOf(tester, footerTagName('pricing')), OmColors.accentSoft);
      expect(
        effectiveStyle(tester, footerTagName('pricing')).decoration,
        TextDecoration.underline,
      );
    });

    testWidgets('showing the x shifts nothing', (tester) async {
      await launchFooterNote(tester, _vault());
      final mouse = await addMouse(tester);
      final memex = tester.getRect(footerTag('memex'));
      final pricing = tester.getRect(footerTag('pricing'));
      final slot = tester.getRect(footerRemove('memex'));
      final footer = tester.getRect(footerRow);

      await hover(tester, mouse, footerTag('memex'));

      expect(footerXShown(tester, 'memex'), isTrue);
      expect(tester.getRect(footerTag('memex')), memex);
      expect(tester.getRect(footerTag('pricing')), pricing);
      expect(tester.getRect(footerRemove('memex')), slot);
      expect(tester.getRect(footerRow), footer);
    });

    testWidgets('the slot is 16 by 18 at the end of the item after the name', (
      tester,
    ) async {
      await launchFooterNote(tester, _vault());

      final item = tester.getRect(footerTag('pricing'));
      final slot = tester.getRect(footerRemove('pricing'));
      final name = tester.getRect(footerTagName('pricing'));
      expect(slot.size, const Size(16, 18));
      expect(slot.right, item.right);
      expect(slot.left, name.right);
      expect(item.left, name.left);
    });

    testWidgets('the x glyph is 12 px fg2', (tester) async {
      await launchFooterNote(tester, _vault());
      final mouse = await addMouse(tester);

      await hover(tester, mouse, footerTag('pricing'));

      final icon = tester.widget<Icon>(
        find.descendant(
          of: footerRemove('pricing'),
          matching: find.byIcon(LucideIcons.x),
        ),
      );
      expect(icon.size, 12);
      expect(icon.color, OmColors.fg2);
    });

    testWidgets('no footer topic has an x', (tester) async {
      await launchFooterNote(
        tester,
        seedFooterVault(chips: const {pricingTopicId: 'Pricing'}),
      );
      final mouse = await addMouse(tester);

      await hover(tester, mouse, footerChip(pricingTopicId));

      expect(
        find.descendant(
          of: footerChip(pricingTopicId),
          matching: find.byIcon(LucideIcons.x),
        ),
        findsNothing,
      );
    });
  });

  group('removing', () {
    testWidgets(
      'the x removes the tag after the write returns and calls the remove action once',
      (tester) async {
        final vault = _vault();
        final gate = _holdWrites(vault);
        final r = await launchFooterNote(tester, vault);
        final mouse = await addMouse(tester);

        await clickX(tester, mouse, 'pricing');
        await pumpFrames(tester);

        // In flight: the tag stays, here and in the rail.
        expect(_removals(r), hasLength(1));
        expect(_removals(r).single.flag('note-id'), footerNoteId);
        expect(_removals(r).single.flag('tag'), 'pricing');
        expect(footerTag('pricing'), findsOneWidget);
        expect(railTag('pricing'), findsOneWidget);

        gate.complete();
        await pumpFrames(tester);

        expect(footerTag('pricing'), findsNothing);
        expect(railTag('pricing'), findsNothing);
        expect(footerTag('memex'), findsOneWidget);
        expect(railTag('memex'), findsOneWidget);
        expect(_removals(r), hasLength(1));
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('a second click while the write is out calls nothing more', (
      tester,
    ) async {
      final vault = _vault();
      final gate = _holdWrites(vault);
      final r = await launchFooterNote(tester, vault);
      final mouse = await addMouse(tester);

      await clickX(tester, mouse, 'pricing');
      await pumpFrames(tester);
      await clickX(tester, mouse, 'pricing');
      await pumpFrames(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await pumpFrames(tester);

      expect(_removals(r), hasLength(1));

      gate.complete();
      await pumpFrames(tester);

      expect(_removals(r), hasLength(1));
      expect(find.byKey(const Key('inline-error')), findsNothing);
    });

    testWidgets(
      'a remove in progress shows a spinner in the slot with the name in fg2',
      (tester) async {
        final vault = _vault();
        final gate = _holdWrites(vault);
        await launchFooterNote(tester, vault);
        final mouse = await addMouse(tester);

        await clickX(tester, mouse, 'pricing');
        await tester.pump();

        expect(footerSpinner('pricing'), findsOneWidget);
        final spinner = tester.widget<Icon>(footerSpinner('pricing'));
        expect(spinner.size, 12);
        expect(spinner.color, OmColors.fg2);
        expect(footerXShown(tester, 'pricing'), isFalse);
        expect(colorOf(tester, footerTagName('pricing')), OmColors.fg2);
        expect(footerSpinner('memex'), findsNothing);

        gate.complete();
        await pumpFrames(tester);
      },
    );

    testWidgets('a refresh during the write keeps the tag until it returns', (
      tester,
    ) async {
      final vault = _vault();
      final gate = _holdWrites(vault);
      final r = await launchFooterNote(tester, vault);
      final mouse = await addMouse(tester);

      await clickX(tester, mouse, 'pricing');
      await pumpFrames(tester);
      r.h.read(vaultRevisionProvider.notifier).state++;
      await pumpFrames(tester);

      expect(footerTag('pricing'), findsOneWidget);
      expect(footerSpinner('pricing'), findsOneWidget);

      gate.complete();
      await pumpFrames(tester);

      expect(footerTag('pricing'), findsNothing);
      expect(footerTag('memex'), findsOneWidget);
    });

    testWidgets(
      'a refresh that already lacks the tag before the write returns shows no error',
      (tester) async {
        final vault = _vault();
        final gate = _holdWrites(vault);
        final r = await launchFooterNote(tester, vault);
        final mouse = await addMouse(tester);

        await clickX(tester, mouse, 'pricing');
        await pumpFrames(tester);
        vault.db.db.execute('DELETE FROM tags WHERE note_id = ? AND tag = ?', [
          footerNoteId,
          'pricing',
        ]);
        r.h.read(vaultRevisionProvider.notifier).state++;
        await pumpFrames(tester);
        expect(footerTag('pricing'), findsNothing);

        gate.complete();
        await pumpFrames(tester);

        expect(footerTag('pricing'), findsNothing);
        expect(footerTag('memex'), findsOneWidget);
        expect(find.byKey(const Key('inline-error')), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('a click on the x does not reveal the tag', (tester) async {
      final r = await launchFooterNote(tester, _vault());
      final mouse = await addMouse(tester);

      await _remove(tester, mouse, 'pricing');

      expect(_removals(r), hasLength(1));
      expectNotRevealed(r.h);
    });

    testWidgets('the last tag takes its row and label and leaves Topics', (
      tester,
    ) async {
      final r = await launchFooterNote(
        tester,
        seedFooterVault(
          body: footerBody(
            footerPerson,
            chips: const ['Pricing'],
            tags: const ['memex'],
          ),
          footerTags: ['memex'],
          chips: const {pricingTopicId: 'Pricing'},
        ),
      );
      final mouse = await addMouse(tester);

      await _remove(tester, mouse, 'memex');

      expect(footerTag('memex'), findsNothing);
      expect(footerLabel('TAGS'), findsNothing);
      expect(footerLabel('TOPICS'), findsOneWidget);
      expect(footerChip(pricingTopicId), findsOneWidget);
      expect(r.segmentText(0), footerPerson);
    });

    testWidgets(
      'removing the last footer item on a clean note keeps the text segment and the caret',
      (tester) async {
        final r = await launchFooterNote(
          tester,
          seedFooterVault(
            body: footerBody(footerPerson, tags: const ['memex']),
            footerTags: ['memex'],
          ),
        );
        final mouse = await addMouse(tester);
        await r.focusSegment(0, offset: 3);
        final handle = r.segment(0);

        await _remove(tester, mouse, 'memex');

        expect(footerRow, findsNothing);
        expect(r.segment(0), same(handle));
        expect(r.segmentText(0), footerPerson);
        expect(r.segmentSelection(0), const TextSelection.collapsed(offset: 3));
        expect(r.h.db.getNote(footerNoteId)!.contentMd, footerPerson);
        await r.waitForSave();
        expect(r.updates, isEmpty, reason: 'a clean note stays clean');
      },
    );

    testWidgets('removing from a clean note writes nothing more', (
      tester,
    ) async {
      final r = await launchFooterNote(tester, _vault());
      final mouse = await addMouse(tester);

      await _remove(tester, mouse, 'pricing');
      await r.waitForSave();

      expect(r.updates, isEmpty);
      expect(r.h.read(editorControllerProvider).lastSavedVersion, 5);
      expect(r.segmentText(0), footerPerson);
    });

    testWidgets('a backfilled note with no marker removes its tag too', (
      tester,
    ) async {
      final r = await launchFooterNote(
        tester,
        seedFooterVault(body: footerPerson, footerTags: _tags),
      );
      final mouse = await addMouse(tester);

      await _remove(tester, mouse, 'pricing');

      expect(footerTag('pricing'), findsNothing);
      expect(footerTag('memex'), findsOneWidget);
      expect(r.segmentText(0), footerPerson);
    });

    testWidgets('source mode after a removal shows the stored markdown', (
      tester,
    ) async {
      final r = await launchFooterNote(tester, _vault());
      final mouse = await addMouse(tester);

      await _remove(tester, mouse, 'pricing');
      await r.toggleSource();

      expect(r.sourceText, footerBody(footerPerson, tags: const ['memex']));
    });

    testWidgets(
      'a tag removed and then added back by a server write shows again',
      (tester) async {
        final r = await launchFooterNote(tester, _vault());
        final mouse = await addMouse(tester);
        await _remove(tester, mouse, 'pricing');
        expect(footerTag('pricing'), findsNothing);

        r.h.db.seedTag(footerNoteId, 'pricing', origin: 'person');
        r.h.read(vaultRevisionProvider.notifier).state++;
        await pumpFrames(tester);

        expect(footerTag('pricing'), findsOneWidget);
      },
    );

    testWidgets('a removal on one note leaves the same tag on the next note', (
      tester,
    ) async {
      final vault = _vault();
      seedFooterNote(
        vault.db,
        id: otherNoteId,
        title: 'Other',
        footerTags: ['pricing'],
      );
      final r = await launchFooterNote(tester, vault);
      final mouse = await addMouse(tester);

      await _remove(tester, mouse, 'pricing');
      await r.open(otherNoteId);

      expect(footerTag('pricing'), findsOneWidget);
      expect(footerSpinner('pricing'), findsNothing);
    });

    testWidgets('a write out on one note shows no spinner on the next note', (
      tester,
    ) async {
      final vault = _vault();
      seedFooterNote(
        vault.db,
        id: otherNoteId,
        title: 'Other',
        footerTags: ['pricing'],
      );
      final gate = _holdWrites(vault);
      final r = await launchFooterNote(tester, vault);
      final mouse = await addMouse(tester);

      await clickX(tester, mouse, 'pricing');
      await pumpFrames(tester);
      await r.open(otherNoteId);

      expect(footerTag('pricing'), findsOneWidget);
      expect(footerSpinner('pricing'), findsNothing);

      gate.complete();
      await pumpFrames(tester);

      expect(footerTag('pricing'), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(_removals(r).single.flag('note-id'), footerNoteId);
    });
  });

  group('failures', () {
    testWidgets(
      'a failed x keeps the tag and shows the inline error which can be dismissed',
      (tester) async {
        final vault = _vault();
        vault.cli.on(
          'tag rm',
          (_) => FakeMemexCli.error('internal', 'the disk is full'),
        );
        final r = await launchFooterNote(tester, vault);
        final mouse = await addMouse(tester);
        final bumpsBefore = r.h.read(vaultRevisionProvider);

        await _remove(tester, mouse, 'pricing');

        expect(footerTag('pricing'), findsOneWidget);
        expect(railTag('pricing'), findsOneWidget);
        expect(footerSpinner('pricing'), findsNothing);
        expect(footerError, findsOneWidget);
        expect(
          find.descendant(
            of: footerError,
            matching: find.text('tag rm failed: the disk is full'),
          ),
          findsOneWidget,
        );
        expect(r.h.read(vaultRevisionProvider), bumpsBefore);
        // Above the rows, inside the footer.
        expect(
          tester.getBottomLeft(footerError).dy,
          lessThanOrEqualTo(tester.getTopLeft(footerTag('memex')).dy),
        );

        await tester.tap(
          find.descendant(
            of: footerError,
            matching: find.byKey(const Key('inline-error-dismiss')),
          ),
        );
        await pumpFrames(tester);

        expect(footerError, findsNothing);
        expect(footerTag('pricing'), findsOneWidget);
      },
    );

    testWidgets(
      'an unreachable hosted server keeps the tag and shows its failure copy with no snackbar',
      (tester) async {
        final vault = _vault();
        vault.cli.on(
          'tag rm',
          (_) => throw const VaultUnreachableException(
            serverName: 'nas',
            mayHaveCommitted: false,
          ),
        );
        await launchFooterNote(tester, vault);
        final mouse = await addMouse(tester);

        await _remove(tester, mouse, 'pricing');

        expect(footerTag('pricing'), findsOneWidget);
        expect(
          find.descendant(
            of: footerError,
            matching: find.text(_unreachableCopy),
          ),
          findsOneWidget,
        );
        expect(find.byType(SnackBar), findsNothing);
      },
    );

    testWidgets(
      'a write the server may have committed shows the same failure copy with no snackbar',
      (tester) async {
        final vault = _vault();
        vault.cli.on(
          'tag rm',
          (_) => throw const VaultUnreachableException(
            serverName: 'nas',
            mayHaveCommitted: true,
          ),
        );
        await launchFooterNote(tester, vault);
        final mouse = await addMouse(tester);

        await _remove(tester, mouse, 'pricing');

        expect(footerTag('pricing'), findsOneWidget);
        expect(
          find.descendant(
            of: footerError,
            matching: find.text(_unreachableCopy),
          ),
          findsOneWidget,
        );
        expect(find.byType(SnackBar), findsNothing);
      },
    );

    testWidgets('the failure copy names the tag that failed', (tester) async {
      final vault = _vault();
      vault.cli.on(
        'tag rm',
        (_) => throw const VaultUnreachableException(
          serverName: 'nas',
          mayHaveCommitted: false,
        ),
      );
      await launchFooterNote(tester, vault);
      final mouse = await addMouse(tester);

      await _remove(tester, mouse, 'memex');

      expect(
        find.text("Couldn't remove #memex. The vault server didn't answer."),
        findsOneWidget,
      );
    });

    testWidgets('a retry that succeeds clears the error', (tester) async {
      final vault = _vault();
      vault.cli.on(
        'tag rm',
        (_) => FakeMemexCli.error('internal', 'the disk is full'),
      );
      await launchFooterNote(tester, vault);
      final mouse = await addMouse(tester);
      await _remove(tester, mouse, 'pricing');
      expect(footerError, findsOneWidget);

      vault.cli.on('tag rm', (call) => applyTagRm(vault.db, call));
      await _remove(tester, mouse, 'pricing');

      expect(footerError, findsNothing);
      expect(footerTag('pricing'), findsNothing);
    });

    testWidgets('a failed x shows no error on the next note', (tester) async {
      final vault = _vault();
      seedFooterNote(
        vault.db,
        id: otherNoteId,
        title: 'Other',
        footerTags: ['pricing'],
      );
      vault.cli.on(
        'tag rm',
        (_) => FakeMemexCli.error('internal', 'the disk is full'),
      );
      final r = await launchFooterNote(tester, vault);
      final mouse = await addMouse(tester);

      await _remove(tester, mouse, 'pricing');
      expect(footerError, findsOneWidget);
      await r.open(otherNoteId);

      expect(footerError, findsNothing);
      expect(find.byKey(const Key('inline-error')), findsNothing);
    });

    testWidgets(
      'a failure that returns after the person left shows no error on the note now open',
      (tester) async {
        final vault = _vault();
        seedFooterNote(
          vault.db,
          id: otherNoteId,
          title: 'Other',
          footerTags: ['pricing'],
        );
        final gate = Completer<void>();
        vault.cli.on('tag rm', (_) async {
          await gate.future;
          return FakeMemexCli.error('internal', 'the disk is full');
        });
        final r = await launchFooterNote(tester, vault);
        final mouse = await addMouse(tester);

        await clickX(tester, mouse, 'pricing');
        await pumpFrames(tester);
        await r.open(otherNoteId);
        gate.complete();
        await pumpFrames(tester);

        expect(find.byKey(const Key('inline-error')), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'a failure that returns after the note tab closed throws nothing',
      (tester) async {
        final vault = _vault();
        final gate = Completer<void>();
        vault.cli.on('tag rm', (_) async {
          await gate.future;
          return FakeMemexCli.error('internal', 'the disk is full');
        });
        final r = await launchFooterNote(tester, vault);
        final mouse = await addMouse(tester);

        await clickX(tester, mouse, 'pricing');
        await pumpFrames(tester);
        r.h.read(tabsProvider.notifier).close(const NoteTab(footerNoteId));
        await pumpFrames(tester);
        gate.complete();
        await pumpFrames(tester);

        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('an already gone tag counts as success', (tester) async {
      final vault = _vault();
      final r = await launchFooterNote(tester, vault);
      final mouse = await addMouse(tester);
      // Gone behind the app's back: still on screen until the x returns.
      vault.db.db.execute('DELETE FROM tags WHERE note_id = ? AND tag = ?', [
        footerNoteId,
        'pricing',
      ]);
      expect(footerTag('pricing'), findsOneWidget);

      await _remove(tester, mouse, 'pricing');

      expect(_removals(r), hasLength(1));
      expect(find.byKey(const Key('inline-error')), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
      expect(footerTag('pricing'), findsNothing);
      expect(railTag('pricing'), findsNothing);
      expect(footerTag('memex'), findsOneWidget);
    });

    testWidgets(
      'a read that fails after a successful write shows no error and the tag leaves the row',
      (tester) async {
        var failReads = false;
        final vault = _vault();
        final r = await launchFooterNote(
          tester,
          vault,
          overrides: [
            vaultAccessProvider.overrideWith((ref) {
              final path = ref.watch(currentVaultProvider).localPath!;
              final db = ref.watch(vaultDbProvider);
              final cli = ref.watch(memexCliProvider);
              return LocalVaultAccess(
                vaultPath: path,
                db: db,
                cli: cli,
                notes: _FlakyNotes(
                  () => failReads,
                  vaultPath: path,
                  db: db,
                  cli: cli,
                ),
              );
            }),
          ],
        );
        final mouse = await addMouse(tester);
        expect(footerTag('pricing'), findsOneWidget);

        failReads = true;
        await _remove(tester, mouse, 'pricing');

        expect(_removals(r), hasLength(1));
        expect(footerTag('pricing'), findsNothing);
        expect(footerTag('memex'), findsOneWidget);
        expect(footerError, findsNothing);
        expect(find.byKey(const Key('inline-error')), findsNothing);
        expect(find.byType(SnackBar), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('the open note', () {
    /// A body tall enough to scroll, with the footer reachable at the bottom.
    String longBody() => footerBody(
      [for (var i = 0; i < 90; i++) 'line $i\n'].join(),
      tags: _tags,
    );

    /// The person section of [longBody] with [line0] as its first line.
    String longPerson(String line0) =>
        ['$line0\n', for (var i = 1; i < 90; i++) 'line $i\n'].join();

    testWidgets(
      'the x on the open note leaves a pending edit intact with no conflict and no scroll jump',
      (tester) async {
        final r = await launchFooterNote(tester, _vault(body: longBody()));
        final mouse = await addMouse(tester);
        final edited = longPerson('line 0 edited');

        await r.typeInSegment(0, edited);
        await tester.pump();
        final handle = r.segment(0);
        final selection = r.segmentSelection(0);
        final scroll = editorScroll(tester);
        scroll.jumpTo(scroll.maxScrollExtent);
        await pumpFrames(tester);
        final offset = scroll.pixels;
        expect(offset, greaterThan(0));

        await _remove(tester, mouse, 'pricing');

        // The pending edit is intact and nothing moved.
        expect(footerTag('pricing'), findsNothing);
        expect(r.segmentText(0), edited);
        expect(r.segment(0), same(handle));
        expect(r.segmentSelection(0), selection);
        expect(editorScroll(tester).pixels, offset);
        expect(r.updates, isEmpty, reason: 'the edit has not saved yet');

        // The next save is on the version the write returned.
        await r.waitForSave();
        expect(r.updates.single.flag('expected-version'), '5');
        expect(r.updates.single.stdinBody, startsWith(edited));
        expect(r.h.read(editorControllerProvider).status, SaveStatus.clean);
        expect(find.byKey(const Key('inline-error')), findsNothing);
        expect(editorScroll(tester).pixels, offset);

        // Rows decide: stale footer text in that save can't bring it back.
        expect(footerTag('pricing'), findsNothing);
        expect(footerTag('memex'), findsOneWidget);
        expect(r.segmentText(0), edited);
      },
    );

    testWidgets('the x on a clean open note does not jump the scroll', (
      tester,
    ) async {
      final r = await launchFooterNote(tester, _vault(body: longBody()));
      final mouse = await addMouse(tester);
      final scroll = editorScroll(tester);
      scroll.jumpTo(scroll.maxScrollExtent);
      await pumpFrames(tester);
      final offset = scroll.pixels;
      final handle = r.segment(0);

      await _remove(tester, mouse, 'pricing');

      expect(footerTag('pricing'), findsNothing);
      expect(r.segment(0), same(handle));
      expect(editorScroll(tester).pixels, offset);
    });

    testWidgets('removing the last footer item keeps the scroll where it was', (
      tester,
    ) async {
      final r = await launchFooterNote(
        tester,
        seedFooterVault(
          body: footerBody(
            [for (var i = 0; i < 90; i++) 'line $i\n'].join(),
            tags: const ['memex'],
          ),
          footerTags: ['memex'],
        ),
      );
      final mouse = await addMouse(tester);
      final scroll = editorScroll(tester);
      // Short of the end, so the shorter page doesn't clamp it.
      scroll.jumpTo(scroll.maxScrollExtent - 120);
      await pumpFrames(tester);
      final offset = scroll.pixels;
      final handle = r.segment(0);

      await _remove(tester, mouse, 'memex');

      expect(footerRow, findsNothing);
      expect(r.segment(0), same(handle));
      expect(editorScroll(tester).pixels, offset);
    });

    testWidgets('text typed while the write is out survives with no conflict', (
      tester,
    ) async {
      final vault = _vault();
      final gate = _holdWrites(vault);
      final r = await launchFooterNote(tester, vault);
      final mouse = await addMouse(tester);

      await clickX(tester, mouse, 'pricing');
      await pumpFrames(tester);
      await r.typeInSegment(0, 'Typed during the write\n');
      gate.complete();
      await pumpFrames(tester);

      expect(footerTag('pricing'), findsNothing);
      expect(r.segmentText(0), 'Typed during the write\n');

      await r.waitForSave();

      expect(r.updates.single.flag('expected-version'), '5');
      expect(
        r.updates.single.stdinBody,
        startsWith('Typed during the write\n'),
      );
      expect(r.h.read(editorControllerProvider).status, SaveStatus.clean);
    });

    testWidgets('a failed x leaves a pending edit to save on the old version', (
      tester,
    ) async {
      final vault = _vault();
      vault.cli.on(
        'tag rm',
        (_) => FakeMemexCli.error('internal', 'the disk is full'),
      );
      final r = await launchFooterNote(tester, vault);
      final mouse = await addMouse(tester);

      await r.typeInSegment(0, 'Edited\n');
      await _remove(tester, mouse, 'pricing');
      expect(r.segmentText(0), 'Edited\n');

      await r.waitForSave();

      expect(r.updates.single.flag('expected-version'), '4');
      expect(r.h.read(editorControllerProvider).status, SaveStatus.clean);
    });
  });

  group('keyboard and semantics', () {
    testWidgets('the x has the semantics label and is operable by keyboard', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final r = await launchFooterNote(tester, _vault());

      // A screen reader finds it at rest, with no hover and no focus.
      final x = find.bySemanticsLabel('Remove tag pricing');
      expect(x, findsOneWidget);
      expect(tester.getSemantics(x), isSemantics(hasTapAction: true));
      expect(find.bySemanticsLabel('Remove tag memex'), findsOneWidget);

      expect(await shiftTabToX(tester, 'pricing'), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await pumpFrames(tester);

      expect(_removals(r), hasLength(1));
      expect(_removals(r).single.flag('tag'), 'pricing');
      expect(footerTag('pricing'), findsNothing);
      expectNotRevealed(r.h);
      semantics.dispose();
    });

    testWidgets('the x is announced as a button for every tag', (tester) async {
      final semantics = tester.ensureSemantics();
      await launchFooterNote(tester, _vault());

      for (final tag in ['pricing', 'memex']) {
        expect(
          tester.getSemantics(find.bySemanticsLabel('Remove tag $tag')),
          isSemantics(
            label: 'Remove tag $tag',
            isButton: true,
            hasTapAction: true,
          ),
        );
      }
      semantics.dispose();
    });

    testWidgets('Space on a focused x removes the tag', (tester) async {
      final r = await launchFooterNote(tester, _vault());

      expect(await shiftTabToX(tester, 'memex'), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await pumpFrames(tester);

      expect(_removals(r), hasLength(1));
      expect(_removals(r).single.flag('tag'), 'memex');
      expect(footerTag('memex'), findsNothing);
    });

    testWidgets('other keys on a focused x do nothing', (tester) async {
      final r = await launchFooterNote(tester, _vault());

      expect(await shiftTabToX(tester, 'pricing'), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await pumpFrames(tester);

      expect(_removals(r), isEmpty);
      expect(footerTag('pricing'), findsOneWidget);
    });

    testWidgets('a footer tag name is not itself a tab stop', (tester) async {
      await launchFooterNote(tester, _vault());

      expect(await shiftTabToX(tester, 'pricing'), isTrue);

      final rect = FocusManager.instance.primaryFocus!.rect;
      expect(
        tester.getRect(footerTagName('pricing')).contains(rect.center),
        isFalse,
      );
    });
  });
}
