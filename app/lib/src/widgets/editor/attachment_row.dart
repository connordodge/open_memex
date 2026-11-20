// The attachment row presenter (Spec #123 V3, WI #143: R23-R26, R28,
// R30-R33, R35-R38, R42; rulings D1, D5-D8, D10, D22): an editor row whose
// line is exactly one attachment reference shows an image row or a file
// card in place of its text, on the row-kind seam (`row_kinds.dart`).
//
// The image and card widgets ([AttachmentBlock], [AttachmentImageBox],
// [AttachmentFileCard], [AttachmentNotice]) are public so excerpt cards
// (#144) show attachments the same way.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../editor/attachment_ref.dart';
import '../../state/attachments_state.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../vault_access/attachments_access.dart';
import '../../vault_access/local/attachments.dart';
import 'line_boxes.dart';
import 'live_preview_styles.dart' show livePreviewStrut;
import 'row_kinds.dart';
import 'segment_view.dart';
import 'text_segment.dart' show editorBodyStyle;

/// The tallest an image row shows (R24), in logical pixels.
const double attachmentImageMaxHeight = 480;

/// An image of more pixels than this shows as a file card (R24).
const int attachmentImageMaxPixels = 100000000;

/// An image file of more bytes than this (30 MB, 1024-based like every size
/// the app shows) shows as a file card (R24).
const int attachmentImageMaxBytes = 30 * 1024 * 1024;

/// The most bytes read from a local image file for its header (D7).
const int _headerBytes = 256 * 1024;

/// The `Reveal in Finder` semantics action of a block (R37, R41).
const _revealAction = CustomSemanticsAction(label: 'Reveal in Finder');

/// Shows why opening or revealing the attachment [name] failed (Spec #123
/// R42, ruling D22): for [AttachmentLookupFailure.offline] a SnackBar
/// through the nearest `ScaffoldMessenger` (none without one) reading
/// `Couldn't open <name>: the vault server can't be reached.`; nothing for
/// any other failure (a missing card is inert, R35).
void showAttachmentOpenFailure(
  BuildContext context,
  String name,
  AttachmentLookupFailure failure,
) {
  if (failure != AttachmentLookupFailure.offline) return;
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
    SnackBar(
      content: Text("Couldn't open $name: the vault server can't be reached."),
    ),
  );
}

/// The size an image of [natural] logical pixels shows at in a column
/// [maxWidth] wide (R24): scaled down, never up, to fit the column and
/// [attachmentImageMaxHeight], aspect kept. An unbounded [maxWidth] fits
/// the height cap only.
Size attachmentImageSize(Size natural, double maxWidth) {
  if (natural.width <= 0 || natural.height <= 0) return Size.zero;
  final scale = math.min(
    1.0,
    math.min(
      maxWidth.isFinite ? maxWidth / natural.width : double.infinity,
      attachmentImageMaxHeight / natural.height,
    ),
  );
  return Size(natural.width * scale, natural.height * scale);
}

/// The pixel size a PNG, GIF, JPEG or WebP file's [header] (its first bytes)
/// declares, or null when it is none of those or the header is cut short.
Size? attachmentImageDims(List<int> header) {
  final b = header;
  final n = b.length;
  int be16(int i) => (b[i] << 8) | b[i + 1];
  int be32(int i) => (be16(i) << 16) | be16(i + 2);
  int le16(int i) => b[i] | (b[i + 1] << 8);
  int le24(int i) => le16(i) | (b[i + 2] << 16);
  bool ascii(int at, String s) {
    if (at + s.length > n) return false;
    for (var i = 0; i < s.length; i++) {
      if (b[at + i] != s.codeUnitAt(i)) return false;
    }
    return true;
  }

  Size? dims(int w, int h) =>
      w > 0 && h > 0 ? Size(w.toDouble(), h.toDouble()) : null;

  if (n >= 24 && b[0] == 0x89 && ascii(1, 'PNG') && ascii(12, 'IHDR')) {
    return dims(be32(16), be32(20));
  }
  if (n >= 10 && (ascii(0, 'GIF87a') || ascii(0, 'GIF89a'))) {
    return dims(le16(6), le16(8));
  }
  if (n >= 4 && b[0] == 0xFF && b[1] == 0xD8) {
    var i = 2;
    while (i + 3 < n) {
      if (b[i] != 0xFF) return null;
      final marker = b[i + 1];
      if (marker == 0xFF) {
        i++;
        continue;
      }
      if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD8)) {
        i += 2;
        continue;
      }
      if (marker == 0xD9 || marker == 0xDA) return null;
      final length = be16(i + 2);
      if (length < 2) return null;
      final frame =
          marker >= 0xC0 &&
          marker <= 0xCF &&
          marker != 0xC4 &&
          marker != 0xC8 &&
          marker != 0xCC;
      if (frame) {
        if (i + 9 > n) return null;
        return dims(be16(i + 7), be16(i + 5));
      }
      i += 2 + length;
    }
    return null;
  }
  if (n >= 30 && ascii(0, 'RIFF') && ascii(8, 'WEBP')) {
    if (ascii(12, 'VP8 ')) return dims(le16(26) & 0x3FFF, le16(28) & 0x3FFF);
    if (ascii(12, 'VP8L') && b[20] == 0x2F) {
      final bits = le24(21) | (b[24] << 24);
      return dims((bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1);
    }
    if (ascii(12, 'VP8X')) return dims(le24(24) + 1, le24(27) + 1);
  }
  return null;
}

/// Whether an image of [dims] and [bytes] is over a cap and shows as a file
/// card instead (R24): more than [attachmentImageMaxPixels] pixels or more
/// than [attachmentImageMaxBytes] bytes.
bool attachmentImageOverCap({Size? dims, int? bytes}) =>
    (dims != null && dims.width * dims.height > attachmentImageMaxPixels) ||
    (bytes != null && bytes > attachmentImageMaxBytes);

/// The text shown for the attachment of [markdown], a whole attachment
/// reference [ref] (R38): its bracketed text with backslash escapes
/// removed, or the stored name when the brackets are empty.
String attachmentShownName(String markdown, AttachmentRef ref) {
  final out = StringBuffer();
  var i = ref.kind == AttachmentRefKind.image ? 2 : 1;
  while (i < markdown.length) {
    final unit = markdown.codeUnitAt(i);
    if (unit == 0x5D) break;
    if (unit == 0x5C && i + 1 < markdown.length) {
      final next = markdown.codeUnitAt(i + 1);
      if (_isAsciiPunctuation(next)) {
        out.writeCharCode(next);
        i += 2;
        continue;
      }
    }
    out.writeCharCode(unit);
    i++;
  }
  final shown = out.toString();
  return shown.isEmpty ? ref.target.name : shown;
}

bool _isAsciiPunctuation(int u) =>
    (u >= 0x21 && u <= 0x2F) ||
    (u >= 0x3A && u <= 0x40) ||
    (u >= 0x5B && u <= 0x60) ||
    (u >= 0x7B && u <= 0x7E);

/// The lucide file-type icon of the attachment [name], by its type group.
IconData attachmentTypeIcon(String name) {
  if (isExecutableName(name)) return LucideIcons.fileTerminal;
  final dot = name.lastIndexOf('.');
  final ext = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  return switch (ext) {
    'png' ||
    'jpg' ||
    'jpeg' ||
    'gif' ||
    'webp' ||
    'heic' ||
    'heif' ||
    'tif' ||
    'tiff' ||
    'bmp' ||
    'svg' ||
    'avif' => LucideIcons.fileImage,
    'mp4' ||
    'mov' ||
    'm4v' ||
    'avi' ||
    'mkv' ||
    'webm' => LucideIcons.fileVideo,
    'mp3' ||
    'm4a' ||
    'wav' ||
    'aac' ||
    'flac' ||
    'ogg' ||
    'aif' ||
    'aiff' => LucideIcons.fileAudio,
    'zip' ||
    'tar' ||
    'gz' ||
    'tgz' ||
    'bz2' ||
    'xz' ||
    '7z' ||
    'rar' => LucideIcons.fileArchive,
    'csv' ||
    'tsv' ||
    'xls' ||
    'xlsx' ||
    'numbers' ||
    'ods' => LucideIcons.fileSpreadsheet,
    'json' ||
    'js' ||
    'ts' ||
    'dart' ||
    'rs' ||
    'go' ||
    'c' ||
    'h' ||
    'cpp' ||
    'java' ||
    'kt' ||
    'swift' ||
    'html' ||
    'css' ||
    'xml' ||
    'yaml' ||
    'yml' ||
    'toml' => LucideIcons.fileCode,
    'pdf' ||
    'txt' ||
    'md' ||
    'rtf' ||
    'doc' ||
    'docx' ||
    'pages' ||
    'odt' ||
    'epub' => LucideIcons.fileText,
    _ => LucideIcons.file,
  };
}

/// What this session learnt about one attachment path (D7): content
/// addressed, so it never changes.
final class _Known {
  /// The file's size in bytes, once known.
  int? size;

  /// An image's declared pixel size, once known.
  Size? dims;

  /// An image that shows as a file card: over a cap, without a header, or
  /// undecodable.
  bool card = false;
}

/// Per decoded path, for the session (D7). It holds only what the file's
/// content says (the path is content addressed), never whether a vault has
/// the file: every probe asks its vault that (R35).
final Map<String, _Known> _session = {};

/// Memo of [_referenceOf]'s last answer: presenters ask on every paint.
String? _memoText;
AttachmentRef? _memoRef;

/// The attachment reference [rowText] is, leading and trailing whitespace
/// aside, or null.
AttachmentRef? _referenceOf(String rowText) {
  if (identical(rowText, _memoText) || rowText == _memoText) return _memoRef;
  _memoText = rowText;
  return _memoRef = parseAttachmentReference(rowText.trim());
}

/// The presenter of `RowKind.attachment` rows (WI #143, rulings D5-D8).
///
/// A row whose text is exactly one attachment reference shows its block
/// (Key `editor-attachment-<segment>-<index>`, under
/// [PresentedRow.blockKey]): an [AttachmentBlock], an image row for an
/// image-form inline image name (R23, R31), a file card for any other
/// reference (R32). Its text slot sits directly above the block, mounted
/// always: offstage while the text is hidden, on stage while the segment
/// has focus and the row holds the selection (or Find reveals it), so the
/// markdown shows as an editable line above the block (R25). The block's
/// size never depends on that (D7), and its subtree stays mounted, so
/// revealing never re-decodes (D6). A row whose text is no reference
/// shows its text slot alone, like a prose row.
///
/// The block owns presses inside its box (D5): see [AttachmentBlock].
class AttachmentRowPresenter extends RowKindPresenter {
  const AttachmentRowPresenter();

  @override
  Widget build(BuildContext context, PresentedRow row, RowTextSlot textSlot) {
    final controller = row.controller;
    // The reference and shown name come from the text at each notify, not
    // from this build: the host need not rebuild the row for a text edit.
    // The block widget is kept while the text is unchanged, so a selection
    // or reveal change rebuilds only the text slot.
    String? blockText;
    Widget? block;
    return ListenableBuilder(
      listenable: Listenable.merge([controller, controller.revealGate]),
      builder: (_, _) {
        final text = controller.text;
        final ref = _referenceOf(text);
        if (ref == null) {
          blockText = null;
          block = null;
        } else if (block == null || text != blockText) {
          blockText = text;
          block = Align(
            alignment: AlignmentDirectional.topStart,
            child: KeyedSubtree(
              key: row.blockKey,
              child: KeyedSubtree(
                key: ValueKey('editor-attachment-${row.segment}-${row.index}'),
                child: AttachmentBlock(
                  reference: ref,
                  name: attachmentShownName(text.trim(), ref),
                  onPlaceCaret: () => _placeCaret(context, row),
                ),
              ),
            ),
          );
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            textSlot(offstage: textHidden(row)),
            ?block,
          ],
        );
      },
    );
  }

  /// Puts the caret at the start of [row]'s text and focuses the row,
  /// through its rows host (D5).
  static void _placeCaret(BuildContext context, PresentedRow row) {
    if (!context.mounted) return;
    final host = context.findAncestorStateOfType<SegmentViewState>();
    final start = host?.rowTextStartOf(row.controller);
    if (host == null || start == null) return;
    host.select(TextSelection.collapsed(offset: start));
    host.rowFocusNode(row.index)?.requestFocus();
  }

  /// The block shows in place of the text: the row's text is a reference,
  /// and neither the selection (with the segment focused) nor Find's reveal
  /// range is on it.
  @override
  bool textHidden(PresentedRow row) {
    final controller = row.controller;
    final revealed =
        (controller.revealGate.value && controller.selection.isValid) ||
        controller.findDecoration?.value?.revealRange != null;
    return !revealed && _referenceOf(controller.text) != null;
  }

  @override
  LineBoxSource? blockBoxes(PresentedRow row) {
    if (!textHidden(row)) return null;
    final box = _blockBox(row);
    if (box == null) return null;
    return BlockLineBoxes(box, textLength: row.controller.text.length);
  }

  /// Presses inside the block's box are the block's (D5); the pointer layer
  /// keeps the revealed text line and the area beside the block.
  @override
  bool ownsPress(PresentedRow row, Offset position) {
    final box = _blockBox(row);
    return box != null &&
        _referenceOf(row.controller.text) != null &&
        (Offset.zero & box.size).contains(box.globalToLocal(position));
  }

  /// The block's laid-out box, or null.
  static RenderBox? _blockBox(PresentedRow row) {
    final box = row.blockKey?.currentContext?.findRenderObject();
    return box is RenderBox && box.attached && box.hasSize ? box : null;
  }
}

/// One attachment's block (WI #143): an image row for an image-form
/// reference with an inline image name (R23, R31), a file card otherwise
/// (R32), read through the open vault's attachments domain
/// (`attachmentsProvider`).
///
/// - Image: [AttachmentImageBox] at its final size from its header (D7). A
///   local file's header is read at first layout (a bounded read), a hosted
///   one's from its bytes, with a one-line reserve until they arrive; known
///   sizes are kept per path for the session. Over 100 MP or 30 MB, without
///   a header, or undecodable, it shows as a file card (R24, R28). Missing,
///   offline or unavailable, an [AttachmentNotice] (R28, R42).
/// - File card: [AttachmentFileCard] with the file's type and size, `—`
///   while a hosted size is unknown; `File not found · <name>` when missing.
///
/// Presses (D5): a tap on an image or notice calls [onPlaceCaret]; a double
/// click on an image and a click on a card open it; a secondary click on
/// either offers `Open` and `Reveal in Finder`. A missing card is inert
/// (R35). Open and reveal go through the domain only (D10); an offline
/// failure shows [showAttachmentOpenFailure]'s toast.
class AttachmentBlock extends ConsumerStatefulWidget {
  const AttachmentBlock({
    super.key,
    required this.reference,
    required this.name,
    this.onPlaceCaret,
  });

  /// The reference the block shows.
  final AttachmentRef reference;

  /// The shown name (the bracketed text, R38).
  final String name;

  /// Puts the caret on the block's line; null for none.
  final VoidCallback? onPlaceCaret;

  @override
  ConsumerState<AttachmentBlock> createState() => _AttachmentBlockState();
}

class _AttachmentBlockState extends ConsumerState<AttachmentBlock> {
  final _menu = ContextMenuController();

  /// The domain the block was probed through.
  AttachmentsAccess? _access;
  bool _probed = false;

  /// Bumped by every probe: answers of an older one are dropped.
  int _generation = 0;

  /// Why the file could not be found or read; null while none failed.
  AttachmentLookupFailure? _failure;

  /// The image's bytes, once read.
  MemoryImage? _image;

  String get _path => widget.reference.target.path;

  bool get _imageForm =>
      widget.reference.kind == AttachmentRefKind.image &&
      isInlineImageName(widget.reference.target.name);

  _Known get _known => _session.putIfAbsent(_path, _Known.new);

  @override
  void didUpdateWidget(AttachmentBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    final old = oldWidget.reference;
    if (old.target.path != _path || old.kind != widget.reference.kind) {
      _probed = false;
    }
  }

  @override
  void dispose() {
    _menu.remove();
    super.dispose();
  }

  /// Learns what the block shows for [access] (D7): synchronously what a
  /// local file's size and header say, then the rest asynchronously.
  void _probe(AttachmentsAccess? access) {
    _probed = true;
    _access = access;
    final generation = ++_generation;
    _failure = null;
    _image = null;
    final known = _known;
    if (access == null) {
      _failure = AttachmentLookupFailure.unsupported;
      return;
    }
    if (access is LocalAttachmentsAccess) {
      final file = File('${access.vaultPath}/$_path');
      final stat = file.statSync();
      if (stat.type != FileSystemEntityType.file) {
        _failure = AttachmentLookupFailure.missing;
        return;
      }
      known.size = stat.size;
      if (!_imageForm || known.card) return;
      if (attachmentImageOverCap(bytes: stat.size)) {
        known.card = true;
        return;
      }
      final dims = known.dims ??= _readHeader(file, stat.size);
      if (dims == null || attachmentImageOverCap(dims: dims)) {
        known.card = true;
        return;
      }
      unawaited(_read(access, generation));
    } else if (_imageForm && !known.card) {
      unawaited(_read(access, generation));
    } else {
      // Asked even when the size is known: the session cache says nothing
      // about whether this vault has the file (R35).
      unawaited(_info(access, generation));
    }
  }

  /// [file]'s header dims, read from at most [_headerBytes] of its [size]
  /// bytes; null when unreadable or no image header.
  static Size? _readHeader(File file, int size) {
    RandomAccessFile? handle;
    try {
      handle = file.openSync();
      return attachmentImageDims(handle.readSync(math.min(size, _headerBytes)));
    } on FileSystemException {
      return null;
    } finally {
      handle?.closeSync();
    }
  }

  Future<void> _read(AttachmentsAccess access, int generation) async {
    final result = await access.read(_path);
    if (!mounted || generation != _generation) return;
    final known = _known;
    setState(() {
      switch (result) {
        case AttachmentBytes(:final bytes):
          known.size = bytes.length;
          final dims = known.dims ?? attachmentImageDims(bytes);
          if (dims == null ||
              attachmentImageOverCap(dims: dims, bytes: bytes.length)) {
            known.card = true;
          } else {
            known.dims = dims;
            _image = MemoryImage(bytes);
          }
        case AttachmentReadFailed(:final failure):
          _failure = failure;
      }
    });
  }

  Future<void> _info(AttachmentsAccess access, int generation) async {
    final result = await access.info(_path);
    if (!mounted || generation != _generation) return;
    setState(() {
      switch (result) {
        case AttachmentInfoFound(:final info):
          _known.size = info.size;
        case AttachmentInfoFailed(:final failure):
          _failure = failure;
      }
    });
  }

  /// The image failed to decode: it shows as a file card (R28).
  void _onDecodeError() {
    if (_known.card) return;
    _known.card = true;
    scheduleMicrotask(() {
      if (mounted) setState(() {});
    });
  }

  /// Opens ([reveal] false) or reveals the file through the domain (D10).
  Future<void> _act({required bool reveal}) async {
    final access = ref.read(attachmentsProvider);
    if (access == null) return;
    final name = widget.name;
    final result = reveal
        ? await access.reveal(_path)
        : await access.open(_path);
    if (!mounted) return;
    if (result case AttachmentActionFailed(:final failure)) {
      showAttachmentOpenFailure(context, name, failure);
    }
  }

  /// Whether the block offers `Reveal in Finder`: on a local vault only
  /// (R41).
  bool get _revealable => _access is LocalAttachmentsAccess;

  void _open() => unawaited(_act(reveal: false));

  void _reveal() => unawaited(_act(reveal: true));

  /// The semantics actions of a block that opens: `Reveal in Finder` where
  /// offered (the tap action opens).
  Map<CustomSemanticsAction, VoidCallback>? get _semanticsActions =>
      _revealable ? {_revealAction: _reveal} : null;

  /// Offers `Open`, and `Reveal in Finder` where offered, at global [at].
  /// The pointer layer leaves a press the block owns alone (D5, D23), so
  /// this is the only menu the press shows.
  void _showMenu(Offset at) {
    ContextMenuButtonItem item(String label, {required bool reveal}) =>
        ContextMenuButtonItem(
          label: label,
          onPressed: () {
            _menu.remove();
            unawaited(_act(reveal: reveal));
          },
        );
    _menu.show(
      context: context,
      contextMenuBuilder: (context) => TapRegion(
        onTapOutside: (_) => _menu.remove(),
        child: TextFieldTapRegion(
          child: AdaptiveTextSelectionToolbar.buttonItems(
            anchors: TextSelectionToolbarAnchors(primaryAnchor: at),
            buttonItems: [
              item('Open', reveal: false),
              if (_revealable) item('Reveal in Finder', reveal: true),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final access = ref.watch(attachmentsProvider);
    if (!_probed || !identical(access, _access)) _probe(access);
    final name = widget.name;
    final known = _known;
    final failure = _failure;
    if (_imageForm && !known.card) {
      final dims = known.dims;
      if (failure != null || dims == null) {
        final notice = failure == null ? '' : _imageNotice(failure, name);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPlaceCaret,
          child: AttachmentNotice(text: notice),
        );
      }
      // Assistive tech opens the image with its tap action and reveals it
      // with a custom one; the pointer gestures stay out of the semantics.
      return Semantics(
        container: true,
        image: true,
        label: name,
        onTap: _open,
        customSemanticsActions: _semanticsActions,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          excludeFromSemantics: true,
          onTap: widget.onPlaceCaret,
          onDoubleTap: _open,
          onSecondaryTapUp: (details) => _showMenu(details.globalPosition),
          child: AttachmentImageBox(
            natural: dims,
            image: _image,
            onError: _onDecodeError,
          ),
        ),
      );
    }
    final missing = failure == AttachmentLookupFailure.missing;
    final size = known.size;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      excludeFromSemantics: true,
      onTap: missing ? null : _open,
      onSecondaryTapUp: missing
          ? null
          : (details) => _showMenu(details.globalPosition),
      child: AttachmentFileCard(
        name: name,
        type: attachmentTypeLabel(widget.reference.target.name),
        icon: attachmentTypeIcon(widget.reference.target.name),
        size: size == null ? null : formatAttachmentSize(size),
        missing: missing,
        onOpen: missing ? null : _open,
        onReveal: missing || !_revealable ? null : _reveal,
      ),
    );
  }

  /// The notice of an image that can't show (R28, R42).
  static String _imageNotice(AttachmentLookupFailure failure, String name) =>
      switch (failure) {
        AttachmentLookupFailure.missing => 'Image not found · $name',
        AttachmentLookupFailure.offline => 'Image unavailable offline · $name',
        AttachmentLookupFailure.serverTooOld ||
        AttachmentLookupFailure.unsupported => 'Image unavailable · $name',
      };
}

/// A muted box one editor text line tall reading [text] (R28): the notice of
/// an image that can't show, or, empty, the reserve of one still loading.
class AttachmentNotice extends StatelessWidget {
  const AttachmentNotice({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    label: text,
    excludeSemantics: true,
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: text.isEmpty ? null : OmColors.surface3,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: text.isEmpty ? 0 : 8),
        child: Text(
          text,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.ellipsis,
          style: editorBodyStyle().copyWith(color: OmColors.fg3),
          // Forced, so the empty reserve is one line tall too: an empty
          // line under the theme's even leading lays out taller.
          strutStyle: livePreviewStrut().merge(
            const StrutStyle(forceStrutHeight: true),
          ),
        ),
      ),
    ),
  );
}

/// An image of [natural] logical pixels at its shown size in the column
/// (R24, [attachmentImageSize]), [image] decoded at that width times the
/// device pixel ratio once given; empty until then. Its size depends only
/// on [natural] and the column width (D7), so a decode never lays out more
/// than the image, and it paints in its own `RepaintBoundary`, so a GIF
/// frame repaints only the image (D8). [onError] runs when [image] fails to
/// decode.
class AttachmentImageBox extends StatelessWidget {
  const AttachmentImageBox({
    super.key,
    required this.natural,
    this.image,
    this.onError,
  });

  final Size natural;
  final ImageProvider? image;
  final VoidCallback? onError;

  @override
  Widget build(BuildContext context) => _ImageFit(
    natural: natural,
    // Laid out tight by the fit, so it is a relayout boundary: a frame's
    // rebuild under the LayoutBuilder relays out only the image.
    child: RepaintBoundary(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final provider = image;
          if (provider == null) return const SizedBox.expand();
          final ratio = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
          return Image(
            image: ResizeImage(
              provider,
              width: math.max(1, (constraints.maxWidth * ratio).round()),
            ),
            width: constraints.maxWidth,
            height: constraints.maxHeight,
            fit: BoxFit.fill,
            gaplessPlayback: true,
            excludeFromSemantics: true,
            errorBuilder: (context, error, stack) {
              onError?.call();
              return const SizedBox.expand();
            },
          );
        },
      ),
    ),
  );
}

/// Sizes itself to [natural] fitted to its width constraint
/// ([attachmentImageSize]) and lays its child out tight at that size.
class _ImageFit extends SingleChildRenderObjectWidget {
  const _ImageFit({required this.natural, super.child});

  final Size natural;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderImageFit(natural);

  @override
  void updateRenderObject(BuildContext context, _RenderImageFit renderObject) =>
      renderObject.natural = natural;
}

class _RenderImageFit extends RenderProxyBox {
  _RenderImageFit(this._natural);

  Size _natural;
  set natural(Size value) {
    if (value == _natural) return;
    _natural = value;
    markNeedsLayout();
  }

  Size _fit(BoxConstraints constraints) => constraints.constrain(
    attachmentImageSize(_natural, constraints.maxWidth),
  );

  @override
  Size computeDryLayout(BoxConstraints constraints) => _fit(constraints);

  @override
  void performLayout() {
    size = _fit(constraints);
    child?.layout(BoxConstraints.tight(size));
  }

  @override
  double computeMinIntrinsicWidth(double height) => 0;

  @override
  double computeMaxIntrinsicWidth(double height) =>
      attachmentImageSize(_natural, double.infinity).width;

  @override
  double computeMinIntrinsicHeight(double width) =>
      attachmentImageSize(_natural, width).height;

  @override
  double computeMaxIntrinsicHeight(double width) =>
      attachmentImageSize(_natural, width).height;
}

/// A compact file card (R32, R36): a lucide [icon], the [name] and
/// `<TYPE> · <size>` ([type], [size], `—` while null), in ExcerptCard's
/// border, radius and type tokens, raised while hovered. [missing] shows a
/// muted `File not found · <name>` instead (R35). Its semantics label is
/// `<name>, <TYPE>, <size>` (R37); assistive tech opens it with its tap
/// action ([onOpen]) and reveals it with a `Reveal in Finder` custom action
/// ([onReveal]). It handles no pointer press itself.
class AttachmentFileCard extends StatefulWidget {
  const AttachmentFileCard({
    super.key,
    required this.name,
    required this.type,
    required this.icon,
    this.size,
    this.missing = false,
    this.onOpen,
    this.onReveal,
  });

  final String name;
  final String type;
  final IconData icon;
  final String? size;
  final bool missing;

  /// The card's semantics tap action; null for none.
  final VoidCallback? onOpen;

  /// The card's `Reveal in Finder` semantics action; null for none.
  final VoidCallback? onReveal;

  /// The widest a card shows.
  static const double maxWidth = 360;

  @override
  State<AttachmentFileCard> createState() => _AttachmentFileCardState();
}

class _AttachmentFileCardState extends State<AttachmentFileCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final missing = widget.missing;
    final name = widget.name;
    final size = widget.size;
    final caption = '${widget.type} · ${size ?? '—'}';
    final label = missing
        ? 'File not found · $name'
        : [name, widget.type, ?size].join(', ');
    final text = missing
        ? Text(
            'File not found · $name',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: OmType.mono(size: 13, color: OmColors.fg3),
          )
        : Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: OmType.mono(size: 13, color: OmColors.fg0),
              ),
              Text(
                caption,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: OmType.mono(size: 11, color: OmColors.fg2),
              ),
            ],
          );
    final onReveal = widget.onReveal;
    return Semantics(
      container: true,
      button: !missing,
      label: label,
      onTap: widget.onOpen,
      customSemanticsActions: onReveal == null
          ? null
          : {_revealAction: onReveal},
      excludeSemantics: true,
      child: MouseRegion(
        cursor: missing ? MouseCursor.defer : SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: AttachmentFileCard.maxWidth,
          ),
          child: Container(
            padding: const EdgeInsets.fromLTRB(10, 6, 12, 6),
            decoration: BoxDecoration(
              color: _hovered && !missing
                  ? OmColors.surface4
                  : OmColors.surface3,
              border: Border.all(color: OmColors.line2, width: 1),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  widget.icon,
                  size: 16,
                  color: missing ? OmColors.fg3 : OmColors.fg2,
                ),
                const SizedBox(width: 8),
                Flexible(child: text),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
