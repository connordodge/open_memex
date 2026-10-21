import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../state/vault_open_controller.dart' show networkDriveRefusalMessage;
import '../theme/colors.dart';
import '../theme/typography.dart';
import 'atoms.dart';

/// What the person chose in the network-drive refusal (board A9 state 1).
/// `showVaultOpenRefusal` opens the set-up sheet for [setUpServer] and the
/// connect dialog for [connectServer] once the refusal closed.
enum NetworkDriveRefusalChoice { cancel, setUpServer, connectServer }

/// Shows the network-drive refusal for the folder at [path] under [eyebrow]
/// ("OPEN LOCAL VAULT", or "CREATE NEW VAULT" in the create flow) and
/// completes with the choice that closed it.
Future<NetworkDriveRefusalChoice?> showNetworkDriveRefusalDialog(
  BuildContext context, {
  required String path,
  required String eyebrow,
}) {
  return showDialog<NetworkDriveRefusalChoice>(
    context: context,
    builder: (ctx) => LocalOpenRefusalDialog(
      key: const Key('network-drive-refusal'),
      eyebrow: eyebrow,
      path: path,
      pathIcon: LucideIcons.hardDrive,
      message: networkDriveRefusalMessage,
      link: KeyedSubtree(
        key: const Key('network-drive-refusal-setup'),
        child: _InfoLink(
          label: 'set up a vault server…',
          onTap: () =>
              Navigator.of(ctx).pop(NetworkDriveRefusalChoice.setUpServer),
        ),
      ),
      cancelKey: const Key('network-drive-refusal-cancel'),
      onCancel: () => Navigator.of(ctx).pop(NetworkDriveRefusalChoice.cancel),
      primaryKey: const Key('network-drive-refusal-connect'),
      primaryLabel: 'connect to a vault server…',
      onPrimary: () =>
          Navigator.of(ctx).pop(NetworkDriveRefusalChoice.connectServer),
    ),
  );
}

/// The A9 state-1 refusal shell (design pack 92): eyebrow, path box, message,
/// an optional link row, then ghost "cancel" and a primary action. Shared by
/// the network-drive and the too-old-memex refusals.
class LocalOpenRefusalDialog extends StatelessWidget {
  const LocalOpenRefusalDialog({
    super.key,
    required this.eyebrow,
    required this.path,
    required this.pathIcon,
    required this.message,
    required this.cancelKey,
    required this.onCancel,
    required this.primaryKey,
    required this.primaryLabel,
    required this.onPrimary,
    this.link,
  });

  final String eyebrow;
  final String path;
  final IconData pathIcon;
  final String message;
  final Widget? link;
  final Key cancelKey;
  final VoidCallback onCancel;
  final Key primaryKey;
  final String primaryLabel;
  final VoidCallback onPrimary;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      elevation: 0,
      child: Container(
        width: 472,
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: OmColors.surface2,
          border: Border.all(color: OmColors.line2, width: 1),
          borderRadius: BorderRadius.circular(10),
          boxShadow: const [
            BoxShadow(
              color: Color(0x99000000),
              offset: Offset(0, 24),
              blurRadius: 64,
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(eyebrow.toUpperCase(), style: OmType.eyebrow()),
            const SizedBox(height: 16),
            _PathBox(path: path, icon: pathIcon),
            const SizedBox(height: 16),
            Text(
              message,
              style: OmType.sans(
                size: 13.5,
                color: OmColors.fg0,
                height: 20.93 / 13.5,
              ),
            ),
            if (link != null) ...[
              const SizedBox(height: 16),
              Align(alignment: Alignment.centerLeft, child: link),
            ],
            const SizedBox(height: 16),
            // A Wrap, not a Row: at a large text scale the primary button
            // drops below "cancel" instead of overflowing.
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 8,
              children: [
                KeyedSubtree(
                  key: cancelKey,
                  child: OmButton(
                    kind: OmButtonKind.ghost,
                    label: 'cancel',
                    onPressed: onCancel,
                  ),
                ),
                KeyedSubtree(
                  key: primaryKey,
                  child: OmButton(
                    kind: OmButtonKind.primary,
                    label: primaryLabel,
                    onPressed: onPrimary,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PathBox extends StatelessWidget {
  const _PathBox({required this.path, required this.icon});

  final String path;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      decoration: BoxDecoration(
        color: OmColors.surface0,
        border: Border.all(color: OmColors.line2, width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          Icon(icon, size: 14, color: OmColors.fg2),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              path,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: OmType.mono(size: 12, color: OmColors.fg1, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoLink extends StatelessWidget {
  const _InfoLink({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(LucideIcons.circleHelp, size: 12, color: OmColors.info),
            const SizedBox(width: 6),
            Text(
              label,
              style: OmType.sans(size: 12, color: OmColors.info, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}
