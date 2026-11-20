// WI #147 (Spec #123 A2: R8, R9, R11; ruling D11): the one Paste route.
// Every Paste entry of the note editor (Cmd+V, the right-click Paste in a
// single row and over a cross-row selection, the spelling menu's Paste and
// Source mode) goes through [pasteOrAttach].
import 'dart:async';

import 'package:flutter/widgets.dart';

/// What one Paste did, in R8's order.
enum PasteOutcome {
  /// File URLs on the clipboard went to the attach action.
  files,

  /// The clipboard's plain text was pasted as before (`pasteText`).
  text,

  /// An image on the clipboard went to the attach action as a PNG named
  /// per R9.
  image,

  /// Nothing was pasted or attached.
  nothing,
}

/// Routes one Paste in the note editor (Spec #123 R8, D11). Reads
/// `pasteboardReaderProvider` and, in this order:
/// - file URLs: `AttachController.attachPaths` with them, in clipboard
///   order, at the caret line; the file-name text Finder also puts on the
///   clipboard is not pasted;
/// - plain text: [pasteText], the paste the entry did before (the field's
///   own paste, or a cross-row `replaceRange`);
/// - an image: `AttachController.attachBytes` with its PNG bytes, named by
///   `AttachController.pastedImageName`, at the caret line;
/// - anything else: nothing.
///
/// While the vault can't be written (`VaultAccess.canWrite` false, or no
/// vault; R11) files and images attach nothing, and text still pastes
/// through [pasteText].
Future<PasteOutcome> pasteOrAttach(
  BuildContext context, {
  required FutureOr<void> Function() pasteText,
}) => Future.value(PasteOutcome.nothing);

/// Whether the note editor offers Paste (R8, R11): the clipboard holds file
/// URLs, text or an image. File URLs and images count only while the vault
/// can be written.
Future<bool> canPasteOrAttach(BuildContext context) => Future.value(false);
