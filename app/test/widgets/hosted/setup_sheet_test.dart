// WI #100 (H6, board A8 "set up a vault server"): the static setup sheet.
// `showSetUpVaultServerSheet(context)` takes no providers, makes no request
// and reads no settings, so every test pumps a bare MaterialApp (no
// ProviderScope). Exact values come from design pack #100; the lead decision
// there makes `docs/hosted-vault.md` monospace text with a footer copy button.
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:open_memex_app/src/theme/app_theme.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/widgets/atoms.dart';
import 'package:open_memex_app/src/widgets/hosted/setup_sheet.dart';

const _eyebrow = 'SET UP A VAULT SERVER';
const _intro =
    'a vault server is memex running on an always-on machine. it keeps your '
    'vaults on its own disk; this mac and your agents reach them over your '
    'network.';
const _docs = 'docs/hosted-vault.md';
const _cmd2 = 'memex init /volume1/memex/memex';
const _cmd3 = 'memex serve --root /volume1/memex --listen 192.168.1.20:7878';
const _cmd4 = 'cat /volume1/memex/.memex/access-token';
const _warning =
    'use your home network or tailscale. never expose the server to the '
    'internet.';
const _connectLabel = 'connect to a vault server…';

const _titles = <String>[
  'install memex on the always-on machine',
  "create a vault in the server's vault root",
  'start the vault server',
  'copy the access token',
  'connect from this app',
];
const _sublines = <String>[
  '(see docs/hosted-vault.md for a nas, linux or a mac)',
  'or create one from this app after you connect.',
  "listen on the machine's home-network or tailscale address.",
  // Step 4 has no subline.
  'choose connect to a vault server…, then paste the url and the token.',
];

// flutter_test draws every font as Ahem (one em per glyph), so text is far
// wider and taller than on the board. Content tests use a window tall enough
// to hold the whole sheet; the layout group uses the real window sizes.
const _tall = Size(1280, 3000);

final _sheet = find.byKey(const Key('setup-sheet'));

/// Records the pushes and pops that happen after the sheet is open.
class _Routes extends NavigatorObserver {
  int pushed = 0;
  int popped = 0;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => pushed++;
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => popped++;
}

/// What a test learns from opening the sheet.
class _Opened {
  _Opened(this.routes);
  final _Routes routes;
  final results = <bool>[];
  final clipboard = <String>[];
}

void _setWindow(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// Pump a bare MaterialApp (no ProviderScope), mock the platform clipboard
/// and open the sheet from a launcher button. The pop count and push count
/// are reset once the sheet is up.
Future<_Opened> _open(WidgetTester tester, {Size size = _tall}) async {
  _setWindow(tester, size);
  final routes = _Routes();
  final opened = _Opened(routes);
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'Clipboard.setData') {
        final args = call.arguments as Map<Object?, Object?>;
        opened.clipboard.add(args['text'] as String);
      }
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: buildOmTheme(),
      navigatorObservers: [routes],
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              key: const Key('open-sheet'),
              onPressed: () async =>
                  opened.results.add(await showSetUpVaultServerSheet(context)),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const Key('open-sheet')));
  await tester.pumpAndSettle();
  routes
    ..pushed = 0
    ..popped = 0;
  return opened;
}

// ------------------------------------------------------------------ helpers

String _plain(Text w) => w.data ?? w.textSpan?.toPlainText() ?? '';

/// The one Text (inside the sheet) whose whole plain text is [s].
Finder _text(String s) => find.descendant(
  of: _sheet,
  matching: find.byWidgetPredicate((w) => w is Text && _plain(w) == s),
);

/// The effective style of the single [Text] whose plain text is [s].
TextStyle _style(WidgetTester tester, String s) {
  final w = tester.widget<Text>(_text(s));
  return w.style ?? w.textSpan!.style!;
}

bool _isMono(TextStyle? s) =>
    (s?.fontFamily ?? '').toLowerCase().contains('jetbrainsmono');

/// One run of text equal to [leaf]: the owning Text, its rect and the style
/// the run is drawn with (span style merged over the Text style).
typedef _Piece = ({Text text, Rect rect, TextStyle? style});

List<_Piece> _pieces(WidgetTester tester, String leaf) {
  final out = <_Piece>[];
  for (final w in tester.widgetList<Text>(
    find.descendant(of: _sheet, matching: find.byType(Text)),
  )) {
    final rect = tester.getRect(find.byWidget(w));
    if (w.data == leaf) {
      out.add((text: w, rect: rect, style: w.style));
      continue;
    }
    final root = w.textSpan;
    if (root == null) continue;
    void walk(InlineSpan s, TextStyle? inherited) {
      if (s is! TextSpan) return;
      final st = s.style == null
          ? inherited
          : inherited?.merge(s.style) ?? s.style;
      if (s.text == leaf) out.add((text: w, rect: rect, style: st));
      for (final c in s.children ?? const <InlineSpan>[]) {
        walk(c, st);
      }
    }

    walk(root, w.style);
  }
  return out;
}

Rect _titleRect(WidgetTester tester, int step) =>
    tester.getRect(_text(_titles[step - 1]));

/// The nearest DecoratedBox ancestor of [of] whose fill is [fill].
BoxDecoration _boxAround(WidgetTester tester, Finder of, Color fill) {
  final f = find.ancestor(
    of: of,
    matching: find.byWidgetPredicate(
      (w) =>
          w is DecoratedBox &&
          w.decoration is BoxDecoration &&
          (w.decoration as BoxDecoration).color == fill,
    ),
  );
  expect(f, findsWidgets, reason: 'a box filled $fill around the widget');
  return tester.widget<DecoratedBox>(f.first).decoration as BoxDecoration;
}

Finder _copyIcons() => find.descendant(
  of: _sheet,
  matching: find.byWidgetPredicate(
    (w) => w is Icon && w.icon == LucideIcons.copy,
  ),
);

Future<void> _tapAcross(WidgetTester tester, Rect r) async {
  for (final f in const [0.02, 0.25, 0.5, 0.75, 0.98]) {
    await tester.tapAt(Offset(r.left + r.width * f, r.center.dy));
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

void main() {
  group('setup sheet content', () {
    testWidgets('the sheet opens with no providers and no errors', (
      tester,
    ) async {
      await _open(tester);
      expect(_sheet, findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the sheet shows the eyebrow and the intro verbatim', (
      tester,
    ) async {
      await _open(tester);
      expect(_text(_eyebrow), findsOneWidget);
      expect(_text(_intro), findsOneWidget);
      final e = _style(tester, _eyebrow);
      expect(_isMono(e), isTrue);
      expect(e.fontSize, 11);
      expect(e.fontWeight, FontWeight.w500);
      expect(e.letterSpacing, 1.0);
      expect(e.color, OmColors.fg2);
      final i = _style(tester, _intro);
      expect(_isMono(i), isFalse);
      expect(i.fontSize, 12.5);
      expect(i.fontWeight, FontWeight.w400);
      expect(i.color, OmColors.fg2);
    });

    testWidgets(
      'the five numbered steps appear in order with the exact titles',
      (tester) async {
        await _open(tester);
        var lastTop = -1.0;
        for (var n = 1; n <= 5; n++) {
          expect(_text(_titles[n - 1]), findsOneWidget, reason: 'step $n');
          final t = _titleRect(tester, n);
          expect(t.top, greaterThan(lastTop), reason: 'step $n below step');
          lastTop = t.top;
          final s = _style(tester, _titles[n - 1]);
          expect(s.fontSize, 13.5);
          expect(s.fontWeight, FontWeight.w500);
          expect(s.color, OmColors.fg0);
          // The numbered badge: a mono 11 fg1 digit on the title row.
          final badge = _text('$n');
          expect(badge, findsOneWidget, reason: 'badge $n');
          expect(
            (tester.getRect(badge).center.dy - t.center.dy).abs(),
            lessThan(14),
            reason: 'badge $n sits on the title row of step $n',
          );
          final b = _style(tester, '$n');
          expect(_isMono(b), isTrue);
          expect(b.fontSize, 11);
          expect(b.fontWeight, FontWeight.w500);
          expect(b.color, OmColors.fg1);
        }
      },
    );

    testWidgets('each step badge is a 22 px circle with a line3 border', (
      tester,
    ) async {
      await _open(tester);
      for (var n = 1; n <= 5; n++) {
        final f = find.ancestor(
          of: _text('$n'),
          matching: find.byWidgetPredicate(
            (w) =>
                w is DecoratedBox &&
                w.decoration is BoxDecoration &&
                (w.decoration as BoxDecoration).shape == BoxShape.circle,
          ),
        );
        expect(f, findsWidgets, reason: 'badge $n is a circle');
        final d =
            tester.widget<DecoratedBox>(f.first).decoration as BoxDecoration;
        expect(d.color, anyOf(isNull, Colors.transparent));
        final border = d.border! as Border;
        expect(border.isUniform, isTrue);
        expect(border.top.width, 1);
        expect(border.top.color, OmColors.line3);
        expect(tester.getSize(f.first), const Size(22, 22));
      }
    });

    testWidgets('the commands and sublines appear verbatim in their steps', (
      tester,
    ) async {
      await _open(tester);
      // Steps 2, 3 and 4 each show their command below their title.
      final cmds = [_cmd2, _cmd3, _cmd4];
      for (var i = 0; i < cmds.length; i++) {
        final step = i + 2;
        expect(_text(cmds[i]), findsOneWidget, reason: 'command $step');
        final c = tester.getRect(_text(cmds[i]));
        expect(c.top, greaterThan(_titleRect(tester, step).bottom - 1));
        expect(c.bottom, lessThan(_titleRect(tester, step + 1).top + 1));
        final s = _style(tester, cmds[i]);
        expect(_isMono(s), isTrue);
        expect(s.fontSize, 12);
        expect(s.fontWeight, FontWeight.w400);
        expect(s.color, OmColors.fg1);
      }
      // Sublines for steps 1, 2, 3 and 5, in the same order as the steps.
      const subStep = [1, 2, 3, 5];
      for (var i = 0; i < _sublines.length; i++) {
        final step = subStep[i];
        expect(_text(_sublines[i]), findsOneWidget, reason: 'subline $step');
        final r = tester.getRect(_text(_sublines[i]));
        expect(r.top, greaterThan(_titleRect(tester, step).top));
        if (step < 5) {
          expect(r.bottom, lessThan(_titleRect(tester, step + 1).top + 1));
        }
      }
      // Sublines other than step 1 are plain fg2 sans 12.5.
      for (final s in _sublines.skip(1)) {
        final st = _style(tester, s);
        expect(st.fontSize, 12.5);
        expect(st.color, OmColors.fg2);
        expect(_isMono(st), isFalse);
      }
    });

    testWidgets('each command sits in a 38 px code block with a copy button', (
      tester,
    ) async {
      await _open(tester);
      final cases = [
        (_cmd2, 'setup-copy-2'),
        (_cmd3, 'setup-copy-3'),
        (_cmd4, 'setup-copy-4'),
      ];
      for (final (cmd, copyKey) in cases) {
        final d = _boxAround(tester, _text(cmd), OmColors.surface0);
        final box = find.ancestor(
          of: _text(cmd),
          matching: find.byWidgetPredicate(
            (w) =>
                w is DecoratedBox &&
                w.decoration is BoxDecoration &&
                (w.decoration as BoxDecoration).color == OmColors.surface0,
          ),
        );
        final border = d.border! as Border;
        expect(border.isUniform, isTrue);
        expect(border.top.width, 1);
        expect(border.top.color, OmColors.line2);
        expect(d.borderRadius, BorderRadius.circular(6));
        expect(tester.getSize(box.first).height, 38);
        // One line, ellipsis when long.
        final t = tester.widget<Text>(_text(cmd));
        expect(t.maxLines, 1);
        expect(t.overflow, TextOverflow.ellipsis);
        // The copy button lives inside the block.
        expect(
          find.descendant(of: box.first, matching: find.byKey(Key(copyKey))),
          findsOneWidget,
          reason: copyKey,
        );
      }
      // Exactly three code blocks: steps 1 and 5 have none.
      final blocks = find.descendant(
        of: _sheet,
        matching: find.byWidgetPredicate(
          (w) =>
              w is DecoratedBox &&
              w.decoration is BoxDecoration &&
              (w.decoration as BoxDecoration).color == OmColors.surface0,
        ),
      );
      expect(blocks, findsNWidgets(3));
    });
  });

  group('setup sheet copy buttons', () {
    testWidgets('step 1 and step 5 have no command and no copy button', (
      tester,
    ) async {
      await _open(tester);
      expect(find.byKey(const Key('setup-copy-1')), findsNothing);
      expect(find.byKey(const Key('setup-copy-5')), findsNothing);
      // Only steps 2, 3, 4 and the footer path carry a copy glyph.
      expect(_copyIcons(), findsNWidgets(4));
      for (final key in const [
        'setup-copy-2',
        'setup-copy-3',
        'setup-copy-4',
        'setup-copy-docs',
      ]) {
        expect(find.byKey(Key(key)), findsOneWidget, reason: key);
      }
    });

    testWidgets('every copy button is a 24 px square with a 12 px fg2 glyph', (
      tester,
    ) async {
      await _open(tester);
      for (final key in const [
        'setup-copy-2',
        'setup-copy-3',
        'setup-copy-4',
        'setup-copy-docs',
      ]) {
        final k = find.byKey(Key(key));
        expect(tester.getSize(k), const Size(24, 24), reason: key);
        final icon = tester.widget<Icon>(
          find.descendant(
            of: k,
            matching: find.byWidgetPredicate(
              (w) => w is Icon && w.icon == LucideIcons.copy,
            ),
          ),
        );
        expect(icon.size, 12, reason: key);
        expect(icon.color, OmColors.fg2, reason: key);
      }
    });

    // (name, key, exact clipboard text); the name is a literal in each tuple.
    final cases = <(String, String, String)>[
      (
        'the step 2 copy button puts exactly the memex init command on the clipboard',
        'setup-copy-2',
        _cmd2,
      ),
      (
        'the step 3 copy button puts exactly the memex serve command on the clipboard',
        'setup-copy-3',
        _cmd3,
      ),
      (
        'the step 4 copy button puts exactly the access token command on the clipboard',
        'setup-copy-4',
        _cmd4,
      ),
      (
        'the footer copy button puts exactly docs/hosted-vault.md on the clipboard',
        'setup-copy-docs',
        _docs,
      ),
    ];
    for (final (name, key, text) in cases) {
      testWidgets(name, (tester) async {
        final o = await _open(tester);
        expect(o.clipboard, isEmpty, reason: 'nothing copied on open');
        await tester.tap(find.byKey(Key(key)));
        await tester.pumpAndSettle();
        expect(o.clipboard, [text]);
        expect(_sheet, findsOneWidget, reason: 'copying keeps the sheet open');
        expect(o.results, isEmpty);
      });
    }

    testWidgets('copying twice in a row writes each command once in order', (
      tester,
    ) async {
      final o = await _open(tester);
      await tester.tap(find.byKey(const Key('setup-copy-3')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('setup-copy-2')));
      await tester.pumpAndSettle();
      expect(o.clipboard, [_cmd3, _cmd2]);
    });
  });

  group('setup sheet docs path', () {
    testWidgets(
      'the docs path renders as monospace text in step 1 and the footer',
      (tester) async {
        await _open(tester);
        final pieces = _pieces(tester, _docs)
          ..sort((a, b) => a.rect.top.compareTo(b.rect.top));
        expect(pieces, hasLength(2), reason: 'step 1 subline and footer');
        final inStep1 = pieces.first.rect;
        final inFooter = pieces.last.rect;
        expect(inStep1.top, greaterThan(_titleRect(tester, 1).top));
        expect(inStep1.bottom, lessThan(_titleRect(tester, 2).top + 1));
        expect(
          inFooter.top,
          greaterThan(tester.getRect(_text(_warning)).bottom),
        );
        for (final p in pieces) {
          expect(_isMono(p.style), isTrue, reason: 'monospace');
          // Lead decision (L22): monospace text, not link coloured.
          expect(p.style?.color, isNot(OmColors.info));
        }
        // The footer run is part of the single line "full guide: <path>".
        expect(_text('full guide: $_docs'), findsOneWidget);
        // Step 1 reads "(see <path> for a nas, linux or a mac)" as one line.
        expect(_text(_sublines[0]), findsOneWidget);
      },
    );

    testWidgets(
      'tapping the docs path in step 1 or the footer navigates nowhere',
      (tester) async {
        final o = await _open(tester);
        final pieces = _pieces(tester, _docs)
          ..sort((a, b) => a.rect.top.compareTo(b.rect.top));
        // Tap along the whole line so the path itself is certainly hit.
        for (final p in pieces) {
          await _tapAcross(tester, p.rect);
        }
        expect(_sheet, findsOneWidget);
        expect(o.routes.pushed, 0, reason: 'no route pushed');
        expect(o.routes.popped, 0, reason: 'no route popped');
        expect(o.results, isEmpty);
        expect(o.clipboard, isEmpty, reason: 'the text is not a copy target');
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('setup sheet warning', () {
    testWidgets('the warning renders in warn styling', (tester) async {
      await _open(tester);
      expect(_text(_warning), findsOneWidget);
      final s = _style(tester, _warning);
      expect(s.color, OmColors.warn);
      expect(s.fontSize, 12.5);
      expect(s.fontWeight, FontWeight.w400);
      expect(_isMono(s), isFalse);
      final box = find.ancestor(
        of: _text(_warning),
        matching: find.byWidgetPredicate(
          (w) =>
              w is DecoratedBox &&
              w.decoration is BoxDecoration &&
              (w.decoration as BoxDecoration).color == OmColors.warnBg,
        ),
      );
      expect(box, findsWidgets);
      final d =
          tester.widget<DecoratedBox>(box.first).decoration as BoxDecoration;
      final border = d.border! as Border;
      expect(border.isUniform, isTrue);
      expect(border.top.width, 1);
      expect(border.top.color, OmColors.warn.withAlpha(64));
      expect(d.borderRadius, BorderRadius.circular(6));
      final icon = tester.widget<Icon>(
        find.descendant(
          of: box.first,
          matching: find.byWidgetPredicate(
            (w) => w is Icon && w.icon == LucideIcons.alertTriangle,
          ),
        ),
      );
      expect(icon.size, 14);
      expect(icon.color, OmColors.warn);
    });
  });

  group('setup sheet footer and result', () {
    testWidgets('close and connect are a ghost and a primary OmButton', (
      tester,
    ) async {
      await _open(tester);
      final close = tester.widget<OmButton>(
        find.byKey(const Key('setup-close')),
      );
      expect(close.kind, OmButtonKind.ghost);
      expect(close.label, 'close');
      expect(close.onPressed, isNotNull);
      final connect = tester.widget<OmButton>(
        find.byKey(const Key('setup-connect')),
      );
      expect(connect.kind, OmButtonKind.primary);
      expect(connect.label, _connectLabel);
      expect(connect.onPressed, isNotNull);
      expect(tester.getSize(find.byKey(const Key('setup-close'))).height, 30);
      expect(tester.getSize(find.byKey(const Key('setup-connect'))).height, 30);
      // Footer order: guide link, then close, then the primary on the right.
      final guide = tester.getRect(_text('full guide: $_docs'));
      final c = tester.getRect(find.byKey(const Key('setup-close')));
      final p = tester.getRect(find.byKey(const Key('setup-connect')));
      expect(guide.right, lessThan(c.left));
      expect(c.right, lessThan(p.left));
      expect((guide.center.dy - p.center.dy).abs(), lessThan(8));
    });

    testWidgets('the close X is a 24 px button with a 14 px fg2 X', (
      tester,
    ) async {
      await _open(tester);
      final x = find.byKey(const Key('setup-close-x'));
      expect(tester.getSize(x), const Size(24, 24));
      final icon = tester.widget<Icon>(
        find.descendant(
          of: x,
          matching: find.byWidgetPredicate(
            (w) => w is Icon && w.icon == LucideIcons.x,
          ),
        ),
      );
      expect(icon.size, 14);
      expect(icon.color, OmColors.fg2);
      // It sits in the header row, to the right of the eyebrow.
      final eyebrow = tester.getRect(_text(_eyebrow));
      final xr = tester.getRect(x);
      expect(xr.left, greaterThan(eyebrow.right));
      expect((xr.center.dy - eyebrow.center.dy).abs(), lessThan(6));
    });

    testWidgets('close returns false and closes the sheet', (tester) async {
      final o = await _open(tester);
      expect(o.results, isEmpty, reason: 'pending while open');
      await tester.tap(find.byKey(const Key('setup-close')));
      await tester.pumpAndSettle();
      expect(o.results, [false]);
      expect(_sheet, findsNothing);
      expect(o.routes.popped, 1);
    });

    testWidgets('the close X returns false and closes the sheet', (
      tester,
    ) async {
      final o = await _open(tester);
      await tester.tap(find.byKey(const Key('setup-close-x')));
      await tester.pumpAndSettle();
      expect(o.results, [false]);
      expect(_sheet, findsNothing);
      expect(o.routes.popped, 1);
    });

    testWidgets('connect to a vault server returns true and closes the sheet', (
      tester,
    ) async {
      final o = await _open(tester);
      await tester.tap(find.byKey(const Key('setup-connect')));
      await tester.pumpAndSettle();
      expect(o.results, [true]);
      expect(_sheet, findsNothing);
      expect(o.routes.popped, 1);
      expect(o.routes.pushed, 0, reason: 'H6 opens nothing else');
    });

    testWidgets('the sheet can be opened again after it was closed', (
      tester,
    ) async {
      final o = await _open(tester);
      await tester.tap(find.byKey(const Key('setup-connect')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('open-sheet')));
      await tester.pumpAndSettle();
      expect(_sheet, findsOneWidget);
      await tester.tap(find.byKey(const Key('setup-close')));
      await tester.pumpAndSettle();
      expect(o.results, [true, false]);
    });
  });

  group('setup sheet shell and layout', () {
    testWidgets('the sheet is 620 wide, flush with the top and centred', (
      tester,
    ) async {
      await _open(tester);
      final r = tester.getRect(_sheet);
      expect(r.width, 620);
      expect(r.top, 0, reason: 'flush with the top of the window');
      expect(r.left, 330, reason: 'centred in 1280');
      // Content padding: 24 px from the left edge (plus a 1 px border).
      final e = tester.getRect(_text(_eyebrow));
      expect(e.left - r.left, inInclusiveRange(24, 25));
    });

    testWidgets('the sheet is surface2 with square top corners and a shadow', (
      tester,
    ) async {
      await _open(tester);
      final f = find.descendant(
        of: _sheet,
        matchRoot: true,
        matching: find.byWidgetPredicate(
          (w) =>
              w is DecoratedBox &&
              w.decoration is BoxDecoration &&
              (w.decoration as BoxDecoration).color == OmColors.surface2,
        ),
      );
      expect(f, findsWidgets, reason: 'a surface2 shell');
      final d =
          tester.widget<DecoratedBox>(f.first).decoration as BoxDecoration;
      expect(
        d.borderRadius,
        const BorderRadius.only(
          bottomLeft: Radius.circular(10),
          bottomRight: Radius.circular(10),
        ),
      );
      final b = d.border! as Border;
      for (final side in [b.left, b.right, b.bottom]) {
        expect(side.width, 1);
        expect(side.color, OmColors.line2);
      }
      expect(d.boxShadow, hasLength(1));
      final sh = d.boxShadow!.single;
      expect(sh.offset, const Offset(0, 24));
      expect(sh.blurRadius, 64);
      expect(sh.color, const Color(0xFF000000).withAlpha(153));
    });

    testWidgets(
      'the sheet dims the window with a surface0 scrim at 72 percent',
      (tester) async {
        await _open(tester);
        final scrim = OmColors.surface0.withAlpha(184);
        final barriers = tester.widgetList<ModalBarrier>(
          find.byType(ModalBarrier),
        );
        expect(barriers.any((b) => b.color == scrim), isTrue);
      },
    );

    final sizes = <(String, Size)>[
      (
        'the sheet renders without overflow in a 1280 by 800 window',
        const Size(1280, 800),
      ),
      (
        'the sheet renders without overflow in a 720 by 900 window',
        const Size(720, 900),
      ),
    ];
    for (final (name, size) in sizes) {
      testWidgets(name, (tester) async {
        await _open(tester, size: size);
        expect(tester.takeException(), isNull);
        final r = tester.getRect(_sheet);
        expect(r.width, 620);
        expect(r.left, (size.width - 620) / 2);
        expect(r.bottom, lessThanOrEqualTo(size.height));
        // The footer stays on screen and the last step can be scrolled to.
        for (final key in const ['setup-close', 'setup-connect']) {
          expect(
            tester.getRect(find.byKey(Key(key))).bottom,
            lessThanOrEqualTo(size.height),
            reason: key,
          );
        }
        final scrollables = find.descendant(
          of: _sheet,
          matching: find.byType(Scrollable),
        );
        if (scrollables.evaluate().isNotEmpty) {
          await tester.scrollUntilVisible(
            _text(_titles[4]),
            80,
            scrollable: scrollables.first,
          );
        }
        expect(_titleRect(tester, 5).bottom, lessThanOrEqualTo(size.height));
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets(
      'the sheet scrolls when the window is shorter than the content',
      (tester) async {
        final o = await _open(tester, size: const Size(720, 400));
        expect(tester.takeException(), isNull, reason: 'no overflow');
        final r = tester.getRect(_sheet);
        expect(r.height, lessThanOrEqualTo(400));
        final scrollable = find
            .descendant(of: _sheet, matching: find.byType(Scrollable))
            .first;
        expect(scrollable, findsOneWidget);
        // The footer stays on screen so the person can always choose.
        expect(
          tester.getRect(find.byKey(const Key('setup-connect'))).bottom,
          lessThanOrEqualTo(400),
        );
        // Scrolling brings the last step into view.
        await tester.scrollUntilVisible(
          _text(_titles[4]),
          80,
          scrollable: scrollable,
        );
        expect(_titleRect(tester, 5).bottom, lessThanOrEqualTo(400));
        expect(tester.takeException(), isNull);
        await tester.tap(find.byKey(const Key('setup-connect')));
        await tester.pumpAndSettle();
        expect(o.results, [true]);
      },
    );
  });

  group('setup sheet dismissal and pinned tokens', () {
    testWidgets('Esc returns false and closes the sheet', (tester) async {
      final o = await _open(tester);
      expect(o.results, isEmpty, reason: 'pending while open');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(o.results, [false]);
      expect(_sheet, findsNothing);
      expect(o.routes.popped, 1);
    });

    testWidgets('tapping the scrim outside the sheet returns false', (
      tester,
    ) async {
      final o = await _open(tester);
      final r = tester.getRect(_sheet);
      // Left of the sheet, inside the window: only the barrier is there.
      expect(r.left, greaterThan(100));
      await tester.tapAt(Offset(50, 300));
      await tester.pumpAndSettle();
      expect(o.results, [false]);
      expect(_sheet, findsNothing);
      expect(o.routes.popped, 1);
    });

    testWidgets('tapping inside the sheet does not dismiss it', (tester) async {
      final o = await _open(tester);
      final r = tester.getRect(_sheet);
      // The gap between the header and the first step is plain sheet fill.
      await tester.tapAt(Offset(r.left + 2, r.top + 200));
      await tester.pumpAndSettle();
      expect(o.results, isEmpty);
      expect(_sheet, findsOneWidget);
    });

    test('OmColors.dialogShadow is black at 60 percent alpha', () {
      expect(OmColors.dialogShadow, const Color(0xFF000000).withAlpha(153));
      expect(OmColors.dialogShadow, const Color(0x99000000));
    });

    testWidgets('the sheet shadow colour is OmColors.dialogShadow', (
      tester,
    ) async {
      await _open(tester);
      final d = _boxAround(tester, _text(_eyebrow), OmColors.surface2);
      expect(d.boxShadow, hasLength(1));
      expect(d.boxShadow!.single.color, OmColors.dialogShadow);
    });

    testWidgets('the docs path is monospace 12 fg1 in step 1 and the footer', (
      tester,
    ) async {
      await _open(tester);
      final pieces = _pieces(tester, _docs);
      expect(pieces, hasLength(2));
      for (final p in pieces) {
        expect(p.style?.color, OmColors.fg1);
        expect(p.style?.fontSize, 12);
        expect(_isMono(p.style), isTrue);
      }
    });

    testWidgets('the sheet border is a 1 px line2 line on both sides and '
        'the bottom', (tester) async {
      await _open(tester);
      final d = _boxAround(tester, _text(_eyebrow), OmColors.surface2);
      final b = d.border! as Border;
      for (final side in [b.left, b.right, b.bottom]) {
        expect(side.width, 1);
        expect(side.color, OmColors.line2);
      }
      // A top line (if drawn) must be the same quiet line2, never louder.
      if (b.top.style != BorderStyle.none && b.top.width > 0) {
        expect(b.top.color, OmColors.line2);
      }
    });

    testWidgets(
      'an icon button fills with surface3 on hover and clears on exit',
      (tester) async {
        await _open(tester);
        Color? fillOf(String key) {
          final box = find.descendant(
            of: find.byKey(Key(key)),
            matching: find.byType(Container),
          );
          final d = tester.widget<Container>(box.first).decoration;
          return (d as BoxDecoration?)?.color;
        }

        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        addTearDown(mouse.removePointer);
        await mouse.addPointer(location: Offset.zero);
        await tester.pump();
        expect(fillOf('setup-close-x'), isNot(OmColors.surface3));
        await mouse.moveTo(
          tester.getCenter(find.byKey(const Key('setup-close-x'))),
        );
        await tester.pump();
        expect(fillOf('setup-close-x'), OmColors.surface3);
        await mouse.moveTo(const Offset(50, 300));
        await tester.pump();
        expect(fillOf('setup-close-x'), isNot(OmColors.surface3));
      },
    );
  });
}
