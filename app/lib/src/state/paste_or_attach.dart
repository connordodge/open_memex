// WI #147 (Spec #123 A2: R8, R9, R11; ruling D11): the one Paste route.
// Every Paste entry of the note editor (Cmd+V, the right-click Paste in a
// single row and over a cross-row selection, the spelling menu's Paste and
// Source mode) goes through [pasteOrAttach].
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'attach_controller.dart';
import 'pasteboard_reader.dart';
import 'vault_access_state.dart';

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

/// Whether the vault open over [container] takes writes (R11); false with
/// no vault.
bool _writable(ProviderContainer container) =>
    container.read(vaultAccessProvider)?.canWrite ?? false;

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
}) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final clip = await container.read(pasteboardReaderProvider).read();
  if (!context.mounted) return PasteOutcome.nothing;
  final writable = _writable(container);
  if (writable && clip.files.isNotEmpty) {
    await container
        .read(attachControllerProvider)
        .attachPaths(context, clip.files);
    return PasteOutcome.files;
  }
  if (clip.hasText) {
    await pasteText();
    return PasteOutcome.text;
  }
  final png = clip.png;
  if (writable && png != null) {
    final controller = container.read(attachControllerProvider);
    await controller.attachBytes(context, png, controller.pastedImageName());
    return PasteOutcome.image;
  }
  return PasteOutcome.nothing;
}

/// How long [canPasteOrAttach] waits for the clipboard before it answers
/// without it, so a menu that asks always shows (#147 r3).
const pasteOfferWait = Duration(milliseconds: 100);

/// [future]'s value, or null when it fails.
Future<T?> _orNull<T>(Future<T> future) =>
    future.then<T?>((value) => value, onError: (Object _) => null);

/// Whether the note editor offers Paste (R8, R11): the clipboard holds file
/// URLs, text or an image. File URLs and images count only while the vault
/// can be written.
///
/// Answers within [pasteOfferWait], so the menu asking still shows its
/// other items: a pasteboard read that fails, or has not answered by then,
/// counts as no file URLs and no image, and Flutter's own text check
/// (`Clipboard.hasStrings`) decides, if it answers by then.
Future<bool> canPasteOrAttach(BuildContext context) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final expired = Completer<void>();
  final limit = Timer(pasteOfferWait, expired.complete);
  try {
    final clip = await Future.any([
      _orNull(container.read(pasteboardReaderProvider).read()),
      expired.future.then((_) => null),
    ]);
    if (clip != null) {
      if (clip.hasText) return true;
      return _writable(container) &&
          (clip.files.isNotEmpty || clip.png != null);
    }
    if (expired.isCompleted) return false;
    return await Future.any([
      _orNull(Clipboard.hasStrings()).then((text) => text ?? false),
      expired.future.then((_) => false),
    ]);
  } finally {
    limit.cancel();
  }
}

/// Whether a right click in the note editor shows [pasteMenuItems] in place
/// of a field's own menu (lead ruling Q3): the clipboard holds file URLs or
/// an image, and the vault can be written. With text only, or nothing, the
/// field's own menu stays.
Future<bool> pasteAttachesFiles(BuildContext context) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final clip = await container.read(pasteboardReaderProvider).read();
  return _writable(container) && (clip.files.isNotEmpty || clip.png != null);
}

/// The items [field]'s own context menu shows on this platform (its
/// labels, order and enabled rules, `EditableTextState.contextMenuButtonItems`)
/// with Paste enabled: Paste invokes the field's `PasteTextIntent`, so it
/// goes through the editor's override and [pasteOrAttach] (Q3). [hide]
/// runs before any item's action.
List<ContextMenuButtonItem> pasteMenuItems(
  EditableTextState field, {
  required VoidCallback hide,
}) {
  const cause = SelectionChangedCause.toolbar;
  VoidCallback? item(bool enabled, void Function() run) => enabled
      ? () {
          hide();
          run();
        }
      : null;
  return EditableText.getEditableButtonItems(
    clipboardStatus: ClipboardStatus.pasteable,
    onCopy: item(field.copyEnabled, () => field.copySelection(cause)),
    onCut: item(field.cutEnabled, () => field.cutSelection(cause)),
    onPaste: item(true, () {
      final context = field.widget.focusNode.context;
      if (context != null && context.mounted) {
        Actions.maybeInvoke(context, const PasteTextIntent(cause));
      }
    }),
    onSelectAll: item(field.selectAllEnabled, () => field.selectAll(cause)),
    onLookUp: item(field.lookUpEnabled, () => field.lookUpSelection(cause)),
    onSearchWeb: item(
      field.searchWebEnabled,
      () => field.searchWebForSelection(cause),
    ),
    onShare: item(field.shareEnabled, () => field.shareSelection(cause)),
    onLiveTextInput: null,
  );
}
