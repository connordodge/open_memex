// WI #38 (Spec #31 req 17, D15) adds the update-ready label: the same one
// Text reads `v<current> · update ready` while the update controller is
// Ready (A0's FakeUpdateController), and only then is it a tap target that
// opens the update modal at Ready. `_wi38` helpers are this WI's.
//
// WI #374 (Spec #367 Req 15-17; label style and position unchanged): the
// vault picker header and the sidebar show `v<version>` from
// appVersionProvider in place of the hard-coded `v0.4`, and show nothing when
// the version is empty (the default); the binary-not-found card says to
// reinstall Open Memex or build it from source. Seams: `pumpVaultPicker`
// (test/support/vault_picker_harness.dart) and `wi362PumpLocal`
// (test/support/wi362_modal.dart), both with `extraOverrides`.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/app_version.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/updater/appcast.dart';
import 'package:open_memex_app/src/updater/update_controller.dart';
import 'package:open_memex_app/src/updater/update_seams.dart';
import 'package:open_memex_app/src/updater/update_state.dart';
import 'package:open_memex_app/src/widgets/sidebar.dart';

import '../support/font_fetch_hold.dart';
import '../support/updater_fakes.dart';
import '../support/vault_picker_harness.dart';
import '../support/wi362_modal.dart';
import '../support/wi363_sidebar.dart';

/// Built at run time so the override carries a real value.
Override _wi374Version(String version) =>
    appVersionProvider.overrideWithValue(version);

/// The Row holding the Text `open memex` (the brand row): the nearest Row
/// around it.
Finder _wi374BrandRow(Finder within) => find
    .ancestor(
      of: find.descendant(of: within, matching: find.text('open memex')),
      matching: find.byType(Row),
    )
    .first;

/// Every Text drawn inside [row], in order.
List<String> _wi374Texts(WidgetTester tester, Finder row) => [
  for (final t in tester.widgetList<Text>(
    find.descendant(of: row, matching: find.byType(Text)),
  ))
    t.data ?? '',
];

/// The label Keys (D15).
const _wi38SidebarLabel = Key('sidebar-version-label');
const _wi38PickerLabel = Key('picker-version-label');

/// `1.2.3`, built at run time.
final _wi38Version = ['1', '2', '3'].join('.');

AppcastItem _wi38Item() => testAppcastItem(
  shortVersionString: ['1', '4', '0'].join('.'),
  version: '12',
);

UpdateReady _wi38Ready() =>
    UpdateReady(_wi38Item(), dmgPath: '/updater-test/wi38.dmg');

/// The app version, the fake controller and updates on (so a modal opened
/// from the label renders the controller's state, not the off copy).
List<Override> _wi38Overrides(FakeUpdateController controller) => [
  appVersionProvider.overrideWithValue(_wi38Version),
  updatesEnabledProvider.overrideWithValue(true),
  updateControllerProvider.overrideWith(() => controller),
];

/// Pumps the picker or the sidebar (a vault open) over [controller].
Future<Finder> _wi38Pump(
  WidgetTester tester,
  FakeUpdateController controller, {
  required bool picker,
}) async {
  final overrides = _wi38Overrides(controller);
  if (picker) {
    await pumpVaultPicker(tester, extraOverrides: overrides);
  } else {
    await wi362PumpLocal(tester, extraOverrides: overrides);
  }
  return find.byKey(picker ? _wi38PickerLabel : _wi38SidebarLabel);
}

/// Draws frames without settling (the workspace animates forever).
Future<void> _wi38Frames(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// The cursor a mouse shows over [target]'s centre; the mouse is removed
/// afterwards.
Future<MouseCursor?> _wi38CursorOver(WidgetTester tester, Finder target) async {
  final at = tester.getCenter(target);
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: at);
  try {
    await tester.pump();
    await mouse.moveTo(at);
    await tester.pump();
    return RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1);
  } finally {
    await mouse.removePointer();
    await tester.pump();
  }
}

/// The states outside Ready, built at run time.
List<UpdateState> _wi38NotReady() => [
  const UpdateIdle(),
  const UpdateChecking(),
  const UpdateUpToDate(),
  UpdateAvailable(_wi38Item()),
  UpdateDownloading(_wi38Item(), progress: 0.5),
  UpdateVerifying(_wi38Item()),
  UpdateError(UpdateErrorCause.downloadFailed, item: _wi38Item()),
];

void main() {
  holdFontFetches();

  final v020 = ['0', '2', '0'].join('.');

  group('vault picker header', () {
    testWidgets(
      'with the version 0.2.0 the picker header shows v0.2.0 and no v0.4',
      (tester) async {
        await pumpVaultPicker(tester, extraOverrides: [_wi374Version(v020)]);

        expect(find.text('v0.2.0'), findsOneWidget);
        expect(find.text('v0.4'), findsNothing);
      },
    );

    testWidgets(
      'the picker version label keeps its style and sits last in the brand row',
      (tester) async {
        await pumpVaultPicker(tester, extraOverrides: [_wi374Version(v020)]);

        expect(find.text('v0.2.0'), findsOneWidget);
        final label = tester.widget<Text>(find.text('v0.2.0'));
        expect(label.style?.fontSize, 11);
        expect(label.style?.color, OmColors.fg3);
        expect(label.style?.letterSpacing, 0.8);
        final row = _wi374BrandRow(find.byType(Scaffold));
        expect(_wi374Texts(tester, row), ['open memex', 'v0.2.0']);
        expect(
          tester.getTopRight(find.text('v0.2.0')).dx,
          tester.getTopRight(row).dx,
          reason: 'pushed to the row end by the Spacer',
        );
        expect(
          tester.getTopLeft(find.text('v0.2.0')).dx,
          greaterThan(tester.getTopRight(find.text('open memex')).dx),
        );
      },
    );

    testWidgets(
      'with the version not overridden the picker builds and shows no version label',
      (tester) async {
        await pumpVaultPicker(tester);

        expect(tester.takeException(), isNull);
        expect(find.text('v0.4'), findsNothing);
        expect(find.textContaining(RegExp(r'^v\d')), findsNothing);
        expect(find.text('v'), findsNothing);
        expect(_wi374Texts(tester, _wi374BrandRow(find.byType(Scaffold))), [
          'open memex',
        ]);
      },
    );

    testWidgets('with an empty version the picker shows no version label', (
      tester,
    ) async {
      await pumpVaultPicker(tester, extraOverrides: [_wi374Version('')]);

      expect(find.text('v'), findsNothing);
      expect(find.textContaining(RegExp(r'^v\d')), findsNothing);
      expect(_wi374Texts(tester, _wi374BrandRow(find.byType(Scaffold))), [
        'open memex',
      ]);
    });
  });

  group('sidebar header', () {
    testWidgets('with the version 0.2.0 the sidebar shows v0.2.0 and no v0.4', (
      tester,
    ) async {
      await wi362PumpLocal(tester, extraOverrides: [_wi374Version(v020)]);

      expect(wi363InSidebar(find.text('v0.2.0')), findsOneWidget);
      expect(wi363InSidebar(find.text('v0.4')), findsNothing);
    });

    testWidgets(
      'the sidebar version label keeps its style and sits last in the header row',
      (tester) async {
        await wi362PumpLocal(tester, extraOverrides: [_wi374Version(v020)]);

        final labelFinder = wi363InSidebar(find.text('v0.2.0'));
        expect(labelFinder, findsOneWidget);
        final label = tester.widget<Text>(labelFinder);
        expect(label.style?.fontSize, 10);
        expect(label.style?.color, OmColors.fg3);
        expect(label.style?.letterSpacing, 0.8);
        final row = _wi374BrandRow(find.byType(Sidebar));
        expect(_wi374Texts(tester, row), ['open memex', 'v0.2.0']);
        expect(
          tester.getTopLeft(labelFinder).dx,
          greaterThan(
            tester.getTopRight(wi363InSidebar(find.text('open memex'))).dx,
          ),
        );
      },
    );

    testWidgets(
      'with the version not overridden the sidebar builds and shows no version label',
      (tester) async {
        await wi362PumpLocal(tester);

        expect(tester.takeException(), isNull);
        expect(wi363InSidebar(find.text('v0.4')), findsNothing);
        expect(
          wi363InSidebar(find.textContaining(RegExp(r'^v\d'))),
          findsNothing,
        );
        expect(wi363InSidebar(find.text('v')), findsNothing);
        expect(_wi374Texts(tester, _wi374BrandRow(find.byType(Sidebar))), [
          'open memex',
        ]);
      },
    );
  });

  group('binary not found card', () {
    testWidgets(
      'the binary not found card says to reinstall Open Memex or build it from source',
      (tester) async {
        await pumpVaultPicker(tester, binary: false);

        expect(
          find.text(
            'reinstall Open Memex, or build it from source:\n'
            '  cargo install --path crates/memex-mcp --locked',
          ),
          findsOneWidget,
        );
        expect(
          find.textContaining('reinstall Open Memex, or build it from source:'),
          findsOneWidget,
        );
        expect(
          find.textContaining('cargo install --path crates/memex-mcp --locked'),
          findsOneWidget,
        );
        expect(find.textContaining('install with:'), findsNothing);
      },
    );

    testWidgets(
      'the binary not found card keeps its title line and locate button',
      (tester) async {
        await pumpVaultPicker(tester, binary: false);

        expect(find.text('memex binary not found'), findsOneWidget);
        expect(
          find.text("local vaults need it. hosted vaults don't."),
          findsOneWidget,
        );
        expect(find.text('locate memex binary…'), findsOneWidget);
      },
    );
  });

  group('update ready label', () {
    for (final (name, picker) in [
      (
        'the sidebar label reads the version and update ready only while ready',
        false,
      ),
      (
        'the picker label reads the version and update ready only while ready',
        true,
      ),
    ]) {
      testWidgets(name, (tester) async {
        final controller = FakeUpdateController();
        final label = await _wi38Pump(tester, controller, picker: picker);

        expect(label, findsOneWidget);
        expect(tester.widget<Text>(label).data, 'v1.2.3');

        controller.emit(_wi38Ready());
        await _wi38Frames(tester);
        expect(label, findsOneWidget);
        expect(tester.widget<Text>(label).data, 'v1.2.3 · update ready');
        expect(find.text('v1.2.3 · update ready'), findsOneWidget);
        expect(find.text('v1.2.3'), findsNothing, reason: 'one Text, not two');

        for (final state in _wi38NotReady()) {
          controller.emit(state);
          await _wi38Frames(tester);
          expect(tester.widget<Text>(label).data, 'v1.2.3', reason: '$state');
        }
      });
    }

    for (final (name, picker, size) in [
      ('the sidebar update ready label keeps the label style', false, 10.0),
      ('the picker update ready label keeps the label style', true, 11.0),
    ]) {
      testWidgets(name, (tester) async {
        final label = await _wi38Pump(
          tester,
          FakeUpdateController(_wi38Ready()),
          picker: picker,
        );

        final text = tester.widget<Text>(label);
        expect(text.data, 'v1.2.3 · update ready');
        expect(text.style?.fontSize, size);
        expect(text.style?.color, OmColors.fg3);
        expect(text.style?.letterSpacing, 0.8);
        final row = _wi374BrandRow(
          picker ? find.byType(Scaffold) : find.byType(Sidebar),
        );
        expect(_wi374Texts(tester, row), [
          'open memex',
          'v1.2.3 · update ready',
        ]);
        expect(
          tester.getTopLeft(label).dx,
          greaterThan(
            tester
                .getTopRight(
                  find.descendant(of: row, matching: find.text('open memex')),
                )
                .dx,
          ),
        );
      });
    }

    for (final (name, picker) in [
      (
        'clicking the sidebar label while ready opens the modal at ready',
        false,
      ),
      ('clicking the picker label while ready opens the modal at ready', true),
    ]) {
      testWidgets(name, (tester) async {
        final controller = FakeUpdateController(_wi38Ready());
        final label = await _wi38Pump(tester, controller, picker: picker);
        expect(find.byKey(const Key('update-modal')), findsNothing);

        await tester.tap(label);
        await _wi38Frames(tester);

        expect(find.byKey(const Key('update-modal')), findsOneWidget);
        expect(
          tester.widget<Text>(find.byKey(const Key('update-modal-title'))).data,
          'Update ready',
        );
        expect(find.byKey(const Key('update-modal-relaunch')), findsOneWidget);
        expect(controller.calls, isEmpty, reason: 'opening calls no action');
      });
    }

    for (final (name, picker) in [
      ('outside ready the sidebar label is no tap target', false),
      ('outside ready the picker label is no tap target', true),
    ]) {
      testWidgets(name, (tester) async {
        final controller = FakeUpdateController();
        final label = await _wi38Pump(tester, controller, picker: picker);
        expect(label, findsOneWidget);

        controller.emit(_wi38Ready());
        await _wi38Frames(tester);
        expect(
          await _wi38CursorOver(tester, label),
          SystemMouseCursors.click,
          reason: 'Ready: a tap target',
        );

        for (final state in _wi38NotReady()) {
          controller.emit(state);
          await _wi38Frames(tester);
          expect(
            await _wi38CursorOver(tester, label),
            isNot(SystemMouseCursors.click),
            reason: '$state',
          );
          await tester.tap(label, warnIfMissed: false);
          await _wi38Frames(tester);
          expect(
            find.byKey(const Key('update-modal')),
            findsNothing,
            reason: '$state',
          );
        }
      });
    }
  });
}
