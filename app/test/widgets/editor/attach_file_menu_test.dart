// WI #146 (Spec #123 A4, R10, R11; L2): "Attach file…" in the note's ⋯
// menu (Key `note-menu-attach-file`) and the Command palette command
// (`palette-row-command-attachFile`), over the real app and editor
// (wi146_attach_harness.dart). The picker is `FakeFilePicker`; stores go to
// the held `FakeAttachmentsAccess`.

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/graph/graph_scope.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/widgets/atoms.dart';

import '../../support/app_harness.dart' show pumpFrames;
import '../../support/editor_rows_probe.dart';
import '../../support/font_fetch_hold.dart';
import '../../support/wi146_attach_harness.dart';

/// The R12 example after attaching mock.png and spec.pdf at line 0.
final _wi146After =
    'Review the draft\n\n${wi146Line('mock.png')}\n${wi146Line('spec.pdf')}'
    '\n\nNext steps';

Future<void> _wi146CaretAfterReview(Wi146Harness r) =>
    r.caretAfter('Review the draft');

/// Leaves the note: the active tab shows the vault graph instead.
Future<void> _wi146ShowGraph(Wi146Harness r) async {
  r.h.read(tabsProvider.notifier).navigate(GraphTab(const GraphScope.vault()));
  await pumpFrames(r.tester);
}

/// Whether the note menu button can be pressed.
bool _wi146MenuEnabled(Wi146Harness r) {
  final button = find.byKey(wi146MenuButtonKey);
  if (button.evaluate().isEmpty) return false;
  return r.tester.widget<OmButton>(button).onPressed != null;
}

void main() {
  holdFontFetches();

  group('the menu item (AC7)', () {
    testWidgets('the note menu shows Attach file with its label', (
      tester,
    ) async {
      final r = await wi146Pump(tester);
      await r.open();
      await r.openMenu();
      expect(find.byKey(wi146MenuItemKey), findsOneWidget);
      expect(
        tester.widget(find.byKey(wi146MenuItemKey)),
        isA<MenuItemButton>(),
      );
      expect(
        find.descendant(
          of: find.byKey(wi146MenuKey),
          matching: find.byKey(wi146MenuItemKey),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(wi146MenuItemKey),
          matching: find.text(wi146Label),
        ),
        findsOneWidget,
      );
    });

    testWidgets(
      'Attach file in the note menu opens the picker with multiple selection and attaches two picked files at the caret line in pick order',
      (tester) async {
        final r = await wi146Pump(tester);
        await r.open();
        await _wi146CaretAfterReview(r);
        r.picker.fileLists.add([wi146MockPath, wi146SpecPath]);

        await r.chooseMenuAttach();
        await r.releaseAll();

        expect(r.pickCalls, hasLength(1));
        expect(r.pickCalls.single.allowMultiple, isTrue);
        expect(
          [for (final c in r.attachments.addCalls) c.filePath],
          [wi146MockPath, wi146SpecPath],
        );
        expect(r.body, _wi146After);
        expect(find.byKey(wi146MenuKey), findsNothing, reason: 'menu closed');
      },
    );

    testWidgets('cancelling the picker from the note menu changes nothing', (
      tester,
    ) async {
      final r = await wi146Pump(tester);
      await r.open();
      await _wi146CaretAfterReview(r);
      r.picker.fileLists.add(null);
      r.bodyChanges.clear();

      await r.chooseMenuAttach();
      await r.releaseAll();

      expect(r.pickCalls, hasLength(1), reason: 'the picker was opened');
      expect(r.attachments.addCalls, isEmpty);
      expect(r.body, wi146Example);
      expect(r.bodyChanges, isEmpty);
      expect(find.textContaining('Attaching'), findsNothing);
      expect(find.textContaining('attach'), findsNothing, reason: 'no toast');
    });

    testWidgets(
      'with no caret the group from the note menu goes at the end of the person section',
      (tester) async {
        final r = await wi146Pump(tester);
        await r.open();
        expect(
          rowsHostOf(tester).focusedRow,
          isNull,
          reason: 'the plain note opens with no caret in its body',
        );
        r.picker.fileLists.add([wi146MockPath, wi146SpecPath]);

        await r.chooseMenuAttach();
        await r.releaseAll();

        expect(
          r.body,
          '$wi146Example\n\n${wi146Line('mock.png')}\n${wi146Line('spec.pdf')}',
        );
      },
    );
  });

  group('the palette command (AC7)', () {
    testWidgets(
      'the palette lists Attach file with its label over an open note',
      (tester) async {
        final r = await wi146Pump(tester);
        await r.open();
        await r.openPalette();
        await r.typePalette('attach');
        expect(r.paletteRow, findsOneWidget);
        expect(
          find.descendant(
            of: r.paletteRow,
            matching: find.text(wi146Label, findRichText: true),
          ),
          findsWidgets,
        );
        r.closePalette();
        await pumpFrames(tester);
      },
    );

    testWidgets(
      'the Attach file palette command opens the picker with multiple selection and attaches at the caret line in pick order',
      (tester) async {
        final r = await wi146Pump(tester);
        await r.open();
        await _wi146CaretAfterReview(r);
        r.picker.fileLists.add([wi146MockPath, wi146SpecPath]);

        await r.choosePaletteAttach();
        await r.releaseAll();

        expect(r.pickCalls, hasLength(1));
        expect(r.pickCalls.single.allowMultiple, isTrue);
        expect(
          [for (final c in r.attachments.addCalls) c.filePath],
          [wi146MockPath, wi146SpecPath],
        );
        expect(r.body, _wi146After);
      },
    );

    testWidgets('cancelling the picker from the palette changes nothing', (
      tester,
    ) async {
      final r = await wi146Pump(tester);
      await r.open();
      await _wi146CaretAfterReview(r);
      r.picker.fileLists.add(null);
      r.bodyChanges.clear();

      await r.choosePaletteAttach();
      await r.releaseAll();

      expect(r.pickCalls, hasLength(1));
      expect(r.attachments.addCalls, isEmpty);
      expect(r.body, wi146Example);
      expect(r.bodyChanges, isEmpty);
    });
  });

  group('only with a note open on a writable vault (AC8)', () {
    testWidgets(
      'the menu item and the palette command are absent with no note open',
      (tester) async {
        final r = await wi146Pump(tester);
        await r.open();
        // Control: offered over the open note.
        await r.openMenu();
        expect(find.byKey(wi146MenuItemKey), findsOneWidget);
        await tester.tapAt(const Offset(1590, 990));
        await pumpFrames(tester);
        await r.openPalette();
        await r.typePalette('attach');
        expect(r.paletteRow, findsOneWidget);
        r.closePalette();
        await pumpFrames(tester);

        await _wi146ShowGraph(r);
        expect(find.byKey(wi146MenuItemKey), findsNothing);
        expect(_wi146MenuEnabled(r), isFalse, reason: 'no note, no menu');
        await r.openPalette();
        await r.typePalette('attach');
        expect(r.paletteRow, findsNothing);
        await r.typePalette('');
        expect(r.paletteRow, findsNothing, reason: 'nor in the full list');
        r.closePalette();
        await pumpFrames(tester);
      },
    );

    testWidgets('the menu item is absent when VaultAccess canWrite is false', (
      tester,
    ) async {
      final r = await wi146Pump(tester);
      await r.open();
      await r.openMenu();
      expect(find.byKey(wi146MenuItemKey), findsOneWidget, reason: 'control');
      await tester.tapAt(const Offset(1590, 990));
      await pumpFrames(tester);

      r.h.read(wi146WritableProvider.notifier).state = false;
      await pumpFrames(tester);
      await r.openMenu();
      expect(find.byKey(wi146MenuItemKey), findsNothing);
      expect(find.text(wi146Label), findsNothing);
    });

    testWidgets(
      'the palette command is absent when VaultAccess canWrite is false',
      (tester) async {
        final r = await wi146Pump(tester);
        await r.open();
        await r.openPalette();
        await r.typePalette('attach');
        expect(r.paletteRow, findsOneWidget, reason: 'control');
        r.closePalette();
        await pumpFrames(tester);

        r.h.read(wi146WritableProvider.notifier).state = false;
        await pumpFrames(tester);
        await r.openPalette();
        await r.typePalette('attach');
        expect(r.paletteRow, findsNothing);
        await r.typePalette('');
        expect(r.paletteRow, findsNothing, reason: 'nor in the full list');
        r.closePalette();
        await pumpFrames(tester);
      },
    );
  });

  group('the busy guard (AC9)', () {
    testWidgets(
      'a second Attach file press while an action is storing starts no second picker',
      (tester) async {
        final r = await wi146Pump(tester);
        await r.open();
        await _wi146CaretAfterReview(r);
        r.attachments.holding = true;
        r.picker.fileLists
          ..add([wi146MockPath, wi146SpecPath])
          ..add([wi146MockPath]);

        await r.chooseMenuAttach();
        expect(r.pickCalls, hasLength(1));
        expect(r.attachments.pending, greaterThan(0), reason: 'storing');

        await r.chooseMenuAttach();
        expect(r.pickCalls, hasLength(1), reason: 'no second picker');
        await r.choosePaletteAttach();
        expect(r.pickCalls, hasLength(1), reason: 'nor from the palette');

        await r.releaseAll();
        expect(r.body, _wi146After, reason: 'the first action completes');
        expect(r.attachments.addCalls, hasLength(2));
      },
    );

    testWidgets(
      'after an action ends a later Attach file press opens the picker again',
      (tester) async {
        final r = await wi146Pump(tester);
        await r.open();
        await _wi146CaretAfterReview(r);
        r.picker.fileLists
          ..add(null)
          ..add([wi146MockPath])
          ..add(null);

        await r.chooseMenuAttach();
        await r.releaseAll();
        expect(r.pickCalls, hasLength(1));

        await r.chooseMenuAttach();
        await r.releaseAll();
        expect(r.pickCalls, hasLength(2), reason: 'free again after a cancel');
        expect(r.attachments.addCalls, hasLength(1));

        await r.chooseMenuAttach();
        await r.releaseAll();
        expect(r.pickCalls, hasLength(3), reason: 'free again after a store');
      },
    );

    testWidgets('two Attach file starts in the same frame open one picker', (
      tester,
    ) async {
      final r = await wi146Pump(tester);
      await r.open();
      await _wi146CaretAfterReview(r);
      r.picker.fileLists
        ..add([wi146MockPath])
        ..add([wi146SpecPath]);

      unawaited(r.controller.attachFromPicker(r.context));
      unawaited(r.controller.attachFromPicker(r.context));
      await r.releaseAll();

      expect(r.pickCalls, hasLength(1));
      expect(
        [for (final c in r.attachments.addCalls) c.filePath],
        [wi146MockPath],
      );
    });
  });
}
