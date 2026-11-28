// WI #77 (56-A3, Spec #59 req 24): the workspace's New note and New canvas
// actions, callable from the sidebar, the workspace and the Command
// palette. Extracted unchanged from `Workspace._createNote` and
// `Sidebar._newCanvas`.
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../vault_access/errors.dart';
import 'tabs_state.dart';
import 'vault_access_state.dart';
import 'vault_state.dart';

/// Makes an `Untitled` note in the open vault and shows it in the active
/// tab. Does nothing on a vault that can't be written. A write failure shows
/// a `Could not create note` snackbar over [context].
Future<void> createNote(BuildContext context) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final access = container.read(vaultAccessProvider);
  if (access == null || !access.canWrite) return;
  try {
    final id = await guardVaultWrite(
      context,
      () =>
          access.notes.addNote(title: 'Untitled', contentMd: '# Untitled\n\n'),
    );
    if (id == null) return;
    container.read(vaultRevisionProvider.notifier).state++;
    container.read(tabsProvider.notifier).navigate(NoteTab(id));
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not create note: $e')));
    }
  }
}

/// Asks for a title (the `New canvas` prompt over [context]), makes a
/// canvas with it and shows it in the active tab. Does nothing on a vault
/// that can't be written, or when the prompt is cancelled or left empty. A
/// write failure shows a `Could not create canvas` snackbar over [context].
Future<void> newCanvas(BuildContext context) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final access = container.read(vaultAccessProvider);
  if (access == null || !access.canWrite) return;
  final title = await _promptCanvasTitle(context);
  if (title == null || title.isEmpty || !context.mounted) return;
  try {
    final c = await guardVaultWrite(
      context,
      () => access.canvas.createCanvas(title: title),
    );
    if (c == null) return;
    container.read(vaultRevisionProvider.notifier).state++;
    container.read(tabsProvider.notifier).navigate(CanvasTab(c.canvasId));
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not create canvas: $e')));
    }
  }
}

Future<String?> _promptCanvasTitle(BuildContext context) async {
  final controller = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (ctx) {
      return AlertDialog(
        title: const Text('New canvas'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Title'),
          onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('new-canvas-confirm'),
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('Create'),
          ),
        ],
      );
    },
  );
}
