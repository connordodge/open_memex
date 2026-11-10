// WI #349 (Spec #347 req 18, TD7, L5): the shared keyboard `DialogButton`,
// moved out of the restore dialog. Tab focuses it, Enter and Space press
// it, a disabled one keeps its focus and does nothing, it reads as a
// labelled button (enabled exactly when it has an onPressed), it draws the
// `accentSoft` focus ring only while the keyboard focus highlight is on, and
// `autofocus: true` takes the focus when its route first shows.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:open_memex_app/src/widgets/atoms.dart';
import 'package:open_memex_app/src/widgets/backups/backup_keys.dart';
import 'package:open_memex_app/src/widgets/backups/restore_dialog.dart';
import 'package:open_memex_app/src/widgets/dialog_button.dart';
import 'package:path/path.dart' as p;

import '../support/font_fetch_hold.dart';
import '../support/wi349_keyboard.dart';

const _aKey = Key('wi349-a');
const _bKey = Key('wi349-b');

/// A press counter for a button's onPressed.
class _Presses {
  int count = 0;
  void call() => count++;
}

/// [children] in a row on a plain screen.
Future<void> _pump(WidgetTester tester, List<Widget> children) =>
    tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: Row(mainAxisSize: MainAxisSize.min, children: children),
          ),
        ),
      ),
    );

/// A screen whose `open` button shows a dialog of [buttons].
Future<void> _pumpDialogOpener(
  WidgetTester tester,
  List<Widget> Function() buttons,
) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: TextButton(
            key: const Key('wi349-open'),
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => Dialog(
                child: Row(mainAxisSize: MainAxisSize.min, children: buttons()),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  ),
);

Future<void> _openDialog(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('wi349-open')));
  await tester.pumpAndSettle();
}

/// A button whose onPressed the test can take away (rebuilds on [enabled]).
class _Toggle extends StatefulWidget {
  const _Toggle({required this.presses, required this.enabled});

  final _Presses presses;
  final ValueNotifier<bool> enabled;

  @override
  State<_Toggle> createState() => _ToggleState();
}

class _ToggleState extends State<_Toggle> {
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: widget.enabled,
    builder: (_, on, _) => DialogButton(
      key: _aKey,
      kind: OmButtonKind.secondary,
      label: 'choose…',
      onPressed: on ? widget.presses.call : null,
    ),
  );
}

void main() {
  holdFontFetches();

  // ==================================================================== AC1
  group('AC1 keyboard', () {
    testWidgets('Tab focuses a DialogButton', (tester) async {
      await _pump(tester, [
        DialogButton(
          key: _aKey,
          kind: OmButtonKind.ghost,
          label: 'cancel',
          onPressed: () {},
        ),
      ]);
      expect(wi349FocusIn(find.byKey(_aKey)), isFalse);

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();

      expect(wi349FocusIn(find.byKey(_aKey)), isTrue);
    });

    for (final (name, key) in [
      (
        'Enter on a focused DialogButton calls onPressed once',
        LogicalKeyboardKey.enter,
      ),
      (
        'Space on a focused DialogButton calls onPressed once',
        LogicalKeyboardKey.space,
      ),
    ]) {
      testWidgets(name, (tester) async {
        final a = _Presses();
        final b = _Presses();
        await _pump(tester, [
          DialogButton(
            key: _aKey,
            kind: OmButtonKind.ghost,
            label: 'cancel',
            onPressed: a.call,
          ),
          DialogButton(
            key: _bKey,
            kind: OmButtonKind.primary,
            label: 'restore',
            onPressed: b.call,
          ),
        ]);

        await wi349TabTo(tester, find.byKey(_bKey));
        await tester.sendKeyEvent(key);
        await tester.pump();

        expect(b.count, 1);
        expect(a.count, 0, reason: 'only the focused button is pressed');
        expect(wi349FocusIn(find.byKey(_bKey)), isTrue);
      });
    }

    testWidgets(
      'a DialogButton that loses its onPressed keeps the focus and Enter and Space do nothing',
      (tester) async {
        final presses = _Presses();
        final enabled = ValueNotifier(true);
        addTearDown(enabled.dispose);
        await _pump(tester, [_Toggle(presses: presses, enabled: enabled)]);

        await wi349TabTo(tester, find.byKey(_aKey));
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(presses.count, 1);

        enabled.value = false;
        await tester.pump();
        await tester.pump();

        expect(
          wi349FocusIn(find.byKey(_aKey)),
          isTrue,
          reason: 'a disabled DialogButton keeps its focus',
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await tester.pump();
        expect(
          presses.count,
          1,
          reason: 'disabled: Enter and Space do nothing',
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('Tab focuses a DialogButton whose onPressed is null', (
      tester,
    ) async {
      await _pump(tester, [
        const DialogButton(
          key: _aKey,
          kind: OmButtonKind.primary,
          icon: LucideIcons.loader2,
          label: 'restoring…',
          onPressed: null,
        ),
      ]);

      await wi349TabTo(tester, find.byKey(_aKey));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();

      expect(wi349FocusIn(find.byKey(_aKey)), isTrue);
      expect(tester.takeException(), isNull);
    });
  });

  // ==================================================================== AC2
  group('AC2 semantics', () {
    testWidgets(
      'a DialogButton reads as an enabled button labelled with its label',
      (tester) async {
        final handle = tester.ensureSemantics();
        await _pump(tester, [
          DialogButton(
            key: _aKey,
            kind: OmButtonKind.secondary,
            icon: LucideIcons.folder,
            label: 'choose…',
            onPressed: () {},
          ),
        ]);

        final node = wi349NodeLabelled(tester, find.byKey(_aKey), 'choose…');
        expect(
          node,
          isSemantics(
            label: 'choose…',
            isButton: true,
            hasEnabledState: true,
            isEnabled: true,
            hasTapAction: true,
          ),
        );
        handle.dispose();
      },
    );

    testWidgets(
      'a DialogButton whose onPressed is null reads as a disabled button with no tap action',
      (tester) async {
        final handle = tester.ensureSemantics();
        await _pump(tester, [
          const DialogButton(
            key: _aKey,
            kind: OmButtonKind.primary,
            label: 'restoring…',
            onPressed: null,
          ),
        ]);

        final node = wi349NodeLabelled(tester, find.byKey(_aKey), 'restoring…');
        expect(
          node,
          isSemantics(
            label: 'restoring…',
            isButton: true,
            hasEnabledState: true,
            isEnabled: false,
            hasTapAction: false,
          ),
        );
        handle.dispose();
      },
    );

    testWidgets('the semantic tap on a DialogButton calls onPressed once', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final presses = _Presses();
      await _pump(tester, [
        DialogButton(
          key: _aKey,
          kind: OmButtonKind.ghost,
          label: 'cancel',
          onPressed: presses.call,
        ),
      ]);

      final node = wi349NodeLabelled(tester, find.byKey(_aKey), 'cancel');
      await wi349SemanticTap(tester, node);

      expect(presses.count, 1);
      handle.dispose();
    });
  });

  // ==================================================================== AC3
  group('AC3 focus ring', () {
    testWidgets(
      'a DialogButton shows the accentSoft ring only while it has the keyboard focus highlight',
      (tester) async {
        wi349HighlightStrategy(FocusHighlightStrategy.alwaysTraditional);
        await _pump(tester, [
          DialogButton(
            key: _aKey,
            kind: OmButtonKind.ghost,
            label: 'cancel',
            onPressed: () {},
          ),
          DialogButton(
            key: _bKey,
            kind: OmButtonKind.primary,
            label: 'restore',
            onPressed: () {},
          ),
        ]);
        expect(wi349Rings(tester, find.byKey(_aKey)), isEmpty);
        expect(wi349Rings(tester, find.byKey(_bKey)), isEmpty);

        await wi349TabTo(tester, find.byKey(_aKey));
        final rings = wi349Rings(tester, find.byKey(_aKey));
        expect(rings, hasLength(1), reason: 'the focused button has a ring');
        expect(rings.single.$1.borderRadius, BorderRadius.circular(6));
        expect(
          rings.single.$2.size,
          tester.getSize(find.byKey(_aKey)),
          reason: 'the ring is drawn on the button itself',
        );
        expect(wi349Rings(tester, find.byKey(_bKey)), isEmpty);

        await wi349TabTo(tester, find.byKey(_bKey));
        expect(
          wi349Rings(tester, find.byKey(_aKey)),
          isEmpty,
          reason: 'the ring leaves with the focus',
        );
        expect(wi349Rings(tester, find.byKey(_bKey)), hasLength(1));

        // The highlight turns off (a pointer is used) while b keeps focus.
        FocusManager.instance.highlightStrategy =
            FocusHighlightStrategy.alwaysTouch;
        await tester.pump();
        expect(wi349FocusIn(find.byKey(_bKey)), isTrue);
        expect(
          wi349Rings(tester, find.byKey(_bKey)),
          isEmpty,
          reason: 'no ring once the focus highlight is off',
        );
      },
    );

    testWidgets('a DialogButton draws no ring on its first frame', (
      tester,
    ) async {
      wi349HighlightStrategy(FocusHighlightStrategy.alwaysTraditional);
      await _pump(tester, [
        DialogButton(
          key: _aKey,
          kind: OmButtonKind.ghost,
          label: 'cancel',
          onPressed: () {},
        ),
      ]);
      expect(find.byKey(_aKey), findsOneWidget);
      expect(wi349Rings(tester, find.byKey(_aKey)), isEmpty);

      await tester.pump();
      expect(wi349Rings(tester, find.byKey(_aKey)), isEmpty);
      // And it is a real, focusable button (so the empty ring means something).
      await wi349TabTo(tester, find.byKey(_aKey));
      expect(wi349Rings(tester, find.byKey(_aKey)), hasLength(1));
    });

    testWidgets(
      'a focused DialogButton shows no ring while the focus highlight is off',
      (tester) async {
        wi349HighlightStrategy(FocusHighlightStrategy.alwaysTouch);
        await _pump(tester, [
          DialogButton(
            key: _aKey,
            kind: OmButtonKind.ghost,
            label: 'cancel',
            onPressed: () {},
          ),
        ]);

        await wi349TabTo(tester, find.byKey(_aKey));

        expect(wi349FocusIn(find.byKey(_aKey)), isTrue);
        expect(wi349Rings(tester, find.byKey(_aKey)), isEmpty);
      },
    );
  });

  // ==================================================================== AC4
  group('AC4 autofocus', () {
    testWidgets(
      'a DialogButton with autofocus true has the focus when its dialog route first shows',
      (tester) async {
        await _pumpDialogOpener(
          tester,
          () => [
            DialogButton(
              key: _bKey,
              kind: OmButtonKind.danger,
              label: 'move to trash',
              onPressed: () {},
            ),
            DialogButton(
              key: _aKey,
              kind: OmButtonKind.ghost,
              label: 'cancel',
              autofocus: true,
              onPressed: () {},
            ),
          ],
        );

        await _openDialog(tester);

        expect(wi349FocusIn(find.byKey(_aKey)), isTrue);
        expect(
          wi349FocusIn(find.byKey(_bKey)),
          isFalse,
          reason: 'the default button, first in order, does not take focus',
        );
      },
    );

    testWidgets(
      'a default DialogButton does not take the focus when its dialog route shows',
      (tester) async {
        await _pumpDialogOpener(
          tester,
          () => [
            DialogButton(
              key: _aKey,
              kind: OmButtonKind.ghost,
              label: 'cancel',
              onPressed: () {},
            ),
          ],
        );

        await _openDialog(tester);
        expect(find.byKey(_aKey), findsOneWidget);
        expect(wi349FocusIn(find.byKey(_aKey)), isFalse);

        // It is focusable, so the above is the default at work.
        await wi349TabTo(tester, find.byKey(_aKey));
        expect(wi349FocusIn(find.byKey(_aKey)), isTrue);
      },
    );
  });

  // ==================================================================== AC5
  group('AC5 restore dialog uses DialogButton', () {
    test(
      'the restore dialog source no longer declares _DialogButton and imports the shared DialogButton',
      () {
        final source = File(
          p.join('lib', 'src', 'widgets', 'backups', 'restore_dialog.dart'),
        ).readAsStringSync();

        expect(source, isNot(contains('_DialogButton')));
        expect(source, contains("import '../dialog_button.dart';"));
        expect(
          RegExp(r'\bDialogButton\(').allMatches(source),
          hasLength(3),
          reason: 'choose, cancel and restore',
        );
      },
    );

    testWidgets(
      'the restore dialog choose cancel and restore controls are DialogButtons',
      (tester) async {
        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              home: Scaffold(
                body: RestoreDialog(
                  file: p.join(
                    Directory.systemTemp.path,
                    'memex-20261109T140312Z-01JC8W5Q3M7X9R2T4V6B8N0PZK.memex.zip',
                  ),
                  bytes: 41234567,
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        for (final key in [
          restoreFolderKey,
          const Key('restore-cancel'),
          restoreSubmitKey,
        ]) {
          expect(
            tester.widget(find.byKey(key)),
            isA<DialogButton>(),
            reason: '$key is the shared DialogButton',
          );
        }
        expect(
          tester.widget<DialogButton>(find.byKey(restoreSubmitKey)).autofocus,
          isFalse,
          reason: 'a pure move: the restore dialog keeps its name-field focus',
        );
      },
    );

    testWidgets(
      'a DialogButton renders an OmButton with its kind label icon and onPressed',
      (tester) async {
        final presses = _Presses();
        final label = ['re', 'store'].join();
        await _pump(tester, [
          DialogButton(
            key: _aKey,
            kind: OmButtonKind.primary,
            icon: LucideIcons.loader2,
            label: label,
            onPressed: presses.call,
          ),
        ]);

        final inner = find.descendant(
          of: find.byKey(_aKey),
          matching: find.byType(OmButton),
        );
        expect(inner, findsOneWidget);
        final button = tester.widget<OmButton>(inner);
        expect(button.kind, OmButtonKind.primary);
        expect(button.label, 'restore');
        expect(button.icon, LucideIcons.loader2);
        expect(button.onPressed, isNotNull);

        await tester.tap(find.byKey(_aKey));
        await tester.pump();
        expect(presses.count, 1, reason: 'a mouse click still presses it');
      },
    );
  });
}
