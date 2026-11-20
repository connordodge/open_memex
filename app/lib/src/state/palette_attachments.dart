// WI #148 (Spec #123 R46-R48, A3): the Command palette's Attachments group,
// fed by the same `search` run as Passages, and its chooser.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../vault_access/search_access.dart';
import 'command_palette_state.dart';

/// The Attachments row's notes line for [notes] (Spec #123 R47):
/// `in <t1>, <t2>, <t3>`, then ` +N` for the notes past the first three.
String attachmentNotesLine(List<SearchAttachmentNote> notes) => '';

/// Chooses an Attachments row (D10): opens its path through the open
/// vault's attachments domain (`attachmentsProvider`), which downloads a
/// hosted file first and reveals an executable instead (R33).
PaletteChooser<AttachmentItem> paletteAttachmentChooser(Ref ref) =>
    (item, {required newTab}) {};
