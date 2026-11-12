// WI #413 follow-up (Spec #394 req 41; RULINGS 2, 20, 22): the Semantic recall
// tab's two turn-on blocks are #411's shared ConnectCodeBlock, not a private
// copy. The local block is Connect's Claude Desktop JSON with the flag on
// (ConnectCodeSyntax.json, button `Copy config`); the hosted block is the
// `memex serve` line (ConnectCodeSyntax.shell, button `Copy`).
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/agents_sheet/connect/snippets.dart';
import 'package:open_memex_app/src/state/settings.dart';
import 'package:open_memex_app/src/state/vault_open_hosted.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/vault_access/agents_access.dart';
import 'package:open_memex_app/src/widgets/agents_sheet/connect/code_block.dart';
import 'package:open_memex_app/src/widgets/agents_sheet/recall_tab.dart';
import 'package:open_memex_app/src/widgets/om_copy_button.dart';
import 'package:path/path.dart' as p;

import '../../support/agents_sheet_harness.dart';
import '../../support/api_fixtures.dart';
import '../../support/fake_memex_cli.dart';
import '../../support/fake_vault_server.dart';
import '../../support/font_fetch_hold.dart';

const _memex = '/Users/tester/.cargo/bin/memex';
const _hostedCommand =
    'memex serve --root <root> --listen <host:port> --with-embeddings';
const _flag = '--with-embeddings';
const _embeddingsPath = '/vaults/seed/api/v1/embeddings';

String _localSnippet() => localClaudeDesktopConfig(
  memexPath: _memex,
  vaultPath: p.absolute(agentsSheetLocalVault.path),
  withEmbeddings: true,
);

Finder get _blocks => find.descendant(
  of: find.byType(RecallTab),
  matching: find.byType(ConnectCodeBlock),
);

ConnectCodeBlock _onlyBlock(WidgetTester tester) {
  expect(_blocks, findsOneWidget);
  return tester.widget<ConnectCodeBlock>(_blocks);
}

/// The coloured runs of the block's text: `(text, effective colour)` for every
/// text span, where a span without its own colour reads the block's base.
List<(String, Color?)> _runs(WidgetTester tester) {
  _onlyBlock(tester);
  final rich = tester.widget<RichText>(
    find.descendant(of: _blocks, matching: find.byType(RichText)).first,
  );
  final base = rich.text.style?.color;
  final out = <(String, Color?)>[];
  rich.text.visitChildren((span) {
    if (span is TextSpan && span.text != null) {
      out.add((span.text!, span.style?.color ?? base));
    }
    return true;
  });
  return out;
}

Future<void> _pumpLocal(WidgetTester tester) async {
  final cli = FakeMemexCli()
    ..on(
      'embeddings status',
      (_) => FakeMemexCli.ok(
        jsonEncode({
          'server_embeddings': null,
          'chunks': 71,
          'embedded': 64,
          'model_cached': true,
          'model_bytes': 127000000,
        }),
      ),
    );
  final h = await pumpAgentsSheet(
    tester,
    cli: cli,
    agents: FakeAgentsAccess(
      vaultPath: agentsSheetLocalVault.path,
      script: [
        AgentActivity(
          agents: [
            agentPresence(
              sessionId: 'S-B',
              clientName: 'claude-code',
              embeddings: false,
              lastRequestAt: agentsT0,
            ),
          ],
          recent: const [],
          available: true,
        ),
      ],
    ),
    binaryPath: _memex,
    size: const Size(1000, 900),
  );
  await tester.ensureVisible(find.byKey(const Key('agents-tab-recall')));
  await tester.pump();
  await tester.tap(find.byKey(const Key('agents-tab-recall')));
  await h.settle();
}

Future<void> _pumpHostedOff(WidgetTester tester) async {
  final server = FakeVaultServer(url: fakeServerUrl)
    ..route(
      'GET',
      _embeddingsPath,
      body: File(
        '$apiV1FixturesDir/embeddings/server_embeddings_off.json',
      ).readAsStringSync(),
    );
  const hostedVault = HostedVaultRef(fakeServerId, seedVaultName);
  final h = await pumpAgentsSheet(
    tester,
    vault: hostedVault,
    servers: [
      SavedServer(id: fakeServerId, name: fakeServerName, url: fakeServerUrl),
    ],
    size: const Size(1000, 900),
    open: false,
  );
  h.container.read(hostedSessionProvider.notifier).state = HostedSession(
    hostedVault,
    server.connect(h.container, accessToken: fakeServerToken),
  );
  await h.open();
  await tester.ensureVisible(find.byKey(const Key('agents-tab-recall')));
  await tester.pump();
  await tester.tap(find.byKey(const Key('agents-tab-recall')));
  await h.settle();
}

List<String> _captureClipboard(WidgetTester tester) {
  final copied = <String>[];
  final messenger = tester.binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.setData') {
      copied.add((call.arguments as Map<Object?, Object?>)['text']! as String);
    }
    return null;
  });
  addTearDown(
    () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
  );
  return copied;
}

void main() {
  holdFontFetches();

  group('local turn on block', () {
    testWidgets(
      'local turn on renders the shared ConnectCodeBlock with the whole flag on snippet',
      (tester) async {
        await _pumpLocal(tester);
        final block = _onlyBlock(tester);
        expect(block.text, _localSnippet());
        expect(block.syntax, ConnectCodeSyntax.json);
        expect(block.copy.label, 'Copy config');
        expect(block.copy.semanticLabel, 'Copy Claude Desktop config');
        expect(block.semanticsLabel, isNull);
      },
    );

    testWidgets(
      'local turn on block highlights keys in fg2 and the flag in accent like Connect',
      (tester) async {
        await _pumpLocal(tester);
        final runs = _runs(tester);
        expect(runs.map((r) => r.$1).join(), _localSnippet());
        expect(runs, contains(('"mcpServers"', OmColors.fg2)));
        expect(runs, contains(('"command"', OmColors.fg2)));
        expect(runs, contains(('"$_flag"', OmColors.accent)));
        expect(runs.where((r) => r.$2 == OmColors.accent).map((r) => r.$1), [
          '"$_flag"',
        ]);
      },
    );

    testWidgets('Copy config copies exactly the text the block shows', (
      tester,
    ) async {
      final copied = _captureClipboard(tester);
      await _pumpLocal(tester);
      final shown = _onlyBlock(tester).text;
      await tester.tap(
        find.descendant(of: _blocks, matching: find.byType(OmCopyButton)),
      );
      await tester.pump();
      await tester.pump();
      expect(copied, [shown]);
      expect(shown, _localSnippet());
    });
  });

  group('hosted turn on block', () {
    testWidgets(
      'hosted turn on renders the shared ConnectCodeBlock with the serve command',
      (tester) async {
        await _pumpHostedOff(tester);
        final block = _onlyBlock(tester);
        expect(block.text, _hostedCommand);
        expect(block.syntax, ConnectCodeSyntax.shell);
        expect(block.copy.label, 'Copy');
        expect(block.copy.semanticLabel, 'Copy server command');
        expect(block.semanticsLabel, isNull);
      },
    );

    testWidgets('hosted turn on block colours only the trailing flag accent', (
      tester,
    ) async {
      await _pumpHostedOff(tester);
      final runs = _runs(tester);
      expect(runs.map((r) => r.$1).join(), _hostedCommand);
      expect(runs.where((r) => r.$2 == OmColors.accent).map((r) => r.$1), [
        _flag,
      ]);
      expect(runs.first.$2, OmColors.fg1);
    });

    testWidgets('Copy copies exactly the command the block shows', (
      tester,
    ) async {
      final copied = _captureClipboard(tester);
      await _pumpHostedOff(tester);
      await tester.tap(
        find.descendant(of: _blocks, matching: find.byType(OmCopyButton)),
      );
      await tester.pump();
      await tester.pump();
      expect(copied, [_onlyBlock(tester).text]);
      expect(copied, [_hostedCommand]);
    });
  });

  group('no private code block', () {
    test('recall_tab.dart has no private code block widget of its own', () {
      final source = File(
        'lib/src/widgets/agents_sheet/recall_tab.dart',
      ).readAsStringSync();
      expect(source, isNot(contains('class _CodeBlock')));
      expect(source, isNot(contains('_CodeBlock(')));
      expect(source, contains('ConnectCodeBlock('));
      expect(source, contains('connect/code_block.dart'));
    });
  });
}
