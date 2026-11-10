import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../db.dart';
import '../state/file_revealer.dart';
import '../state/settings.dart';
import '../state/vault_open_hosted.dart';
import '../state/vault_ref.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';
import 'dialog_button.dart';
import 'picker/delete_vault_dialog.dart';

/// Reveals the local vault folder at [path] in Finder
/// (`fileRevealerProvider`). When [path] is no longer a vault
/// (`VaultDb.isVault`), nothing opens and a SnackBar reads
/// `<path> is no longer a vault folder.`
Future<void> showVaultInFinder(
  BuildContext context,
  WidgetRef ref,
  String path,
) async {
  if (!VaultDb.isVault(path)) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text('$path is no longer a vault folder.')),
    );
    return;
  }
  await ref.read(fileRevealerProvider).reveal(path);
}

/// Drops [vault] from the recents: its recorded row outcome is cleared,
/// then the ref is forgotten. The row's × and the menu's
/// `remove from recents` both run this.
void forgetRecentVault(WidgetRef ref, VaultRef vault) {
  ref.read(recentRowOutcomeProvider(vault).notifier).state = null;
  ref.read(settingsProvider.notifier).forgetRef(vault);
}

/// Sent up from a [VaultMenuRegion] when the delete-vault dialog it opened
/// closes, so the row around it can re-check its folder.
class VaultDeleteDialogClosed extends Notification {
  const VaultDeleteDialogClosed();
}

enum _VaultItem { finder, remove, delete }

/// The menu surface (pack 361, S2): `surface3`, 1px `line3`, radius 6,
/// 4 above and below the items, the 200-wide menu holding 198-wide items.
final _menuStyle = MenuStyle(
  backgroundColor: const WidgetStatePropertyAll(OmColors.surface3),
  surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
  shadowColor: const WidgetStatePropertyAll(OmColors.menuShadow),
  elevation: const WidgetStatePropertyAll(12),
  padding: const WidgetStatePropertyAll(
    EdgeInsets.symmetric(horizontal: 1, vertical: 4),
  ),
  shape: WidgetStatePropertyAll(
    RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(6),
      side: BorderSide(color: OmColors.line3),
    ),
  ),
);

/// An item: 198x32, padding 0/12, `surface4` while hovered or focused.
final _itemStyle = ButtonStyle(
  minimumSize: const WidgetStatePropertyAll(Size(198, 32)),
  fixedSize: const WidgetStatePropertyAll(Size(198, 32)),
  maximumSize: const WidgetStatePropertyAll(Size(198, 32)),
  padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 12)),
  visualDensity: VisualDensity.compact,
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  shape: const WidgetStatePropertyAll(RoundedRectangleBorder()),
  overlayColor: const WidgetStatePropertyAll(Colors.transparent),
  backgroundColor: WidgetStateProperty.resolveWith(
    (states) =>
        states.contains(WidgetState.hovered) ||
            states.contains(WidgetState.focused)
        ? OmColors.surface4
        : Colors.transparent,
  ),
);

/// A secondary click on [child] opens [vault]'s menu at the pointer
/// (Spec #357 Req 19, 21): `show in Finder` (`vault-menu-finder`, local
/// only), `remove from recents` (`vault-menu-remove`, not when [isOpen]),
/// `delete vault…` (`vault-menu-delete`, local only), then, when
/// [onManage] is given, a divider and `manage…` (`vault-menu-manage`). With
/// no items, a secondary click opens nothing.
///
/// A local folder that is no longer a vault has no `delete vault…`, as its
/// row has no delete button. The first item takes the focus when the menu
/// opens; the arrow keys move it and Enter or Space choose an item once
/// per key press.
///
/// [onOpenChanged] hears `true` when the menu opens and `false` when it
/// closes (not when the region is disposed with the menu open). A region
/// with no items never opens, so never calls it.
class VaultMenuRegion extends ConsumerStatefulWidget {
  const VaultMenuRegion({
    super.key,
    required this.vault,
    required this.isOpen,
    this.onManage,
    this.onOpenChanged,
    required this.child,
  });

  final VaultRef vault;
  final bool isOpen;
  final VoidCallback? onManage;
  final ValueChanged<bool>? onOpenChanged;
  final Widget child;

  @override
  ConsumerState<VaultMenuRegion> createState() => _VaultMenuRegionState();
}

class _VaultMenuRegionState extends ConsumerState<VaultMenuRegion> {
  final _controller = MenuController();
  final _firstItem = FocusNode(debugLabel: 'vault-menu-first');

  /// The vault items of the menu now open, fixed when it opens.
  List<_VaultItem> _shown = const [];

  @override
  void dispose() {
    _firstItem.dispose();
    super.dispose();
  }

  List<_VaultItem> _vaultItems() => switch (widget.vault) {
    LocalVaultRef(:final path) => [
      _VaultItem.finder,
      if (!widget.isOpen) _VaultItem.remove,
      if (VaultDb.isVault(path)) _VaultItem.delete,
    ],
    HostedVaultRef() => [if (!widget.isOpen) _VaultItem.remove],
  };

  void _open(TapUpDetails details) {
    final items = _vaultItems();
    if (items.isEmpty && widget.onManage == null) return;
    setState(() => _shown = items);
    _controller.open(position: details.localPosition);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _controller.isOpen) _firstItem.requestFocus();
    });
  }

  Future<void> _delete(String path) async {
    await confirmDeleteVault(context, path: path);
    if (mounted) const VaultDeleteDialogClosed().dispatch(context);
  }

  Widget _item({
    required String key,
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
    required bool first,
    bool danger = false,
  }) {
    final colour = danger ? OmColors.danger : OmColors.fg0;
    return Shortcuts(
      shortcuts: keyboardButtonShortcuts,
      child: MenuItemButton(
        key: Key(key),
        focusNode: first ? _firstItem : null,
        style: _itemStyle,
        onPressed: onPressed,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 14,
              color: danger ? OmColors.danger : OmColors.fg2,
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                label,
                style: OmType.sans(size: 13, color: colour),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _menuChildren() {
    final vault = widget.vault;
    final onManage = widget.onManage;
    final children = <Widget>[
      for (final item in _shown)
        switch (item) {
          _VaultItem.finder => _item(
            key: 'vault-menu-finder',
            icon: LucideIcons.folderSearch,
            label: 'show in Finder',
            first: item == _shown.first,
            onPressed: () {
              if (vault is LocalVaultRef) {
                showVaultInFinder(context, ref, vault.path);
              }
            },
          ),
          _VaultItem.remove => _item(
            key: 'vault-menu-remove',
            icon: LucideIcons.x,
            label: 'remove from recents',
            first: item == _shown.first,
            onPressed: () => forgetRecentVault(ref, vault),
          ),
          _VaultItem.delete => _item(
            key: 'vault-menu-delete',
            icon: LucideIcons.trash2,
            label: 'delete vault…',
            first: item == _shown.first,
            danger: true,
            onPressed: () {
              if (vault is LocalVaultRef) _delete(vault.path);
            },
          ),
        },
    ];
    if (onManage != null) {
      if (children.isNotEmpty) {
        children.add(Divider(height: 9, thickness: 1, color: OmColors.line2));
      }
      children.add(
        _item(
          key: 'vault-menu-manage',
          icon: LucideIcons.settings2,
          label: 'manage…',
          first: _shown.isEmpty,
          onPressed: onManage,
        ),
      );
    }
    return children;
  }

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      controller: _controller,
      style: _menuStyle,
      onOpen: () => widget.onOpenChanged?.call(true),
      onClose: () => widget.onOpenChanged?.call(false),
      menuChildren: _menuChildren(),
      child: GestureDetector(onSecondaryTapUp: _open, child: widget.child),
    );
  }
}
