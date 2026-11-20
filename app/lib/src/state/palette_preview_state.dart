// WI #78 (56-A4, Spec #59 req 29): the Command palette's preview source.
import 'dart:async';

import 'package:flutter/widgets.dart' show WidgetsBinding;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../db.dart' show CanvasDetailRow;
import 'clock.dart';
import 'command_palette_state.dart';
import 'vault_access_state.dart';
import 'vault_state.dart';

/// The narrowest window that shows the preview pane (Spec #59 req 9).
const palettePreviewMinWidth = 950.0;

/// How long a selection rests before its preview is read (req 29).
const palettePreviewRest = Duration(milliseconds: 120);

/// The window's logical width now. Read at every selection, so a window
/// that widens while the palette is open previews the next selection.
final paletteWindowWidthProvider = Provider<double Function()>(
  (ref) => () {
    final dispatcher = WidgetsBinding.instance.platformDispatcher;
    final view = dispatcher.implicitView ?? dispatcher.views.firstOrNull;
    if (view == null) return 0;
    return view.physicalSize.width / view.devicePixelRatio;
  },
);

/// A note or daily note preview with what its eyebrow needs: the row's
/// [kind] and the note's `updatedAt` (ms epoch).
class PalettePreviewNote extends PreviewNote {
  const PalettePreviewNote({
    required super.noteId,
    required super.title,
    required super.contentMd,
    required this.kind,
    required this.updatedAt,
  });

  final PaletteNoteKind kind;
  final int updatedAt;
}

/// Fills `palettePreviewProvider` (#76's seam): the selected row's preview,
/// read once the selection has rested [palettePreviewRest]; nothing under
/// [palettePreviewMinWidth].
///
/// - A command shows its description at once, with no read.
/// - A note, daily note or passage reads `NotesAccess.getNote`; a canvas
///   `CanvasAccess.getCanvasDetail`. [PreviewLoading] shows from the
///   selection until the read answers, [PreviewFailed] when it throws or
///   finds nothing.
/// - Only the latest selection's read shows. It never writes.
class PalettePreviewReader extends PalettePreviewNotifier {
  Timer? _timer;

  /// Bumped by every [select] and [close]: an older read never shows.
  var _seq = 0;

  @override
  PreviewView build() {
    _timer?.cancel();
    _timer = null;
    _seq++;
    ref.onDispose(() {
      _timer?.cancel();
      _timer = null;
      _seq++;
    });
    return const PreviewNone();
  }

  bool get _wide =>
      ref.read(paletteWindowWidthProvider)() >= palettePreviewMinWidth;

  @override
  void select(PaletteItem? item) {
    _timer?.cancel();
    _timer = null;
    final seq = ++_seq;
    // An Attachments row has no preview: none at once, with no `loading…`.
    if (item == null || item is AttachmentItem || !_wide) {
      state = const PreviewNone();
      return;
    }
    if (item is CommandItem) {
      state = _command(item);
      return;
    }
    state = const PreviewLoading();
    _timer = ref.read(clockProvider).after(palettePreviewRest, () {
      _timer = null;
      if (seq != _seq) return;
      if (!_wide) {
        state = const PreviewNone();
        return;
      }
      _read(item, seq);
    });
  }

  @override
  void close() {
    _timer?.cancel();
    _timer = null;
    _seq++;
  }

  PreviewCommand _command(CommandItem item) {
    final vault = ref.read(currentVaultProvider);
    final now = ref.read(clockProvider).now();
    final today =
        '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
    return PreviewCommand(
      item.command,
      label: item.label,
      description: item.command.description(
        vaultName: switch (vault) {
          LocalVaultRef(:final path) => p.basename(path),
          HostedVaultRef(:final vaultName) => vaultName,
          null => '',
        },
        today: today,
        rightPanelOpen: ref.read(rightPanelOpenProvider),
      ),
    );
  }

  Future<void> _read(PaletteItem item, int seq) async {
    final access = ref.read(vaultAccessProvider);
    PreviewView view;
    try {
      if (access == null) throw StateError('no vault open');
      view = switch (item) {
        NoteItem(kind: PaletteNoteKind.canvas, :final noteId) => await _canvas(
          access.canvas.getCanvasDetail(noteId),
        ),
        NoteItem(:final noteId, :final kind, :final title) => await () async {
          final note = await access.notes.getNote(noteId);
          if (note == null) return const PreviewFailed();
          return PalettePreviewNote(
            noteId: noteId,
            title: title,
            contentMd: note.contentMd,
            kind: kind,
            updatedAt: note.updatedAt,
          );
        }(),
        PassageItem(:final hit) => await () async {
          final note = await access.notes.getNote(hit.noteId);
          if (note == null) return const PreviewFailed();
          return PreviewPassage(hit, contentMd: note.contentMd);
        }(),
        CommandItem() => _command(item),
        AttachmentItem() => const PreviewNone(),
      };
    } catch (_) {
      view = const PreviewFailed();
    }
    if (seq == _seq) state = view;
  }

  static Future<PreviewView> _canvas(Future<CanvasDetailRow?> read) async {
    final detail = await read;
    if (detail == null) return const PreviewFailed();
    return PreviewCanvas(
      canvasId: detail.canvasId,
      title: detail.title,
      cardCount: detail.nodes.length,
      cardTitles: [for (final n in detail.nodes.take(8)) n.noteTitle],
    );
  }
}
