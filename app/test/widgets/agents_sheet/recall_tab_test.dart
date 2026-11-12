// WI #413 (Spec #394 req 9, 15-16, 36-42, 44, 47; user story 6; D14, D16,
// D31; design pack design/394-agents-sheet/packs/413.md and RULINGS 8,
// 19-24): the Agents sheet Semantic recall tab. Every test opens the real
// sheet with `pumpAgentsSheet`; coverage and model status come from a
// FakeMemexCli (`memex embeddings status`, local) or a FakeVaultServer
// (`GET …/embeddings`, hosted), and agents from #390's FakeAgentsAccess.
// The refresh schedule is pinned in
// test/state/agents_sheet/recall_loading_test.dart.
//
// Keys the tab exposes (robot tests use them):
//   recall-heading-dot (the 8 px status dot beside the heading),
//   recall-coverage-bar (the 6 px track), recall-coverage-fill (its fill),
//   recall-agent-<sessionId> (one per-agent row: name, then the value),
//   recall-agent-command-<sessionId> (its `Turn on in its command` link),
//   recall-model (the Model row: key `Model`, then the value),
//   recall-model-download (the `Download it from Echoes.` link),
//   recall-locate-memex (the `Locate memex…` OmButton).
// The two links are their own widgets (so they can be keyed, tapped and
// focused), not TextSpan recognizers.
//
// Every copy string is one paragraph (a Text, or a Text.rich of TextSpans
// for inline code and colour), so `find.text(…, findRichText: true)` matches
// the whole sentence. Spec req 36-42 copy wins over the board (RULINGS 19).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/agents_sheet/agents_sheet_state.dart';
import 'package:open_memex_app/src/state/agent_activity.dart';
import 'package:open_memex_app/src/state/agents_sheet/recall_tab_state.dart';
import 'package:open_memex_app/src/state/settings.dart';
import 'package:open_memex_app/src/state/vault_open_hosted.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/agents_sheet/connect/snippets.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/vault_access/agents_access.dart';
import 'package:open_memex_app/src/widgets/agents_sheet/agents_tab_loading.dart';
import 'package:open_memex_app/src/widgets/agents_sheet/connect_tab.dart';
import 'package:open_memex_app/src/widgets/agents_sheet/recall_tab.dart';
import 'package:open_memex_app/src/widgets/atoms.dart';
import 'package:open_memex_app/src/widgets/om_copy_button.dart';
import 'package:open_memex_app/src/widgets/right_panel.dart';
import 'package:path/path.dart' as p;

import '../../support/agents_sheet_harness.dart';
import '../../support/api_fixtures.dart';
import '../../support/fake_memex_cli.dart';
import '../../support/fake_vault_server.dart';
import '../../support/file_picker_fakes.dart';
import '../../support/font_fetch_hold.dart';

// ---------------------------------------------------------------------- copy

const _localOnHeading = 'Agents use semantic recall';
const _localOffHeading = 'Connected agents use keyword search only';
const _localNoneHeading = 'No agent is connected';
const _hostedOnHeading = 'Semantic recall is on on this vault server';
const _hostedOffHeading = 'Semantic recall is off on this vault server';
const _hostedUnknownHeading =
    'Semantic recall status unknown on this vault server';

const _localOnBody =
    'Agents’ searches match by meaning as well as keywords. Echoes use the '
    'same embeddings.';
const _localOffBody =
    'The connected agents run memex without --with-embeddings, so their '
    'searches match keywords only. Echoes in this app don’t depend on agents: '
    'they use the model once you download it.';
const _localNoneBody =
    'Connect an agent with --with-embeddings for meaning-based search. '
    'Echoes in this app don’t depend on agents: they use the model once you '
    'download it.';
String _hostedOnBody(String host) =>
    'The server at $host embeds your notes when they’re saved. Echoes and '
    'agents’ searches use it.';
String _hostedOffBody(String host) =>
    'The server at $host runs without --with-embeddings. It decides for '
    'every vault it serves and every agent that connects to it, so only '
    'whoever runs it can turn recall on.';
const _hostedUnknownBody =
    'The server is older than this app. Update memex on it to see semantic '
    'recall status here.';

const _localCoverageNote =
    'Passages are embedded in the background by an agent running with '
    '--with-embeddings, and by echoes in this app once the model is '
    'downloaded.';
const _hostedCoverageNote =
    'The server embeds new passages when they’re saved.';

const _agentOn = 'on · runs with --with-embeddings';
const _agentOff = 'off · keyword search only. Turn on in its command';

const _localTurnOnNote =
    'Put this in Claude Desktop’s config and restart it. It uses the model in '
    'this vault, downloading it on first run if needed, then embeds your '
    'notes in the background.';
const _hostedCommand =
    'memex serve --root <root> --listen <host:port> --with-embeddings';
const _hostedTurnOnNote =
    'Add the flag to the server’s service definition and restart it. The '
    'server downloads the model once into <root>/.memex/models and shares it '
    'with every vault it serves.';

const _closingNote =
    'Open Memex can’t switch an agent’s flag for it. To turn recall on or off '
    'for an agent, change that agent’s config (Connect shows it with or '
    'without the flag) and restart the agent.';

const _tooOldText = 'Coverage unavailable: this memex is older than the app.';

/// The harness's default picked memex binary.
const _memex = '/Users/tester/.cargo/bin/memex';

// ------------------------------------------------------------------ fixtures

const _embeddingsDir = '$apiV1FixturesDir/embeddings';
const _embeddingsPath = '/vaults/seed/api/v1/embeddings';

String _status({
  bool? server,
  int chunks = 71,
  int embedded = 64,
  bool cached = true,
  int bytes = 127000000,
}) => jsonEncode({
  'server_embeddings': server,
  'chunks': chunks,
  'embedded': embedded,
  'model_cached': cached,
  'model_bytes': bytes,
});

FakeMemexCli _cliWith(String stdout) =>
    FakeMemexCli()..on('embeddings status', (_) => FakeMemexCli.ok(stdout));

AgentPresence _on(String id, String name, {int ago = 0}) => agentPresence(
  sessionId: id,
  clientName: name,
  embeddings: true,
  lastRequestAt: agentsT0 - ago,
);

AgentPresence _off(String id, String name, {int ago = 0}) => agentPresence(
  sessionId: id,
  clientName: name,
  embeddings: false,
  lastRequestAt: agentsT0 - ago,
);

FakeAgentsAccess _agents(List<AgentPresence> presences) => FakeAgentsAccess(
  vaultPath: agentsSheetLocalVault.path,
  script: [AgentActivity(agents: presences, recent: const [], available: true)],
);

// ------------------------------------------------------------------- finders

Finder _key(String k) => find.byKey(Key(k));

Finder _para(String text) => find.text(text, findRichText: true);

/// Every paragraph under [f] (itself included), joined by spaces, with runs
/// of whitespace collapsed.
String _flat(WidgetTester tester, Finder f) {
  expect(f, findsOneWidget);
  final parts = [
    for (final e
        in find
            .descendant(of: f, matching: find.byType(RichText), matchRoot: true)
            .evaluate())
      (e.widget as RichText).text.toPlainText(),
  ];
  return parts.join(' ').replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// The effective style of the one paragraph reading [text].
TextStyle _style(WidgetTester tester, String text) {
  final f = _para(text);
  expect(f, findsOneWidget, reason: text);
  return tester.widget<RichText>(f).text.style!;
}

Rect _rect(WidgetTester tester, Finder f) {
  expect(f, findsOneWidget);
  return tester.getRect(f);
}

/// The fill colour of the first decorated or coloured box at or under [f].
Color? _boxColor(WidgetTester tester, Finder f) {
  expect(f, findsOneWidget);
  for (final e
      in find
          .descendant(
            of: f,
            matching: find.byWidgetPredicate(
              (w) =>
                  (w is DecoratedBox && w.decoration is BoxDecoration) ||
                  w is ColoredBox,
            ),
            matchRoot: true,
          )
          .evaluate()) {
    final w = e.widget;
    if (w is ColoredBox) return w.color;
    final c = ((w as DecoratedBox).decoration as BoxDecoration).color;
    if (c != null) return c;
  }
  return null;
}

Finder _copyButton(String label) => find.byWidgetPredicate(
  (w) => w is OmCopyButton && w.label == label,
  description: 'OmCopyButton($label)',
);

Finder get _anyCopyButton => find.descendant(
  of: find.byType(RecallTab),
  matching: find.byType(OmCopyButton),
);

// ---------------------------------------------------------------------- pump

/// Taps the Semantic recall chip, first scrolling the tab row so it is in
/// view (the row scrolls sideways in a narrow window, ruling 11).
Future<void> _showRecall(WidgetTester tester, AgentsSheetHarness h) async {
  await tester.ensureVisible(_key('agents-tab-recall'));
  await tester.pump();
  await tester.tap(_key('agents-tab-recall'));
  await h.settle();
}

/// Pumps past the sheet's 150 ms fade-out and the route's removal.
Future<void> _fadeOut(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<AgentsSheetHarness> _pumpLocal(
  WidgetTester tester, {
  FakeMemexCli? cli,
  List<AgentPresence> agents = const [],
  FakeAgentsAccess? access,
  String? binaryPath = _memex,
  Size size = const Size(1000, 900),
  double textScale = 1.0,
  bool show = true,
  List<Override> overrides = const [],
}) async {
  final h = await pumpAgentsSheet(
    tester,
    cli: cli ?? _cliWith(_status()),
    agents: access ?? _agents(agents),
    binaryPath: binaryPath,
    size: size,
    textScale: textScale,
    overrides: overrides,
  );
  if (show) await _showRecall(tester, h);
  return h;
}

/// A hosted vault `seed` on a fake server at [url], saved as [serverUrl]
/// (default: the same). [prepare] sets the server up before the sheet opens.
Future<(AgentsSheetHarness, FakeVaultServer)> _pumpHosted(
  WidgetTester tester, {
  String? response,
  String url = fakeServerUrl,
  String? savedUrl,
  void Function(FakeVaultServer server)? prepare,
  Size size = const Size(1000, 900),
  double textScale = 1.0,
  bool show = true,
  List<Override> overrides = const [],
}) async {
  final server = FakeVaultServer(url: url);
  if (response != null) {
    server.route('GET', _embeddingsPath, body: response);
  }
  prepare?.call(server);
  const hostedVault = HostedVaultRef(fakeServerId, seedVaultName);
  final h = await pumpAgentsSheet(
    tester,
    vault: hostedVault,
    servers: [
      SavedServer(id: fakeServerId, name: fakeServerName, url: savedUrl ?? url),
    ],
    size: size,
    textScale: textScale,
    overrides: overrides,
    open: false,
  );
  h.container.read(hostedSessionProvider.notifier).state = HostedSession(
    hostedVault,
    server.connect(h.container, accessToken: fakeServerToken),
  );
  await h.open();
  if (show) await _showRecall(tester, h);
  return (h, server);
}

String _fixture(String name) =>
    File('$_embeddingsDir/$name').readAsStringSync();

String _compat() => File(
  '$apiV1FixturesDir/compat/embeddings_not_found.json',
).readAsStringSync();

int _serverReads(FakeVaultServer s) =>
    s.requests.where((r) => r.url.path.endsWith('/embeddings')).length;

/// Captures `Clipboard.setData` text while installed.
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

/// The whole local Claude Desktop snippet with the flag on, as the Connect
/// tab builds it (RULINGS 22).
String _localSnippet({String memex = _memex}) => localClaudeDesktopConfig(
  memexPath: memex,
  vaultPath: p.absolute(agentsSheetLocalVault.path),
  withEmbeddings: true,
);

/// An activity notifier whose build throws: the unknown-activity input.
class _Wi413ErrorActivity extends AgentActivityNotifier {
  @override
  Future<AgentActivityView> build() async => throw StateError('activity');
}

void main() {
  holdFontFetches();

  // ------------------------------------------------------- local heading

  group('local heading, dot and body', () {
    testWidgets(
      'one agent with recall on reads Agents use semantic recall with an accent dot',
      (tester) async {
        final h = await _pumpLocal(
          tester,
          agents: [_on('S-A', 'claude-desktop')],
        );
        expect(find.byType(RecallTab), findsOneWidget);
        expect(_para(_localOnHeading), findsOneWidget);
        expect(_para(_localOnBody), findsOneWidget);
        expect(_para(_localOffHeading), findsNothing);
        expect(_para(_localNoneHeading), findsNothing);
        expect(tester.getSize(_key('recall-heading-dot')), const Size(8, 8));
        expect(
          _boxColor(tester, _key('recall-heading-dot'))?.toARGB32(),
          OmColors.accent.toARGB32(),
        );
        expect(h.read(recallTabDotProvider), isTrue);
        // Req 36: sans 15 w600 fg0.
        final style = _style(tester, _localOnHeading);
        expect(style.fontSize, 15);
        expect(style.fontWeight, FontWeight.w600);
        expect(style.color?.toARGB32(), OmColors.fg0.toARGB32());
        // The dot sits left of the heading on its line.
        final dot = _rect(tester, _key('recall-heading-dot'));
        final heading = _rect(tester, _para(_localOnHeading));
        expect(dot.right, lessThanOrEqualTo(heading.left));
        expect(dot.center.dy, closeTo(heading.center.dy, 4));
      },
    );

    testWidgets(
      'one agent on among others still reads Agents use semantic recall',
      (tester) async {
        final h = await _pumpLocal(
          tester,
          agents: [
            _off('S-B', 'claude-code'),
            _on('S-A', 'claude-desktop', ago: 500),
          ],
        );
        expect(_para(_localOnHeading), findsOneWidget);
        expect(_para(_localOnBody), findsOneWidget);
        expect(h.read(recallTabDotProvider), isTrue);
      },
    );

    testWidgets(
      'agents connected with none on read keyword search only with an fg2 dot',
      (tester) async {
        final h = await _pumpLocal(
          tester,
          agents: [_off('S-B', 'claude-code'), _off('S-C', 'cursor', ago: 9)],
        );
        expect(_para(_localOffHeading), findsOneWidget);
        expect(_para(_localOffBody), findsOneWidget);
        expect(_para(_localOnHeading), findsNothing);
        expect(tester.getSize(_key('recall-heading-dot')), const Size(8, 8));
        expect(
          _boxColor(tester, _key('recall-heading-dot'))?.toARGB32(),
          OmColors.fg2.toARGB32(),
        );
        expect(h.read(recallTabDotProvider), isFalse);
      },
    );

    testWidgets('no agent connected reads No agent is connected with no dot', (
      tester,
    ) async {
      final h = await _pumpLocal(tester);
      expect(_para(_localNoneHeading), findsOneWidget);
      expect(_para(_localNoneBody), findsOneWidget);
      expect(_key('recall-heading-dot'), findsNothing);
      expect(h.read(recallTabDotProvider), isNull);
      final style = _style(tester, _localNoneHeading);
      expect(style.fontSize, 15);
      expect(style.fontWeight, FontWeight.w600);
    });

    testWidgets(
      'the local tab dot follows the agents before the tab is ever shown',
      (tester) async {
        final cli = _cliWith(_status());
        final h = await _pumpLocal(
          tester,
          cli: cli,
          agents: [_on('S-A', 'claude-desktop')],
          show: false,
        );
        // The sheet opened on Live; Semantic recall was never shown.
        expect(find.byType(RecallTab), findsNothing);
        expect(h.read(recallTabDotProvider), isTrue);
        expect(cli.callsFor('embeddings status'), isEmpty);
      },
    );

    testWidgets(
      'the local tab dot is off when connected agents all run without the flag',
      (tester) async {
        final h = await _pumpLocal(
          tester,
          agents: [_off('S-B', 'claude-code')],
          show: false,
        );
        expect(h.read(recallTabDotProvider), isFalse);
      },
    );

    testWidgets(
      'the local tab dot is none while agent activity is still loading',
      (tester) async {
        final access = _agents([_on('S-A', 'claude-desktop')])..holdNextRead();
        final h = await _pumpLocal(tester, access: access, show: false);
        // Activity still loading after 300 ms: the sheet opened on Connect.
        expect(access.holding, isTrue);
        expect(h.read(recallTabDotProvider), isNull);
        access.release();
        await h.settle();
        expect(h.read(recallTabDotProvider), isTrue);
      },
    );
  });

  // ------------------------------------------------------ hosted heading

  group('hosted heading, dot and body', () {
    testWidgets(
      'server_embeddings true reads on on this vault server with the host and an accent dot',
      (tester) async {
        final (h, _) = await _pumpHosted(
          tester,
          response: _fixture('server_embeddings_on.json'),
        );
        expect(_para(_hostedOnHeading), findsOneWidget);
        expect(_para(_hostedOnBody('nas.local')), findsOneWidget);
        expect(tester.getSize(_key('recall-heading-dot')), const Size(8, 8));
        expect(
          _boxColor(tester, _key('recall-heading-dot'))?.toARGB32(),
          OmColors.accent.toARGB32(),
        );
        expect(h.read(recallTabDotProvider), isTrue);
        final style = _style(tester, _hostedOnHeading);
        expect(style.fontSize, 15);
        expect(style.fontWeight, FontWeight.w600);
        expect(style.color?.toARGB32(), OmColors.fg0.toARGB32());
      },
    );

    testWidgets(
      'server_embeddings false reads off on this vault server with the host and an fg2 dot',
      (tester) async {
        final (h, _) = await _pumpHosted(
          tester,
          response: _fixture('server_embeddings_off.json'),
        );
        expect(_para(_hostedOffHeading), findsOneWidget);
        expect(_para(_hostedOffBody('nas.local')), findsOneWidget);
        expect(
          _boxColor(tester, _key('recall-heading-dot'))?.toARGB32(),
          OmColors.fg2.toARGB32(),
        );
        expect(h.read(recallTabDotProvider), isFalse);
      },
    );

    testWidgets(
      'the body names the saved server URL host, not its scheme or port',
      (tester) async {
        await _pumpHosted(
          tester,
          url: 'https://vault.example.org:8443',
          savedUrl: 'https://vault.example.org:8443/',
          response: _fixture('server_embeddings_off.json'),
        );
        expect(_para(_hostedOffBody('vault.example.org')), findsOneWidget);
        expect(_para(_hostedOffBody('nas.local')), findsNothing);
      },
    );

    testWidgets(
      'the compat embeddings_not_found fixture shows the unknown heading with no dot, the older server body and the closing note only',
      (tester) async {
        final (h, server) = await _pumpHosted(
          tester,
          prepare: (s) => s.serveDomain('compat'),
        );
        expect(_serverReads(server), 1);
        expect(_para(_hostedUnknownHeading), findsOneWidget);
        expect(_para(_hostedUnknownBody), findsOneWidget);
        expect(_para(_closingNote), findsOneWidget);
        expect(_key('recall-heading-dot'), findsNothing);
        expect(h.read(recallTabDotProvider), isNull);
        // Coverage, model and turn-on are omitted (RULINGS 23).
        expect(
          find.textContaining('passages embedded', findRichText: true),
          findsNothing,
        );
        expect(_key('recall-coverage-bar'), findsNothing);
        expect(_key('recall-model'), findsNothing);
        expect(
          find.textContaining('BGE-small', findRichText: true),
          findsNothing,
        );
        expect(
          find.textContaining('memex serve', findRichText: true),
          findsNothing,
        );
        expect(_anyCopyButton, findsNothing);
        expect(find.byKey(const Key('inline-error')), findsNothing);
        // The heading comes first, then the body, then the closing note.
        final heading = _rect(tester, _para(_hostedUnknownHeading));
        final body = _rect(tester, _para(_hostedUnknownBody));
        final note = _rect(tester, _para(_closingNote));
        expect(body.top, greaterThanOrEqualTo(heading.bottom));
        expect(note.top, greaterThanOrEqualTo(body.bottom));
      },
    );

    testWidgets('the hosted tab dot is none before the first load', (
      tester,
    ) async {
      final (h, server) = await _pumpHosted(
        tester,
        response: _fixture('server_embeddings_on.json'),
        show: false,
      );
      expect(h.read(recallTabDotProvider), isNull);
      expect(_serverReads(server), 0);
      await _showRecall(tester, h);
      expect(h.read(recallTabDotProvider), isTrue);
    });

    testWidgets(
      'the hosted tab dot keeps the loaded value after leaving the tab',
      (tester) async {
        final (h, _) = await _pumpHosted(
          tester,
          response: _fixture('server_embeddings_off.json'),
        );
        expect(h.read(recallTabDotProvider), isFalse);
        await tester.tap(_key('agents-tab-connect'));
        await h.settle();
        expect(find.byType(RecallTab), findsNothing);
        expect(h.read(recallTabDotProvider), isFalse);
      },
    );

    testWidgets('the hosted tab dot is none when the read errors', (
      tester,
    ) async {
      final (h, server) = await _pumpHosted(
        tester,
        response: _fixture('server_embeddings_on.json'),
        prepare: (s) => s.token = 'rotated-token',
      );
      expect(_serverReads(server), 1);
      expect(find.byKey(const Key('inline-error')), findsOneWidget);
      expect(h.read(recallTabDotProvider), isNull);
    });

    testWidgets('a hosted vault reads the server even with no memex binary', (
      tester,
    ) async {
      final (h, server) = await _pumpHosted(
        tester,
        response: _fixture('server_embeddings_on.json'),
        overrides: [memexCliProvider.overrideWithValue(null)],
      );
      expect(_serverReads(server), 1);
      expect(_para(_hostedOnHeading), findsOneWidget);
      expect(find.text('memex not found'), findsNothing);
      expect(h.read(recallTabDotProvider), isTrue);
    });
  });

  // ------------------------------------------------------------ coverage

  group('coverage', () {
    testWidgets(
      'local coverage shows embedded of chunks, waiting, the bar and the local note',
      (tester) async {
        await _pumpLocal(
          tester,
          cli: _cliWith(_status(chunks: 71, embedded: 64)),
          agents: [_on('S-A', 'claude-desktop')],
        );
        expect(_para('64 of 71 passages embedded'), findsOneWidget);
        expect(_para('7 waiting'), findsOneWidget);
        expect(_para(_localCoverageNote), findsOneWidget);
        expect(_para(_hostedCoverageNote), findsNothing);
        // A 6 px bar: accentSoft on surface4, filled to embedded / chunks.
        final track = _rect(tester, _key('recall-coverage-bar'));
        final fill = _rect(tester, _key('recall-coverage-fill'));
        expect(track.height, 6);
        expect(fill.height, 6);
        expect(fill.left, closeTo(track.left, 0.5));
        expect(fill.width / track.width, closeTo(64 / 71, 0.01));
        expect(
          _boxColor(tester, _key('recall-coverage-bar'))?.toARGB32(),
          OmColors.surface4.toARGB32(),
        );
        expect(
          _boxColor(tester, _key('recall-coverage-fill'))?.toARGB32(),
          OmColors.accentSoft.toARGB32(),
        );
        // Counts sit above the bar, the note below it.
        final count = _rect(tester, _para('64 of 71 passages embedded'));
        final note = _rect(tester, _para(_localCoverageNote));
        expect(track.top, greaterThanOrEqualTo(count.bottom));
        expect(note.top, greaterThanOrEqualTo(track.bottom));
        // The waiting count is on the right of the same row.
        final waiting = _rect(tester, _para('7 waiting'));
        expect(waiting.left, greaterThanOrEqualTo(count.right));
        expect(waiting.right, closeTo(track.right, 1));
      },
    );

    testWidgets(
      'local coverage shows in the off state with nothing embedded and an empty bar',
      (tester) async {
        await _pumpLocal(
          tester,
          cli: _cliWith(_status(chunks: 71, embedded: 0, cached: false)),
          agents: [_off('S-B', 'claude-code')],
        );
        expect(_para('0 of 71 passages embedded'), findsOneWidget);
        expect(_para('71 waiting'), findsOneWidget);
        expect(_key('recall-coverage-bar'), findsOneWidget);
        final fill = _key('recall-coverage-fill');
        if (fill.evaluate().isNotEmpty) {
          expect(tester.getSize(fill).width, closeTo(0, 0.5));
        }
      },
    );

    testWidgets(
      'a vault with no passages shows 0 of 0 and an empty bar without failing',
      (tester) async {
        await _pumpLocal(
          tester,
          cli: _cliWith(_status(chunks: 0, embedded: 0)),
        );
        expect(tester.takeException(), isNull);
        expect(_para('0 of 0 passages embedded'), findsOneWidget);
        expect(_para('0 waiting'), findsOneWidget);
        expect(_key('recall-coverage-bar'), findsOneWidget);
        final fill = _key('recall-coverage-fill');
        if (fill.evaluate().isNotEmpty) {
          expect(tester.getSize(fill).width, closeTo(0, 0.5));
        }
      },
    );

    testWidgets('a fully embedded vault fills the bar', (tester) async {
      await _pumpLocal(
        tester,
        cli: _cliWith(_status(chunks: 40, embedded: 40)),
      );
      expect(_para('40 of 40 passages embedded'), findsOneWidget);
      expect(_para('0 waiting'), findsOneWidget);
      expect(
        _rect(tester, _key('recall-coverage-fill')).width,
        closeTo(_rect(tester, _key('recall-coverage-bar')).width, 0.5),
      );
    });

    testWidgets(
      'hosted coverage shows the counts, the bar and the hosted note when on',
      (tester) async {
        await _pumpHosted(
          tester,
          response: _status(server: true, chunks: 120, embedded: 30),
        );
        expect(_para('30 of 120 passages embedded'), findsOneWidget);
        expect(_para('90 waiting'), findsOneWidget);
        expect(_para(_hostedCoverageNote), findsOneWidget);
        expect(_para(_localCoverageNote), findsNothing);
        expect(
          _rect(tester, _key('recall-coverage-fill')).width /
              _rect(tester, _key('recall-coverage-bar')).width,
          closeTo(0.25, 0.01),
        );
      },
    );

    testWidgets(
      'hosted coverage also shows when the server runs without the flag',
      (tester) async {
        await _pumpHosted(
          tester,
          response: _fixture('server_embeddings_off.json'),
        );
        expect(_para('0 of 10 passages embedded'), findsOneWidget);
        expect(_para('10 waiting'), findsOneWidget);
        expect(_para(_hostedCoverageNote), findsOneWidget);
        expect(_key('recall-coverage-bar'), findsOneWidget);
      },
    );
  });

  // ----------------------------------------------------------- per agent

  group('per agent rows', () {
    testWidgets(
      'each connected agent has a row reading on or off by its flag',
      (tester) async {
        await _pumpLocal(
          tester,
          agents: [
            _on('S-A', 'claude-desktop'),
            _off('S-B', 'claude-code', ago: 1000),
          ],
        );
        expect(
          _flat(tester, _key('recall-agent-S-A')),
          'claude-desktop $_agentOn',
        );
        expect(
          _flat(tester, _key('recall-agent-S-B')),
          'claude-code $_agentOff',
        );
        // Only the off row links to its command.
        expect(_key('recall-agent-command-S-B'), findsOneWidget);
        expect(_key('recall-agent-command-S-A'), findsNothing);
        expect(
          _flat(tester, _key('recall-agent-command-S-B')),
          'Turn on in its command',
        );
        // Rows follow the connected order (newest request first).
        expect(
          _rect(tester, _key('recall-agent-S-A')).top,
          lessThan(_rect(tester, _key('recall-agent-S-B')).top),
        );
      },
    );

    testWidgets('its command selects the Connect tab', (tester) async {
      final h = await _pumpLocal(tester, agents: [_off('S-B', 'claude-code')]);
      expect(h.read(agentsSheetTabProvider), AgentsTab.recall);
      await tester.tap(_key('recall-agent-command-S-B'));
      await h.settle();
      expect(h.read(agentsSheetTabProvider), AgentsTab.connect);
      expect(find.byType(ConnectTab), findsOneWidget);
      expect(find.byType(RecallTab), findsNothing);
    });

    testWidgets('no agent connected shows no agent rows', (tester) async {
      await _pumpLocal(tester);
      expect(_para(_localNoneHeading), findsOneWidget);
      expect(
        find.textContaining('runs with --with-embeddings', findRichText: true),
        findsNothing,
      );
      expect(
        find.textContaining('keyword search only. ', findRichText: true),
        findsNothing,
      );
    });

    testWidgets('a hosted vault shows no per agent rows', (tester) async {
      await _pumpHosted(
        tester,
        response: _fixture('server_embeddings_off.json'),
      );
      expect(_para(_hostedOffHeading), findsOneWidget);
      expect(
        find.textContaining('runs with --with-embeddings', findRichText: true),
        findsNothing,
      );
      expect(
        find.text('Turn on in its command', findRichText: true),
        findsNothing,
      );
    });
  });

  // --------------------------------------------------------------- model

  group('model line', () {
    testWidgets(
      'a downloaded local model shows downloaded to this vault with its size',
      (tester) async {
        await _pumpLocal(
          tester,
          cli: _cliWith(_status(cached: true, bytes: 127000000)),
        );
        expect(
          _flat(tester, _key('recall-model')),
          matches(
            RegExp(
              r'^Model BGE-small-en-v1\.5 · downloaded to this vault '
              r'\(127(\.0)? MB\)$',
            ),
          ),
        );
        expect(_key('recall-model-download'), findsNothing);
        expect(
          find.textContaining('Download it from Echoes', findRichText: true),
          findsNothing,
        );
      },
    );

    testWidgets('the local model size follows model_bytes', (tester) async {
      await _pumpLocal(
        tester,
        cli: _cliWith(_status(cached: true, bytes: 64000000)),
      );
      expect(
        _flat(tester, _key('recall-model')),
        matches(RegExp(r'\(64(\.0)? MB\)$')),
      );
    });

    testWidgets(
      'a local model not downloaded shows about 130 MB and the Echoes link',
      (tester) async {
        // Partial files on disk still read as not downloaded.
        await _pumpLocal(
          tester,
          cli: _cliWith(_status(cached: false, bytes: 5000000)),
        );
        expect(
          _flat(tester, _key('recall-model')),
          matches(
            RegExp(
              r'^Model BGE-small-en-v1\.5 · not downloaded \(about 130 MB\)'
              r'\.? ?Download it from Echoes\.$',
            ),
          ),
        );
        expect(
          _flat(tester, _key('recall-model-download')),
          'Download it from Echoes.',
        );
        expect(
          find.textContaining('downloaded to this vault', findRichText: true),
          findsNothing,
        );
      },
    );

    testWidgets(
      'Download it from Echoes opens the right panel on Echoes and closes the sheet with zero CLI calls',
      (tester) async {
        final cli = _cliWith(_status(cached: false, bytes: 0));
        final h = await _pumpLocal(tester, cli: cli);
        h.container.read(rightPanelOpenProvider.notifier).state = false;
        h.container.read(rightPanelTabProvider.notifier).state =
            RightPanelTab.connections;
        await tester.pump();
        final callsBefore = cli.calls.length;
        expect(agentsSheetFinder, findsOneWidget);

        await tester.tap(_key('recall-model-download'));
        await _fadeOut(tester);

        expect(h.read(rightPanelOpenProvider), isTrue);
        expect(h.read(rightPanelTabProvider), RightPanelTab.echoes);
        expect(agentsSheetFinder, findsNothing);
        expect(h.openCallsCompleted, 1);
        expect(cli.calls.length, callsBefore);
      },
    );

    testWidgets(
      'a hosted model downloaded on the server shows downloaded to the vault server with its size',
      (tester) async {
        await _pumpHosted(
          tester,
          response: _status(server: true, cached: true, bytes: 127000000),
        );
        expect(
          _flat(tester, _key('recall-model')),
          matches(
            RegExp(
              r'^Model BGE-small-en-v1\.5 · downloaded to the vault server '
              r'\(127(\.0)? MB\)$',
            ),
          ),
        );
        expect(_key('recall-model-download'), findsNothing);
      },
    );

    testWidgets(
      'a hosted model not downloaded shows not downloaded on the vault server with no Echoes link',
      (tester) async {
        await _pumpHosted(
          tester,
          response: _fixture('server_embeddings_off.json'),
        );
        expect(
          _flat(tester, _key('recall-model')),
          'Model BGE-small-en-v1.5 · not downloaded on the vault server',
        );
        expect(_key('recall-model-download'), findsNothing);
        expect(
          find.textContaining('Download it from Echoes', findRichText: true),
          findsNothing,
        );
      },
    );
  });

  // ------------------------------------------------------------- turn on

  group('turn on', () {
    testWidgets(
      'local with no agent on shows the whole flag on snippet and Copy config copies the same text',
      (tester) async {
        final copied = _captureClipboard(tester);
        await _pumpLocal(tester, agents: [_off('S-B', 'claude-code')]);
        final snippet = _localSnippet();
        expect(snippet, contains('"--with-embeddings"'));
        expect(_para(snippet), findsOneWidget);
        expect(_para(_localTurnOnNote), findsOneWidget);
        expect(_copyButton('Copy config'), findsOneWidget);
        await tester.tap(_copyButton('Copy config'));
        await tester.pump();
        await tester.pump();
        expect(copied, [snippet]);
      },
    );

    testWidgets(
      'local with no agent connected also shows the flag on snippet',
      (tester) async {
        await _pumpLocal(tester);
        expect(_para(_localSnippet()), findsOneWidget);
        expect(_copyButton('Copy config'), findsOneWidget);
        expect(_para(_localTurnOnNote), findsOneWidget);
      },
    );

    testWidgets('the local snippet holds the picked memex path', (
      tester,
    ) async {
      const picked = '/opt/memex tools/bin/memex';
      final h = await _pumpLocal(
        tester,
        binaryPath: picked,
        agents: [_off('S-B', 'claude-code')],
      );
      expect(h.read(settingsProvider).memexBinaryPath, picked);
      expect(_para(_localSnippet(memex: picked)), findsOneWidget);
      expect(_para(_localSnippet()), findsNothing);
    });

    testWidgets(
      'hosted off shows the server command with literal root and host port and Copy copies it',
      (tester) async {
        final copied = _captureClipboard(tester);
        await _pumpHosted(
          tester,
          response: _fixture('server_embeddings_off.json'),
        );
        expect(_para(_hostedCommand), findsOneWidget);
        expect(_para(_hostedTurnOnNote), findsOneWidget);
        expect(_copyButton('Copy'), findsOneWidget);
        expect(_copyButton('Copy config'), findsNothing);
        await tester.tap(_copyButton('Copy'));
        await tester.pump();
        await tester.pump();
        expect(copied, [_hostedCommand]);
      },
    );

    testWidgets('no turn on section shows when an agent uses recall', (
      tester,
    ) async {
      await _pumpLocal(tester, agents: [_on('S-A', 'claude-desktop')]);
      expect(_para(_localOnHeading), findsOneWidget);
      expect(_para(_localSnippet()), findsNothing);
      expect(_para(_localTurnOnNote), findsNothing);
      expect(_anyCopyButton, findsNothing);
    });

    testWidgets(
      'no turn on section shows when the vault server has recall on',
      (tester) async {
        await _pumpHosted(
          tester,
          response: _fixture('server_embeddings_on.json'),
        );
        expect(_para(_hostedOnHeading), findsOneWidget);
        expect(_para(_hostedCommand), findsNothing);
        expect(_para(_hostedTurnOnNote), findsNothing);
        expect(_anyCopyButton, findsNothing);
      },
    );
  });

  // -------------------------------------------------------- closing note

  group('closing note', () {
    final states = <(String, Future<void> Function(WidgetTester tester))>[
      (
        'the closing note shows when an agent uses recall',
        (t) => _pumpLocal(t, agents: [_on('S-A', 'claude-desktop')]),
      ),
      (
        'the closing note shows when connected agents use keyword search only',
        (t) => _pumpLocal(t, agents: [_off('S-B', 'claude-code')]),
      ),
      (
        'the closing note shows when no agent is connected',
        (t) => _pumpLocal(t),
      ),
      (
        'the closing note shows when the vault server has recall on',
        (t) => _pumpHosted(t, response: _fixture('server_embeddings_on.json')),
      ),
      (
        'the closing note shows when the vault server has recall off',
        (t) => _pumpHosted(t, response: _fixture('server_embeddings_off.json')),
      ),
      (
        'the closing note shows when the vault server is older than the app',
        (t) => _pumpHosted(
          t,
          response: null,
          prepare: (s) {
            s.route('GET', _embeddingsPath, status: 404, body: _compat());
          },
        ),
      ),
      (
        'the closing note shows when memex is not found',
        (t) => _pumpLocal(
          t,
          overrides: [memexCliProvider.overrideWithValue(null)],
        ),
      ),
      (
        'the closing note shows when memex is older than the app',
        (t) => _pumpLocal(
          t,
          cli: FakeMemexCli()
            ..on(
              'embeddings status',
              (_) => FakeMemexCli.failure('usage', exitCode: 2),
            ),
        ),
      ),
      (
        'the closing note shows beside an error',
        (t) => _pumpLocal(
          t,
          cli: FakeMemexCli()
            ..on(
              'embeddings status',
              (_) => FakeMemexCli.error('internal', 'boom'),
            ),
        ),
      ),
    ];
    for (final (name, pump) in states) {
      testWidgets(name, (tester) async {
        await pump(tester);
        expect(find.byType(RecallTab), findsOneWidget);
        expect(_para(_closingNote), findsOneWidget);
        expect(
          _boxColor(
            tester,
            find
                .ancestor(
                  of: _para(_closingNote),
                  matching: find.byWidgetPredicate(
                    (w) =>
                        w is DecoratedBox &&
                        w.decoration is BoxDecoration &&
                        (w.decoration as BoxDecoration).color != null,
                  ),
                )
                .first,
          )?.toARGB32(),
          OmColors.infoBg.toARGB32(),
        );
      });
    }
  });

  // -------------------------------------------------------------- states

  group('states', () {
    testWidgets(
      'no binary shows memex not found with Locate memex and no coverage',
      (tester) async {
        final h = await _pumpLocal(
          tester,
          overrides: [memexCliProvider.overrideWithValue(null)],
        );
        expect(
          find.text('memex not found', findRichText: true),
          findsOneWidget,
        );
        expect(_key('recall-locate-memex'), findsOneWidget);
        expect(
          tester.widget<OmButton>(_key('recall-locate-memex')).label,
          'Locate memex…',
        );
        expect(
          find.textContaining('passages embedded', findRichText: true),
          findsNothing,
        );
        expect(find.byKey(const Key('inline-error')), findsNothing);
        expect(h.cli.callsFor('embeddings status'), isEmpty);
      },
    );

    testWidgets(
      'Locate memex opens the file picker and a picked binary is stored',
      (tester) async {
        final picker = installFakeFilePicker();
        final picked = Platform.resolvedExecutable;
        picker.files.add(picked);
        final h = await _pumpLocal(
          tester,
          overrides: [memexCliProvider.overrideWithValue(null)],
        );
        await tester.tap(_key('recall-locate-memex'));
        await h.settle();
        expect(picker.calls.map((c) => c.method), ['pickFiles']);
        expect(h.read(settingsProvider).memexBinaryPath, picked);
      },
    );

    testWidgets(
      'a binary that cannot start is the same memex not found state',
      (tester) async {
        final cli = FakeMemexCli()
          ..on(
            'embeddings status',
            (_) => throw const ProcessException('memex', ['embeddings']),
          );
        await _pumpLocal(tester, cli: cli);
        expect(
          find.text('memex not found', findRichText: true),
          findsOneWidget,
        );
        expect(_key('recall-locate-memex'), findsOneWidget);
        expect(cli.callsFor('embeddings status'), hasLength(1));
      },
    );

    testWidgets(
      'exit 2 shows coverage unavailable because memex is older than the app',
      (tester) async {
        final cli = FakeMemexCli()
          ..on(
            'embeddings status',
            (_) => FakeMemexCli.failure(
              "error: unrecognized subcommand 'embeddings'",
              exitCode: 2,
            ),
          );
        await _pumpLocal(tester, cli: cli);
        expect(_para(_tooOldText), findsOneWidget);
        expect(find.byKey(const Key('inline-error')), findsNothing);
        expect(find.text('memex not found', findRichText: true), findsNothing);
        expect(
          find.textContaining('passages embedded', findRichText: true),
          findsNothing,
        );
      },
    );

    testWidgets(
      'a failed run shows an InlineError with the CLI message and Retry',
      (tester) async {
        final cli = FakeMemexCli()
          ..on(
            'embeddings status',
            (_) => FakeMemexCli.error('internal', 'chunk_vec is locked'),
          );
        await _pumpLocal(tester, cli: cli);
        expect(find.byKey(const Key('inline-error')), findsOneWidget);
        expect(
          find.textContaining('chunk_vec is locked', findRichText: true),
          findsOneWidget,
        );
        expect(find.byKey(const Key('inline-error-retry')), findsOneWidget);
        expect(_para(_tooOldText), findsNothing);
        expect(
          find.textContaining('passages embedded', findRichText: true),
          findsNothing,
        );
      },
    );

    testWidgets(
      'a hosted unauthorized read shows an InlineError with the server message',
      (tester) async {
        await _pumpHosted(
          tester,
          response: _fixture('server_embeddings_on.json'),
          prepare: (s) => s.token = 'rotated-token',
        );
        expect(find.byKey(const Key('inline-error')), findsOneWidget);
        expect(
          find.textContaining(
            'missing or wrong access token',
            findRichText: true,
          ),
          findsOneWidget,
        );
        expect(find.byKey(const Key('inline-error-retry')), findsOneWidget);
        expect(_para(_hostedUnknownHeading), findsNothing);
      },
    );

    testWidgets('an unreachable server shows an InlineError with Retry', (
      tester,
    ) async {
      final (h, _) = await _pumpHosted(
        tester,
        response: _fixture('server_embeddings_on.json'),
        prepare: (s) => s.failure = FakeServerFailure.refused,
      );
      expect(find.byKey(const Key('inline-error')), findsOneWidget);
      expect(find.byKey(const Key('inline-error-retry')), findsOneWidget);
      expect(h.read(recallTabDotProvider), isNull);
    });

    testWidgets(
      'the first read shows the shared loading state until it answers',
      (tester) async {
        final gate = Completer<void>();
        addTearDown(() {
          if (!gate.isCompleted) gate.complete();
        });
        final cli = FakeMemexCli()
          ..on('embeddings status', (_) async {
            await gate.future;
            return FakeMemexCli.ok(_status());
          });
        final h = await _pumpLocal(tester, cli: cli);
        expect(cli.callsFor('embeddings status'), hasLength(1));
        expect(find.byType(AgentsTabLoading), findsOneWidget);
        expect(
          find.textContaining('passages embedded', findRichText: true),
          findsNothing,
        );
        gate.complete();
        await h.settle();
        expect(find.byType(AgentsTabLoading), findsNothing);
        expect(_para('64 of 71 passages embedded'), findsOneWidget);
      },
    );
  });

  // --------------------------------------------------------------- retry

  group('retry', () {
    testWidgets('Retry re-reads once and shows the status when it answers', (
      tester,
    ) async {
      var fail = true;
      final cli = FakeMemexCli()
        ..on(
          'embeddings status',
          (_) => fail
              ? FakeMemexCli.error('internal', 'boom')
              : FakeMemexCli.ok(_status(chunks: 9, embedded: 3)),
        );
      final h = await _pumpLocal(tester, cli: cli);
      expect(cli.callsFor('embeddings status'), hasLength(1));
      expect(find.byKey(const Key('inline-error')), findsOneWidget);
      fail = false;
      await tester.tap(find.byKey(const Key('inline-error-retry')));
      await h.settle();
      expect(cli.callsFor('embeddings status'), hasLength(2));
      expect(find.byKey(const Key('inline-error')), findsNothing);
      expect(_para('3 of 9 passages embedded'), findsOneWidget);
    });

    testWidgets('a retry that fails again shows the new message', (
      tester,
    ) async {
      var n = 0;
      final cli = FakeMemexCli()
        ..on(
          'embeddings status',
          (_) => FakeMemexCli.error('internal', 'boom ${++n}'),
        );
      final h = await _pumpLocal(tester, cli: cli);
      expect(find.textContaining('boom 1', findRichText: true), findsOneWidget);
      await tester.tap(find.byKey(const Key('inline-error-retry')));
      await h.settle();
      expect(find.textContaining('boom 2', findRichText: true), findsOneWidget);
      expect(find.textContaining('boom 1', findRichText: true), findsNothing);
      expect(cli.callsFor('embeddings status'), hasLength(2));
    });

    testWidgets('two Retry presses in one frame run one read', (tester) async {
      var held = false;
      final gate = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      final cli = FakeMemexCli()
        ..on('embeddings status', (_) async {
          if (!held) return FakeMemexCli.error('internal', 'boom');
          await gate.future;
          return FakeMemexCli.ok(_status());
        });
      final h = await _pumpLocal(tester, cli: cli);
      expect(cli.callsFor('embeddings status'), hasLength(1));
      held = true;
      await tester.tap(find.byKey(const Key('inline-error-retry')));
      await tester.tap(find.byKey(const Key('inline-error-retry')));
      await h.settle();
      expect(cli.callsFor('embeddings status'), hasLength(2));
      gate.complete();
      await h.settle();
      expect(cli.callsFor('embeddings status'), hasLength(2));
      expect(_para('64 of 71 passages embedded'), findsOneWidget);
    });

    testWidgets('Retry on a hosted error reads the server again once', (
      tester,
    ) async {
      final (h, server) = await _pumpHosted(
        tester,
        response: _fixture('server_embeddings_on.json'),
        prepare: (s) => s.token = 'rotated-token',
      );
      expect(_serverReads(server), 1);
      server.token = fakeServerToken;
      await tester.tap(find.byKey(const Key('inline-error-retry')));
      await h.settle();
      expect(_serverReads(server), 2);
      expect(find.byKey(const Key('inline-error')), findsNothing);
      expect(_para(_hostedOnHeading), findsOneWidget);
    });
  });

  // -------------------------------------------------------------- layout

  group('layout', () {
    final cases = <(String, double, double, bool)>[
      (
        'local off at 1.5x text in a 720 px sheet does not overflow',
        1000,
        1.5,
        false,
      ),
      (
        'local off at 1.5x text in a 640 px sheet does not overflow',
        672,
        1.5,
        false,
      ),
      (
        'local off at 1.0x text in a 480 px window does not overflow',
        480,
        1.0,
        false,
      ),
      (
        'local off at 1.5x text in a 480 px window does not overflow',
        480,
        1.5,
        false,
      ),
      (
        'hosted off at 1.5x text in a 720 px sheet does not overflow',
        1000,
        1.5,
        true,
      ),
      (
        'hosted off at 1.5x text in a 640 px sheet does not overflow',
        672,
        1.5,
        true,
      ),
      (
        'hosted off at 1.0x text in a 480 px window does not overflow',
        480,
        1.0,
        true,
      ),
      (
        'hosted off at 1.5x text in a 480 px window does not overflow',
        480,
        1.5,
        true,
      ),
    ];
    for (final (name, width, scale, hosted) in cases) {
      testWidgets(name, (tester) async {
        final size = Size(width, 900);
        if (hosted) {
          await _pumpHosted(
            tester,
            response: _status(server: false, chunks: 71, embedded: 0),
            size: size,
            textScale: scale,
          );
          expect(_para(_hostedCommand), findsOneWidget);
        } else {
          await _pumpLocal(
            tester,
            cli: _cliWith(_status(cached: false, bytes: 0)),
            agents: [
              _off('S-B', 'claude-code-with-a-long-client-name'),
              _off('S-C', 'cursor', ago: 9),
            ],
            size: size,
            textScale: scale,
          );
          expect(_para(_localSnippet()), findsOneWidget);
          expect(_key('recall-model-download'), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
        final sheet = _rect(tester, agentsSheetFinder);
        for (final f in [
          _para(_closingNote),
          _key('recall-coverage-bar'),
          _key('recall-model'),
        ]) {
          final r = _rect(tester, f);
          expect(r.left, greaterThanOrEqualTo(sheet.left));
          expect(r.right, lessThanOrEqualTo(sheet.right));
        }
      });
    }

    testWidgets('an error fits a 480 px window at 1.5x text', (tester) async {
      final cli = FakeMemexCli()
        ..on(
          'embeddings status',
          (_) => FakeMemexCli.error('internal', 'boom ' * 20),
        );
      await _pumpLocal(
        tester,
        cli: cli,
        size: const Size(480, 900),
        textScale: 1.5,
      );
      expect(find.byKey(const Key('inline-error')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  // --------------------------------------------------- pinned contracts

  group('formatModelBytes', () {
    final cases = <(String, int, String)>[
      ('zero bytes reads 0 B', 0, '0 B'),
      ('999 bytes reads 999 B', 999, '999 B'),
      ('1000 bytes reads 1 KB', 1000, '1 KB'),
      ('1499 bytes reads 1 KB', 1499, '1 KB'),
      ('1500 bytes reads 2 KB', 1500, '2 KB'),
      ('512000 bytes reads 512 KB', 512000, '512 KB'),
      ('1000000 bytes reads 1.0 MB', 1000000, '1.0 MB'),
      ('2500000 bytes reads 2.5 MB', 2500000, '2.5 MB'),
      ('9900000 bytes reads 9.9 MB', 9900000, '9.9 MB'),
      ('10000000 bytes reads 10 MB', 10000000, '10 MB'),
      ('127000000 bytes reads 127 MB', 127000000, '127 MB'),
      ('127600000 bytes reads 128 MB', 127600000, '128 MB'),
      ('1000000000 bytes reads 1.0 GB', 1000000000, '1.0 GB'),
      ('1250000000 bytes reads 1.3 GB', 1250000000, '1.3 GB'),
    ];
    for (final (name, bytes, text) in cases) {
      test(name, () => expect(formatModelBytes(bytes), text));
    }
  });

  group('hosted server_embeddings null', () {
    testWidgets('a hosted status with server_embeddings null reads as off', (
      tester,
    ) async {
      final (h, _) = await _pumpHosted(tester, response: _status(server: null));
      expect(_para(_hostedOffHeading), findsOneWidget);
      expect(_para(_hostedOnHeading), findsNothing);
      expect(
        _boxColor(tester, _key('recall-heading-dot'))?.toARGB32(),
        OmColors.fg2.toARGB32(),
      );
      expect(h.read(recallTabDotProvider), isFalse);
      expect(_para(_hostedCommand), findsOneWidget);
    });
  });

  group('activity still loading', () {
    testWidgets(
      'the local tab shows No agent is connected with no dot and no agent rows while activity loads',
      (tester) async {
        final access = _agents([_on('S-A', 'claude-desktop')])..holdNextRead();
        final h = await _pumpLocal(tester, access: access);
        expect(access.holding, isTrue);
        expect(find.byType(RecallTab), findsOneWidget);
        expect(_para('64 of 71 passages embedded'), findsOneWidget);
        expect(_para(_localNoneHeading), findsOneWidget);
        expect(_key('recall-heading-dot'), findsNothing);
        expect(_key('recall-agent-S-A'), findsNothing);
        access.release();
        await h.settle();
        expect(_para(_localOnHeading), findsOneWidget);
        expect(_key('recall-agent-S-A'), findsOneWidget);
      },
    );
  });

  group('activity unknown', () {
    testWidgets(
      'an errored activity reads No agent is connected with no dot and no agent rows',
      (tester) async {
        final h = await _pumpLocal(
          tester,
          overrides: [
            agentActivityAsyncProvider.overrideWith(_Wi413ErrorActivity.new),
          ],
        );
        expect(h.read(agentActivityAsyncProvider).hasError, isTrue);
        expect(_para('64 of 71 passages embedded'), findsOneWidget);
        expect(_para(_localNoneHeading), findsOneWidget);
        expect(_key('recall-heading-dot'), findsNothing);
        expect(h.read(recallTabDotProvider), isNull);
        expect(_key('recall-agent-S-A'), findsNothing);
      },
    );

    test(
      'recallConnectedAgents is null for loading, error and unavailable',
      () {
        final on = _on('S-A', 'claude-desktop');
        final view = AgentActivityView(
          connected: [ConnectedAgent(presence: on, working: false)],
          recent: const [],
          available: true,
          clockOffsetMs: 0,
        );
        expect(recallConnectedAgents(AsyncData(view))!.single, same(on));
        expect(
          recallConnectedAgents(AsyncData(AgentActivityView.empty)),
          isEmpty,
        );
        expect(
          recallConnectedAgents(
            AsyncError<AgentActivityView>(StateError('x'), StackTrace.empty),
          ),
          isNull,
        );
        expect(
          recallConnectedAgents(const AsyncLoading<AgentActivityView>()),
          isNull,
        );
        expect(
          recallConnectedAgents(
            AsyncData(
              AgentActivityView(
                connected: view.connected,
                recent: const [],
                available: false,
                clockOffsetMs: 0,
              ),
            ),
          ),
          isNull,
        );
      },
    );
  });

  group('dismissing an error', () {
    testWidgets(
      'dismiss hides the error and keeps the closing note, and the next read shows its error again',
      (tester) async {
        final cli = FakeMemexCli()
          ..on(
            'embeddings status',
            (_) => FakeMemexCli.error('internal', 'chunk_vec is locked'),
          );
        final h = await _pumpLocal(tester, cli: cli);
        expect(find.byKey(const Key('inline-error')), findsOneWidget);
        await tester.tap(find.byKey(const Key('inline-error-dismiss')));
        await h.settle();
        expect(find.byKey(const Key('inline-error')), findsNothing);
        expect(find.byKey(const Key('inline-error-retry')), findsNothing);
        expect(_para(_closingNote), findsOneWidget);
        expect(_para(_localNoneHeading), findsOneWidget);
        expect(cli.callsFor('embeddings status'), hasLength(1));
        // The 10 s tick reads again; its error shows even though the same
        // message was dismissed.
        h.clock.advance(const Duration(seconds: 10));
        await h.settle();
        expect(cli.callsFor('embeddings status'), hasLength(2));
        expect(find.byKey(const Key('inline-error')), findsOneWidget);
      },
    );

    testWidgets(
      'dismiss on a hosted error hides it and keeps the closing note',
      (tester) async {
        final (h, _) = await _pumpHosted(
          tester,
          response: _fixture('server_embeddings_on.json'),
          prepare: (s) => s.token = 'rotated-token',
        );
        expect(find.byKey(const Key('inline-error')), findsOneWidget);
        await tester.tap(find.byKey(const Key('inline-error-dismiss')));
        await h.settle();
        expect(find.byKey(const Key('inline-error')), findsNothing);
        expect(_para(_closingNote), findsOneWidget);
      },
    );
  });

  group('locate memex', () {
    testWidgets('locating the same binary again reads the status again', (
      tester,
    ) async {
      final picked = Platform.resolvedExecutable;
      final picker = installFakeFilePicker();
      picker.files.add(picked);
      var answers = false;
      final cli = FakeMemexCli()
        ..on('embeddings status', (_) {
          if (!answers) throw const ProcessException('memex', ['embeddings']);
          return FakeMemexCli.ok(_status());
        });
      final h = await _pumpLocal(tester, cli: cli, binaryPath: picked);
      expect(_key('recall-locate-memex'), findsOneWidget);
      expect(cli.callsFor('embeddings status'), hasLength(1));
      answers = true;
      await tester.tap(_key('recall-locate-memex'));
      await h.settle();
      expect(picker.calls.map((c) => c.method), ['pickFiles']);
      expect(cli.callsFor('embeddings status'), hasLength(2));
      expect(_key('recall-locate-memex'), findsNothing);
      expect(_para('64 of 71 passages embedded'), findsOneWidget);
    });

    testWidgets(
      'cancelling the picker keeps memex not found and reads nothing',
      (tester) async {
        final picker = installFakeFilePicker();
        final h = await _pumpLocal(
          tester,
          overrides: [memexCliProvider.overrideWithValue(null)],
        );
        await tester.tap(_key('recall-locate-memex'));
        await h.settle();
        expect(picker.calls, hasLength(1));
        expect(_key('recall-locate-memex'), findsOneWidget);
        expect(h.cli.callsFor('embeddings status'), isEmpty);
      },
    );
  });

  group('links', () {
    void focusEchoesLink(WidgetTester tester) {
      final text = find.descendant(
        of: _key('recall-model-download'),
        matching: find.text('Download it from Echoes.'),
      );
      Focus.of(tester.element(text)).requestFocus();
    }

    Future<AgentsSheetHarness> pumpEchoesLink(
      WidgetTester tester, {
      bool focus = true,
    }) async {
      final h = await _pumpLocal(
        tester,
        cli: _cliWith(_status(cached: false, bytes: 0)),
      );
      h.container.read(rightPanelOpenProvider.notifier).state = false;
      h.container.read(rightPanelTabProvider.notifier).state =
          RightPanelTab.connections;
      await tester.pump();
      if (focus) focusEchoesLink(tester);
      await tester.pump();
      return h;
    }

    final keys = <(String, LogicalKeyboardKey)>[
      (
        'Enter on the focused Echoes link opens Echoes',
        LogicalKeyboardKey.enter,
      ),
      (
        'Numpad Enter on the focused Echoes link opens Echoes',
        LogicalKeyboardKey.numpadEnter,
      ),
      (
        'Space on the focused Echoes link opens Echoes',
        LogicalKeyboardKey.space,
      ),
    ];
    for (final (name, key) in keys) {
      testWidgets(name, (tester) async {
        final h = await pumpEchoesLink(tester);
        await tester.sendKeyEvent(key);
        await _fadeOut(tester);
        expect(h.read(rightPanelOpenProvider), isTrue);
        expect(h.read(rightPanelTabProvider), RightPanelTab.echoes);
        expect(agentsSheetFinder, findsNothing);
      });
    }

    testWidgets('another key on the focused Echoes link does nothing', (
      tester,
    ) async {
      final h = await pumpEchoesLink(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(h.read(rightPanelOpenProvider), isFalse);
      expect(h.read(rightPanelTabProvider), RightPanelTab.connections);
      expect(agentsSheetFinder, findsOneWidget);
    });

    testWidgets(
      'a held Enter or a released Enter does not activate the Echoes link',
      (tester) async {
        // Enter went down before the link had focus: the link sees only the
        // repeat and the release.
        final h = await pumpEchoesLink(tester, focus: false);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
        focusEchoesLink(tester);
        await tester.pump();
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.enter);
        expect(h.read(rightPanelTabProvider), RightPanelTab.connections);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
        expect(h.read(rightPanelTabProvider), RightPanelTab.connections);
        expect(h.read(rightPanelOpenProvider), isFalse);
        expect(agentsSheetFinder, findsOneWidget);
      },
    );

    testWidgets('the Echoes link is a leaf link node with its label and tap', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _pumpLocal(tester, cli: _cliWith(_status(cached: false, bytes: 0)));
      final node = tester.getSemantics(_key('recall-model-download'));
      expect(
        node,
        matchesSemantics(
          label: 'Download it from Echoes.',
          isLink: true,
          hasTapAction: true,
        ),
      );
      expect(node.childrenCount, 0);
      handle.dispose();
    });

    testWidgets('the Connect link is a leaf link node with its label and tap', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _pumpLocal(tester, agents: [_off('S-B', 'claude-code')]);
      final node = tester.getSemantics(_key('recall-agent-command-S-B'));
      expect(
        node,
        matchesSemantics(
          label: 'Turn on in its command',
          isLink: true,
          hasTapAction: true,
        ),
      );
      expect(node.childrenCount, 0);
      handle.dispose();
    });

    testWidgets('the status heading is a semantics header', (tester) async {
      final handle = tester.ensureSemantics();
      await _pumpLocal(tester, agents: [_on('S-A', 'claude-desktop')]);
      expect(
        tester.getSemantics(_para(_localOnHeading)),
        matchesSemantics(label: _localOnHeading, isHeader: true),
      );
      handle.dispose();
    });
  });
}
