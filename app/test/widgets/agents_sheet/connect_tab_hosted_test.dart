// WI #411 (Spec #394 req 25-28, 46, 47; design pack
// design/394-agents-sheet/packs/411.md, RULINGS #15-#17): the Connect tab on
// a hosted vault. The MCP address, the masked token row with Reveal / Hide
// and Copy, the bridge snippet, the one-line Claude Code command and its two
// notes, the no-token state, Keychain reads per press, Semantics labels and
// the narrow and large-text layouts. Snippet strings come from #404's
// builders; the token is read only through `tokenStoreProvider` (a
// FakeTokenStore), never the real Keychain.
import 'dart:async';
import 'dart:ui' show Tristate;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart' show Icon;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/agents_sheet/connect/snippets.dart';
import 'package:open_memex_app/src/agents_sheet/connect/token_text.dart';
import 'package:open_memex_app/src/state/token_store.dart';

import '../../support/connect_tab_rig.dart';
import '../../support/font_fetch_hold.dart';
import '../../support/token_store_fakes.dart';

const _token = 'om411-hosted-token-Q7zP-Wx2Lm9Rv-7f3a';
const _intro =
    'Agents reach this vault through its vault server. Every client needs '
    'the MCP address and the access token.';
const _tokenLabel = 'Access token · from this Mac’s Keychain';
const _bridgeNote =
    'Copy puts the real token into the snippet. The bridge, memex serve '
    '--remote, sends your current UTC offset itself.';
const _offsetNote =
    '+05:45 is this Mac’s offset now. Claude Code sends it as written, so '
    'add the server again after a daylight-saving change.';
const _historyNote =
    'Pasting this into a terminal keeps the token in your shell history.';
const _noToken = 'No token in this Mac’s Keychain for this server';

String _entry(TokenText token) => hostedClaudeDesktopEntry(
  memexPath: connectMemexPath,
  vaultName: 'studio',
  mcpAddress: connectMcpAddress,
  token: token,
);

String _code(TokenText token) => hostedClaudeCodeCommand(
  vaultName: 'studio',
  mcpAddress: connectMcpAddress,
  token: token,
  utcOffset: connectUtcOffset,
);

final _masked = MaskedTokenText(_token);
final _real = RealTokenText(_token);

Future<ConnectRig> _pumpHosted(
  WidgetTester tester, {
  Map<String, String>? tokens,
  List<Override> overrides = const [],
  Size size = const Size(1000, 900),
  double textScale = 1.0,
}) => pumpConnect(
  tester,
  vault: agentsSheetHostedVault,
  tokens: tokens ?? {agentsSheetServer.id: _token},
  overrides: overrides,
  size: size,
  textScale: textScale,
);

/// A [FakeTokenStore] whose reads can be parked until [release].
class _Wi411HeldTokenStore extends FakeTokenStore {
  _Wi411HeldTokenStore(super.initial, {this.holding = false});

  bool holding;
  final _held = <Completer<void>>[];

  @override
  Future<String?> read(String serverId) async {
    calls.add('read $serverId');
    if (holding) {
      final gate = Completer<void>();
      _held.add(gate);
      await gate.future;
    }
    return tokens[serverId];
  }

  void release() {
    for (final g in List.of(_held)) {
      g.complete();
    }
    _held.clear();
  }

  int get reads => calls.where((c) => c.startsWith('read ')).length;
}

/// The Semantics node labelled exactly [label].
SemanticsNode _node(String label) {
  final f = find.semantics.byPredicate(
    (n) => n.getSemanticsData().label == label,
  );
  expect(f, findsOne, reason: 'one Semantics node labelled $label');
  return f.evaluate().single;
}

void main() {
  holdFontFetches();

  group('hosted layout', () {
    testWidgets(
      'hosted Claude Desktop shows the MCP address the masked token row and the bridge snippet',
      (tester) async {
        final rig = await _pumpHosted(tester);

        expect(inSheet(textShowing(_intro)), findsOneWidget);
        expect(inSheet(textShowing('MCP address')), findsOneWidget);
        expect(codeBlockText(tester, copyMcpAddressLabel), connectMcpAddress);
        expect(inSheet(textShowing(_tokenLabel)), findsOneWidget);
        expect(inSheet(textShowing(maskToken(_token))), findsOneWidget);
        expect(inSheet(find.text('Reveal')), findsOneWidget);
        expect(copyButton(copyAccessTokenLabel), findsOneWidget);

        expect(inSheet(textShowing(connectStepHostedMerge)), findsOneWidget);
        expect(codeBlockText(tester, copyDesktopConfigLabel), _entry(_masked));
        expect(inSheet(textShowing(_bridgeNote)), findsOneWidget);
        expect(inSheet(textShowing(connectStepRestart)), findsOneWidget);
        expect(
          tester.getTopLeft(textShowing(connectStepHostedMerge)).dy,
          lessThan(tester.getTopLeft(textShowing(connectStepRestart)).dy),
        );

        // No recall switch (memex serve --remote takes no flag), no local
        // steps, and the real token nowhere on screen.
        expect(recallSwitch(), findsNothing);
        expect(textContaining('--with-embeddings'), findsNothing);
        expect(textShowing(connectStepOpenConfig), findsNothing);
        expect(textContaining(_token), findsNothing);
        expect(textContaining('om411-hosted'), findsNothing);
        expect(rig.tokenReads(), 1, reason: 'opening reads the Keychain once');
      },
    );

    testWidgets(
      'hosted Claude Code shows the one line command with the masked token and both notes',
      (tester) async {
        final rig = await _pumpHosted(tester);
        await rig.chooseClient('Claude Code');

        expect(inSheet(textShowing(connectStepTerminal)), findsOneWidget);
        final line = codeBlockText(tester, copyCodeCommandLabel);
        expect(line, _code(_masked));
        expect(line, isNot(contains('\n')));
        expect(line, isNot(contains(r' \')));
        expect(line, contains("'memex-studio' '$connectMcpAddress'"));
        expect(line, contains("'X-Memex-UTC-Offset: +05:45'"));

        expect(inSheet(textShowing(_offsetNote)), findsOneWidget);
        expect(inSheet(textShowing(_historyNote)), findsOneWidget);
        final block = tester.getRect(codeBlock(copyCodeCommandLabel));
        final offsetTop = tester.getTopLeft(textShowing(_offsetNote)).dy;
        expect(offsetTop, greaterThanOrEqualTo(block.bottom));
        expect(
          tester.getTopLeft(textShowing(_historyNote)).dy,
          greaterThan(offsetTop),
        );

        // The address and token rows stay; the Desktop pane is gone.
        expect(codeBlockText(tester, copyMcpAddressLabel), connectMcpAddress);
        expect(inSheet(textShowing(maskToken(_token))), findsOneWidget);
        expect(copyButton(copyDesktopConfigLabel), findsNothing);
        expect(textShowing(_bridgeNote), findsNothing);
        expect(recallSwitch(), findsNothing);
      },
    );

    testWidgets('copying the MCP address copies it in plain text', (
      tester,
    ) async {
      final rig = await _pumpHosted(tester);
      final reads = rig.tokenReads();

      await rig.copy(copyMcpAddressLabel);

      expect(rig.clipboard, [connectMcpAddress]);
      expect(rig.sensitive, isEmpty);
      expect(rig.tokenReads(), reads, reason: 'no token in the address');
    });
  });

  group('reveal and hide', () {
    testWidgets(
      'Reveal shows the real token in the row and the snippets and Hide masks it again',
      (tester) async {
        final rig = await _pumpHosted(tester);
        final opened = rig.tokenReads();

        await rig.tap(inSheet(find.text('Reveal')));

        expect(rig.tokenReads(), opened + 1, reason: 'Reveal reads once');
        expect(inSheet(textShowing(_token)), findsOneWidget);
        expect(textShowing(maskToken(_token)), findsNothing);
        expect(codeBlockText(tester, copyDesktopConfigLabel), _entry(_real));
        expect(inSheet(find.text('Hide')), findsOneWidget);
        expect(find.text('Reveal'), findsNothing);

        // Switching client keeps it revealed (only Hide or close mask it).
        await rig.chooseClient('Claude Code');
        expect(codeBlockText(tester, copyCodeCommandLabel), _code(_real));
        expect(inSheet(textShowing(_token)), findsOneWidget);
        await rig.chooseClient('Claude Desktop');
        expect(codeBlockText(tester, copyDesktopConfigLabel), _entry(_real));

        final revealedReads = rig.tokenReads();
        await rig.tap(inSheet(find.text('Hide')));

        expect(rig.tokenReads(), revealedReads, reason: 'Hide reads nothing');
        expect(inSheet(textShowing(maskToken(_token))), findsOneWidget);
        expect(textShowing(_token), findsNothing);
        expect(textContaining('om411-hosted'), findsNothing);
        expect(codeBlockText(tester, copyDesktopConfigLabel), _entry(_masked));
        expect(inSheet(find.text('Reveal')), findsOneWidget);

        await rig.tap(inSheet(find.text('Reveal')));
        expect(
          rig.tokenReads(),
          revealedReads + 1,
          reason: 'each Reveal reads',
        );
        expect(inSheet(textShowing(_token)), findsOneWidget);
      },
    );

    testWidgets(
      'closing the sheet while revealed and reopening shows the token masked',
      (tester) async {
        final rig = await _pumpHosted(tester);
        await rig.tap(inSheet(find.text('Reveal')));
        expect(inSheet(textShowing(_token)), findsOneWidget);

        await rig.closeSheet();
        await rig.reopen();

        expect(inSheet(textShowing(maskToken(_token))), findsOneWidget);
        expect(textContaining('om411-hosted'), findsNothing);
        expect(codeBlockText(tester, copyDesktopConfigLabel), _entry(_masked));
        expect(inSheet(find.text('Reveal')), findsOneWidget);
        expect(find.text('Hide'), findsNothing);
      },
    );

    testWidgets(
      'two presses on Reveal while the Keychain read is pending reveal once',
      (tester) async {
        final store = _Wi411HeldTokenStore({agentsSheetServer.id: _token});
        final rig = await _pumpHosted(
          tester,
          overrides: [tokenStoreProvider.overrideWithValue(store)],
        );
        expect(inSheet(textShowing(maskToken(_token))), findsOneWidget);
        final opened = store.reads;

        store.holding = true;
        await tester.tap(inSheet(find.text('Reveal')));
        await tester.pump();
        await tester.tap(inSheet(find.text('Reveal')), warnIfMissed: false);
        await tester.pump();
        expect(store.reads, opened + 1, reason: 'the second press waits');

        store.holding = false;
        store.release();
        await rig.settle();

        expect(inSheet(textShowing(_token)), findsOneWidget);
        expect(inSheet(find.text('Hide')), findsOneWidget);
        expect(store.reads, opened + 1);
      },
    );
  });

  group('token lifetime', () {
    testWidgets(
      'while the open time Keychain read is pending the tab shows loading and neither the no token row nor placeholders',
      (tester) async {
        final store = _Wi411HeldTokenStore({
          agentsSheetServer.id: _token,
        }, holding: true);
        final rig = await _pumpHosted(
          tester,
          overrides: [tokenStoreProvider.overrideWithValue(store)],
        );
        expect(store.reads, 1);

        rig.harness.clock.advance(const Duration(milliseconds: 400));
        await rig.settle();
        expect(inSheet(find.text('loading…')), findsOneWidget);
        expect(codeBlockText(tester, copyMcpAddressLabel), connectMcpAddress);
        expect(inSheet(textShowing(_noToken)), findsNothing);
        expect(inSheet(find.text('Update token')), findsNothing);
        expect(inSheet(find.text('Reveal')), findsNothing);
        expect(copyButton(copyAccessTokenLabel), findsNothing);
        expect(copyButton(copyDesktopConfigLabel), findsNothing);
        expect(textContaining('paste-the-access-token-here'), findsNothing);

        store.holding = false;
        store.release();
        await rig.settle();
        expect(inSheet(find.text('loading…')), findsNothing);
        expect(inSheet(textShowing(maskToken(_token))), findsOneWidget);
        expect(codeBlockText(tester, copyDesktopConfigLabel), _entry(_masked));
        expect(store.reads, 1);
      },
    );

    testWidgets(
      'closing the sheet while the open time read is pending drops the result',
      (tester) async {
        final store = _Wi411HeldTokenStore({
          agentsSheetServer.id: _token,
        }, holding: true);
        final rig = await _pumpHosted(
          tester,
          overrides: [tokenStoreProvider.overrideWithValue(store)],
        );
        await rig.closeSheet();

        store.holding = false;
        store.release();
        await rig.settle();
        expect(tester.takeException(), isNull);

        await rig.reopen();
        expect(inSheet(textShowing(maskToken(_token))), findsOneWidget);
        expect(textContaining(_token), findsNothing);
      },
    );

    testWidgets(
      'closing the sheet while Reveal is pending drops the token and reopening shows it masked',
      (tester) async {
        final store = _Wi411HeldTokenStore({agentsSheetServer.id: _token});
        final rig = await _pumpHosted(
          tester,
          overrides: [tokenStoreProvider.overrideWithValue(store)],
        );
        store.holding = true;
        await tester.tap(inSheet(find.text('Reveal')));
        await tester.pump();
        await rig.closeSheet();

        store.holding = false;
        store.release();
        await rig.settle();
        expect(tester.takeException(), isNull);

        await rig.reopen();
        expect(inSheet(textShowing(maskToken(_token))), findsOneWidget);
        expect(inSheet(find.text('Reveal')), findsOneWidget);
        expect(textContaining(_token), findsNothing);
      },
    );
  });

  group('copy icons', () {
    testWidgets(
      'the token row Copy shows no icon idle or copied while the other Copy buttons keep theirs',
      (tester) async {
        final rig = await _pumpHosted(tester);
        Finder iconsIn(String label) =>
            find.descendant(of: copyButton(label), matching: find.byType(Icon));

        expect(iconsIn(copyAccessTokenLabel), findsNothing);
        expect(iconsIn(copyMcpAddressLabel), findsOneWidget);
        expect(iconsIn(copyDesktopConfigLabel), findsOneWidget);

        await rig.copy(copyAccessTokenLabel);
        expect(
          find.descendant(
            of: copyButton(copyAccessTokenLabel),
            matching: find.text('Copied'),
          ),
          findsOneWidget,
          reason: 'the button is in its copied state',
        );
        expect(iconsIn(copyAccessTokenLabel), findsNothing);
      },
    );
  });

  group('copy', () {
    testWidgets(
      'each token bearing Copy goes through copySensitive with the real token and reads the Keychain once per press',
      (tester) async {
        final rig = await _pumpHosted(tester);
        var reads = rig.tokenReads();

        await rig.copy(copyAccessTokenLabel);
        expect(rig.sensitive, [_token]);
        expect(rig.tokenReads(), reads + 1);
        reads = rig.tokenReads();

        await rig.copy(copyDesktopConfigLabel);
        expect(rig.sensitive.last, _entry(_real));
        expect(rig.tokenReads(), reads + 1);
        reads = rig.tokenReads();

        await rig.chooseClient('Claude Code');
        reads = rig.tokenReads();
        await rig.copy(copyCodeCommandLabel);
        expect(rig.sensitive.last, _code(_real));
        expect(rig.tokenReads(), reads + 1);

        // Revealed, a Copy still reads the Keychain again.
        await rig.tap(inSheet(find.text('Reveal')));
        reads = rig.tokenReads();
        await rig.copy(copyCodeCommandLabel);
        expect(rig.sensitive.last, _code(_real));
        expect(rig.tokenReads(), reads + 1);

        expect(rig.sensitive, hasLength(4));
        expect(rig.clipboard, isEmpty, reason: 'never the plain clipboard');
        // The screen still shows the mask where it was masked before.
        await rig.tap(inSheet(find.text('Hide')));
        expect(codeBlockText(tester, copyCodeCommandLabel), _code(_masked));
      },
    );

    testWidgets(
      'with no token in the Keychain the row offers update token and the snippets use the placeholder',
      (tester) async {
        final rig = await _pumpHosted(tester, tokens: const {});
        const placeholder = PlaceholderTokenText();

        expect(inSheet(textShowing(_noToken)), findsOneWidget);
        expect(find.text('Reveal'), findsNothing);
        expect(copyButton(copyAccessTokenLabel), findsNothing);
        expect(
          codeBlockText(tester, copyDesktopConfigLabel),
          _entry(placeholder),
        );

        await rig.tap(inSheet(labelIgnoringCase('update token')));
        expect(rig.updateTokenCalls, [agentsSheetServer.id]);

        await rig.copy(copyDesktopConfigLabel);
        expect([...rig.clipboard, ...rig.sensitive], [_entry(placeholder)]);

        await rig.chooseClient('Claude Code');
        expect(codeBlockText(tester, copyCodeCommandLabel), _code(placeholder));
        expect(inSheet(textShowing(_noToken)), findsOneWidget);
      },
    );
  });

  group('semantics', () {
    testWidgets(
      'every copy button the Reveal toggle and the switch carry their labels',
      (tester) async {
        final rig = await _pumpHosted(tester);

        for (final label in [
          copyMcpAddressLabel,
          copyAccessTokenLabel,
          copyDesktopConfigLabel,
        ]) {
          expect(_node(label), isSemantics(isButton: true), reason: label);
        }
        expect(
          _node('Reveal access token'),
          isSemantics(
            isButton: true,
            isFocusable: true,
            hasToggledState: true,
            isToggled: false,
            hasTapAction: true,
          ),
        );
        expect(_node('Reveal access token').childrenCount, 0);
        expect(find.bySemanticsLabel('Hide access token'), findsNothing);
        // The masked token reads as its label, never as 32 bullets.
        expect(
          find.bySemanticsLabel(tokenSemanticsLabel(_token)),
          findsWidgets,
        );
        expect(find.bySemanticsLabel(maskToken(_token)), findsNothing);
        // Check again is a keyboard-reachable button (D9).
        expect(
          _node('Check again'),
          isSemantics(isButton: true, isFocusable: true, hasTapAction: true),
        );

        await rig.tap(inSheet(find.text('Reveal')));
        expect(
          _node('Hide access token'),
          isSemantics(
            isButton: true,
            isFocusable: true,
            hasToggledState: true,
            isToggled: true,
            hasTapAction: true,
          ),
        );
        expect(_node('Hide access token').childrenCount, 0);
        expect(find.bySemanticsLabel('Reveal access token'), findsNothing);

        await rig.chooseClient('Claude Code');
        expect(_node(copyCodeCommandLabel), isSemantics(isButton: true));

        // Local: the config path, the Claude Desktop config, the Claude
        // Code command and the switch.
        await rig.closeSheet();
        await pumpConnect(tester);
        expect(_node(copyConfigPathLabel), isSemantics(isButton: true));
        expect(_node(copyDesktopConfigLabel), isSemantics(isButton: true));
        expect(
          recallSwitch()
              .evaluate()
              .single
              .getSemanticsData()
              .flagsCollection
              .isToggled,
          Tristate.isTrue,
        );
      },
    );
  });

  group('large text and narrow windows', () {
    testWidgets(
      'hosted Connect panes do not overflow at large text and narrow widths',
      (tester) async {
        const cases = <(Size, double)>[
          (Size(1000, 900), 1.5), // sheet 720
          (Size(672, 900), 1.5), // sheet 640
          (Size(480, 900), 1.0),
          (Size(480, 900), 1.5),
        ];
        for (final (size, scale) in cases) {
          for (final hasToken in [true, false]) {
            final rig = await _pumpHosted(
              tester,
              size: size,
              textScale: scale,
              tokens: hasToken ? null : const {},
            );
            final at = '$size at ${scale}x, token $hasToken';
            expect(tester.takeException(), isNull, reason: 'Desktop, $at');
            expect(
              codeBlock(copyDesktopConfigLabel),
              findsOneWidget,
              reason: at,
            );
            if (hasToken) {
              await rig.tap(inSheet(find.text('Reveal')));
              expect(tester.takeException(), isNull, reason: 'revealed, $at');
              expect(inSheet(textShowing(_token)), findsOneWidget, reason: at);
            }
            await rig.chooseClient('Claude Code');
            expect(tester.takeException(), isNull, reason: 'Code, $at');
            expect(codeBlock(copyCodeCommandLabel), findsOneWidget, reason: at);
          }
        }
      },
    );
  });
}
