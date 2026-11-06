// WI #253 fix round 1 (review-r1): keyboard focus after a footer tag leaves the
// row (Q4), and the failure copy of a x whose write fails for any reason but a
// MemexException (Q5). Writes run through the fake CLI and are awaited by
// pumping frames, never by wall-clock time.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/state/vault_access_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/vault_access/local/local_vault_access.dart';

import '../robots/segmented_editor_robot.dart';
import '../support/app_harness.dart';
import '../support/fake_memex_cli.dart';
import '../support/note_footer_harness.dart';
import '../support/tags_seed.dart';

const _three = ['alpha', 'beta', 'gamma'];
const _card = '![[2026-09-05#^b7k2m9]]\n';
const _copy = "Couldn't remove #beta. The vault server didn't answer.";
const _noCli = 'The memex CLI is not available.';

/// A tags domain that counts the writes it is asked for. Every one throws, so
/// a write that reaches it is also a failed write.
class _CountingTags extends LocalTagsAccess {
  _CountingTags() : super(vaultPath: '/tmp/om-253-vault');

  final removed = <String>[];

  @override
  Future<TagRmResult> removeTag(String noteId, String tag) async {
    removed.add('$noteId/$tag');
    throw StateError('should not be reached');
  }
}

/// `vaultAccessProvider` over a local vault with no CLI (`canWrite` false)
/// whose tags domain is [tags]. Reads still go to the harness's database.
Override _noCliAccess(FooterVault vault, _CountingTags tags) =>
    vaultAccessProvider.overrideWith((ref) {
      final path = ref.watch(currentVaultProvider).localPath;
      if (path == null) return null;
      return LocalVaultAccess(vaultPath: path, db: vault.db, tags: tags);
    });

/// What [body] logs through `debugPrint`. The swap is undone inside the test
/// body: a tearDown restore fails the test as a changed debug variable.
Future<List<String>> _logged(Future<void> Function() body) async {
  final logged = <String>[];
  final saved = debugPrint;
  debugPrint = (message, {wrapWidth}) => logged.add(message ?? '');
  try {
    await body();
  } finally {
    debugPrint = saved;
  }
  return logged;
}

FooterVault _vault(
  List<String> tags, {
  Map<String, String> chips = const {},
  String person = footerPerson,
}) => seedFooterVault(
  body: footerBody(person, chips: chips.values.toList(), tags: tags),
  footerTags: tags,
  chips: chips,
);

/// Presses Enter on the focused x and lets the write and the re-read finish.
Future<void> _enter(WidgetTester tester) async {
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await pumpFrames(tester);
}

/// Whether keyboard focus sits on any of the footer x of [tags].
bool _anyXFocused(WidgetTester tester, List<String> tags) =>
    tags.any((tag) => xHasFocus(tester, tag));

void main() {
  group('focus after a keyboard x', () {
    testWidgets('moves to the next x when the removed tag has one after it', (
      tester,
    ) async {
      await launchFooterNote(tester, _vault(_three));
      expect(await shiftTabToX(tester, 'beta'), isTrue);

      await _enter(tester);

      expect(footerTag('beta'), findsNothing);
      expect(xHasFocus(tester, 'gamma'), isTrue);
      expect(xHasFocus(tester, 'alpha'), isFalse);
      expect(footerXShown(tester, 'gamma'), isTrue);
    });

    testWidgets('moves to the next x when the first tag is removed', (
      tester,
    ) async {
      await launchFooterNote(tester, _vault(_three));
      expect(await shiftTabToX(tester, 'alpha'), isTrue);

      await _enter(tester);

      expect(footerTag('alpha'), findsNothing);
      expect(xHasFocus(tester, 'beta'), isTrue);
      expect(xHasFocus(tester, 'gamma'), isFalse);
    });

    testWidgets('moves to the previous x when the last tag is removed', (
      tester,
    ) async {
      await launchFooterNote(tester, _vault(_three));
      expect(await shiftTabToX(tester, 'gamma'), isTrue);

      await _enter(tester);

      expect(footerTag('gamma'), findsNothing);
      expect(xHasFocus(tester, 'beta'), isTrue);
      expect(xHasFocus(tester, 'alpha'), isFalse);
      expect(footerXShown(tester, 'beta'), isTrue);
    });

    testWidgets('keeps going to the next x for each removal in turn', (
      tester,
    ) async {
      await launchFooterNote(tester, _vault(_three));
      expect(await shiftTabToX(tester, 'alpha'), isTrue);

      await _enter(tester);
      await _enter(tester);

      expect(footerTag('alpha'), findsNothing);
      expect(footerTag('beta'), findsNothing);
      expect(footerTag('gamma'), findsOneWidget);
      expect(xHasFocus(tester, 'gamma'), isTrue);
    });

    testWidgets('moves to the editor text when the last tag leaves Topics', (
      tester,
    ) async {
      final r = await launchFooterNote(
        tester,
        _vault(['alpha'], chips: {pricingTopicId: 'Pricing'}),
      );
      expect(await shiftTabToX(tester, 'alpha'), isTrue);

      await _enter(tester);

      expect(footerTag('alpha'), findsNothing);
      expect(footerRow, findsOneWidget);
      expect(r.segmentHasFocus(0), isTrue);
      expect(_anyXFocused(tester, ['alpha']), isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'moves to the editor text with the caret at its end when no footer is left',
      (tester) async {
        final r = await launchFooterNote(tester, _vault(['alpha']));
        expect(await shiftTabToX(tester, 'alpha'), isTrue);
        final scrollBefore = editorScroll(tester).pixels;

        await _enter(tester);

        expect(footerRow, findsNothing);
        expect(r.segmentHasFocus(0), isTrue);
        expect(r.segmentSelection(0).isCollapsed, isTrue);
        expect(r.segmentSelection(0).baseOffset, r.segmentText(0).length);
        expect(editorScroll(tester).pixels, scrollBefore);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('puts the caret at the end of the last text above the footer', (
      tester,
    ) async {
      final r = await launchFooterNote(
        tester,
        _vault(['alpha'], person: 'Intro\n${_card}Outro text\n'),
      );
      expect(r.allCards, findsOneWidget);
      // The caret is elsewhere in that text, so only the move can put it at
      // the end.
      await r.focusSegment(2, offset: 0);
      expect(r.segmentSelection(2).baseOffset, 0);
      expect(await shiftTabToX(tester, 'alpha'), isTrue);

      await _enter(tester);

      expect(r.segmentHasFocus(2), isTrue);
      expect(r.segmentHasFocus(0), isFalse);
      expect(r.segmentSelection(2).baseOffset, r.segmentText(2).length);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a pending edit survives the move to the editor', (
      tester,
    ) async {
      final r = await launchFooterNote(tester, _vault(['alpha']));
      await r.typeInSegment(0, 'Annual plan draft more\n');
      expect(await shiftTabToX(tester, 'alpha'), isTrue);

      await _enter(tester);

      expect(r.segmentText(0), 'Annual plan draft more\n');
      expect(r.segmentHasFocus(0), isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a failed x keeps focus on its own x', (tester) async {
      final vault = _vault(_three);
      vault.cli.on(
        'tag rm',
        (_) => FakeMemexCli.error('internal', 'the disk is full'),
      );
      await launchFooterNote(tester, vault);
      expect(await shiftTabToX(tester, 'beta'), isTrue);

      await _enter(tester);

      expect(footerTag('beta'), findsOneWidget);
      expect(xHasFocus(tester, 'beta'), isTrue);
      expect(xHasFocus(tester, 'gamma'), isFalse);
    });

    testWidgets('a mouse click on a x moves no keyboard focus to another x', (
      tester,
    ) async {
      await launchFooterNote(tester, _vault(_three));
      final mouse = await addMouse(tester);

      await clickX(tester, mouse, 'beta');
      await pumpFrames(tester);

      expect(footerTag('beta'), findsNothing);
      expect(_anyXFocused(tester, _three), isFalse);
    });

    testWidgets(
      'a tag another client removes moves focus off it the same way',
      (tester) async {
        final vault = _vault(_three);
        final r = await launchFooterNote(tester, vault);
        expect(await shiftTabToX(tester, 'beta'), isTrue);

        vault.db.db.execute('DELETE FROM tags WHERE note_id = ? AND tag = ?', [
          footerNoteId,
          'beta',
        ]);
        r.h.read(vaultRevisionProvider.notifier).state++;
        await pumpFrames(tester);

        expect(footerTag('beta'), findsNothing);
        expect(xHasFocus(tester, 'gamma'), isTrue);
      },
    );

    testWidgets('the tag leaving before the write returns moves focus once', (
      tester,
    ) async {
      final vault = _vault(_three);
      final gate = Completer<void>();
      late SegmentedEditorRobot r;
      vault.cli.on('tag rm', (call) async {
        final result = applyTagRm(vault.db, call);
        r.h.read(vaultRevisionProvider.notifier).state++;
        await gate.future;
        return result;
      });
      r = await launchFooterNote(tester, vault);
      expect(await shiftTabToX(tester, 'beta'), isTrue);

      await _enter(tester);
      expect(footerTag('beta'), findsNothing);
      expect(xHasFocus(tester, 'gamma'), isTrue);
      gate.complete();
      await pumpFrames(tester);

      expect(xHasFocus(tester, 'gamma'), isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a tag the vault gets back takes keyboard focus again', (
      tester,
    ) async {
      final r = await launchFooterNote(tester, _vault(_three));
      expect(await shiftTabToX(tester, 'beta'), isTrue);
      await _enter(tester);
      expect(footerTag('beta'), findsNothing);

      r.h.db.seedTag(footerNoteId, 'beta', origin: 'agent');
      r.h.read(vaultRevisionProvider.notifier).state++;
      await pumpFrames(tester);
      expect(footerTag('beta'), findsOneWidget);

      expect(await shiftTabToX(tester, 'beta'), isTrue);
      expect(footerXShown(tester, 'beta'), isTrue);
    });
  });

  group('failure copy of a x', () {
    testWidgets('a StateError from the write shows the vault server copy', (
      tester,
    ) async {
      final vault = _vault(_three);
      vault.cli.on(
        'tag rm',
        (_) => throw StateError('The memex CLI is not available.'),
      );
      await launchFooterNote(tester, vault);
      final mouse = await addMouse(tester);

      await clickX(tester, mouse, 'beta');
      await pumpFrames(tester);

      expect(find.text(_copy), findsOneWidget);
      expect(find.textContaining('Bad state'), findsNothing);
      expect(find.textContaining('CLI is not available'), findsNothing);
      expect(footerTag('beta'), findsOneWidget);
    });

    testWidgets('no CLI at all says the memex CLI is not available', (
      tester,
    ) async {
      final logged = await _logged(() async {
        await launchFooterNote(
          tester,
          _vault(_three),
          overrides: [memexCliProvider.overrideWithValue(null)],
        );
        final mouse = await addMouse(tester);

        await clickX(tester, mouse, 'beta');
        await pumpFrames(tester);
      });

      expect(find.text(_noCli), findsOneWidget);
      expect(find.text(_copy), findsNothing);
      expect(find.textContaining('Bad state'), findsNothing);
      expect(footerTag('beta'), findsOneWidget);
      expect(footerSpinner('beta'), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
      expect(logged, isEmpty);
    });

    testWidgets('a vault that cannot write never tries the write', (
      tester,
    ) async {
      final tags = _CountingTags();
      final vault = _vault(_three);
      final logged = await _logged(() async {
        await launchFooterNote(
          tester,
          vault,
          overrides: [
            memexCliProvider.overrideWithValue(null),
            _noCliAccess(vault, tags),
          ],
        );
        final mouse = await addMouse(tester);

        await clickX(tester, mouse, 'beta');
        await pumpFrames(tester);
      });

      expect(tags.removed, isEmpty);
      expect(vault.cli.callsFor('tag rm'), isEmpty);
      expect(find.text(_noCli), findsOneWidget);
      expect(footerTag('beta'), findsOneWidget);
      expect(logged, isEmpty);
    });

    testWidgets('a x that said the CLI is missing can be clicked again', (
      tester,
    ) async {
      await launchFooterNote(
        tester,
        _vault(_three),
        overrides: [memexCliProvider.overrideWithValue(null)],
      );
      final mouse = await addMouse(tester);
      await clickX(tester, mouse, 'beta');
      await pumpFrames(tester);
      await tester.tap(
        find.descendant(
          of: footerRow,
          matching: find.byKey(const Key('inline-error-dismiss')),
        ),
      );
      await pumpFrames(tester);
      expect(find.text(_noCli), findsNothing);

      await clickX(tester, mouse, 'beta');
      await pumpFrames(tester);

      expect(find.text(_noCli), findsOneWidget);
      expect(footerSpinner('beta'), findsNothing);
      expect(footerTag('beta'), findsOneWidget);
    });

    testWidgets('a failure that is not a MemexException is logged', (
      tester,
    ) async {
      final vault = _vault(_three);
      vault.cli.on('tag rm', (_) => throw StateError('kaboom'));
      final logged = await _logged(() async {
        await launchFooterNote(tester, vault);
        final mouse = await addMouse(tester);

        await clickX(tester, mouse, 'beta');
        await pumpFrames(tester);
      });

      expect(find.text(_copy), findsOneWidget);
      expect(find.textContaining('kaboom'), findsNothing);
      expect(logged.where((l) => l.contains('kaboom')), hasLength(1));
      expect(logged.where((l) => l.contains('#beta')), isNotEmpty);
    });

    testWidgets('a MemexException is not logged', (tester) async {
      final vault = _vault(_three);
      vault.cli.on('tag rm', (_) => throw MemexException('nope'));
      final logged = await _logged(() async {
        await launchFooterNote(tester, vault);
        final mouse = await addMouse(tester);

        await clickX(tester, mouse, 'beta');
        await pumpFrames(tester);
      });

      expect(find.text('nope'), findsOneWidget);
      expect(logged, isEmpty);
    });

    testWidgets('a vault that closes under the x is not a missing CLI', (
      tester,
    ) async {
      final open = StateProvider<bool>((_) => true);
      final vault = _vault(_three);
      late ProviderContainer container;
      final logged = await _logged(() async {
        await launchFooterNote(
          tester,
          vault,
          overrides: [
            vaultAccessProvider.overrideWith((ref) {
              final path = ref.watch(currentVaultProvider).localPath;
              if (path == null || !ref.watch(open)) return null;
              return LocalVaultAccess(
                vaultPath: path,
                db: vault.db,
                cli: vault.cli,
              );
            }),
          ],
        );
        container = ProviderScope.containerOf(
          tester.element(footerTag('beta')),
        );
        final mouse = await addMouse(tester);
        await hover(tester, mouse, footerRemove('beta'));
        await mouse.down(tester.getCenter(footerRemove('beta')));
        // Closed between the press and the release, before any frame: the
        // footer is still on screen when the click reads the access.
        container.read(open.notifier).state = false;
        await mouse.up();
        await pumpFrames(tester);
      });

      // The footer goes with the vault, so the error has nowhere to show: the
      // write was tried (and failed with the vault gone) and the log has it.
      expect(find.text(_noCli), findsNothing);
      expect(logged.where((l) => l.contains('No vault is open')), hasLength(1));
    });

    testWidgets('an Exception that is not a MemexException shows the copy', (
      tester,
    ) async {
      final vault = _vault(_three);
      vault.cli.on('tag rm', (_) => throw Exception('socket closed'));
      await launchFooterNote(tester, vault);
      final mouse = await addMouse(tester);

      await clickX(tester, mouse, 'beta');
      await pumpFrames(tester);

      expect(find.text(_copy), findsOneWidget);
      expect(find.textContaining('socket closed'), findsNothing);
    });

    testWidgets('a MemexException keeps its own message', (tester) async {
      final vault = _vault(_three);
      vault.cli.on(
        'tag rm',
        (_) => throw MemexException('tag rm failed: nope'),
      );
      await launchFooterNote(tester, vault);
      final mouse = await addMouse(tester);

      await clickX(tester, mouse, 'beta');
      await pumpFrames(tester);

      expect(find.text('tag rm failed: nope'), findsOneWidget);
      expect(find.text(_copy), findsNothing);
    });
  });
}
