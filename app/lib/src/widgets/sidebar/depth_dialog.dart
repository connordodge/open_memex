import 'package:flutter/material.dart';

/// The depth dialog's question (Req 37). [requiredDepth] is the server's
/// `required_depth`, verbatim.
String depthDialogQuestion(int requiredDepth) =>
    'Would you like to update your max Smart Folder depth setting to '
    '$requiredDepth?';

/// Shows the depth dialog (Key `depth-dialog`) after a Smart Folder create
/// or move failed with `depth_exceeded`. Resolves true on Confirm (Key
/// `depth-dialog-confirm`), false on Cancel (Key `depth-dialog-cancel`) or
/// when dismissed.
Future<bool> showDepthDialog(BuildContext context, int requiredDepth) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (_) => _DepthDialog(requiredDepth: requiredDepth),
  );
  return confirmed ?? false;
}

class _DepthDialog extends StatelessWidget {
  const _DepthDialog({required this.requiredDepth});
  final int requiredDepth;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('depth-dialog'),
      title: const Text('Smart Folder depth'),
      content: Text(depthDialogQuestion(requiredDepth)),
      actions: [
        TextButton(
          key: const Key('depth-dialog-cancel'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('depth-dialog-confirm'),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Update'),
        ),
      ],
    );
  }
}
