import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../cli/note_cli.dart';
import '../../db.dart';
import '../../graph/graph_scope.dart';
import '../../memex_cli.dart';
import '../../state/editor_controller.dart';
import '../../state/graph_state.dart';
import '../../state/note_edits_state.dart';
import '../../state/tabs_state.dart';
import '../../state/vault_access_state.dart';
import '../../state/vault_state.dart';
import '../../vault_access/errors.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../agent_edits_keys.dart';
import '../atoms.dart';

/// The editor toolbar's ellipsis button (Key `note-menu-button`). It opens
/// [NoteMenu] for the open note, and is disabled when no note is open.
class NoteMenuButton extends ConsumerWidget {
  const NoteMenuButton({super.key, required this.note});
  final Note? note;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final note = this.note;
    return MenuAnchor(
      style: MenuStyle(
        backgroundColor: const WidgetStatePropertyAll(OmColors.surface3),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(6),
            side: BorderSide(color: OmColors.line3),
          ),
        ),
      ),
      menuChildren: [
        if (note != null)
          NoteMenu(note: note, hostContext: context, hostRef: ref),
      ],
      builder: (context, controller, _) => OmButton(
        key: const Key('note-menu-button'),
        kind: OmButtonKind.ghost,
        size: 26,
        icon: LucideIcons.ellipsis,
        onPressed: note == null
            ? null
            : () => controller.isOpen ? controller.close() : controller.open(),
        tooltip: 'more',
      ),
    );
  }
}

/// The note menu for [note] (Key `note-menu`), shown by [NoteMenuButton].
/// Items are [MenuItemButton]s in the column; selecting one closes the menu.
/// To add an item, append a [MenuItemButton] to the column's children.
class NoteMenu extends StatelessWidget {
  const NoteMenu({
    super.key,
    required this.note,
    required this.hostContext,
    this.hostRef,
  });
  final Note note;

  /// The context of the widget that hosts the menu ([NoteMenuButton]). Item
  /// actions that outlive the menu (dialogs) use it, since the menu's own
  /// context is deactivated once an item closes the menu.
  final BuildContext hostContext;

  /// The host's [WidgetRef], for item actions that open tabs after the menu
  /// has closed (`Open graph`). Without one that item is disabled.
  final WidgetRef? hostRef;

  /// The Graph scope `Open graph` opens: the topic scope for a topic note,
  /// the day scope for a daily note, none otherwise. The unsaved virtual
  /// Today note (#22) is in no graph yet, so it has none either.
  static GraphScope? graphScopeFor(Note note) {
    if (VirtualTodayTab.dateOf(note.id) case _?) return null;
    return switch (note.role) {
      'topic' => GraphScope.topic(note.id),
      'daily' => GraphScope.day(note.id),
      _ => null,
    };
  }

  @override
  Widget build(BuildContext context) {
    final ref = hostRef;
    return Column(
      key: const Key('note-menu'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The Vault Guide cannot be deleted.
        if (note.role != 'guide')
          MenuItemButton(
            key: const Key('note-menu-delete'),
            leadingIcon: const Icon(LucideIcons.trash2, size: 14),
            // The unsaved virtual Today note (#22) has nothing to delete.
            onPressed: VirtualTodayTab.dateOf(note.id) != null
                ? null
                : () => confirmAndDeleteNote(
                    hostContext,
                    ProviderScope.containerOf(hostContext),
                    note,
                  ),
            child: const Text('Delete note'),
          ),
        if (graphScopeFor(note) case final scope?)
          MenuItemButton(
            key: const Key('note-menu-open-graph'),
            leadingIcon: const Icon(LucideIcons.network, size: 14),
            onPressed: switch (ref) {
              final ref? => () => openGraph(ref, scope),
              null => null,
            },
            child: const Text('Open graph'),
          ),
        // Spec #7 Req 7 and 31: the flag can't be set on a daily note or the
        // Vault Guide. The unsaved virtual Today note is a `role: daily` note.
        if (note.role != 'daily' && note.role != 'guide')
          _AgentReadOnlyItem(note: note, hostContext: hostContext),
      ],
    );
  }
}

/// The checkable `Read-only for agents` item (Key
/// [noteMenuAgentReadOnlyKey], Spec #7 Req 31), shown only while
/// [agentEditsAvailableProvider] is true (D17). Its check is [note]'s stored
/// flag, the re-read note the editor shows (D18).
class _AgentReadOnlyItem extends ConsumerWidget {
  const _AgentReadOnlyItem({required this.note, required this.hostContext});
  final Note note;
  final BuildContext hostContext;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(agentEditsAvailableProvider)) return const SizedBox.shrink();
    final on = note.agentReadOnly;
    final container = ProviderScope.containerOf(context, listen: false);
    return MenuItemButton(
      key: noteMenuAgentReadOnlyKey,
      leadingIcon: Icon(
        on ? LucideIcons.squareCheck : LucideIcons.square,
        size: 14,
      ),
      onPressed: () => _toggleAgentReadOnly(hostContext, container, note),
      child: Semantics(checked: on, child: const Text('Read-only for agents')),
    );
  }
}

/// The note ids whose Agent read-only toggle is in flight: the busy guard
/// of [_toggleAgentReadOnly]. It lives in the container, not the menu, since
/// the menu closes when the item is chosen.
final _agentReadOnlyBusyProvider = Provider<Set<String>>((_) => <String>{});

/// The toggle's inline error when the vault can't be written (no `memex`
/// CLI): the app's existing copy for that case (smart folders, topics).
const _noCliMessage = 'The memex CLI is not available.';

/// Sets [note]'s Agent read-only flag to the opposite of its stored value
/// through [NoteEditsActions.setAgentReadOnly], inside `guardVaultWrite`.
/// While one toggle of [note] is in flight, another starts nothing. No
/// optimistic state: the check and the title icon change when the bump's
/// re-read note does (D18). On failure nothing changes except
/// [noteDeleteErrorProvider], which shows the CLI or server message (Req 33);
/// a later successful toggle of [note] clears that message. An unreachable
/// vault server shows the guard's snackbar instead.
///
/// With no vault open or no `memex` CLI (`VaultAccess.canWrite` false) it
/// makes no call and shows [_noCliMessage]. Any other failure (a
/// [StateError], a [MemexCliTimeout]) shows its message in the same slot
/// rather than escaping as an uncaught async error.
Future<void> _toggleAgentReadOnly(
  BuildContext context,
  ProviderContainer container,
  Note note,
) async {
  final busy = container.read(_agentReadOnlyBusyProvider);
  if (!busy.add(note.id)) return;
  try {
    if (!context.mounted) return;
    final errors = container.read(noteDeleteErrorProvider.notifier);
    final access = container.read(vaultAccessProvider);
    if (access == null || !access.canWrite) {
      errors.state = (noteId: note.id, message: _noCliMessage);
      return;
    }
    final bool? done;
    try {
      done = await guardVaultWrite(context, () async {
        await container
            .read(noteEditsActionsProvider)
            .setAgentReadOnly(note.id, !note.agentReadOnly);
        return true;
      });
    } on MemexException catch (e) {
      errors.state = (noteId: note.id, message: e.message);
      return;
    } on StateError catch (e) {
      errors.state = (noteId: note.id, message: e.message);
      return;
    } on Exception catch (e) {
      errors.state = (noteId: note.id, message: e.toString());
      return;
    }
    if (done == null) return;
    if (errors.state?.noteId == note.id) errors.state = null;
  } finally {
    busy.remove(note.id);
  }
}

/// The inline error left by a failed note delete or Agent read-only toggle:
/// the id of the note it belongs to and the CLI message. Null when there is
/// none.
final noteDeleteErrorProvider =
    StateProvider<({String noteId, String message})?>((_) => null);

/// Asks for confirmation, then deletes [note] through `VaultAccess.notes`
/// (`memex rm` on a local vault) with the editor's last saved version, inside
/// `guardVaultWrite`. On success the note's tab closes and the vault reads
/// refresh. On failure nothing changes except [noteDeleteErrorProvider]; an
/// unreachable vault server shows the guard's snackbar instead.
///
/// Takes the [container] rather than a `WidgetRef`: the note menu is gone by
/// the time the person answers the dialog.
Future<void> confirmAndDeleteNote(
  BuildContext context,
  ProviderContainer container,
  Note note,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (_) => _DeleteNoteDialog(title: note.title),
  );
  if (confirmed != true || !context.mounted) return;

  final access = container.read(vaultAccessProvider);
  if (access == null || !access.canWrite) return;
  final errors = container.read(noteDeleteErrorProvider.notifier);
  final version =
      container.read(editorControllerProvider).lastSavedVersion ?? note.version;
  final NoteDeleteResult? deleted;
  try {
    deleted = await guardVaultWrite(
      context,
      () => access.notes.deleteNote(noteId: note.id, expectedVersion: version),
    );
  } on MemexException catch (e) {
    errors.state = (noteId: note.id, message: e.message);
    return;
  }
  if (deleted == null) return;
  errors.state = null;
  container.read(tabsProvider.notifier).close(NoteTab(note.id));
  container.read(vaultRevisionProvider.notifier).state++;
}

class _DeleteNoteDialog extends StatelessWidget {
  const _DeleteNoteDialog({required this.title});
  final String title;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('delete-note-dialog'),
      title: const Text('Delete note?'),
      content: Text('"$title" will be deleted. This can\'t be undone.'),
      actions: [
        TextButton(
          key: const Key('delete-note-cancel'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const Key('delete-note-confirm'),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text('Delete', style: TextStyle(color: OmColors.danger)),
        ),
      ],
    );
  }
}

/// The dismissible inline error (Key `inline-error`) for a failed delete of
/// [noteId]; empty when the open note has none.
class NoteDeleteError extends ConsumerWidget {
  const NoteDeleteError({super.key, required this.noteId});
  final String noteId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final error = ref.watch(noteDeleteErrorProvider);
    if (error == null || error.noteId != noteId) {
      return const SizedBox.shrink();
    }
    return Container(
      key: const Key('inline-error'),
      color: OmColors.surface1,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              error.message,
              style: OmType.mono(size: 11, color: OmColors.danger),
            ),
          ),
          OmButton(
            key: const Key('inline-error-dismiss'),
            kind: OmButtonKind.ghost,
            size: 22,
            icon: LucideIcons.x,
            tooltip: 'dismiss',
            onPressed: () =>
                ref.read(noteDeleteErrorProvider.notifier).state = null,
          ),
        ],
      ),
    );
  }
}
