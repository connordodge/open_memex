// The Agents sheet's `Semantic recall` tab (WI #413; Spec #394 req 15-16,
// 36-42, 44, 47; design pack design/394-agents-sheet/packs/413.md and
// RULINGS 19-24). It only shows what `recallStatusProvider` read and what
// #390's agent activity reports; it never starts a download and never
// switches an agent's flag.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../agents_sheet/connect/snippets.dart';
import 'connect/code_block.dart';
import '../../agents_sheet/recall/embeddings_status.dart';
import '../../state/agent_activity.dart';
import '../../state/agents_sheet/agents_sheet_state.dart';
import '../../state/agents_sheet/recall_tab_state.dart';
import '../../state/settings.dart';
import '../../state/vault_state.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../vault_access/agents_access.dart';
import '../atoms.dart';
import '../inline_error.dart';
import '../memex_too_old_dialog.dart' show locateMemexBinary;
import '../om_copy_button.dart';
import '../right_panel.dart' show RightPanelTab, rightPanelTabProvider;
import 'agents_tab_loading.dart';

/// The embeddings flag, set in mono inside prose and coloured in snippets.
const _flag = '--with-embeddings';

/// The embedding model every memex uses (#391).
const _modelName = 'BGE-small-en-v1.5';

/// Below this window width the key-value rows stack the key over the value
/// (Spec #394 req 47; as Tools rows).
const _stackBelow = 672.0;

const _keyColumn = 150.0;
const _columnGap = 12.0;

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
    'The connected agents run memex without $_flag, so their searches match '
    'keywords only. Echoes in this app don’t depend on agents: they use the '
    'model once you download it.';
const _localNoneBody =
    'Connect an agent with $_flag for meaning-based search. Echoes in this '
    'app don’t depend on agents: they use the model once you download it.';
String _hostedOnBody(String host) =>
    'The server at $host embeds your notes when they’re saved. Echoes and '
    'agents’ searches use it.';
String _hostedOffBody(String host) =>
    'The server at $host runs without $_flag. It decides for every vault it '
    'serves and every agent that connects to it, so only whoever runs it can '
    'turn recall on.';
const _hostedUnknownBody =
    'The server is older than this app. Update memex on it to see semantic '
    'recall status here.';

const _localCoverageNote =
    'Passages are embedded in the background by an agent running with '
    '$_flag, and by echoes in this app once the model is downloaded.';
const _hostedCoverageNote =
    'The server embeds new passages when they’re saved.';

const _localTurnOnNote =
    'Put this in Claude Desktop’s config and restart it. It uses the model in '
    'this vault, downloading it on first run if needed, then embeds your '
    'notes in the background.';
const _hostedCommand = 'memex serve --root <root> --listen <host:port> $_flag';
const _hostedTurnOnNote =
    'Add the flag to the server’s service definition and restart it. The '
    'server downloads the model once into <root>/.memex/models and shares it '
    'with every vault it serves.';

const _closingNote =
    'Open Memex can’t switch an agent’s flag for it. To turn recall on or off '
    'for an agent, change that agent’s config (Connect shows it with or '
    'without the flag) and restart the agent.';

const _tooOld = 'Coverage unavailable: this memex is older than the app.';

/// The Agents sheet's `Semantic recall` tab body.
class RecallTab extends ConsumerStatefulWidget {
  const RecallTab({super.key});

  @override
  ConsumerState<RecallTab> createState() => _RecallTabState();
}

class _RecallTabState extends ConsumerState<RecallTab> {
  // The error the person dismissed; it shows nothing until a read gives a
  // new result.
  EmbeddingsStatusError? _dismissed;
  bool _locating = false;

  Future<void> _locate() async {
    if (_locating) return;
    _locating = true;
    try {
      final before = ref.read(settingsProvider).memexBinaryPath;
      await locateMemexBinary(ref.read(settingsProvider.notifier));
      if (!mounted) return;
      // A different path rebuilds the read through the settings watch. The
      // same path (a reinstalled binary) changes nothing there, so read again.
      if (ref.read(settingsProvider).memexBinaryPath == before) {
        ref.read(recallStatusProvider.notifier).retry();
      }
    } finally {
      _locating = false;
    }
  }

  /// `Download it from Echoes.`: the right panel opens on Echoes, where
  /// #391's download lives, and the sheet closes (D16).
  void _openEchoes() {
    ref.read(rightPanelOpenProvider.notifier).state = true;
    ref.read(rightPanelTabProvider.notifier).state = RightPanelTab.echoes;
    unawaited(Navigator.of(context).maybePop());
  }

  void _openConnect() =>
      ref.read(agentsSheetTabProvider.notifier).select(AgentsTab.connect);

  @override
  Widget build(BuildContext context) {
    final result = ref.watch(recallStatusProvider);
    final vault = ref.watch(currentVaultProvider);
    if (result == null) return const AgentsTabLoading();
    final stacked = MediaQuery.sizeOf(context).width < _stackBelow;
    final children = vault is HostedVaultRef
        ? _hosted(result, vault, stacked)
        : _local(result, vault, stacked);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [...children, const _ClosingNote()],
    );
  }

  // ------------------------------------------------------------------ local

  List<Widget> _local(
    EmbeddingsStatusResult result,
    VaultRef? vault,
    bool stacked,
  ) {
    if (result is EmbeddingsBinaryNotFound) {
      return [
        const _Heading(text: 'memex not found', dot: null),
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerLeft,
          child: OmButton(
            key: const Key('recall-locate-memex'),
            label: 'Locate memex…',
            focusable: true,
            onPressed: _locate,
          ),
        ),
      ];
    }
    final agents = recallConnectedAgents(ref.watch(agentActivityAsyncProvider));
    final use = recallAgentsUseIt(agents);
    final (heading, body) = switch (use) {
      true => (_localOnHeading, _localOnBody),
      false => (_localOffHeading, _localOffBody),
      null => (_localNoneHeading, _localNoneBody),
    };
    final agentRows = [
      for (final a in agents ?? const <AgentPresence>[])
        _KeyValue(
          key: Key('recall-agent-${a.sessionId}'),
          name: a.clientName,
          stacked: stacked,
          value: _agentValue(a),
        ),
    ];
    final out = <Widget>[_Heading(text: heading, dot: use), _Body(body)];
    switch (result) {
      case EmbeddingsStatusOk(:final status):
        out
          ..add(_Coverage(status: status, note: _localCoverageNote))
          ..add(
            _Rows([
              ...agentRows,
              _KeyValue(
                key: const Key('recall-model'),
                name: 'Model',
                stacked: stacked,
                value: status.modelCached
                    ? _Value(
                        '$_modelName · downloaded to this vault '
                        '(${formatModelBytes(status.modelBytes)})',
                      )
                    : _ValueWithLink(
                        text: '$_modelName · not downloaded (about 130 MB).',
                        link: _Link(
                          key: const Key('recall-model-download'),
                          label: 'Download it from Echoes.',
                          onTap: _openEchoes,
                        ),
                      ),
              ),
            ]),
          );
        if (use != true && vault is LocalVaultRef) {
          final memex =
              ref.watch(settingsProvider.select((s) => s.memexBinaryPath)) ??
              'memex';
          final config = localClaudeDesktopConfig(
            memexPath: memex,
            vaultPath: p.absolute(vault.path),
            withEmbeddings: true,
          );
          out.add(
            _TurnOn(
              label: 'TO TURN IT ON',
              code: config,
              copy: OmCopyButton(
                text: () => config,
                label: 'Copy config',
                semanticLabel: 'Copy Claude Desktop config',
              ),
              syntax: ConnectCodeSyntax.json,
              note: _localTurnOnNote,
            ),
          );
        }
      case EmbeddingsTooOld():
        out
          ..add(_StateLine(_tooOld))
          ..add(_Rows(agentRows));
      case EmbeddingsStatusError():
        out
          ..add(_error(result))
          ..add(_Rows(agentRows));
      case EmbeddingsBinaryNotFound() || EmbeddingsServerTooOld():
        out.add(_Rows(agentRows));
    }
    return out;
  }

  Widget _agentValue(AgentPresence a) {
    final base = OmType.sans(size: 12.5, height: 1.5, color: OmColors.fg1);
    if (a.embeddings) {
      return Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: 'on',
              style: TextStyle(color: OmColors.accent),
            ),
            const TextSpan(text: ' · runs with '),
            _codeSpan(_flag),
          ],
        ),
        style: base,
      );
    }
    return _ValueWithLink(
      rich: TextSpan(
        children: [
          TextSpan(
            text: 'off',
            style: TextStyle(color: OmColors.fg2),
          ),
          const TextSpan(text: ' · keyword search only.'),
        ],
      ),
      link: _Link(
        key: Key('recall-agent-command-${a.sessionId}'),
        label: 'Turn on in its command',
        onTap: _openConnect,
      ),
    );
  }

  // ----------------------------------------------------------------- hosted

  List<Widget> _hosted(
    EmbeddingsStatusResult result,
    HostedVaultRef vault,
    bool stacked,
  ) {
    switch (result) {
      case EmbeddingsServerTooOld():
        return const [
          _Heading(text: _hostedUnknownHeading, dot: null),
          _Body(_hostedUnknownBody),
        ];
      case EmbeddingsStatusError():
        return [_error(result)];
      case EmbeddingsTooOld():
        return const [_StateLine(_tooOld)];
      case EmbeddingsBinaryNotFound():
        // A hosted read never runs the local binary.
        return const [_StateLine('memex not found')];
      case EmbeddingsStatusOk(:final status):
        final on = status.serverEmbeddings == true;
        final host = _serverHost(vault.serverId);
        return [
          _Heading(text: on ? _hostedOnHeading : _hostedOffHeading, dot: on),
          _Body(on ? _hostedOnBody(host) : _hostedOffBody(host)),
          _Coverage(status: status, note: _hostedCoverageNote),
          _Rows([
            _KeyValue(
              key: const Key('recall-model'),
              name: 'Model',
              stacked: stacked,
              value: _Value(
                status.modelCached
                    ? '$_modelName · downloaded to the vault server '
                          '(${formatModelBytes(status.modelBytes)})'
                    : '$_modelName · not downloaded on the vault server',
              ),
            ),
          ]),
          if (!on)
            _TurnOn(
              label: 'ON THE VAULT SERVER',
              code: _hostedCommand,
              copy: OmCopyButton(
                text: () => _hostedCommand,
                semanticLabel: 'Copy server command',
              ),
              syntax: ConnectCodeSyntax.shell,
              note: _hostedTurnOnNote,
            ),
        ];
    }
  }

  /// The saved server URL's host (no scheme or port), or the server id when
  /// no saved server has it.
  String _serverHost(String serverId) {
    for (final s in ref.watch(settingsProvider).savedServers) {
      if (s.id != serverId) continue;
      final host = Uri.tryParse(s.url)?.host ?? '';
      return host.isEmpty ? s.name : host;
    }
    return serverId;
  }

  Widget _error(EmbeddingsStatusError result) {
    if (identical(result, _dismissed)) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: InlineError(
        message: result.message,
        onRetry: () => ref.read(recallStatusProvider.notifier).retry(),
        onDismiss: () => setState(() => _dismissed = result),
      ),
    );
  }
}

/// A model cache size in decimal units, as the board shows it (`127 MB`).
String formatModelBytes(int bytes) {
  if (bytes >= 1000000000) {
    return '${(bytes / 1000000000).toStringAsFixed(1)} GB';
  }
  if (bytes >= 10000000) return '${(bytes / 1000000).round()} MB';
  if (bytes >= 1000000) return '${(bytes / 1000000).toStringAsFixed(1)} MB';
  if (bytes >= 1000) return '${(bytes / 1000).round()} KB';
  return '$bytes B';
}

/// The embeddings flag as inline code inside prose (pack: mono 11.5 fg1).
TextSpan _codeSpan(String text) => TextSpan(
  text: text,
  style: OmType.mono(size: 11.5, color: OmColors.fg1),
);

/// [text] as spans, with every `--with-embeddings` set as inline code.
List<InlineSpan> _prose(String text) {
  final parts = text.split(_flag);
  return [
    for (var i = 0; i < parts.length; i++) ...[
      if (i > 0) _codeSpan(_flag),
      if (parts[i].isNotEmpty) TextSpan(text: parts[i]),
    ],
  ];
}

// ---------------------------------------------------------------- widgets

/// The status heading: an 8 px dot (accent on, fg2 off, none for null;
/// RULINGS 24) and sans 15 w600 fg0.
class _Heading extends StatelessWidget {
  const _Heading({required this.text, required this.dot});

  final String text;
  final bool? dot;

  @override
  Widget build(BuildContext context) {
    final dot = this.dot;
    return Semantics(
      header: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (dot != null) ...[
            Container(
              key: const Key('recall-heading-dot'),
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: dot ? OmColors.accent : OmColors.fg2,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 10),
          ],
          Flexible(
            child: Text(
              text,
              style: OmType.sans(
                size: 15,
                weight: FontWeight.w600,
                color: OmColors.fg0,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Body copy: sans 12.5, line height 1.55, fg2, 6 px under the heading.
class _Body extends StatelessWidget {
  const _Body(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 6),
    child: Text.rich(
      TextSpan(children: _prose(text)),
      style: OmType.sans(size: 12.5, height: 1.55, color: OmColors.fg2),
    ),
  );
}

/// A state line in place of coverage (too old): sans 12.5 fg1.
class _StateLine extends StatelessWidget {
  const _StateLine(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 16),
    child: Text(
      text,
      style: OmType.sans(size: 12.5, height: 1.5, color: OmColors.fg1),
    ),
  );
}

/// Coverage (Spec #394 req 38): the counts, a 6 px bar (accentSoft on
/// surface4) filled to embedded / chunks, and the note under it.
class _Coverage extends StatelessWidget {
  const _Coverage({required this.status, required this.note});

  final EmbeddingsStatus status;
  final String note;

  @override
  Widget build(BuildContext context) {
    final chunks = status.chunks;
    final fraction = chunks <= 0
        ? 0.0
        : (status.embedded / chunks).clamp(0.0, 1.0).toDouble();
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Text(
                  '${status.embedded} of $chunks passages embedded',
                  style: OmType.sans(
                    size: 12.5,
                    height: 1.5,
                    color: OmColors.fg1,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                '${status.waiting} waiting',
                style: OmType.mono(size: 11, color: OmColors.fg2),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Container(
            key: const Key('recall-coverage-bar'),
            height: 6,
            decoration: BoxDecoration(
              color: OmColors.surface4,
              borderRadius: BorderRadius.circular(3),
            ),
            child: FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: fraction,
              child: Container(
                key: const Key('recall-coverage-fill'),
                decoration: BoxDecoration(
                  color: OmColors.accentSoft,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text.rich(
              TextSpan(children: _prose(note)),
              style: OmType.sans(size: 12, height: 1.55, color: OmColors.fg2),
            ),
          ),
        ],
      ),
    );
  }
}

/// The key-value grid: 14 px above, 8 px between rows.
class _Rows extends StatelessWidget {
  const _Rows(this.rows);

  final List<Widget> rows;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) const SizedBox(height: 8),
            rows[i],
          ],
        ],
      ),
    );
  }
}

/// One key-value row: the key (fg2) in a 150 px column, then the value; the
/// key stacks over the value below a 672 px window.
class _KeyValue extends StatelessWidget {
  const _KeyValue({
    super.key,
    required this.name,
    required this.value,
    required this.stacked,
  });

  final String name;
  final Widget value;
  final bool stacked;

  @override
  Widget build(BuildContext context) {
    final keyText = Text(
      name,
      style: OmType.sans(size: 12.5, height: 1.5, color: OmColors.fg2),
    );
    if (stacked) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [keyText, const SizedBox(height: 2), value],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: _keyColumn, child: keyText),
        const SizedBox(width: _columnGap),
        Expanded(child: value),
      ],
    );
  }
}

/// A plain value: sans 12.5 fg1.
class _Value extends StatelessWidget {
  const _Value(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: OmType.sans(size: 12.5, height: 1.5, color: OmColors.fg1),
  );
}

/// A value followed by a link, wrapping onto the next line when narrow.
class _ValueWithLink extends StatelessWidget {
  const _ValueWithLink({this.text, this.rich, required this.link});

  final String? text;
  final InlineSpan? rich;
  final Widget link;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 4,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      Text.rich(
        rich ?? TextSpan(text: text),
        style: OmType.sans(size: 12.5, height: 1.5, color: OmColors.fg1),
      ),
      link,
    ],
  );
}

/// An inline link (info, underlined): a Tab stop that Enter and Space
/// activate.
class _Link extends StatefulWidget {
  const _Link({super.key, required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  State<_Link> createState() => _LinkState();
}

class _LinkState extends State<_Link> {
  bool _focused = false;

  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    final key = event.logicalKey;
    if (key != LogicalKeyboardKey.enter &&
        key != LogicalKeyboardKey.numpadEnter &&
        key != LogicalKeyboardKey.space) {
      return KeyEventResult.ignored;
    }
    if (event is KeyDownEvent) widget.onTap();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final ring =
        _focused &&
        FocusManager.instance.highlightMode == FocusHighlightMode.traditional;
    return Semantics(
      container: true,
      link: true,
      label: widget.label,
      onTap: widget.onTap,
      excludeSemantics: true,
      child: Focus(
        includeSemantics: false,
        onFocusChange: (f) => setState(() => _focused = f),
        onKeyEvent: _onKey,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: Container(
              foregroundDecoration: ring
                  ? BoxDecoration(
                      border: Border.all(
                        color: OmColors.accent,
                        width: 2,
                        strokeAlign: BorderSide.strokeAlignOutside,
                      ),
                      borderRadius: BorderRadius.circular(3),
                    )
                  : null,
              child: Text(
                widget.label,
                style:
                    OmType.sans(
                      size: 12.5,
                      height: 1.5,
                      color: OmColors.info,
                    ).copyWith(
                      decoration: TextDecoration.underline,
                      decorationColor: OmColors.info,
                    ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The turn-on section (Spec #394 req 41): an eyebrow label, the shared
/// [ConnectCodeBlock] with its copy button pinned top right, and a note.
class _TurnOn extends StatelessWidget {
  const _TurnOn({
    required this.label,
    required this.code,
    required this.copy,
    required this.syntax,
    required this.note,
  });

  final String label;
  final String code;
  final OmCopyButton copy;
  final ConnectCodeSyntax syntax;
  final String note;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: OmType.mono(
              size: 10.5,
              weight: FontWeight.w500,
              letterSpacing: 0.8,
              color: OmColors.fg2,
            ),
          ),
          const SizedBox(height: 8),
          ConnectCodeBlock(text: code, copy: copy, syntax: syntax),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              note,
              style: OmType.sans(size: 12.5, height: 1.5, color: OmColors.fg2),
            ),
          ),
        ],
      ),
    );
  }
}

/// The closing note (Spec #394 req 42), in every state: infoBg, radius 6,
/// padding 10 / 12, sans 12.5 fg1, 16 px above.
class _ClosingNote extends StatelessWidget {
  const _ClosingNote();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 16),
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
      decoration: BoxDecoration(
        color: OmColors.infoBg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        _closingNote,
        style: OmType.sans(size: 12.5, height: 1.5, color: OmColors.fg1),
      ),
    ),
  );
}
