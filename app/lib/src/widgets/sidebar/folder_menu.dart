import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../graph/graph_scope.dart';
import '../../state/graph_state.dart';
import '../../state/smart_folder_actions.dart';
import '../../state/topics_state.dart';
import '../../state/topics_tree.dart';
import '../../state/vault_state.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../vault_access/vault_scoped.dart';
import '../atoms.dart';
import '../vault_settings_dialog.dart';
import 'depth_dialog.dart';

/// The menu surface style shared by the folder and membership menus.
final _menuStyle = MenuStyle(
  backgroundColor: const WidgetStatePropertyAll(OmColors.surface3),
  shape: WidgetStatePropertyAll(
    RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(6),
      side: BorderSide(color: OmColors.line3),
    ),
  ),
);

/// The Topics header's Smart Folder actions (#25): `+ New Smart Folder`
/// (Key `topics-new-folder`), the Whole vault `Graph` action (Key
/// `topics-graph-action`) and the vault settings surface (Key
/// `topics-vault-settings`).
class SmartFolderHeaderActions extends ConsumerWidget {
  const SmartFolderHeaderActions({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        OmButton(
          key: const Key('topics-new-folder'),
          kind: OmButtonKind.ghost,
          size: 24,
          icon: LucideIcons.folderPlus,
          tooltip: 'New Smart Folder',
          onPressed: () => _newFolder(context, ref),
        ),
        OmButton(
          key: const Key('topics-graph-action'),
          kind: OmButtonKind.ghost,
          size: 24,
          icon: LucideIcons.network,
          tooltip: 'Graph · Whole vault',
          onPressed: () => openGraph(ref, const GraphScope.vault()),
        ),
        OmButton(
          key: const Key('topics-vault-settings'),
          kind: OmButtonKind.ghost,
          size: 24,
          icon: LucideIcons.settings2,
          tooltip: 'Vault settings',
          onPressed: () => showVaultSettingsDialog(context),
        ),
      ],
    );
  }

  /// `+ New Smart Folder`: asks for a name, then creates the folder inside
  /// the selected folder, or at root when none is selected.
  Future<void> _newFolder(BuildContext context, WidgetRef ref) async {
    final container = ProviderScope.containerOf(context);
    final parentId = ref.read(selectedFolderInTreeProvider);
    final name = await showFolderNameDialog(
      context,
      title: 'New Smart Folder',
      confirmLabel: 'Create',
    );
    if (name == null || !context.mounted) return;
    await createSmartFolder(
      container,
      context,
      name: name,
      parentId: parentId,
      confirmDepth: (depth) => showDepthDialog(context, depth),
    );
  }
}

/// The ellipsis button on a folder row (Key `folder-menu-<id>`) and its
/// edit menu: Rename, Move, Pin/Unpin, Delete and `Open graph` (Keys
/// `folder-menu-rename|move|pinned|delete|open-graph`).
///
/// [hostContext] is the Topics pane's context: dialogs run on it, since the
/// menu (and possibly the row) is gone by the time they answer.
class FolderMenuButton extends ConsumerWidget {
  const FolderMenuButton({
    super.key,
    required this.folder,
    required this.hostContext,
  });

  final FolderNode folder;
  final BuildContext hostContext;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = folder.id;
    final container = ProviderScope.containerOf(context);
    return MenuAnchor(
      style: _menuStyle,
      menuChildren: [
        MenuItemButton(
          key: const Key('folder-menu-rename'),
          leadingIcon: const Icon(LucideIcons.pencil, size: 14),
          onPressed: () => _rename(container),
          child: const Text('Rename'),
        ),
        MenuItemButton(
          key: const Key('folder-menu-move'),
          leadingIcon: const Icon(LucideIcons.folderInput, size: 14),
          onPressed: () => _move(container),
          child: const Text('Move to…'),
        ),
        MenuItemButton(
          key: const Key('folder-menu-pinned'),
          leadingIcon: Icon(
            folder.pinned ? LucideIcons.pinOff : LucideIcons.pin,
            size: 14,
          ),
          onPressed: () => setSmartFolderPinned(
            container,
            hostContext,
            id: id,
            pinned: !folder.pinned,
          ),
          child: Text(folder.pinned ? 'Unpin' : 'Pin'),
        ),
        MenuItemButton(
          key: const Key('folder-menu-open-graph'),
          leadingIcon: const Icon(LucideIcons.network, size: 14),
          onPressed: () => openGraph(ref, GraphScope.folder(id)),
          child: const Text('Open graph'),
        ),
        MenuItemButton(
          key: const Key('folder-menu-delete'),
          leadingIcon: const Icon(LucideIcons.trash2, size: 14),
          onPressed: () => _delete(container),
          child: Text('Delete', style: TextStyle(color: OmColors.danger)),
        ),
      ],
      builder: (context, controller, _) => OmButton(
        key: Key('folder-menu-$id'),
        kind: OmButtonKind.ghost,
        size: 20,
        icon: LucideIcons.ellipsis,
        tooltip: 'folder actions',
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }

  Future<void> _rename(ProviderContainer container) async {
    final name = await showFolderNameDialog(
      hostContext,
      title: 'Rename Smart Folder',
      confirmLabel: 'Rename',
      initial: folder.name,
    );
    if (name == null || !hostContext.mounted) return;
    await renameSmartFolder(container, hostContext, id: folder.id, name: name);
  }

  Future<void> _move(ProviderContainer container) async {
    final target = await showFolderMoveDialog(
      hostContext,
      tree:
          currentVaultData(
            container.read(smartFolderTreeAsyncProvider),
            container.read(currentVaultProvider),
          )?.value ??
          emptyTopicsTree(),
      folderId: folder.id,
    );
    if (target == null || !hostContext.mounted) return;
    await moveSmartFolder(
      container,
      hostContext,
      id: folder.id,
      parentId: target.parentId,
      confirmDepth: (depth) => showDepthDialog(hostContext, depth),
    );
  }

  Future<void> _delete(ProviderContainer container) async {
    final confirmed = await showDialog<bool>(
      context: hostContext,
      builder: (_) => _DeleteFolderDialog(name: folder.name),
    );
    if (confirmed != true || !hostContext.mounted) return;
    await deleteSmartFolder(container, hostContext, id: folder.id);
  }
}

/// The membership context menu of a topic row (secondary click): pin or
/// unpin that note's membership in [folderId] (Key
/// `membership-menu-pinned-<folderId>-<noteId>`), through `memex folder add
/// --pinned`.
class MembershipMenu extends StatefulWidget {
  const MembershipMenu({
    super.key,
    required this.folderId,
    required this.noteId,
    required this.pinned,
    required this.child,
  });

  final String folderId;
  final String noteId;

  /// The membership's current pin.
  final bool pinned;
  final Widget child;

  @override
  State<MembershipMenu> createState() => _MembershipMenuState();
}

class _MembershipMenuState extends State<MembershipMenu> {
  final _controller = MenuController();

  @override
  Widget build(BuildContext context) {
    final container = ProviderScope.containerOf(context);
    return MenuAnchor(
      controller: _controller,
      style: _menuStyle,
      menuChildren: [
        MenuItemButton(
          key: Key(
            'membership-menu-pinned-${widget.folderId}-${widget.noteId}',
          ),
          leadingIcon: Icon(
            widget.pinned ? LucideIcons.pinOff : LucideIcons.pin,
            size: 14,
          ),
          onPressed: () => addToSmartFolder(
            container,
            context,
            folderId: widget.folderId,
            noteId: widget.noteId,
            pinned: !widget.pinned,
          ),
          child: Text(widget.pinned ? 'Unpin in folder' : 'Pin in folder'),
        ),
      ],
      child: GestureDetector(
        onSecondaryTapUp: (details) =>
            _controller.open(position: details.localPosition),
        child: widget.child,
      ),
    );
  }
}

/// Asks for a Smart Folder name (Key `folder-name-dialog`, field
/// `folder-name-field`, buttons `folder-name-confirm` / `folder-name-cancel`).
/// Resolves the trimmed name, or null on Cancel or a blank name.
Future<String?> showFolderNameDialog(
  BuildContext context, {
  required String title,
  required String confirmLabel,
  String initial = '',
}) async {
  final name = await showDialog<String>(
    context: context,
    builder: (_) => _FolderNameDialog(
      title: title,
      confirmLabel: confirmLabel,
      initial: initial,
    ),
  );
  return name == null || name.isEmpty ? null : name;
}

class _FolderNameDialog extends StatefulWidget {
  const _FolderNameDialog({
    required this.title,
    required this.confirmLabel,
    required this.initial,
  });
  final String title;
  final String confirmLabel;
  final String initial;

  @override
  State<_FolderNameDialog> createState() => _FolderNameDialogState();
}

class _FolderNameDialogState extends State<_FolderNameDialog> {
  late final _name = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_name.text.trim());

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('folder-name-dialog'),
      title: Text(widget.title),
      content: TextField(
        key: const Key('folder-name-field'),
        controller: _name,
        autofocus: true,
        decoration: const InputDecoration(hintText: 'Name'),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          key: const Key('folder-name-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('folder-name-confirm'),
          onPressed: _submit,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

/// Where the move picker sends a folder: inside [parentId], or root when
/// it is null.
typedef FolderMoveTarget = ({String? parentId});

/// The move picker (Key `folder-move-dialog`): root (Key
/// `folder-move-target-root`) and every other folder of [tree] (Keys
/// `folder-move-target-<id>`), indented by depth. Which targets are valid is
/// the server's call (depth, cycles). Resolves null when dismissed.
Future<FolderMoveTarget?> showFolderMoveDialog(
  BuildContext context, {
  required TopicsTree tree,
  required String folderId,
}) {
  final targets = <FolderNode>[];
  void collect(FolderNode f) {
    if (f.id != folderId) targets.add(f);
    f.children.forEach(collect);
  }

  tree.folders.forEach(collect);
  return showDialog<FolderMoveTarget>(
    context: context,
    builder: (ctx) {
      Widget target(
        Key key,
        IconData icon,
        String label,
        int depth,
        String? parentId,
      ) => ListTile(
        key: key,
        contentPadding: EdgeInsets.only(left: 8 + depth * 14.0, right: 8),
        leading: Icon(icon, size: 14, color: OmColors.fg2),
        title: Text(label, style: OmType.sans(size: 13, color: OmColors.fg0)),
        onTap: () => Navigator.of(ctx).pop((parentId: parentId)),
      );
      return AlertDialog(
        key: const Key('folder-move-dialog'),
        title: const Text('Move to'),
        content: SizedBox(
          width: 320,
          child: ListView(
            shrinkWrap: true,
            children: [
              target(
                const Key('folder-move-target-root'),
                LucideIcons.house,
                'Root',
                0,
                null,
              ),
              for (final f in targets)
                target(
                  Key('folder-move-target-${f.id}'),
                  LucideIcons.folder,
                  f.name,
                  f.depth + 1,
                  f.id,
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
        ],
      );
    },
  );
}

class _DeleteFolderDialog extends StatelessWidget {
  const _DeleteFolderDialog({required this.name});
  final String name;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('folder-delete-dialog'),
      title: const Text('Delete Smart Folder?'),
      content: Text(
        '"$name" will be deleted. Its subfolders move up a level and its '
        'topics stay in the vault.',
      ),
      actions: [
        TextButton(
          key: const Key('folder-delete-cancel'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const Key('folder-delete-confirm'),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text('Delete', style: TextStyle(color: OmColors.danger)),
        ),
      ],
    );
  }
}
