import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../state/settings.dart';
import '../../state/token_store.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../vault_access/hosted/hosted_client.dart';
import '../atoms.dart';

/// The HTTP client the connect and edit-server dialogs probe a vault server
/// with (through `HostedClient.probeServer`). Tests override it with
/// `FakeVaultServer.client`.
final connectServerHttpClientProvider = Provider<http.Client>((ref) {
  final client = http.Client();
  ref.onDispose(client.close);
  return client;
});

/// Shows "connect to a vault server" (boards A4/A5), or the edit-server
/// dialog for [edit] (A5 state 6). Returns the saved server, or null when
/// the dialog was cancelled. "how do I set one up?" calls [onSetUp].
Future<SavedServer?> showConnectServerDialog(
  BuildContext context, {
  SavedServer? edit,
  VoidCallback? onSetUp,
}) => showDialog<SavedServer>(
  context: context,
  barrierColor: OmColors.surface0.withAlpha(184),
  builder: (_) => _ConnectServerDialog(edit: edit, onSetUp: onSetUp),
);

/// Probes `GET <url>/api/v1/info` through #77's [HostedClient] on
/// [connectServerHttpClientProvider], reporting under [serverId].
typedef _Probe =
    Future<ServerProbe> Function({
      required String serverId,
      required String serverName,
      required String serverUrl,
      required String accessToken,
    });

final _probeProvider = Provider<_Probe>(
  (ref) =>
      ({
        required String serverId,
        required String serverName,
        required String serverUrl,
        required String accessToken,
      }) => HostedClient(
        ref,
        serverId: serverId,
        serverName: serverName,
        serverUrl: serverUrl,
        accessToken: accessToken,
        httpClient: ref.read(connectServerHttpClientProvider),
      ).probeServer(),
);

/// The status key a connect probe reports under when its URL isn't saved
/// yet (there is no saved-server id to report under).
const _unsavedServerId = 'connect-server-dialog';

const _dialogWidth = 472.0;
const _schemeError = 'enter a url starting with http:// or https://';
const _tokenRejected = 'access token rejected';
const _connectHint =
    'from <vault root>/.memex/access-token on the server. '
    'kept in your keychain.';
const _editHint = 'saved in your keychain. paste a new one to replace it.';

/// The host of [url] when it is an http(s) URL with a host, else null.
String? _httpHost(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || uri.host.isEmpty) return null;
  final scheme = uri.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') return null;
  return uri.host;
}

class _ConnectServerDialog extends ConsumerStatefulWidget {
  const _ConnectServerDialog({this.edit, this.onSetUp});

  final SavedServer? edit;
  final VoidCallback? onSetUp;

  @override
  ConsumerState<_ConnectServerDialog> createState() =>
      _ConnectServerDialogState();
}

class _ConnectServerDialogState extends ConsumerState<_ConnectServerDialog>
    with SingleTickerProviderStateMixin {
  late final _name = TextEditingController(text: widget.edit?.name ?? '');
  late final _url = TextEditingController(text: widget.edit?.url ?? '');
  final _token = TextEditingController();
  late final _spin = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  bool _showToken = false;
  bool _connecting = false;

  /// The inline error under the server url field, or null.
  String? _urlError;

  /// The inline error under the access token field, or null.
  String? _tokenError;

  /// The L9 danger box above the actions, or null.
  String? _apiError;

  bool get _editing => widget.edit != null;

  @override
  void initState() {
    super.initState();
    // The name placeholder follows the url's host.
    _lastHost = _httpHost(_url.text);
    _url.addListener(_onUrlChanged);
  }

  /// The entered url's host: the name field's placeholder.
  String? _lastHost;

  void _onUrlChanged() {
    final host = _httpHost(_url.text);
    if (host != _lastHost) setState(() => _lastHost = host);
  }

  @override
  void dispose() {
    _url.removeListener(_onUrlChanged);
    _name.dispose();
    _url.dispose();
    _token.dispose();
    _spin.dispose();
    super.dispose();
  }

  void _setConnecting(bool value) {
    _connecting = value;
    if (value) {
      _spin.repeat();
    } else {
      _spin.stop();
    }
  }

  Future<void> _submit() async {
    if (_connecting) return;
    final settings = ref.read(settingsProvider.notifier);
    final edit = widget.edit;

    setState(() {
      _urlError = null;
      _tokenError = null;
      _apiError = null;
    });

    final host = _httpHost(_url.text);
    if (host == null) {
      setState(() => _urlError = _schemeError);
      return;
    }
    final url = normalizeServerUrl(_url.text);
    final typedName = _name.text.trim();
    final name = typedName.isEmpty ? host : typedName;
    final pasted = _token.text.trim();

    // A URL that is already saved: connect updates that server (D18); an
    // edit may not take another saved server's URL.
    SavedServer? match;
    for (final s in ref.read(settingsProvider).savedServers) {
      if (normalizeServerUrl(s.url) == url) match = s;
    }
    if (edit != null && match != null && match.id != edit.id) {
      setState(() => _urlError = '$url is already saved as ${match!.name}');
      return;
    }

    setState(() => _setConnecting(true));
    final token = pasted.isNotEmpty || edit == null
        ? pasted
        : await ref.read(tokenStoreProvider).read(edit.id) ?? '';
    if (!mounted) return;

    final probe = await ref.read(_probeProvider)(
      serverId: edit?.id ?? match?.id ?? _unsavedServerId,
      serverName: name,
      serverUrl: url,
      accessToken: token,
    );
    // Cancelled while connecting: a late answer changes nothing.
    if (!mounted) return;

    switch (probe.kind) {
      case ServerProbeKind.unreachable:
        setState(() {
          _setConnecting(false);
          _urlError = "can't reach $url";
        });
      case ServerProbeKind.unauthorized:
        setState(() {
          _setConnecting(false);
          _tokenError = _tokenRejected;
        });
      case ServerProbeKind.notMemex:
        setState(() {
          _setConnecting(false);
          _urlError = "$url isn't a memex vault server";
        });
      case ServerProbeKind.apiMismatch:
        setState(() {
          _setConnecting(false);
          _apiError =
              '$name runs memex ${probe.serverVersion}, which this app '
              "can't use. update the app or memex on the server so both are "
              'the same release.';
        });
      case ServerProbeKind.connected:
        final saved = edit == null
            ? await settings.saveServer(name: name, url: url, token: token)
            : await settings.updateServer(
                edit.id,
                name: name,
                url: url,
                token: pasted.isEmpty ? null : pasted,
              );
        if (!mounted) return;
        Navigator.of(context).pop(saved);
    }
  }

  void _cancel() => Navigator.of(context).pop();

  @override
  Widget build(BuildContext context) {
    final edit = widget.edit;
    final hint = _tokenError == null
        ? (_editing ? _editHint : _connectHint)
        : null;
    return Center(
      child: Material(
        type: MaterialType.transparency,
        child: Container(
          key: const Key('connect-server-dialog'),
          width: _dialogWidth,
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: OmColors.surface2,
            border: Border.all(color: OmColors.line2),
            borderRadius: BorderRadius.circular(10),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withAlpha(153),
                offset: const Offset(0, 24),
                blurRadius: 64,
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: Eyebrow(
                  edit == null
                      ? 'connect to a vault server'
                      : 'edit ${edit.name}',
                ),
              ),
              const SizedBox(height: 16),
              _Field(
                label: 'name (optional)',
                input: _Input(
                  fieldKey: const Key('connect-name'),
                  controller: _name,
                  readOnly: _connecting,
                  style: OmType.sans(size: 13, height: 1.4),
                  placeholder: _lastHost,
                  placeholderStyle: OmType.sans(
                    size: 13,
                    height: 1.4,
                    color: OmColors.fg2,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              _Field(
                label: 'server url',
                error: _urlError,
                input: _Input(
                  fieldKey: const Key('connect-url'),
                  controller: _url,
                  readOnly: _connecting,
                  invalid: _urlError != null,
                  autofocus: edit == null,
                  keyboardType: TextInputType.url,
                  style: _monoInput(),
                  onChanged: (_) {
                    if (_urlError != null) setState(() => _urlError = null);
                  },
                ),
              ),
              const SizedBox(height: 16),
              _Field(
                label: 'access token',
                error: _tokenError,
                hint: hint,
                input: _Input(
                  fieldKey: const Key('connect-token'),
                  controller: _token,
                  readOnly: _connecting,
                  invalid: _tokenError != null,
                  autofocus: edit != null,
                  obscure: !_showToken,
                  style: _showToken
                      ? _monoInput()
                      : _monoInput().copyWith(letterSpacing: 2),
                  placeholder: edit == null ? null : '•' * 26,
                  placeholderStyle: _monoInput(
                    color: OmColors.fg2,
                  ).copyWith(letterSpacing: 2),
                  onChanged: (_) {
                    if (_tokenError != null) {
                      setState(() => _tokenError = null);
                    }
                  },
                  trailing: _EyeToggle(
                    shown: _showToken,
                    onTap: () => setState(() => _showToken = !_showToken),
                  ),
                ),
              ),
              if (_apiError != null) ...[
                const SizedBox(height: 16),
                _ApiErrorBox(_apiError!),
              ],
              const SizedBox(height: 16),
              _Actions(
                editing: _editing,
                connecting: _connecting,
                spin: _spin,
                onSetUp: widget.onSetUp,
                onCancel: _cancel,
                onSubmit: _submit,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

TextStyle _monoInput({Color color = OmColors.fg0}) =>
    OmType.mono(size: 12, height: 1.4, color: color);

/// A labelled field (column, gap 6): label, input, then an inline error or
/// a hint.
class _Field extends StatelessWidget {
  const _Field({
    required this.label,
    required this.input,
    this.error,
    this.hint,
  });

  final String label;
  final Widget input;
  final String? error;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final error = this.error;
    final hint = this.hint;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: OmType.mono(size: 11, height: 1.5, color: OmColors.fg2),
        ),
        const SizedBox(height: 6),
        input,
        if (error != null) ...[
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 2),
                child: Icon(
                  LucideIcons.alertTriangle,
                  size: 12,
                  color: OmColors.danger,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  error,
                  style: OmType.mono(
                    size: 11,
                    height: 1.5,
                    color: OmColors.danger,
                  ),
                ),
              ),
            ],
          ),
        ] else if (hint != null) ...[
          const SizedBox(height: 6),
          Text(
            hint,
            style: OmType.mono(size: 11, height: 1.5, color: OmColors.fg2),
          ),
        ],
      ],
    );
  }
}

/// The 36 px input box (A12 inputs): `surface3`, a `line2` border, an
/// accent border and ring while focused, and a `danger` border when
/// [invalid]. [fieldKey] keys the box.
class _Input extends StatefulWidget {
  const _Input({
    required this.fieldKey,
    required this.controller,
    required this.readOnly,
    required this.style,
    this.invalid = false,
    this.autofocus = false,
    this.obscure = false,
    this.keyboardType,
    this.placeholder,
    this.placeholderStyle,
    this.onChanged,
    this.trailing,
  });

  final Key fieldKey;
  final TextEditingController controller;
  final bool readOnly;
  final TextStyle style;
  final bool invalid;
  final bool autofocus;
  final bool obscure;
  final TextInputType? keyboardType;
  final String? placeholder;
  final TextStyle? placeholderStyle;
  final ValueChanged<String>? onChanged;
  final Widget? trailing;

  @override
  State<_Input> createState() => _InputState();
}

class _InputState extends State<_Input> {
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocus);
  }

  void _onFocus() => setState(() {});

  @override
  void dispose() {
    _focus.removeListener(_onFocus);
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final focused = _focus.hasFocus;
    final border = widget.invalid
        ? OmColors.danger.withAlpha(166)
        : focused
        ? OmColors.accent.withAlpha(140)
        : OmColors.line2;
    final trailing = widget.trailing;
    return SizedBox(
      key: widget.fieldKey,
      height: 36,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: OmColors.surface3,
          border: Border.all(color: border),
          borderRadius: BorderRadius.circular(6),
          boxShadow: focused && !widget.invalid
              ? [
                  BoxShadow(
                    color: OmColors.accent.withAlpha(31),
                    spreadRadius: 3,
                  ),
                ]
              : null,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: widget.controller,
                  focusNode: _focus,
                  readOnly: widget.readOnly,
                  autofocus: widget.autofocus,
                  obscureText: widget.obscure,
                  enableSuggestions: !widget.obscure,
                  autocorrect: false,
                  keyboardType: widget.keyboardType,
                  style: widget.style,
                  cursorColor: OmColors.accent,
                  cursorWidth: 1,
                  cursorHeight: 15,
                  onChanged: widget.onChanged,
                  decoration: InputDecoration.collapsed(
                    hintText: widget.placeholder,
                    hintStyle: widget.placeholderStyle,
                  ),
                ),
              ),
              if (trailing != null) ...[const SizedBox(width: 8), trailing],
            ],
          ),
        ),
      ),
    );
  }
}

/// The token field's show/hide toggle: 24x24, `eye` while hidden, `eyeOff`
/// on `surface4` while shown.
class _EyeToggle extends StatelessWidget {
  const _EyeToggle({required this.shown, required this.onTap});

  final bool shown;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        key: const Key('connect-token-toggle'),
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          width: 24,
          height: 24,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: shown ? OmColors.surface4 : null,
            borderRadius: BorderRadius.circular(5),
          ),
          child: Icon(
            shown ? LucideIcons.eyeOff : LucideIcons.eye,
            size: 14,
            color: shown ? OmColors.fg0 : OmColors.fg2,
          ),
        ),
      ),
    );
  }
}

/// The L9 danger box (A5 state 5), key `connect-error`.
class _ApiErrorBox extends StatelessWidget {
  const _ApiErrorBox(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('connect-error'),
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
      decoration: BoxDecoration(
        color: OmColors.dangerBg,
        border: Border.all(color: OmColors.danger.withAlpha(69)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: Icon(
              LucideIcons.alertTriangle,
              size: 14,
              color: OmColors.danger,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: OmType.sans(size: 12.5, color: OmColors.danger),
            ),
          ),
        ],
      ),
    );
  }
}

/// The actions row: the setup link (connect only), then "cancel" and the
/// primary ("connect" / "save", "connecting…" with a spinner while the
/// probe runs).
class _Actions extends StatelessWidget {
  const _Actions({
    required this.editing,
    required this.connecting,
    required this.spin,
    required this.onSetUp,
    required this.onCancel,
    required this.onSubmit,
  });

  final bool editing;
  final bool connecting;
  final Animation<double> spin;
  final VoidCallback? onSetUp;
  final VoidCallback onCancel;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 30,
      child: Row(
        children: [
          Expanded(
            child: editing
                ? const SizedBox.shrink()
                : Align(
                    alignment: Alignment.centerLeft,
                    child: _SetupLink(onTap: onSetUp),
                  ),
          ),
          const SizedBox(width: 8),
          OmButton(
            key: const Key('connect-cancel'),
            kind: OmButtonKind.ghost,
            label: 'cancel',
            onPressed: onCancel,
          ),
          const SizedBox(width: 8),
          _PrimaryButton(
            label: connecting
                ? 'connecting…'
                : editing
                ? 'save'
                : 'connect',
            spin: connecting ? spin : null,
            // While connecting the button is drawn undimmed (A5 state 2) and
            // a tap does nothing.
            onTap: connecting ? null : onSubmit,
          ),
        ],
      ),
    );
  }
}

class _SetupLink extends StatelessWidget {
  const _SetupLink({required this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        key: const Key('connect-setup-link'),
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(LucideIcons.circleHelp, size: 12, color: OmColors.info),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                'how do I set one up?',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: OmType.sans(size: 12, color: OmColors.info),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The primary action (accent fill, 30 px). [spin], when given, turns a
/// leading `loader2`.
class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton({
    required this.label,
    required this.spin,
    required this.onTap,
  });

  final String label;
  final Animation<double>? spin;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final spin = this.spin;
    return MouseRegion(
      cursor: onTap == null
          ? SystemMouseCursors.basic
          : SystemMouseCursors.click,
      child: GestureDetector(
        key: const Key('connect-submit'),
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: OmColors.accent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (spin != null) ...[
                RotationTransition(
                  turns: spin,
                  child: const Icon(
                    LucideIcons.loader2,
                    size: 14,
                    color: OmColors.accentFg,
                  ),
                ),
                const SizedBox(width: 7),
              ],
              Text(
                label,
                maxLines: 1,
                style: OmType.sans(
                  size: 13,
                  weight: FontWeight.w500,
                  color: OmColors.accentFg,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
