// WI #146 (Spec #123 A4, R9-R14; L2, L14, L16): the attach action every
// entry point shares ("Attach file…", and #147's drop and paste).
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The app's [AttachController].
final attachControllerProvider = Provider<AttachController>(
  (ref) => AttachController(ref),
);

/// Runs attach actions on the note open in the editor (R9-R14). One action
/// stores each file through `attachmentsProvider`, then inserts every
/// stored file's markdown line once, as one edit and one undo step
/// (`planAttachmentInsert`), in live preview and in Source mode. Toasts go
/// to [BuildContext]'s `ScaffoldMessenger`.
class AttachController {
  AttachController(this.ref);

  final Ref ref;

  /// Attaches the files at [paths], in order, to the open note. The group
  /// goes after body line [anchorLine] (0-based, the note body's `\n`
  /// lines), or after the caret line when [anchorLine] is null.
  Future<void> attachPaths(
    BuildContext context,
    List<String> paths, {
    int? anchorLine,
  }) async {}

  /// Attaches [bytes] stored under [name] (a pasted image, R8/R9) to the
  /// open note, at [anchorLine] or the caret line as [attachPaths] does.
  Future<void> attachBytes(
    BuildContext context,
    Uint8List bytes,
    String name, {
    int? anchorLine,
  }) async {}

  /// "Attach file…" (R10): opens the file picker with multiple selection
  /// and attaches the picked files at the caret line, or at the end of the
  /// person section when the editor has no caret. Cancelling changes
  /// nothing. While an action runs, another start opens no picker.
  Future<void> attachFromPicker(BuildContext context) async {}

  /// The R9 name of an image pasted now: `Pasted image YYYY-MM-DD
  /// HH.MM.SS.png` in local time, from `clockProvider`.
  String pastedImageName() => '';
}
