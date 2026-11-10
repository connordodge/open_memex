// WI #374 (Spec #367 Req 15-17; label style and position unchanged): the
// vault picker header and the sidebar show `v<version>` from
// appVersionProvider in place of the hard-coded `v0.4`, and show nothing when
// the version is empty (the default); the binary-not-found card says to
// reinstall Open Memex or build it from source. Seams: `pumpVaultPicker`
// (test/support/vault_picker_harness.dart) and `wi362PumpLocal`
// (test/support/wi362_modal.dart), both with `extraOverrides`.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/app_version.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/widgets/sidebar.dart';

import '../support/font_fetch_hold.dart';
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
}
