import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../db.dart';
import '../../theme/colors.dart';
import '../atoms.dart';

/// The editor toolbar's ellipsis button (Key `note-menu-button`). It opens
/// [NoteMenu] for the open note, and is disabled when no note is open.
class NoteMenuButton extends StatelessWidget {
  const NoteMenuButton({super.key, required this.note});
  final Note? note;

  @override
  Widget build(BuildContext context) {
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
      menuChildren: [if (note != null) NoteMenu(note: note)],
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
/// Empty for now: later work adds the items.
class NoteMenu extends StatelessWidget {
  const NoteMenu({super.key, required this.note});
  final Note note;

  @override
  Widget build(BuildContext context) {
    return const Column(
      key: Key('note-menu'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [],
    );
  }
}
