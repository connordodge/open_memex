// WI #146 (Spec #123 A4, R9-R14; L2, L14, L16): the attach action every
// entry point shares ("Attach file…", and #147's drop and paste).
import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../editor/attachment_insert.dart';
import '../vault_access/attachments_access.dart';
import 'attachments_state.dart';
import 'clock.dart';
import 'editor_controller.dart';
import 'vault_access_state.dart';
import 'vault_state.dart';

/// The note editor an attach action works on, as the editor showing a note
/// registers it in [attachEditorProvider] (`NoteAttachHost`, beside the
/// body like Find in note's host). #147's drop and paste reach it through
/// [AttachController] too.
abstract interface class AttachEditor {
  /// One note shown in one editor: a new object when the editor shows
  /// another note. An action whose session is gone by the time its files
  /// are stored inserts nothing (R13).
  Object get session;

  /// The shown note's title, for the closed-note toast.
  String get noteTitle;

  /// The 0-based body line (lines split at `\n`) of the editor's caret,
  /// remembered while focus is elsewhere (the ⋯ menu, the palette). Null
  /// while the note has had no caret since it was shown.
  int? get caretLine;

  /// Inserts [lines] where `planAttachmentInsert` puts them for
  /// [anchorLine] (null: the end of the person section), as one edit and
  /// one undo step, with the caret where the plan puts it. False when the
  /// editor could not take the edit.
  bool insert(List<String> lines, int? anchorLine);
}

/// The editor showing a note, or null while none does (R11: "Attach file…"
/// exists only then).
final attachEditorProvider = StateProvider<AttachEditor?>((_) => null);

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

  /// True while an "Attach file…" action runs, from its picker to its
  /// insert: the busy guard.
  bool _picking = false;

  /// Whether the open vault takes writes (`VaultAccess.canWrite`, R11).
  /// False with no vault: every entry point fails closed.
  bool get _canWrite => ref.read(vaultAccessProvider)?.canWrite ?? false;

  /// Attaches the files at [paths], in order, to the open note. The group
  /// goes after body line [anchorLine] (0-based, the note body's `\n`
  /// lines), or after the caret line when [anchorLine] is null. Does
  /// nothing while the vault can't be written (R11).
  Future<void> attachPaths(
    BuildContext context,
    List<String> paths, {
    int? anchorLine,
  }) async {
    final editor = ref.read(attachEditorProvider);
    final access = ref.read(attachmentsProvider);
    if (editor == null || access == null || paths.isEmpty || !_canWrite) {
      return;
    }
    final vault = ref.read(currentVaultProvider);
    final anchor = _Anchor(ref, anchorLine ?? editor.caretLine);
    await _run(ScaffoldMessenger.maybeOf(context), editor, vault, anchor, [
      for (final path in paths)
        (name: p.basename(path), store: () => access.add(path, null)),
    ]);
  }

  /// Attaches [bytes] stored under [name] (a pasted image, R8/R9) to the
  /// open note, at [anchorLine] or the caret line as [attachPaths] does.
  /// Does nothing while the vault can't be written (R11).
  Future<void> attachBytes(
    BuildContext context,
    Uint8List bytes,
    String name, {
    int? anchorLine,
  }) async {
    final editor = ref.read(attachEditorProvider);
    final access = ref.read(attachmentsProvider);
    if (editor == null || access == null || !_canWrite) return;
    final vault = ref.read(currentVaultProvider);
    final anchor = _Anchor(ref, anchorLine ?? editor.caretLine);
    await _run(ScaffoldMessenger.maybeOf(context), editor, vault, anchor, [
      (name: name, store: () => access.addBytes(bytes, name)),
    ]);
  }

  /// "Attach file…" (R10): opens the file picker with multiple selection
  /// and attaches the picked files at the caret line, or at the end of the
  /// person section when the editor has no caret. Cancelling changes
  /// nothing. While an action runs, another start opens no picker. Does
  /// nothing while the vault can't be written (R11).
  Future<void> attachFromPicker(BuildContext context) async {
    if (_picking) return;
    final editor = ref.read(attachEditorProvider);
    final access = ref.read(attachmentsProvider);
    if (editor == null || access == null || !_canWrite) return;
    _picking = true;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final vault = ref.read(currentVaultProvider);
    final anchor = _Anchor(ref, editor.caretLine);
    try {
      final picked = await FilePicker.platform.pickFiles(allowMultiple: true);
      final paths = picked?.paths.whereType<String>().toList() ?? const [];
      if (paths.isEmpty) return;
      await _run(messenger, editor, vault, anchor, [
        for (final path in paths)
          (name: p.basename(path), store: () => access.add(path, null)),
      ]);
    } finally {
      anchor.close();
      _picking = false;
    }
  }

  /// The R9 name of an image pasted now: `Pasted image YYYY-MM-DD
  /// HH.MM.SS.png` in local time, from `clockProvider`.
  String pastedImageName() {
    final t = ref.read(clockProvider).now().toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return 'Pasted image ${t.year.toString().padLeft(4, '0')}-'
        '${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}.${two(t.minute)}.${two(t.second)}.png';
  }

  /// One action (R13, R14): stores [files] in order under the Attaching
  /// toast, then inserts the stored files' lines once into [editor]'s note
  /// at [anchor], or shows the closed-note toast when that note is no
  /// longer shown: another note, no note, or another vault than [vault]
  /// (the vault the files went to; leaving it closes the note, and a
  /// virtual Today note has the same id in every vault). Failed files get
  /// one failure toast.
  Future<void> _run(
    ScaffoldMessengerState? messenger,
    AttachEditor editor,
    VaultRef? vault,
    _Anchor anchor,
    List<_File> files,
  ) async {
    final session = editor.session;
    final title = editor.noteTitle;
    final toast = _AttachingToast.show(messenger, files.length);
    final stored = <String>[];
    final failed = <({String name, String message})>[];
    try {
      for (final file in files) {
        final AttachmentAddResult result;
        try {
          result = await file.store();
        } on Exception catch (e) {
          failed.add((name: file.name, message: '$e'));
          continue;
        }
        switch (result) {
          case AttachmentAdded(:final attachment):
            stored.add(attachment.markdown);
          case AttachmentAddFailed(:final message):
            failed.add((name: file.name, message: message));
        }
      }
    } finally {
      toast.close();
      anchor.close();
    }
    if (stored.isNotEmpty) {
      final now = ref.read(attachEditorProvider);
      final n = stored.length;
      final files = n == 1 ? 'file' : 'files';
      if (now == null ||
          !identical(now.session, session) ||
          ref.read(currentVaultProvider) != vault) {
        _toast(
          messenger,
          'Attached $n $files, but $title was closed; '
          'drop or pick them again to add them.',
        );
      } else if (!now.insert(
        stored,
        anchor.lost ? now.caretLine : anchor.line,
      )) {
        // The note is still open but its editor couldn't take the edit.
        _toast(
          messenger,
          "Attached $n $files, but couldn't add them to $title; "
          'drop or pick them again to add them.',
        );
      }
    }
    if (failed.isNotEmpty) {
      final first = failed.first;
      _toast(
        messenger,
        failed.length == 1
            ? "Couldn't attach ${first.name}: ${first.message}"
            : "Couldn't attach ${failed.length} files: ${first.message}",
      );
    }
  }
}

/// One file of an action: its name for the failure toast, and its store.
typedef _File = ({String name, Future<AttachmentAddResult> Function() store});

/// Shows [message] as a toast (queued after any toast showing).
void _toast(ScaffoldMessengerState? messenger, String message) =>
    messenger?.showSnackBar(
      SnackBar(
        content: Text(message),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      ),
    );

/// An action's anchor line carried through the edits made while it runs
/// (R13, `carryAttachmentAnchor`), from the editor's markdown.
class _Anchor {
  _Anchor(Ref ref, this.line) {
    _body = ref.read(editorControllerProvider).contentMd;
    _sub = ref.listen<String>(
      editorControllerProvider.select((s) => s.contentMd),
      (_, next) {
        final at = line;
        if (at != null) {
          line = carryAttachmentAnchor(_body, next, at);
          if (line == null) lost = true;
        }
        _body = next;
      },
    );
  }

  /// The anchor line now; null with no caret at the start, or once [lost].
  int? line;

  /// True once an edit removed the anchor line: the group then goes after
  /// the caret line.
  bool lost = false;

  late String _body;
  late final ProviderSubscription<String> _sub;
  bool _closed = false;

  /// Stops following edits; a second call does nothing.
  void close() {
    if (_closed) return;
    _closed = true;
    _sub.close();
  }
}

/// The `Attaching N files…` toast (R14): shown while an action stores its
/// files, however long that takes, and removed when the action ends.
class _AttachingToast {
  _AttachingToast._(this.messenger);

  final ScaffoldMessengerState? messenger;

  /// The toast's content has been built: it is the current toast.
  bool shown = false;

  /// The action ended: the toast must go.
  bool done = false;

  /// The toast has gone.
  bool closed = false;

  static _AttachingToast show(ScaffoldMessengerState? messenger, int count) {
    final toast = _AttachingToast._(messenger);
    if (messenger == null) return toast;
    final text = count == 1 ? 'Attaching 1 file…' : 'Attaching $count files…';
    messenger
        .showSnackBar(
          SnackBar(
            content: _AttachingText(toast: toast, text: text),
            // Until the action ends (close).
            duration: const Duration(days: 1),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          ),
        )
        .closed
        .then((_) => toast.closed = true);
    return toast;
  }

  /// Ends the toast: removed now when it shows, else as soon as it does
  /// (it still waits behind another toast).
  void close() {
    done = true;
    if (shown && !closed) messenger?.removeCurrentSnackBar();
  }
}

class _AttachingText extends StatefulWidget {
  const _AttachingText({required this.toast, required this.text});

  final _AttachingToast toast;
  final String text;

  @override
  State<_AttachingText> createState() => _AttachingTextState();
}

class _AttachingTextState extends State<_AttachingText> {
  @override
  void initState() {
    super.initState();
    final toast = widget.toast..shown = true;
    if (toast.done) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!toast.closed) toast.messenger?.removeCurrentSnackBar();
      });
    }
  }

  @override
  Widget build(BuildContext context) => Text(widget.text);
}
