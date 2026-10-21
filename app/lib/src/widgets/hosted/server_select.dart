import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../memex_cli.dart';
import '../../state/settings.dart';
import '../../state/token_store.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../vault_access/errors.dart';
import '../../vault_access/hosted/hosted_client.dart';

/// The HTTP client the open and create "on a server" dialogs send their
/// `HostedClient` requests with. Tests override it with a fake vault
/// server's client.
final serverDialogHttpClientProvider = Provider<http.Client>((ref) {
  final client = http.Client();
  ref.onDispose(client.close);
  return client;
});

/// Builds the `HostedClient` of a saved server for the dialogs.
final _serverDialogClientFactoryProvider =
    Provider<HostedClient Function(SavedServer, String)>(
      (ref) =>
          (server, token) => HostedClient(
            ref,
            serverId: server.id,
            serverName: server.name,
            serverUrl: server.url,
            accessToken: token,
            httpClient: ref.read(serverDialogHttpClientProvider),
          ),
    );

/// One request to [server]'s vault server through `HostedClient` (D17), with
/// the access token from the token store. A server with no stored token fails
/// like a rejected one (`unauthorized`) and sends nothing.
Future<Map<String, Object?>> sendServerDialogRequest(
  WidgetRef ref,
  SavedServer server,
  String method,
  String path, {
  required String operation,
  Object? body,
}) async {
  final factory = ref.read(_serverDialogClientFactoryProvider);
  final token = await ref.read(tokenStoreProvider).read(server.id);
  if (token == null) {
    throw MemexException(
      '$operation failed: no access token saved',
      code: 'unauthorized',
    );
  }
  return factory(
    server,
    token,
  ).serverRequest(method, path, operation: operation, body: body);
}

/// A failure the dialogs show inline under the server select.
class ServerDialogError {
  const ServerDialogError(this.text) : canUpdateToken = false;

  /// "access token rejected", with the "update token" link.
  const ServerDialogError.tokenRejected()
    : text = 'access token rejected',
      canUpdateToken = true;

  /// "can't reach" and the server URL.
  ServerDialogError.unreachable(SavedServer server)
    : text = "can't reach ${server.url}",
      canUpdateToken = false;

  /// A create that may have committed (L17).
  ServerDialogError.unconfirmed(SavedServer server)
    : text = "couldn't confirm with ${server.name} — check before trying again",
      canUpdateToken = false;

  final String text;
  final bool canUpdateToken;
}

/// What a failed request to [server] shows. [confirmable] is true for a write
/// that may have committed when it times out. Anything but a
/// `MemexException` or a `VaultUnreachableException` is rethrown.
ServerDialogError describeServerFailure(
  Object error,
  SavedServer server, {
  required String operation,
  bool confirmable = false,
}) => switch (error) {
  VaultUnreachableException(:final mayHaveCommitted) =>
    mayHaveCommitted && confirmable
        ? ServerDialogError.unconfirmed(server)
        : ServerDialogError.unreachable(server),
  MemexException(code: 'unauthorized') =>
    const ServerDialogError.tokenRejected(),
  MemexException(:final message) => ServerDialogError(
    message.replaceFirst('$operation failed: ', ''),
  ),
  _ => throw error,
};

/// `host:port` of a server URL, the host alone when it has no port.
String hostPortOf(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.host.isEmpty) return url;
  return uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
}

/// Shows [dialog] over a dimmed barrier.
Future<T?> showServerDialog<T>(BuildContext context, Widget dialog) =>
    showGeneralDialog<T>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'close',
      barrierColor: OmColors.surface0.withAlpha(184),
      transitionDuration: const Duration(milliseconds: 150),
      pageBuilder: (context, _, _) => Center(
        child: Material(type: MaterialType.transparency, child: dialog),
      ),
      transitionBuilder: (context, animation, _, child) =>
          FadeTransition(opacity: animation, child: child),
    );

/// The 472 wide dialog box of boards A6 and A7: eyebrow, then [children].
class ServerDialogShell extends StatelessWidget {
  const ServerDialogShell({
    super.key,
    required this.eyebrow,
    required this.children,
  });

  final String eyebrow;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 472,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: OmColors.surface2,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: OmColors.line2),
        boxShadow: [
          BoxShadow(
            color: OmColors.dialogShadow,
            offset: const Offset(0, 24),
            blurRadius: 64,
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(eyebrow, style: OmType.eyebrow()),
          ...children,
        ],
      ),
    );
  }
}

/// A lower case mono field label (11 px, `fg2`).
class ServerDialogLabel extends StatelessWidget {
  const ServerDialogLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) =>
      Text(text, style: OmType.mono(size: 11, color: OmColors.fg2));
}

/// An inline error row: a danger triangle and a mono 11 message, with an
/// optional trailing widget (the "update token" link).
class ServerDialogErrorRow extends StatelessWidget {
  const ServerDialogErrorRow({
    required Key key,
    required this.text,
    this.trailing,
  }) : super(key: key);

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
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
            text,
            style: OmType.mono(size: 11, color: OmColors.danger, height: 1.5),
          ),
        ),
        ?trailing,
      ],
    );
  }
}

/// The failure row under the server select (`server-dialog-error`).
class ServerFailureRow extends StatelessWidget {
  const ServerFailureRow({
    super.key,
    required this.error,
    required this.onUpdateToken,
  });

  final ServerDialogError error;
  final VoidCallback onUpdateToken;

  @override
  Widget build(BuildContext context) {
    return ServerDialogErrorRow(
      key: const Key('server-dialog-error'),
      text: error.text,
      trailing: error.canUpdateToken
          ? Padding(
              padding: const EdgeInsets.only(left: 8),
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  key: const Key('server-dialog-update-token'),
                  behavior: HitTestBehavior.opaque,
                  onTap: onUpdateToken,
                  child: Text(
                    'update token',
                    style: OmType.sans(size: 12, color: OmColors.info),
                  ),
                ),
              ),
            )
          : null,
    );
  }
}

/// The server choice of both dialogs: the saved servers, then "connect to a
/// vault server…". The select is 36 high; its menu opens at the select's
/// width.
class ServerSelect extends StatefulWidget {
  const ServerSelect({
    super.key,
    required this.servers,
    required this.selectedId,
    required this.onSelected,
    this.onConnect,
    this.hasError = false,
    this.enabled = true,
  });

  final List<SavedServer> servers;
  final String? selectedId;
  final ValueChanged<String> onSelected;
  final VoidCallback? onConnect;

  /// The server's last request failed: the invalid border.
  final bool hasError;
  final bool enabled;

  @override
  State<ServerSelect> createState() => _ServerSelectState();
}

class _ServerSelectState extends State<ServerSelect> {
  final _menu = OverlayPortalController();
  final _link = LayerLink();

  SavedServer? get _current {
    for (final s in widget.servers) {
      if (s.id == widget.selectedId) return s;
    }
    return null;
  }

  void _toggle() {
    if (!widget.enabled) return;
    _menu.isShowing ? _menu.hide() : _menu.show();
  }

  @override
  Widget build(BuildContext context) {
    final current = _current;
    return CompositedTransformTarget(
      link: _link,
      child: OverlayPortal(
        controller: _menu,
        overlayChildBuilder: _buildMenu,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            key: const Key('open-on-server-server-menu'),
            behavior: HitTestBehavior.opaque,
            onTap: _toggle,
            child: Container(
              height: 36,
              padding: const EdgeInsets.fromLTRB(10, 0, 8, 0),
              decoration: BoxDecoration(
                color: OmColors.surface3,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: widget.hasError
                      ? OmColors.danger.withAlpha(166)
                      : OmColors.line2,
                ),
              ),
              child: Row(
                children: [
                  const Icon(LucideIcons.server, size: 14, color: OmColors.fg2),
                  const SizedBox(width: 8),
                  Expanded(
                    child: current == null
                        ? Text(
                            'no saved servers',
                            style: OmType.sans(size: 13, color: OmColors.fg2),
                          )
                        : _ServerLabel(
                            server: current,
                            nameColor: OmColors.fg0,
                          ),
                  ),
                  const Icon(
                    LucideIcons.chevronDown,
                    size: 14,
                    color: OmColors.fg2,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMenu(BuildContext overlayContext) {
    final width = (context.findRenderObject() as RenderBox).size.width;
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _menu.hide,
          ),
        ),
        Positioned(
          width: width,
          child: CompositedTransformFollower(
            link: _link,
            targetAnchor: Alignment.bottomLeft,
            offset: const Offset(0, 4),
            child: Material(
              type: MaterialType.transparency,
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: OmColors.surface3,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: OmColors.line2),
                  boxShadow: [
                    BoxShadow(
                      color: OmColors.surface0.withAlpha(128),
                      offset: const Offset(0, 16),
                      blurRadius: 40,
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final s in widget.servers) ...[
                      _MenuItem(
                        key: Key('server-select-item-${s.id}'),
                        server: s,
                        current: s.id == widget.selectedId,
                        onTap: () {
                          _menu.hide();
                          if (s.id != widget.selectedId) {
                            widget.onSelected(s.id);
                          }
                        },
                      ),
                      const SizedBox(height: 1),
                    ],
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Container(height: 1, color: OmColors.line1),
                    ),
                    _MenuRow(
                      key: const Key('server-select-connect'),
                      icon: LucideIcons.plus,
                      onTap: () {
                        _menu.hide();
                        widget.onConnect?.call();
                      },
                      child: Text(
                        'connect to a vault server…',
                        style: OmType.sans(size: 13, color: OmColors.fg1),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The server name, then its host and port.
class _ServerLabel extends StatelessWidget {
  const _ServerLabel({required this.server, required this.nameColor});

  final SavedServer server;
  final Color nameColor;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Flexible(
          child: Text(
            server.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: OmType.sans(size: 13, color: nameColor),
          ),
        ),
        const SizedBox(width: 3),
        Flexible(
          child: Text(
            '· ${hostPortOf(server.url)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: OmType.mono(size: 11, color: OmColors.fg2),
          ),
        ),
      ],
    );
  }
}

class _MenuItem extends StatelessWidget {
  const _MenuItem({
    super.key,
    required this.server,
    required this.current,
    required this.onTap,
  });

  final SavedServer server;
  final bool current;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _MenuRow(
      icon: LucideIcons.server,
      highlighted: current,
      onTap: onTap,
      trailing: current
          ? const Icon(LucideIcons.check, size: 14, color: OmColors.accent)
          : null,
      child: _ServerLabel(
        server: server,
        nameColor: current ? OmColors.fg0 : OmColors.fg1,
      ),
    );
  }
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({
    super.key,
    required this.icon,
    required this.child,
    required this.onTap,
    this.highlighted = false,
    this.trailing,
  });

  final IconData icon;
  final Widget child;
  final VoidCallback onTap;
  final bool highlighted;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final fg = highlighted ? OmColors.fg0 : OmColors.fg1;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          height: 31,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: highlighted ? OmColors.surface4 : null,
            borderRadius: BorderRadius.circular(5),
          ),
          child: Row(
            children: [
              Icon(icon, size: 14, color: fg),
              const SizedBox(width: 8),
              Expanded(child: child),
              ?trailing,
            ],
          ),
        ),
      ),
    );
  }
}
