// WI #363 (Spec #357 Req 1-3, 17-20, 22, 26; design pack 363, boards S1,
// S2): seams for the sidebar MANAGE header and vault pill tests, over
// #362's whole-app env (`wi362PumpLocal` / `wi362PumpHosted`):
// - finders for the MANAGE button (`sidebar-vaults-manage`), the VAULTS and
//   CANVASES headers and the vault pills (a local pill by its folder name,
//   a hosted pill by `vault-pill-<serverId>-<vault>`);
// - probes for the MANAGE button's and a pill's drawn style (fill, border,
//   text colour) read off the boxes and paragraphs they draw;
// - a secondary click and a menu-item press that settle without
//   pumpAndSettle (the workspace animates forever);
// - `wi363LeaveVault`: switch vault through the controller, now that the
//   sidebar no longer calls `leaveVault` (existing guard tests use it).
// Helpers carry the `wi363` prefix so stacked siblings never collide.
import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/screens/workspace.dart';
import 'package:open_memex_app/src/state/vault_open_controller.dart';
import 'package:open_memex_app/src/widgets/atoms.dart';
import 'package:open_memex_app/src/widgets/sidebar.dart';

import 'wi362_modal.dart';

const wi363ManageKey = Key('sidebar-vaults-manage');

/// The VAULTS header's MANAGE button.
Finder get wi363Manage => find.byKey(wi363ManageKey);

/// The sidebar's [PanelHeader] whose eyebrow reads [eyebrow] (upper case).
Finder wi363Header(String eyebrow) =>
    find.ancestor(of: find.text(eyebrow), matching: find.byType(PanelHeader));

/// [matching] inside the sidebar.
Finder wi363InSidebar(Finder matching) =>
    find.descendant(of: find.byType(Sidebar), matching: matching);

/// The label of the pill whose text is [label] (a local folder name or a
/// hosted `<vault> · <server>`), inside the sidebar.
Finder wi363PillLabel(String label) => wi363InSidebar(find.text(label));

/// The hosted pill of [vault] on [serverId].
Finder wi363HostedPill(String serverId, String vault) =>
    find.byKey(Key('vault-pill-$serverId-$vault'));

/// The outline box of the pill labelled [label]: the nearest box around
/// the label drawn fully rounded (radius 999).
Finder wi363PillBox(String label) => find
    .ancestor(
      of: wi363PillLabel(label),
      matching: find.byWidgetPredicate(
        (w) =>
            w is DecoratedBox &&
            w.decoration is BoxDecoration &&
            (w.decoration as BoxDecoration).borderRadius ==
                BorderRadius.circular(999),
      ),
    )
    .first;

/// What a box draws: its fill and its four border colours and widths.
class Wi363Style {
  const Wi363Style(this.fill, this.border, this.borderWidth);

  /// The fill, or null when none (null or fully transparent).
  final Color? fill;

  /// The border colour when all four sides agree, or null when none.
  final Color? border;
  final double borderWidth;

  @override
  String toString() => 'fill $fill border $border ($borderWidth)';
}

Color? _wi363Visible(Color? c) => c == null || c.a == 0 ? null : c;

Wi363Style _wi363StyleOf(BoxDecoration d) {
  final b = d.border;
  if (b is! Border) return Wi363Style(_wi363Visible(d.color), null, 0);
  final sides = [b.top, b.right, b.bottom, b.left];
  final same = sides.every(
    (s) => s.color == b.top.color && s.width == b.top.width,
  );
  return Wi363Style(
    _wi363Visible(d.color),
    same && b.top.style != BorderStyle.none ? _wi363Visible(b.top.color) : null,
    same ? b.top.width : -1,
  );
}

/// The style of the pill labelled [label].
Wi363Style wi363PillStyle(WidgetTester tester, String label) => _wi363StyleOf(
  tester.widget<DecoratedBox>(wi363PillBox(label)).decoration as BoxDecoration,
);

/// The styles of every radius-4 box at or under the MANAGE button (its
/// fill, border and focus ring), top-most first.
List<Wi363Style> wi363ManageBoxes(WidgetTester tester) => [
  for (final e
      in find
          .descendant(
            of: wi363Manage,
            matching: find.byType(DecoratedBox),
            matchRoot: true,
          )
          .evaluate())
    if ((e.widget as DecoratedBox).decoration case final BoxDecoration d
        when d.borderRadius == BorderRadius.circular(4))
      _wi363StyleOf(d),
];

/// The fills the MANAGE button draws (none when idle).
List<Color> wi363ManageFills(WidgetTester tester) => [
  for (final s in wi363ManageBoxes(tester)) ?s.fill,
];

/// The border colours the MANAGE button draws (none when idle).
List<Color> wi363ManageBorders(WidgetTester tester) => [
  for (final s in wi363ManageBoxes(tester)) ?s.border,
];

/// The colour the paragraph showing [text] under [of] paints its text in.
Color? wi363TextColour(WidgetTester tester, Finder of, String text) {
  final f = find.descendant(of: of, matching: find.text(text));
  expect(f, findsOneWidget, reason: '$text under $of');
  final para = tester.renderObject<RenderParagraph>(f);
  return para.text.style?.color;
}

/// A secondary (right) mouse click on [target]'s centre, then settles.
Future<void> wi363SecondaryClick(WidgetTester tester, Finder target) async {
  expect(target, findsOneWidget);
  await tester.tapAt(
    tester.getCenter(target),
    buttons: kSecondaryButton,
    kind: PointerDeviceKind.mouse,
  );
  await wi362Settle(tester);
}

/// The vault menu item keys, in menu order.
const wi363MenuKeys = [
  'vault-menu-finder',
  'vault-menu-remove',
  'vault-menu-delete',
  'vault-menu-manage',
];

/// The `vault-menu-*` items now shown, top to bottom.
List<String> wi363MenuShown(WidgetTester tester) {
  final shown = [
    for (final k in wi363MenuKeys)
      if (find.byKey(Key(k)).evaluate().isNotEmpty) k,
  ];
  shown.sort(
    (a, b) => tester
        .getRect(find.byKey(Key(a)))
        .top
        .compareTo(tester.getRect(find.byKey(Key(b))).top),
  );
  return shown;
}

/// Presses the vault menu item [key] (one of [wi363MenuKeys]) and settles.
Future<void> wi363PressMenu(WidgetTester tester, String key) async {
  final item = find.byKey(Key(key));
  expect(item, findsOneWidget, reason: '$key shows');
  await tester.tap(item);
  await wi362Settle(tester);
}

/// Switch vault (the old VAULTS `+ new`): `VaultOpenController.leaveVault`
/// from the workspace, not awaited, as a tap would leave it running. The
/// sidebar no longer calls it (#363); the controller keeps its contract.
void wi363LeaveVault(WidgetTester tester) {
  final context = tester.element(find.byType(Workspace));
  unawaited(
    ProviderScope.containerOf(
      context,
      listen: false,
    ).read(vaultOpenControllerProvider).leaveVault(context),
  );
}
