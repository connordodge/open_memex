import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../state/hosted_connection_state.dart';
import '../../state/server_probes.dart';
import '../../state/settings.dart';
import '../../state/vault_open_hosted.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../vault_access/hosted/hosted_client.dart';
import '../atoms.dart';

/// "host:port" of a saved server [url] (the port only when the URL
/// names one), as a hosted recent row's subline shows it.
String serverHostPort(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.host.isEmpty) return url;
  return uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
}

/// The status dot for a saved server's connection [status] (Req 38): null is
/// checking; an incompatible server shows the danger dot.
StatusDotState statusDotFor(HostedConnectionStatus? status) => switch (status) {
  null => StatusDotState.checking,
  HostedConnectionStatus.connected => StatusDotState.connected,
  HostedConnectionStatus.unreachable => StatusDotState.cantReach,
  HostedConnectionStatus.tokenRejected => StatusDotState.tokenRejected,
  HostedConnectionStatus.incompatible => StatusDotState.tokenRejected,
};

/// The danger text for an incompatible [server] (its last probe found no
/// memex vault server, or an api mismatch).
String incompatibleCopy(SavedServer server, ServerProbe? probe) =>
    probe?.kind == ServerProbeKind.apiMismatch
    ? hostedApiMismatchMessage(server.name, probe!.serverVersion ?? '?')
    : hostedNotMemexMessage(server.url);

/// The shared chrome of a picker row (pack 97 "Row chrome"): min height 56,
/// padding 12/10/8/10, `surface2` fill (`surface3` on hover), a 1 px
/// [border] (default `line2`) and radius 6.
class PickerRowShell extends StatefulWidget {
  const PickerRowShell({
    super.key,
    required this.child,
    this.onTap,
    this.border,
  });

  final Widget child;
  final VoidCallback? onTap;
  final Color? border;

  @override
  State<PickerRowShell> createState() => _PickerRowShellState();
}

class _PickerRowShellState extends State<PickerRowShell> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final tappable = widget.onTap != null;
    return MouseRegion(
      cursor: tappable ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 56),
          padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
          decoration: BoxDecoration(
            color: _hover && tappable ? OmColors.surface3 : OmColors.surface2,
            border: Border.all(color: widget.border ?? OmColors.line2),
            borderRadius: BorderRadius.circular(6),
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

/// The row's name: Inter Tight w500 13.5 / 18.23.
TextStyle pickerRowNameStyle(Color color) => OmType.sans(
  size: 13.5,
  weight: FontWeight.w500,
  color: color,
  height: 18.23 / 13.5,
);

/// The row's subline: JetBrains Mono 10.5 / 15.75.
TextStyle pickerRowSublineStyle(Color color) =>
    OmType.mono(size: 10.5, color: color, height: 15.75 / 10.5);

/// A 24×24 trailing icon button (radius 5, 12 px `fg2` glyph, no fill).
class PickerRowIconButton extends StatelessWidget {
  const PickerRowIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onPressed,
          child: SizedBox(
            width: 24,
            height: 24,
            child: Center(child: Icon(icon, size: 12, color: OmColors.fg2)),
          ),
        ),
      ),
    );
  }
}

/// A SERVERS row (key `server-row-<id>`, pack 97): server icon, name, the
/// status dot and URL (or, for an incompatible server, its message in
/// `danger`), then edit (`server-row-edit-<id>`) and remove
/// (`server-row-remove-<id>`).
class ServerRow extends ConsumerWidget {
  const ServerRow({
    super.key,
    required this.server,
    required this.onEdit,
    required this.onRemove,
  });

  final SavedServer server;
  final VoidCallback onEdit;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(hostedConnectionStatusProvider(server.id));
    final incompatible = status == HostedConnectionStatus.incompatible;
    final subline = incompatible
        ? incompatibleCopy(
            server,
            ref.watch(serverProbeResultProvider(server.id)),
          )
        : server.url;
    return PickerRowShell(
      key: Key('server-row-${server.id}'),
      child: Row(
        children: [
          const Icon(LucideIcons.server, size: 14, color: OmColors.fg2),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  server.name,
                  style: pickerRowNameStyle(OmColors.fg0),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    StatusDot(state: statusDotFor(status)),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        subline,
                        style: pickerRowSublineStyle(
                          incompatible ? OmColors.danger : OmColors.fg2,
                        ),
                        maxLines: incompatible ? null : 1,
                        overflow: incompatible ? null : TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          PickerRowIconButton(
            key: Key('server-row-edit-${server.id}'),
            icon: LucideIcons.pencil,
            tooltip: 'edit server',
            onPressed: onEdit,
          ),
          const SizedBox(width: 10),
          PickerRowIconButton(
            key: Key('server-row-remove-${server.id}'),
            icon: LucideIcons.trash,
            tooltip: 'remove server',
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}
