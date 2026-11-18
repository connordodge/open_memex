// WI #76 (56-A2) stub, filled by #78 (56-A4, Spec #59 req 29; design pack 78
// C1, C2, C5, F4, F5). #77's shell places it in the wide card's preview
// slot, above its hint footer.
import 'dart:convert';
import 'dart:math' show max, min;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/clock.dart';
import '../../state/command_palette_state.dart';
import '../../state/palette_passages.dart' show paletteAge, passageMarks;
import '../../state/palette_preview_state.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../vault_access/search_access.dart';
import 'palette_row.dart';

/// The preview pane for the selected row (Spec #59 req 29), drawn from
/// `paletteProvider`'s `preview`. Nothing is built under
/// [palettePreviewMinWidth]. Plain, read-only text: never the editor.
/// - a command: `COMMAND`, its label and its C5 description;
/// - a note or daily note: its eyebrow, title and `contentMd` from the top;
/// - a passage: the same for its note, with the chunk's lines on a
///   `surface3` band (typed words in `accentMark`) scrolled so the band sits
///   about a third of the way down; a null `start_byte` shows from the top
///   with no band;
/// - a canvas (not drawn; the WI fallback): `CANVAS`, its title,
///   `<n> cards` and up to 8 card titles;
/// - `loading…` while the read runs, `couldn't load the preview.` on failure.
class PalettePreview extends ConsumerWidget {
  const PalettePreview({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (MediaQuery.sizeOf(context).width < palettePreviewMinWidth) {
      return const SizedBox.shrink();
    }
    final palette = ref.watch(paletteProvider);
    final view = palette.preview;
    final now = ref.read(clockProvider).now();
    final child = switch (view) {
      PreviewNone() => const SizedBox.shrink(),
      PreviewLoading() => const _StatusLine('loading…'),
      PreviewFailed() => const _StatusLine("couldn't load the preview."),
      PreviewCommand(:final label, :final description) => _PreviewBody(
        key: ObjectKey(view),
        eyebrow: 'COMMAND',
        title: Text(label, style: _commandTitleStyle),
        titleGap: 10,
        children: [Text(description, style: _commandBodyStyle)],
      ),
      PreviewNote(:final title, :final contentMd) => _PreviewBody(
        key: ObjectKey(view),
        eyebrow: _noteEyebrow(view, now),
        title: Text(title, style: _noteTitleStyle),
        children: _paragraphs(contentMd),
      ),
      PreviewPassage(:final hit, :final contentMd) => _passage(
        view,
        hit,
        contentMd,
        palette.query.trim(),
        now,
      ),
      PreviewCanvas(:final title, :final cardCount, :final cardTitles) =>
        _PreviewBody(
          key: ObjectKey(view),
          eyebrow: 'CANVAS',
          title: Text(title, style: _noteTitleStyle),
          children: [
            Text(
              cardCount == 1 ? '1 card' : '$cardCount cards',
              style: _noteBodyStyle,
            ),
            for (final card in cardTitles) Text(card, style: _noteBodyStyle),
          ],
        ),
    };
    // The body fills the slot it is given; with nothing selected the pane
    // takes no room.
    return KeyedSubtree(
      key: PaletteKeys.preview,
      child: view is PreviewNone ? child : SizedBox.expand(child: child),
    );
  }

  static Widget _passage(
    PreviewPassage view,
    SearchHit hit,
    String content,
    String query,
    DateTime now,
  ) {
    final eyebrow = hit.noteRole == 'daily'
        ? 'DAILY NOTE · ${paletteAge(hit.noteUpdatedAt, now).toUpperCase()}'
        : 'NOTE · EDITED ${paletteAge(hit.noteUpdatedAt, now).toUpperCase()}';
    final title = Text(hit.noteTitle, style: _noteTitleStyle);
    final split = _chunkLines(content, hit);
    if (split == null) {
      return _PreviewBody(
        key: ObjectKey(view),
        eyebrow: eyebrow,
        title: title,
        children: _paragraphs(content),
      );
    }
    final (before, band, after) = split;
    final anchor = GlobalKey();
    return _PreviewBody(
      key: ObjectKey(view),
      eyebrow: eyebrow,
      title: title,
      anchor: anchor,
      children: [
        ..._paragraphs(before),
        _Band(key: anchor, text: band, marks: passageMarks(band, query)),
        ..._paragraphs(after),
      ],
    );
  }
}

/// [content] split around the lines holding [hit]'s chunk: (before, the
/// chunk's lines, after), or null with no byte offset or one past the end.
/// The chunk runs from `start_byte` for the length of the hit's passage
/// text (its 280-character cut and `…` aside).
(String, String, String)? _chunkLines(String content, SearchHit hit) {
  final byte = hit.startByte;
  if (byte == null || byte < 0) return null;
  final bytes = utf8.encode(content);
  if (byte >= bytes.length) return null;
  final start = utf8
      .decode(bytes.sublist(0, byte), allowMalformed: true)
      .length;
  final snippet = hit.snippet.endsWith('…')
      ? hit.snippet.substring(0, hit.snippet.length - 1)
      : hit.snippet;
  final length = max<int>(1, snippet.trimRight().length);
  final end = min(content.length, start + length);
  final lineStart = start == 0 ? 0 : content.lastIndexOf('\n', start - 1) + 1;
  final lastChar = max(start, end - 1);
  var lineEnd = content.indexOf('\n', lastChar);
  if (lineEnd < 0) lineEnd = content.length;
  return (
    content.substring(0, lineStart).replaceFirst(RegExp(r'\n+$'), ''),
    content.substring(lineStart, lineEnd),
    content.substring(lineEnd).replaceFirst(RegExp(r'^\n+'), ''),
  );
}

/// [text]'s paragraphs (split at blank lines), each one plain body text.
List<Widget> _paragraphs(String text) => [
  for (final para in text.split(RegExp(r'\n[ \t]*\n')))
    if (para.trim().isNotEmpty) Text(para, style: _noteBodyStyle),
];

String _noteEyebrow(PreviewNote view, DateTime now) {
  if (view is! PalettePreviewNote) return 'NOTE';
  final age = paletteAge(view.updatedAt, now).toUpperCase();
  return switch (view.kind) {
    PaletteNoteKind.daily => 'DAILY NOTE · $age',
    _ => 'NOTE · EDITED $age',
  };
}

final _eyebrowStyle = OmType.mono(
  size: 11,
  color: OmColors.fg2,
  height: 14 / 11,
  letterSpacing: 1,
);
final _commandTitleStyle = OmType.sans(
  size: 19,
  weight: FontWeight.w600,
  height: 23 / 19,
);
final _commandBodyStyle = OmType.sans(
  size: 13.5,
  color: OmColors.fg1,
  height: 22.28 / 13.5,
);
final _noteTitleStyle = OmType.serif(size: 26, height: 1, letterSpacing: -0.3);
final _noteBodyStyle = OmType.sans(
  size: 13.5,
  color: OmColors.fg2,
  height: 22.28 / 13.5,
);

/// `loading…` / `couldn't load the preview.`: not drawn; mono 11 `fg2` at
/// the eyebrow's place.
class _StatusLine extends StatelessWidget {
  const _StatusLine(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topLeft,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(28, 24, 28, 0),
      child: Text(text, style: _eyebrowStyle),
    ),
  );
}

/// The scrolling preview body: eyebrow, title, then [children] 12 apart.
/// Text sits 28 in from the pane's sides; a [_Band] 18. With an [anchor],
/// the first frame scrolls so the anchor's first text line sits a third of
/// the way down the viewport.
class _PreviewBody extends StatefulWidget {
  const _PreviewBody({
    super.key,
    required this.eyebrow,
    required this.title,
    this.titleGap = 14,
    required this.children,
    this.anchor,
  });

  final String eyebrow;
  final Widget title;
  final double titleGap;
  final List<Widget> children;
  final GlobalKey? anchor;

  @override
  State<_PreviewBody> createState() => _PreviewBodyState();
}

class _PreviewBodyState extends State<_PreviewBody> {
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    if (widget.anchor != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _place());
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _place() {
    if (!mounted || !_scroll.hasClients) return;
    final box = widget.anchor?.currentContext?.findRenderObject();
    if (box == null || !box.attached) return;
    final position = _scroll.position;
    final top = RenderAbstractViewport.of(box).getOffsetToReveal(box, 0).offset;
    final target = top + _Band.padV - position.viewportDimension / 3;
    _scroll.jumpTo(
      target.clamp(position.minScrollExtent, position.maxScrollExtent),
    );
  }

  @override
  Widget build(BuildContext context) {
    Widget inset(Widget child) => child is _Band
        ? child
        : Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: child,
          );
    return SingleChildScrollView(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(18, 24, 18, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          inset(Text(widget.eyebrow, style: _eyebrowStyle)),
          const SizedBox(height: 8),
          inset(widget.title),
          SizedBox(height: widget.titleGap),
          for (var i = 0; i < widget.children.length; i++) ...[
            if (i > 0) const SizedBox(height: 12),
            inset(widget.children[i]),
          ],
        ],
      ),
    );
  }
}

/// The passage band (C2, F5): the chunk's lines on `surface3`, radius 6,
/// padding V8 H10, in `fg0`, the typed words in `accentMark`.
class _Band extends StatelessWidget {
  const _Band({super.key, required this.text, required this.marks});

  static const padV = 8.0;

  final String text;
  final List<TextRange> marks;

  @override
  Widget build(BuildContext context) {
    final mark = TextStyle(backgroundColor: OmColors.accentMark);
    final runs = <TextSpan>[];
    var at = 0;
    for (final r in marks) {
      if (r.start < at || r.end > text.length) continue;
      if (r.start > at) runs.add(TextSpan(text: text.substring(at, r.start)));
      runs.add(TextSpan(text: text.substring(r.start, r.end), style: mark));
      at = r.end;
    }
    if (at < text.length) runs.add(TextSpan(text: text.substring(at)));
    return DecoratedBox(
      decoration: BoxDecoration(
        color: OmColors.surface3,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: padV),
        child: Text.rich(
          TextSpan(
            style: OmType.sans(
              size: 13.5,
              color: OmColors.fg0,
              height: 22.28 / 13.5,
            ),
            children: runs,
          ),
        ),
      ),
    );
  }
}
