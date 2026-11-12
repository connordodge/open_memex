// WI #411 (Spec #394 req 13, 15, 22-30, 46): the Connect tab's test rig,
// shared by the four connect_tab_*_test.dart files. It wraps the shell's
// `pumpAgentsSheet` (never edited here) and adds what Connect needs:
//
// - `claudeConfigReaderProvider` always overridden (a FakeClaudeConfigReader
//   answering "missing" by default), so no test reads the real
//   `~/Library/Application Support/Claude/claude_desktop_config.json`;
// - `memexCliProvider` derived from the settings' binary path (null when
//   there is none), so a tab may read either seam;
// - a fixed UTC offset (`utcOffsetProvider`, +05:45) for the hosted Claude
//   Code line;
// - a recording `updateTokenSeamProvider`;
// - the clipboard (`Clipboard.setData`), `copySensitive` on
//   `open_memex/files` and the accessibility channel, mocked and recorded.
//
// Every finder reads what is on screen (text, Semantics) or the public
// `OmCopyButton` seam, never a private widget.
import 'dart:async';
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/agents_sheet/connect/claude_config_reader.dart';
import 'package:open_memex_app/src/state/app_focus.dart';
import 'package:open_memex_app/src/state/hosted_connection_state.dart';
import 'package:open_memex_app/src/state/settings.dart';
import 'package:open_memex_app/src/state/vault_open_hosted.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/state/vault_trash.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/widgets/om_copy_button.dart';

import 'agents_sheet_harness.dart';
import 'claude_config_reader_fakes.dart';
import 'fake_memex_cli.dart';

export 'agents_sheet_harness.dart';
export 'claude_config_reader_fakes.dart';

/// The picked memex binary the harness seeds by default.
const connectMemexPath = '/Users/tester/.cargo/bin/memex';

/// The local vault's absolute path (`agentsSheetLocalVault`).
const connectVaultPath = '/Users/tester/vaults/Studio';

/// The hosted vault's MCP address: `agentsSheetServer.url` with its
/// trailing slash dropped, then `/vaults/studio/mcp`.
const connectMcpAddress = 'http://nas.local:7878/vaults/studio/mcp';

/// The UTC offset the rig fixes for the hosted Claude Code line.
const connectUtcOffset = Duration(hours: 5, minutes: 45);

/// Step 1 of local Claude Desktop (Spec #394 req 23).
const connectStepOpenConfig = 'Open Claude Desktop’s config file';

/// Step 2 of local Claude Desktop.
const connectStepMerge = 'Merge this into its mcpServers';

/// The restart step (local and hosted Claude Desktop).
const connectStepRestart = 'Quit and reopen Claude Desktop';

/// The local restart step's note.
const connectRestartNote =
    'Its tools menu then lists the memex tools, and it shows under Live as '
    'soon as it connects. Do this again after every Open Memex update.';

/// The Claude Code step (local and hosted).
const connectStepTerminal = 'Run this in a terminal';

/// Hosted Claude Desktop's step 1.
const connectStepHostedMerge = 'Merge this into Claude Desktop’s mcpServers';

/// The unstable-path warning (Spec #394 req 15).
const connectUnstableWarning =
    'Move Open Memex to Applications first; this path changes.';

/// The Copy buttons' Semantics labels (Spec #394 req 46).
const copyConfigPathLabel = 'Copy config file path';
const copyDesktopConfigLabel = 'Copy Claude Desktop config';
const copyCodeCommandLabel = 'Copy Claude Code command';
const copyMcpAddressLabel = 'Copy MCP address';
const copyAccessTokenLabel = 'Copy access token';

/// Everything a Connect test drives and inspects.
class ConnectRig {
  ConnectRig._(this.tester, this.harness, this.reader);

  final WidgetTester tester;
  final AgentsSheetHarness harness;

  /// Behind `claudeConfigReaderProvider` (null when the test passed its own
  /// override for it).
  final FakeClaudeConfigReader? reader;

  /// `text` of every `Clipboard.setData` call, in order.
  final clipboard = <String>[];

  /// The argument of every `copySensitive` call, in order.
  final sensitive = <String>[];

  /// The server id of every `updateTokenSeamProvider` call, in order.
  final updateTokenCalls = <String>[];

  ProviderContainer get container => harness.container;

  /// Keychain reads of [serverId] so far.
  int tokenReads([String serverId = 'srv-nas']) =>
      harness.tokens.calls.where((c) => c == 'read $serverId').length;

  /// A few frames, for provider futures and short animations.
  Future<void> settle() => harness.settle();

  /// Taps [finder] and settles.
  Future<void> tap(Finder finder) async {
    expect(finder, findsOneWidget, reason: 'the tap target is on screen');
    await tester.tap(finder);
    await settle();
  }

  /// Selects the `Claude Desktop` or `Claude Code` segment.
  Future<void> chooseClient(String label) => tap(inSheet(find.text(label)));

  /// Taps the Copy button labelled [semanticLabel] and lets the copy land.
  Future<void> copy(String semanticLabel) async {
    expect(copyButton(semanticLabel), findsOneWidget, reason: semanticLabel);
    await tester.tap(copyButton(semanticLabel));
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }
    await settle();
  }

  /// Activates the `Include semantic recall` switch (its Semantics tap).
  Future<void> toggleRecall() async {
    expect(recallSwitch(), findsOne, reason: 'the recall switch is shown');
    tester.semantics.tap(recallSwitch());
    await settle();
  }

  /// Whether the recall switch reads on, from its Semantics toggled state.
  bool get recallOn =>
      recallSwitch()
          .evaluate()
          .single
          .getSemanticsData()
          .flagsCollection
          .isToggled ==
      Tristate.isTrue;

  /// Taps the shell's tab chip for [tab] (`live`, `connect`, `tools`,
  /// `recall`).
  Future<void> showTab(String tab) => tap(find.byKey(Key('agents-tab-$tab')));

  /// Closes the sheet with its footer `Close` and lets the fade finish.
  Future<void> closeSheet() async {
    await tester.tap(find.byKey(const Key('agents-sheet-footer-close')));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(agentsSheetFinder, findsNothing, reason: 'the sheet closed');
  }

  /// Opens the sheet again (it opens on Connect with no agents).
  Future<void> reopen() async {
    await harness.open();
    await settle();
  }

  /// The window loses focus, then regains it.
  Future<void> refocusApp() async {
    final focus = container.read(appFocusProvider.notifier) as FakeAppFocus;
    focus.set(false);
    await settle();
    focus.set(true);
    await settle();
  }
}

/// Pumps the Agents sheet open on Connect with the rig's overrides.
///
/// [reader] answers the config reads (default: the file is missing).
/// [overrides] come last, so a test's own override wins.
Future<ConnectRig> pumpConnect(
  WidgetTester tester, {
  VaultRef vault = agentsSheetLocalVault,
  String? binaryPath = connectMemexPath,
  Map<String, String>? tokens,
  List<SavedServer> servers = const [agentsSheetServer],
  FakeClaudeConfigReader? reader,
  List<Override> overrides = const [],
  Size size = const Size(1000, 900),
  double textScale = 1.0,
}) async {
  final fakeReader = reader ?? FakeClaudeConfigReader.missing();
  // A second pump in one test would otherwise keep the first app's
  // navigator, and with it the first sheet: start from an empty tree.
  await tester.pumpWidget(const SizedBox.shrink());
  late ConnectRig rig;
  final harness = await pumpAgentsSheet(
    tester,
    vault: vault,
    binaryPath: binaryPath,
    tokens: tokens,
    servers: servers,
    size: size,
    textScale: textScale,
    open: false,
    claudeConfig: fakeReader,
    overrides: [
      memexCliProvider.overrideWith((ref) {
        final path = ref.watch(settingsProvider).memexBinaryPath;
        if (path == null || path.isEmpty) return null;
        return FakeMemexCli(binaryPath: path);
      }),
      utcOffsetProvider.overrideWithValue(() => connectUtcOffset),
      updateTokenSeamProvider.overrideWithValue(
        (serverId) => rig.updateTokenCalls.add(serverId),
      ),
      ...overrides,
    ],
  );
  rig = ConnectRig._(tester, harness, fakeReader);
  _mockChannels(tester, rig);
  await harness.open();
  await rig.settle();
  return rig;
}

void _mockChannels(WidgetTester tester, ConnectRig rig) {
  final messenger = tester.binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.setData') {
      final args = call.arguments as Map<Object?, Object?>;
      rig.clipboard.add(args['text']! as String);
    }
    return null;
  });
  messenger.setMockMethodCallHandler(vaultFilesChannel, (call) async {
    if (call.method == 'copySensitive') {
      rig.sensitive.add(call.arguments as String);
    }
    return null;
  });
  messenger.setMockDecodedMessageHandler<Object?>(
    SystemChannels.accessibility,
    (_) async => null,
  );
  addTearDown(() {
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    messenger.setMockMethodCallHandler(vaultFilesChannel, null);
    messenger.setMockDecodedMessageHandler<Object?>(
      SystemChannels.accessibility,
      null,
    );
  });
}

/// The Semantics node of the `Include semantic recall` switch: labelled
/// exactly that, with a toggled state (Spec #394 req 46).
SemanticsFinder recallSwitch() => find.semantics.byPredicate((n) {
  final d = n.getSemanticsData();
  return d.label == 'Include semantic recall' &&
      d.flagsCollection.isToggled != Tristate.none;
}, describeMatch: (_) => 'the Include semantic recall switch');

/// [f] inside the sheet.
Finder inSheet(Finder f) => find.descendant(of: agentsSheetFinder, matching: f);

/// The `OmCopyButton` whose Semantics label is [semanticLabel].
Finder copyButton(String semanticLabel) => find.byWidgetPredicate(
  (w) => w is OmCopyButton && w.semanticLabel == semanticLabel,
  description: 'OmCopyButton($semanticLabel)',
);

/// The plain text a text widget shows: a `RichText`'s spans or an
/// `EditableText`'s value.
String? shownText(Widget w) => switch (w) {
  RichText() => w.text.toPlainText(includePlaceholders: false),
  EditableText() => w.controller.text,
  _ => null,
};

/// Every on-screen text widget (RichText or EditableText) showing exactly
/// [text].
Finder textShowing(String text) => find.byWidgetPredicate(
  (w) => shownText(w) == text,
  description: 'text showing "$text"',
);

/// Every on-screen text widget whose text contains [part].
Finder textContaining(String part) => find.byWidgetPredicate(
  (w) => shownText(w)?.contains(part) ?? false,
  description: 'text containing "$part"',
);

/// A text widget whose text equals [label] ignoring case (a button label).
Finder labelIgnoringCase(String label) => find.byWidgetPredicate(
  (w) => shownText(w)?.toLowerCase() == label.toLowerCase(),
  description: 'label "$label"',
);

/// The code block (surface0 box) that holds the Copy button labelled
/// [copyLabel]: its nearest such ancestor, found now (nothing when that
/// Copy button is not on screen).
Finder codeBlock(String copyLabel) {
  final ancestors = find
      .ancestor(
        of: copyButton(copyLabel),
        matching: find.byWidgetPredicate(
          (w) =>
              w is DecoratedBox &&
              w.decoration is BoxDecoration &&
              (w.decoration as BoxDecoration).color == OmColors.surface0,
          description: 'surface0 box',
        ),
      )
      .evaluate()
      .toList();
  final nearest = ancestors.isEmpty ? null : ancestors.first;
  return find.byElementPredicate(
    (e) => nearest != null && e == nearest,
    description: 'code block of $copyLabel',
  );
}

/// The text the code block around [copyLabel] shows, its Copy button left
/// out: its text widgets top to bottom, joined with newlines.
String codeBlockText(WidgetTester tester, String copyLabel) {
  expect(copyButton(copyLabel), findsOneWidget, reason: copyLabel);
  final block = codeBlock(copyLabel);
  final copyTexts = find
      .descendant(
        of: copyButton(copyLabel),
        matching: find.byWidgetPredicate((w) => shownText(w) != null),
      )
      .evaluate()
      .map((e) => e.widget)
      .toSet();
  final texts = find
      .descendant(
        of: block,
        matching: find.byWidgetPredicate((w) => shownText(w) != null),
      )
      .evaluate()
      .where((e) => !copyTexts.contains(e.widget))
      .toList();
  texts.sort((a, b) {
    final ra = tester.getTopLeft(find.byElementPredicate((e) => e == a));
    final rb = tester.getTopLeft(find.byElementPredicate((e) => e == b));
    final dy = ra.dy.compareTo(rb.dy);
    return dy != 0 ? dy : ra.dx.compareTo(rb.dx);
  });
  return texts.map((e) => shownText(e.widget)).join('\n');
}

/// One run of text in a span tree with its effective (inherited) style.
typedef StyledRun = ({String text, TextStyle style});

/// Flattens [root] into runs, merging each span's style into its parent's.
List<StyledRun> styledRuns(InlineSpan root, [TextStyle? inherited]) {
  final out = <StyledRun>[];
  void visit(InlineSpan span, TextStyle parent) {
    final style = parent.merge(span.style);
    if (span is TextSpan) {
      final text = span.text;
      if (text != null && text.isNotEmpty) {
        out.add((text: text, style: style));
      }
      for (final child in span.children ?? const <InlineSpan>[]) {
        visit(child, style);
      }
    }
  }

  visit(root, inherited ?? const TextStyle());
  return out;
}

/// The styled runs of every RichText in the code block around [copyLabel],
/// its Copy button left out.
List<StyledRun> codeBlockRuns(WidgetTester tester, String copyLabel) {
  expect(copyButton(copyLabel), findsOneWidget, reason: copyLabel);
  final copyRich = find
      .descendant(of: copyButton(copyLabel), matching: find.byType(RichText))
      .evaluate()
      .map((e) => e.widget)
      .toSet();
  return [
    for (final e
        in find
            .descendant(
              of: codeBlock(copyLabel),
              matching: find.byType(RichText),
            )
            .evaluate())
      if (!copyRich.contains(e.widget))
        ...styledRuns((e.widget as RichText).text),
  ];
}

/// Holds Claude Desktop config reads until the test releases them, and
/// records how many ran at once.
class HeldClaudeConfigReader implements ClaudeConfigReader {
  HeldClaudeConfigReader(this.result);

  ClaudeConfigRead result;
  final _held = <Completer<void>>[];

  /// Reads started.
  int reads = 0;

  /// Reads started and not yet finished.
  int inFlight = 0;

  /// The most reads ever in flight at once.
  int maxInFlight = 0;

  /// Whether new reads wait for [release].
  bool holding = true;

  @override
  Future<ClaudeConfigRead> read() async {
    reads++;
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    try {
      if (holding) {
        final gate = Completer<void>();
        _held.add(gate);
        await gate.future;
      }
      return result;
    } finally {
      inFlight--;
    }
  }

  /// Completes every held read.
  void release() {
    for (final g in List.of(_held)) {
      g.complete();
    }
    _held.clear();
  }
}
