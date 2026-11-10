// WI #363 (Spec #357 Req 17-20, 22, 26, TD5, TD6; design pack 363, boards
// S1, S2, flows F2, F3): the sidebar's vault pills. A local pill leads with
// a folder icon in `vaultColorFor(<folder name>)` and no dot; a hosted pill
// keeps its server icon in `vaultColorFor(<vault> · <server>)` and its
// status dot; `sidebar.dart` keeps no copy of the colour hash. A secondary
// click on a pill opens its vault menu (#361's VaultMenuRegion) ending in
// `manage…`: open local (show in Finder, delete vault…, manage…), other
// local (show in Finder, remove from recents, delete vault…, manage…),
// hosted (remove from recents, manage…), open hosted (manage… only). Each
// item does what it says: the modal, the file revealer, the recents, and
// the open vault's close-then-delete ending on the full-screen picker. A
// pill draws `surface3` / `line3` while its menu shows. A left click still
// switches. Seams: test/support/wi362_modal.dart (whole app, temp vaults,
// FakeVaultTrash, FakeFileRevealer, recording leave guard) and
// wi363_sidebar.dart. Never a real Finder, Trash or vault.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:open_memex_app/src/screens/vault_picker.dart';
import 'package:open_memex_app/src/screens/workspace.dart';
import 'package:open_memex_app/src/state/vault_open_hosted.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/widgets/atoms.dart';
import 'package:open_memex_app/src/widgets/picker/delete_vault_dialog.dart';
import 'package:open_memex_app/src/widgets/vault_color.dart';

import '../support/api_fixtures.dart';
import '../support/fake_vault_server.dart';
import '../support/font_fetch_hold.dart';
import '../support/hosted_harness.dart';
import '../support/wi362_modal.dart';
import '../support/wi363_sidebar.dart';

const _finder = 'vault-menu-finder';
const _remove = 'vault-menu-remove';
const _delete = 'vault-menu-delete';
const _manage = 'vault-menu-manage';

/// The hosted seed pill's label, built at run time.
String get _seedLabel => hostedVaultLabel(seedVaultName, fakeServerName);

/// The pill finder for [label]: a local pill by its folder name, the seed
/// pill by its Key.
Finder _pill(String label) => label == _seedLabel
    ? wi363HostedPill(fakeServerId, seedVaultName)
    : wi363PillLabel(label);

/// The leading icon of the pill labelled [label] (the first Icon left of
/// its label), with the label's left edge.
Icon _leadingIcon(WidgetTester tester, String label, IconData data) {
  final row = find
      .ancestor(of: wi363PillLabel(label), matching: find.byType(Row))
      .first;
  final icon = find.descendant(of: row, matching: find.byIcon(data));
  expect(icon, findsOneWidget, reason: '$label leads with $data');
  expect(
    tester.getTopLeft(wi363PillLabel(label)).dx - tester.getTopRight(icon).dx,
    7,
    reason: '$label: icon, 7, label',
  );
  return tester.widget<Icon>(icon);
}

/// The pill's row (its icon, label and any status dot).
Finder _pillRow(String label) =>
    find.ancestor(of: wi363PillLabel(label), matching: find.byType(Row)).first;

void main() {
  holdFontFetches();

  group('type-icon pills (AC3, AC4)', () {
    testWidgets(
      'a local pill shows a folder icon in its vault colour and no dot while a hosted pill keeps its server icon and status dot',
      (tester) async {
        await wi362PumpLocal(tester, openNote: false);

        for (final name in ['memex', 'work-notes']) {
          final icon = _leadingIcon(tester, name, LucideIcons.folder);
          expect(icon.size, 11, reason: name);
          expect(icon.color, vaultColorFor(name), reason: name);
          expect(
            find.descendant(of: _pillRow(name), matching: find.byType(OmDot)),
            findsNothing,
            reason: '$name has no dot',
          );
          expect(
            find.descendant(
              of: _pillRow(name),
              matching: find.byType(StatusDot),
            ),
            findsNothing,
          );
          expect(
            find.descendant(
              of: _pillRow(name),
              matching: find.byIcon(LucideIcons.server),
            ),
            findsNothing,
          );
        }

        final label = _seedLabel;
        final server = _leadingIcon(tester, label, LucideIcons.server);
        expect(server.size, 11);
        expect(server.color, vaultColorFor(label));
        expect(
          find.descendant(
            of: wi363HostedPill(fakeServerId, seedVaultName),
            matching: find.byType(StatusDot),
          ),
          findsOneWidget,
          reason: 'the hosted pill keeps its status dot',
        );
        expect(
          find.descendant(
            of: wi363HostedPill(fakeServerId, seedVaultName),
            matching: find.byIcon(LucideIcons.folder),
          ),
          findsNothing,
        );
      },
    );

    testWidgets(
      'the open hosted pill keeps its server icon in the colour of its full label',
      (tester) async {
        await wi362PumpHosted(tester);

        for (final label in [
          _seedLabel,
          hostedVaultLabel('work', wi362Studio().name),
        ]) {
          final icon = _leadingIcon(tester, label, LucideIcons.server);
          expect(icon.color, vaultColorFor(label), reason: label);
        }
        expect(wi363InSidebar(find.byIcon(LucideIcons.folder)), findsNothing);
      },
    );

    test('sidebar.dart no longer defines its own vault colour hash', () {
      final source = File('lib/src/widgets/sidebar.dart').readAsStringSync();
      expect(source, isNot(contains('_vaultColorFor')));
      expect(
        source,
        contains("import 'vault_color.dart';"),
        reason: 'the pills use the shared vaultColorFor',
      );
      expect(
        RegExp(r'palette\[').hasMatch(source),
        isFalse,
        reason: 'no second palette lookup',
      );
    });
  });

  group('pill menus (AC5)', () {
    for (final (name, hosted, label, items) in [
      (
        'a secondary click on the open local pill opens show in Finder then delete vault then manage',
        false,
        'memex',
        [_finder, _delete, _manage],
      ),
      (
        'a secondary click on another local pill opens show in Finder then remove from recents then delete vault then manage',
        false,
        'work-notes',
        [_finder, _remove, _delete, _manage],
      ),
      (
        'a secondary click on a hosted pill opens remove from recents then manage',
        false,
        hostedVaultLabel(seedVaultName, fakeServerName),
        [_remove, _manage],
      ),
      (
        'a secondary click on the open hosted pill opens manage only',
        true,
        hostedVaultLabel(seedVaultName, fakeServerName),
        [_manage],
      ),
    ]) {
      testWidgets(name, (tester) async {
        final env = hosted
            ? await wi362PumpHosted(tester)
            : await wi362PumpLocal(tester, openNote: false);
        final before = wi362Snapshot(env);
        expect(wi363MenuShown(tester), isEmpty);

        await wi363SecondaryClick(tester, _pill(label));

        expect(wi363MenuShown(tester), items, reason: label);
        for (final k in items) {
          expect(find.byKey(Key(k)), findsOneWidget, reason: 'one menu');
        }
        expect(wi362Modal, findsNothing, reason: 'the menu opens nothing');
        expect(wi362Snapshot(env), before, reason: 'nothing changed');
        expect(env.guardCalls, isEmpty);
      });
    }

    testWidgets('the pill menu opens at the pointer and closes with Escape', (
      tester,
    ) async {
      await wi362PumpLocal(tester, openNote: false);
      final pill = wi363PillLabel('work-notes');

      await wi363SecondaryClick(tester, pill);
      final item = tester.getRect(find.byKey(const Key(_finder)));
      final at = tester.getCenter(pill);
      expect(
        (item.left - at.dx).abs(),
        lessThan(12),
        reason: 'the menu starts at the pointer',
      );
      expect(item.top, greaterThanOrEqualTo(at.dy - 1));

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await wi362Settle(tester);
      expect(wi363MenuShown(tester), isEmpty);
    });

    testWidgets('a left click on a pill opens no menu', (tester) async {
      final env = await wi362PumpLocal(tester, openNote: false);
      env.allow = false;

      await wi362Tap(tester, wi363PillLabel('work-notes'));

      expect(wi363MenuShown(tester), isEmpty);
      expect(env.guardCalls, hasLength(1), reason: 'the left click switches');
    });
  });

  group('manage from a pill (AC6)', () {
    for (final (name, hosted, label) in [
      (
        'manage from the open local pill menu opens the vault picker modal',
        false,
        'memex',
      ),
      (
        'manage from another local pill menu opens the vault picker modal',
        false,
        'work-notes',
      ),
      (
        'manage from a hosted pill menu opens the vault picker modal',
        false,
        hostedVaultLabel(seedVaultName, fakeServerName),
      ),
      (
        'manage from the open hosted pill menu opens the vault picker modal',
        true,
        hostedVaultLabel(seedVaultName, fakeServerName),
      ),
    ]) {
      testWidgets(name, (tester) async {
        final env = hosted
            ? await wi362PumpHosted(tester)
            : await wi362PumpLocal(tester, openNote: false);
        final before = wi362Snapshot(env);

        await wi363SecondaryClick(tester, _pill(label));
        await wi363PressMenu(tester, _manage);

        expect(wi362Modal, findsOneWidget, reason: 'the modal shows');
        expect(wi363MenuShown(tester), isEmpty, reason: 'the menu closed');
        expect(find.byType(Workspace), findsOneWidget);
        expect(find.byType(VaultPickerScreen), findsNothing);
        expect(wi362Snapshot(env), before, reason: 'the open vault stays');
        expect(env.guardCalls, isEmpty);
        expect(
          wi362KeyInModal('recent-row-open-tag-0'),
          findsOneWidget,
          reason: 'the open vault leads the modal',
        );
      });
    }
  });

  group('menu-open pill style (AC8)', () {
    testWidgets(
      'a pill draws surface3 and line3 while its menu is open and its normal style after it closes',
      (tester) async {
        await wi362PumpLocal(tester, openNote: false);
        const name = 'work-notes';

        var style = wi363PillStyle(tester, name);
        expect(style.fill, isNull, reason: 'idle: no fill');
        expect(style.border, OmColors.line1, reason: 'idle: line1');

        await wi363SecondaryClick(tester, wi363PillLabel(name));
        style = wi363PillStyle(tester, name);
        expect(style.fill, OmColors.surface3, reason: 'menu open: surface3');
        expect(style.border, OmColors.line3, reason: 'menu open: line3');
        expect(style.borderWidth, 1);
        expect(
          wi363TextColour(tester, _pillRow(name), name),
          OmColors.fg2,
          reason: 'text unchanged',
        );
        // Another pill is untouched.
        expect(wi363PillStyle(tester, _seedLabel).fill, isNull);

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await wi362Settle(tester);
        expect(wi363MenuShown(tester), isEmpty);
        style = wi363PillStyle(tester, name);
        expect(style.fill, isNull, reason: 'closed: no fill');
        expect(style.border, OmColors.line1, reason: 'closed: line1');
      },
    );

    testWidgets(
      'a pill returns to its normal style when a window resize closes its menu',
      (tester) async {
        await wi362PumpLocal(tester, openNote: false);
        const name = 'work-notes';
        await wi363SecondaryClick(tester, wi363PillLabel(name));
        expect(wi363PillStyle(tester, name).fill, OmColors.surface3);
        expect(wi363MenuShown(tester), isNotEmpty);

        // The anchor closes its menu (after the frame that saw the new
        // size): the pill restyles with nothing thrown.
        tester.view.physicalSize = const Size(1180, 760);
        addTearDown(tester.view.resetPhysicalSize);
        await wi362Settle(tester);

        expect(tester.takeException(), isNull);
        expect(wi363MenuShown(tester), isEmpty, reason: 'the resize closed it');
        final style = wi363PillStyle(tester, name);
        expect(style.fill, isNull, reason: 'closed: no fill');
        expect(style.border, OmColors.line1, reason: 'closed: line1');
      },
    );

    testWidgets(
      'a hosted pill draws surface3 and line3 while its menu is open and its normal style after an item is chosen',
      (tester) async {
        final env = await wi362PumpLocal(tester, openNote: false);
        final label = _seedLabel;

        await wi363SecondaryClick(tester, _pill(label));
        var style = wi363PillStyle(tester, label);
        expect(style.fill, OmColors.surface3);
        expect(style.border, OmColors.line3);

        await wi363PressMenu(tester, _manage);
        await wi362Tap(tester, wi362Close);
        expect(wi362Modal, findsNothing);
        style = wi363PillStyle(tester, label);
        expect(style.fill, isNull);
        expect(style.border, OmColors.line1);
        expect(env.current, LocalVaultRef(env.openPath!));
      },
    );

    testWidgets(
      'the open pill keeps surface4 while its menu is open and after it closes',
      (tester) async {
        await wi362PumpLocal(tester, openNote: false);
        const name = 'memex';
        expect(wi363PillStyle(tester, name).fill, OmColors.surface4);

        await wi363SecondaryClick(tester, wi363PillLabel(name));
        expect(wi363MenuShown(tester), [_finder, _delete, _manage]);
        var style = wi363PillStyle(tester, name);
        expect(style.fill, OmColors.surface4, reason: 'the open pill keeps it');
        expect(style.border, OmColors.line3);
        expect(wi363TextColour(tester, _pillRow(name), name), OmColors.fg0);

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await wi362Settle(tester);
        style = wi363PillStyle(tester, name);
        expect(style.fill, OmColors.surface4);
        expect(style.border, OmColors.line3);
      },
    );

    testWidgets(
      'a pill returns to its normal style after a click outside closes its menu',
      (tester) async {
        await wi362PumpLocal(tester, openNote: false);
        const name = 'work-notes';

        await wi363SecondaryClick(tester, wi363PillLabel(name));
        expect(wi363PillStyle(tester, name).fill, OmColors.surface3);

        // A click on the sidebar brand row, away from the menu.
        await tester.tapAt(
          tester.getTopLeft(find.text('open memex')) + const Offset(2, 2),
        );
        await wi362Settle(tester);

        expect(wi363MenuShown(tester), isEmpty);
        expect(wi363PillStyle(tester, name).fill, isNull);
        expect(wi363PillStyle(tester, name).border, OmColors.line1);
      },
    );
  });

  group('delete from a pill (AC9)', () {
    testWidgets(
      'delete vault on the open local pill closes the vault and shows the full screen picker without it',
      (tester) async {
        final env = await wi362PumpLocal(tester);

        await wi363SecondaryClick(tester, wi363PillLabel('memex'));
        await wi363PressMenu(tester, _delete);
        expect(find.byType(DeleteVaultDialog), findsOneWidget);
        expect(
          find.byKey(const Key('delete-vault-open-line')),
          findsOneWidget,
          reason: 'the dialog says the vault is open',
        );
        await wi362Tap(tester, find.byKey(const Key('delete-vault-confirm')));
        await wi362Settle(tester, rounds: 12);

        expect(env.trash.calls, [env.openPath]);
        expect(env.current, isNull);
        expect(env.settings.lastVaultRef, isNull);
        expect(find.byType(DeleteVaultDialog), findsNothing);
        expect(find.byType(VaultPickerScreen), findsOneWidget);
        expect(find.byType(Workspace), findsNothing);
        expect(
          find.descendant(
            of: find.byType(VaultPickerScreen),
            matching: find.text('memex'),
          ),
          findsNothing,
          reason: 'the deleted vault is not listed',
        );
        expect(
          env.settings.recentRefs,
          isNot(contains(LocalVaultRef(env.openPath!))),
        );
      },
    );

    testWidgets(
      'cancelling delete vault from the open local pill keeps the vault open',
      (tester) async {
        final env = await wi362PumpLocal(tester);
        final before = wi362Snapshot(env);

        await wi363SecondaryClick(tester, wi363PillLabel('memex'));
        await wi363PressMenu(tester, _delete);
        expect(find.byType(DeleteVaultDialog), findsOneWidget);
        await wi362Tap(tester, find.byKey(const Key('delete-vault-cancel')));

        expect(env.trash.calls, isEmpty);
        expect(find.byType(DeleteVaultDialog), findsNothing);
        expect(find.byType(Workspace), findsOneWidget);
        expect(wi362Snapshot(env), before);
      },
    );

    testWidgets(
      'delete vault on another local pill trashes it and keeps the open vault',
      (tester) async {
        final env = await wi362PumpLocal(tester);

        await wi363SecondaryClick(tester, wi363PillLabel('work-notes'));
        await wi363PressMenu(tester, _delete);
        expect(
          find.byKey(const Key('delete-vault-open-line')),
          findsNothing,
          reason: 'not the open vault',
        );
        await wi362Tap(tester, find.byKey(const Key('delete-vault-confirm')));
        await wi362Settle(tester);

        expect(env.trash.calls, [env.otherPath]);
        expect(env.current, LocalVaultRef(env.openPath!));
        expect(find.byType(Workspace), findsOneWidget);
        expect(wi363PillLabel('work-notes'), findsNothing);
        expect(env.guardCalls, isEmpty);
      },
    );
  });

  group('remove from recents and show in Finder (AC10, AC11)', () {
    testWidgets(
      'remove from recents on another local pill removes that pill and keeps the open vault',
      (tester) async {
        final env = await wi362PumpLocal(tester);
        final current = env.current;

        await wi363SecondaryClick(tester, wi363PillLabel('work-notes'));
        await wi363PressMenu(tester, _remove);

        expect(wi363PillLabel('work-notes'), findsNothing);
        expect(
          env.settings.recentRefs,
          isNot(contains(LocalVaultRef(env.otherPath!))),
        );
        expect(Directory(env.otherPath!).existsSync(), isTrue);
        expect(env.trash.calls, isEmpty);
        expect(env.current, current);
        expect(env.settings.lastVaultRef, LocalVaultRef(env.openPath!));
        expect(wi363PillLabel('memex'), findsOneWidget);
        expect(find.byType(Workspace), findsOneWidget);
        expect(env.guardCalls, isEmpty);
      },
    );

    testWidgets(
      'remove from recents on a hosted pill removes that pill and keeps the open vault',
      (tester) async {
        final env = await wi362PumpLocal(tester);

        await wi363SecondaryClick(tester, _pill(_seedLabel));
        await wi363PressMenu(tester, _remove);

        expect(wi363HostedPill(fakeServerId, seedVaultName), findsNothing);
        expect(env.settings.recentRefs, isNot(contains(seedHostedRef)));
        expect(env.settings.savedServers, hasLength(1), reason: 'server kept');
        expect(env.current, LocalVaultRef(env.openPath!));
        expect(find.byType(Workspace), findsOneWidget);
      },
    );

    for (final (name, open) in [
      (
        'show in Finder on the open local pill calls the file revealer with its path',
        true,
      ),
      (
        'show in Finder on another local pill calls the file revealer with its path',
        false,
      ),
    ]) {
      testWidgets(name, (tester) async {
        final env = await wi362PumpLocal(tester);
        final before = wi362Snapshot(env);
        final path = open ? env.openPath! : env.otherPath!;

        await wi363SecondaryClick(
          tester,
          wi363PillLabel(open ? 'memex' : 'work-notes'),
        );
        await wi363PressMenu(tester, _finder);

        expect(env.revealer.paths, [path]);
        expect(wi363MenuShown(tester), isEmpty);
        expect(wi362Snapshot(env), before);
      });
    }
  });

  group('left click (AC12)', () {
    testWidgets(
      'a left click on another local pill still switches to that vault',
      (tester) async {
        final env = await wi362PumpLocal(tester);

        await wi362Tap(tester, wi363PillLabel('work-notes'));
        await wi362Settle(tester, rounds: 12);

        expect(env.guardCalls, hasLength(1));
        expect(env.current, LocalVaultRef(env.otherPath!));
        expect(wi363MenuShown(tester), isEmpty);
        expect(wi362Modal, findsNothing);
      },
    );
  });
}
