import 'package:flutter/material.dart';

import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../atoms.dart';

/// Asks before removing the saved server [serverName] (Req 46, board A9
/// state 2). Completes true for "remove" (`remove-server-confirm`), false
/// for "cancel" (`remove-server-cancel`) or a dismiss.
Future<bool> confirmRemoveServer(
  BuildContext context, {
  required String serverName,
}) async {
  final chosen = await showDialog<bool>(
    context: context,
    builder: (_) => RemoveServerDialog(serverName: serverName),
  );
  return chosen ?? false;
}

/// The A9 state-2 remove-server confirm (pack 97; shell as pack 92): 472
/// wide, eyebrow "REMOVE SERVER", the question, the body, then ghost
/// "cancel" and danger "remove".
class RemoveServerDialog extends StatelessWidget {
  const RemoveServerDialog({super.key, required this.serverName});

  final String serverName;

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
          border: Border.all(color: OmColors.line2),
          borderRadius: BorderRadius.circular(10),
          boxShadow: const [
            BoxShadow(
              color: OmColors.dialogShadow,
              offset: Offset(0, 24),
              blurRadius: 64,
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('REMOVE SERVER', style: OmType.eyebrow()),
            const SizedBox(height: 16),
            Text(
              'remove $serverName?',
              style: OmType.sans(
                size: 15,
                weight: FontWeight.w600,
                color: OmColors.fg0,
                height: 21 / 15,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'its vaults leave your recents. nothing on the server is '
              'touched.',
              style: OmType.sans(
                size: 13.5,
                color: OmColors.fg1,
                height: 20.93 / 13.5,
              ),
            ),
            const SizedBox(height: 20),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 8,
              children: [
                OmButton(
                  key: const Key('remove-server-cancel'),
                  kind: OmButtonKind.ghost,
                  label: 'cancel',
                  onPressed: () => Navigator.of(context).pop(false),
                ),
                OmButton(
                  key: const Key('remove-server-confirm'),
                  kind: OmButtonKind.danger,
                  label: 'remove',
                  onPressed: () => Navigator.of(context).pop(true),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
