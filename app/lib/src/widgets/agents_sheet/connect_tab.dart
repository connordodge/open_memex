// WI #411 (Spec #394 req 13, 15, 22-30, 46; design pack
// design/394-agents-sheet/packs/411.md, RULINGS #3, #12, #15-#17): the
// Agents sheet's Connect tab.
//
// Token lifetime (req 27): the access token is read from
// `tokenStoreProvider` only (a) when the tab opens, to derive the mask,
// then dropped; (b) inside each token-bearing Copy's `text` function; and
// (c) on each Reveal. While revealed it lives only in this tab's State
// (`_revealed`), so closing the sheet drops it. It never reaches a
// provider, a Semantics label, a log line or an error.
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../agents_sheet/connect/claude_config_match.dart';
import '../../agents_sheet/connect/claude_config_reader.dart';
import '../../agents_sheet/connect/snippets.dart';
import '../../agents_sheet/connect/token_text.dart';
import '../../state/agents_sheet/connect_tab_state.dart';
import '../../state/app_focus.dart';
import '../../state/hosted_connection_state.dart';
import '../../state/settings.dart';
import '../../state/token_store.dart';
import '../../state/vault_open_hosted.dart';
import '../../state/vault_state.dart';
import '../../vault_access/hosted/utc_offset.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../atoms.dart';
import '../memex_too_old_dialog.dart' show locateMemexBinary;
import '../om_copy_button.dart';
import 'agents_tab_loading.dart';
import 'connect/code_block.dart';
import 'connect/controls.dart';
import 'connect/detection_line.dart';
import 'connect/step.dart';
import 'connect/token_row.dart';

/// The Agents sheet's `Connect` tab body: setup snippets for Claude
/// Desktop and Claude Code on the open vault.
class ConnectTab extends ConsumerWidget {
  const ConnectTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vault = ref.watch(currentVaultProvider);
    if (vault == null) return const SizedBox.shrink();
    // A new vault starts afresh: its own reads, masked, recall on.
    return _ConnectBody(key: ValueKey(vault), vault: vault);
  }
}

const _localIntro =
    'Give an MCP client this vault. The snippets already hold this vault’s '
    'path and the memex this app runs.';
const _bundledIntro =
    'Give an MCP client this vault. The snippets already hold this vault’s '
    'path and the memex that ships inside Open Memex.';
const _hostedIntro =
    'Agents reach this vault through its vault server. Every client needs '
    'the MCP address and the access token.';
const _restartTitle = 'Quit and reopen Claude Desktop';
const _terminalTitle = 'Run this in a terminal';

class _ConnectBody extends ConsumerStatefulWidget {
  const _ConnectBody({super.key, required this.vault});

  final VaultRef vault;

  @override
  ConsumerState<_ConnectBody> createState() => _ConnectBodyState();
}

class _ConnectBodyState extends ConsumerState<_ConnectBody> {
  /// The `Include semantic recall` switch (local vaults); on by default.
  bool _withEmbeddings = true;

  /// The last detection result; null until the first read finishes.
  ClaudeDesktopSetup? _setup;

  /// This tab is waiting on a config read; further requests are dropped.
  /// [claudeConfigReadsProvider] keeps it to one read across remounts.
  bool _detecting = false;

  /// Whether the open-time Keychain read (hosted) has finished.
  bool _tokenLoaded = false;

  /// The masked form of the Keychain token; null when there is none.
  MaskedTokenText? _masked;

  /// The real token, only while revealed (req 27).
  String? _revealed;

  /// A Reveal's Keychain read is in flight; further presses are ignored.
  bool _revealing = false;

  /// The `Locate memex…` picker is open.
  bool _locating = false;

  @override
  void initState() {
    super.initState();
    // Mounted means Connect is shown (the shell builds only the active
    // tab), so this read is the "shown" / "shown again" one.
    _detect();
    ref.listenManual<bool>(appFocusProvider, (previous, focused) {
      if (previous == false && focused) _detect();
    });
    if (widget.vault is HostedVaultRef) _loadMask();
  }

  // --- Claude Desktop detection (req 13, 29) -------------------------------

  /// What the config is matched against, or null when the hosted vault's
  /// server is no longer saved.
  ClaudeVaultTarget? _target() => switch (widget.vault) {
    LocalVaultRef(:final path) => LocalClaudeVaultTarget(p.absolute(path)),
    HostedVaultRef(:final vaultName) => switch (_server()) {
      null => null,
      final server => HostedClaudeVaultTarget(
        mcpAddress(serverUrl: server.url, vaultName: vaultName),
      ),
    },
  };

  Future<void> _detect() async {
    if (_detecting) return;
    final target = _target();
    if (target == null) return;
    _detecting = true;
    ClaudeDesktopSetup result;
    try {
      final read = await ref.read(claudeConfigReadsProvider).read();
      result = detectClaudeDesktopSetup(
        read,
        vault: target,
        homeDirectory: claudeHomeDirectory(),
        resolvePath: resolveSymlinksOrSelf,
      );
    } on Object {
      // Never shown or logged: only the fixed copy appears (req 29).
      result = const ClaudeDesktopConfigUnreadable();
    } finally {
      _detecting = false;
    }
    if (!mounted) return;
    setState(() => _setup = result);
  }

  // --- The access token (req 26, 27) ---------------------------------------

  SavedServer? _server() => switch (widget.vault) {
    HostedVaultRef(:final serverId) =>
      ref
          .read(settingsProvider)
          .savedServers
          .where((s) => s.id == serverId)
          .firstOrNull,
    LocalVaultRef() => null,
  };

  /// One Keychain read of the hosted vault's token; null when there is
  /// none or the read fails (the failure is dropped unlogged).
  Future<String?> _readToken() async {
    final vault = widget.vault;
    if (vault is! HostedVaultRef) return null;
    try {
      return await ref.read(tokenStoreProvider).read(vault.serverId);
    } on Object {
      return null;
    }
  }

  Future<void> _loadMask() async {
    final token = await _readToken();
    if (!mounted) return;
    setState(() {
      _tokenLoaded = true;
      _masked = token == null ? null : MaskedTokenText(token);
    });
  }

  /// Hide masks again at once (no read); Reveal reads the Keychain once.
  Future<void> _toggleReveal() async {
    if (_revealed != null) {
      setState(() => _revealed = null);
      return;
    }
    // Set before the first await so a second press is ignored.
    if (_revealing) return;
    _revealing = true;
    final token = await _readToken();
    _revealing = false;
    if (!mounted) return;
    setState(() {
      _masked = token == null ? null : MaskedTokenText(token);
      _revealed = token;
    });
  }

  /// A Copy's token: read afresh on each press, the placeholder when the
  /// Keychain has none.
  Future<TokenText> _copyToken() async {
    final token = await _readToken();
    return token == null ? const PlaceholderTokenText() : RealTokenText(token);
  }

  // --- memex binary (req 15) -----------------------------------------------

  Future<void> _locate() async {
    if (_locating) return;
    _locating = true;
    try {
      await locateMemexBinary(ref.read(settingsProvider.notifier));
    } finally {
      _locating = false;
    }
  }

  // --- Build ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final binary = settings.memexBinaryPath;
    final memex = binary == null || binary.isEmpty ? null : binary;
    final client = ref.watch(connectClientProvider(widget.vault));
    final clientSwitch = ConnectClientSwitch(
      value: client,
      onChanged: (c) =>
          ref.read(connectClientProvider(widget.vault).notifier).state = c,
    );
    final children = switch (widget.vault) {
      LocalVaultRef(:final path) => _local(
        vaultPath: p.absolute(path),
        memex: memex,
        client: client,
        clientSwitch: clientSwitch,
      ),
      HostedVaultRef(:final vaultName) => _hosted(
        vaultName: vaultName,
        memex: memex,
        client: client,
        clientSwitch: clientSwitch,
      ),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }

  Widget _intro(String text) => Text(
    text,
    style: OmType.sans(size: 12.5, height: 1.55, color: OmColors.fg2),
  );

  /// The detection line (Claude Desktop pane), once a read has finished.
  List<Widget> _detection() => [
    if (_setup case final setup?)
      ConnectDetectionLine(setup: setup, onCheckAgain: _detect),
  ];

  /// `Move Open Memex to Applications first; this path changes.`, above
  /// step 1 in fg1 (req 15).
  List<Widget> _unstableWarning(String memex) => [
    if (isUnstableMemexPath(memex))
      Padding(
        padding: const EdgeInsets.only(top: 14),
        child: Text(
          'Move Open Memex to Applications first; this path changes.',
          style: OmType.sans(size: 12.5, height: 1.5, color: OmColors.fg1),
        ),
      ),
  ];

  /// `memex wasn't found.` and `Locate memex…`, in place of the snippets.
  Widget _noBinary() => Padding(
    padding: const EdgeInsets.only(top: 16),
    child: Wrap(
      spacing: 12,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          'memex wasn\'t found.',
          style: OmType.sans(
            size: 13,
            weight: FontWeight.w500,
            height: 1.4,
            color: OmColors.fg0,
          ),
        ),
        OmButton(
          onPressed: _locate,
          kind: OmButtonKind.secondary,
          focusable: true,
          label: 'Locate memex…',
        ),
      ],
    ),
  );

  List<Widget> _local({
    required String vaultPath,
    required String? memex,
    required ConnectClient client,
    required Widget clientSwitch,
  }) {
    final bundled = memex != null && isBundledMemexPath(memex);
    final recall = ConnectRecallSwitch(
      value: _withEmbeddings,
      onChanged: (on) => setState(() => _withEmbeddings = on),
    );
    return [
      _intro(bundled ? _bundledIntro : _localIntro),
      const SizedBox(height: 14),
      clientSwitch,
      if (client == ConnectClient.claudeDesktop) ..._detection(),
      if (memex == null)
        _noBinary()
      else ...[
        ..._unstableWarning(memex),
        ...switch (client) {
          ConnectClient.claudeDesktop => _localDesktop(
            memex,
            vaultPath,
            recall,
          ),
          ConnectClient.claudeCode => _localCode(memex, vaultPath, recall),
        },
      ],
    ];
  }

  List<Widget> _localDesktop(String memex, String vaultPath, Widget recall) {
    final config = localClaudeDesktopConfig(
      memexPath: memex,
      vaultPath: vaultPath,
      withEmbeddings: _withEmbeddings,
    );
    return [
      ConnectStep(
        number: 1,
        title: 'Open Claude Desktop’s config file',
        children: [
          ConnectCodeBlock(
            text: claudeDesktopConfigPath,
            copy: OmCopyButton(
              text: () => claudeDesktopConfigPath,
              semanticLabel: 'Copy config file path',
            ),
          ),
        ],
      ),
      ConnectStep(
        number: 2,
        title: 'Merge this into its mcpServers',
        children: [
          recall,
          ConnectCodeBlock(
            text: config,
            syntax: ConnectCodeSyntax.json,
            copy: OmCopyButton(
              text: () => config,
              semanticLabel: 'Copy Claude Desktop config',
            ),
          ),
        ],
      ),
      const ConnectStep(
        number: 3,
        title: _restartTitle,
        children: [
          ConnectStepNote(
            'Its tools menu then lists the memex tools, and it shows under '
            'Live as soon as it connects. Do this again after every Open '
            'Memex update.',
            top: 0,
          ),
        ],
      ),
    ];
  }

  List<Widget> _localCode(String memex, String vaultPath, Widget recall) {
    final command = localClaudeCodeCommand(
      memexPath: memex,
      vaultPath: vaultPath,
      withEmbeddings: _withEmbeddings,
    );
    return [
      ConnectStep(
        number: 1,
        title: _terminalTitle,
        children: [
          recall,
          ConnectCodeBlock(
            text: command,
            syntax: ConnectCodeSyntax.shell,
            copy: OmCopyButton(
              text: () => command,
              semanticLabel: 'Copy Claude Code command',
            ),
          ),
        ],
      ),
    ];
  }

  List<Widget> _hosted({
    required String vaultName,
    required String? memex,
    required ConnectClient client,
    required Widget clientSwitch,
  }) {
    final server = _server();
    if (server == null) return [_intro(_hostedIntro)];
    final address = mcpAddress(serverUrl: server.url, vaultName: vaultName);
    final head = [
      _intro(_hostedIntro),
      const ConnectFieldLabel('MCP address'),
      ConnectAddressRow(address: address),
      const ConnectFieldLabel('Access token · from this Mac’s Keychain'),
    ];
    if (!_tokenLoaded) return [...head, const AgentsTabLoading()];

    final masked = _masked;
    final revealed = _revealed;
    // What the snippets show, and what Semantics reads for them: never the
    // real token (req 27), the mask's label in its place.
    final TokenText shown = revealed != null
        ? RealTokenText(revealed)
        : masked ?? const PlaceholderTokenText();
    final TokenText spoken = masked ?? const PlaceholderTokenText();
    String speak(String snippet) => masked == null
        ? snippet
        : snippet.replaceAll(masked.text, masked.semanticsLabel);

    return [
      ...head,
      if (masked == null)
        ConnectNoTokenRow(
          onUpdateToken: () => ref.read(updateTokenSeamProvider)(server.id),
        )
      else
        ConnectTokenRow(
          shown: revealed ?? masked.text,
          semanticsLabel: masked.semanticsLabel,
          revealed: revealed != null,
          onToggle: _toggleReveal,
          copyToken: () async => (await _copyToken()).text,
        ),
      const SizedBox(height: 16),
      clientSwitch,
      ...switch (client) {
        ConnectClient.claudeDesktop => [
          ..._detection(),
          if (memex == null)
            _noBinary()
          else ...[
            _hostedDesktopStep(
              memex: memex,
              vaultName: vaultName,
              address: address,
              shown: shown,
              spoken: speak(
                hostedClaudeDesktopEntry(
                  memexPath: memex,
                  vaultName: vaultName,
                  mcpAddress: address,
                  token: spoken,
                ),
              ),
            ),
            const ConnectStep(number: 2, title: _restartTitle),
          ],
        ],
        ConnectClient.claudeCode => [
          _hostedCodeStep(
            vaultName: vaultName,
            address: address,
            shown: shown,
            speak: speak,
            spoken: spoken,
          ),
        ],
      },
    ];
  }

  Widget _hostedDesktopStep({
    required String memex,
    required String vaultName,
    required String address,
    required TokenText shown,
    required String spoken,
  }) {
    return ConnectStep(
      number: 1,
      title: 'Merge this into Claude Desktop’s mcpServers',
      children: [
        ConnectCodeBlock(
          text: hostedClaudeDesktopEntry(
            memexPath: memex,
            vaultName: vaultName,
            mcpAddress: address,
            token: shown,
          ),
          semanticsLabel: spoken,
          syntax: ConnectCodeSyntax.json,
          copy: OmCopyButton(
            text: () async => hostedClaudeDesktopEntry(
              memexPath: memex,
              vaultName: vaultName,
              mcpAddress: address,
              token: await _copyToken(),
            ),
            semanticLabel: 'Copy Claude Desktop config',
            sensitive: true,
          ),
        ),
        const ConnectStepNote(
          'Copy puts the real token into the snippet. The bridge, memex serve '
          '--remote, sends your current UTC offset itself.',
        ),
      ],
    );
  }

  Widget _hostedCodeStep({
    required String vaultName,
    required String address,
    required TokenText shown,
    required String Function(String) speak,
    required TokenText spoken,
  }) {
    final offset = ref.read(utcOffsetProvider)();
    String command(TokenText token, Duration utcOffset) =>
        hostedClaudeCodeCommand(
          vaultName: vaultName,
          mcpAddress: address,
          token: token,
          utcOffset: utcOffset,
        );
    return ConnectStep(
      number: 1,
      title: _terminalTitle,
      children: [
        ConnectCodeBlock(
          text: command(shown, offset),
          semanticsLabel: speak(command(spoken, offset)),
          syntax: ConnectCodeSyntax.shell,
          copy: OmCopyButton(
            text: () async {
              final token = await _copyToken();
              return command(token, ref.read(utcOffsetProvider)());
            },
            semanticLabel: 'Copy Claude Code command',
            sensitive: true,
          ),
        ),
        ConnectStepNote(
          '${formatUtcOffset(offset)} is this Mac’s offset now. Claude '
          'Code sends it as written, so add the server again after a '
          'daylight-saving change.',
        ),
        const ConnectStepNote(
          'Pasting this into a terminal keeps the token in your shell history.',
        ),
      ],
    );
  }
}
