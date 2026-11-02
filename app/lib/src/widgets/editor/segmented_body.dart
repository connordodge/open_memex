import 'dart:async';
import 'dart:ui' as ui show BoxHeightStyle;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../cli/excerpt_cli.dart';
import '../../db.dart';
import '../../editor/segments.dart';
import '../../memex_cli.dart';
import '../../state/tabs_state.dart' show VirtualTodayTab;
import '../../state/topic_actions.dart';
import '../../state/vault_access_state.dart';
import '../../state/vault_state.dart';
import '../../vault_access/errors.dart';
import '../inline_error.dart';
import 'capture_gutter.dart';
import 'excerpt_card.dart';
import 'footer_chip_row.dart';
import 'line_boxes.dart';
import 'live_preview_controller.dart';
import 'segment_view.dart';
import 'text_segment.dart';

/// One segment on screen: an editable text run, an excerpt card or the
/// daily footer.
sealed class _Seg {}

class _TextSeg extends _Seg {
  _TextSeg(String text, this.focus, {required this.ownsFocus})
    : ctrl = LivePreviewController.fromValue(
        TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: text.length),
        ),
      ),
      gate = _FocusGate(focus) {
    ctrl.revealGate = gate;
  }

  final LivePreviewController ctrl;
  final FocusNode focus;

  /// The controller's reveal gate: the segment's focus.
  final _FocusGate gate;

  /// False for the host's primary focus node, which this body never
  /// disposes.
  final bool ownsFocus;
}

/// True while [focus] has focus; notifies only when that changes.
///
/// It also re-checks [focus] on every primary focus change: when a focused
/// row field under [focus] goes away (a re-split replaces the segment's
/// rows), the focus manager drops that primary focus without notifying its
/// ancestors, so [focus] alone would never report losing focus.
class _FocusGate extends ValueNotifier<bool> {
  _FocusGate(this.focus) : super(focus.hasFocus) {
    focus.addListener(_sync);
    FocusManager.instance.addListener(_sync);
  }

  final FocusNode focus;

  void _sync() => value = focus.hasFocus;

  @override
  void dispose() {
    focus.removeListener(_sync);
    FocusManager.instance.removeListener(_sync);
    super.dispose();
  }
}

class _CardSeg extends _Seg {
  _CardSeg(this.segment);
  final TransclusionSegment segment;
}

class _FooterSeg extends _Seg {
  _FooterSeg(this.segment);
  final FooterSegment segment;
}

/// The segmented note body (WI #27): the note's markdown split by
/// `segments.dart`'s [split] into editable text segments
/// (Key `text-segment-<index>`), read-only [ExcerptCard]s and, for a daily
/// note, the [FooterChipBar]. `<index>` is the segment's position in
/// [split]'s list. The first text segment (a daily note's person field)
/// also carries Key `editor-body` and uses [primaryFocusNode]. Each text
/// segment is a [SegmentView]: editor rows over the segment's text (#167).
///
/// Edits report [join] of all segments through [onContentChanged]. The
/// segment list is not rebuilt while typing: it is recomputed when
/// [content] changes from outside (another note, a Source edit, a server
/// write) and after each save ([savedVersion] changes), keeping the
/// controllers when the segments' shape did not change.
///
/// A card's `×` removes the excerpt through `memex excerpt rm`; on success
/// the editor takes the version the CLI returned as its base version and the
/// vault revision is bumped; on failure the card stays and a dismissible
/// inline error (Key `inline-error`) shows the CLI message.
class SegmentedBody extends ConsumerStatefulWidget {
  const SegmentedBody({
    super.key,
    required this.note,
    required this.content,
    required this.savedVersion,
    required this.onContentChanged,
    this.header,
    this.errorMessage,
    this.primaryFocusNode,
    this.onDismissError,
  });

  /// The note shown (its id and role).
  final Note note;

  /// The editor's current markdown for [note].
  final String content;

  /// The editor's base version; a change means a save completed.
  final int? savedVersion;
  final ValueChanged<String> onContentChanged;
  final Widget? header;
  final String? errorMessage;

  /// Focus node of the first text segment, owned by the host.
  final FocusNode? primaryFocusNode;

  /// Dismisses the save [errorMessage] (shown as an inline error).
  final VoidCallback? onDismissError;

  @override
  ConsumerState<SegmentedBody> createState() => _SegmentedBodyState();
}

class _SegmentedBodyState extends ConsumerState<SegmentedBody> {
  final _kindChips = KindChipHost();
  FocusNode? _ownPrimary;
  List<_Seg> _segs = const [];
  late bool _isDaily;

  /// False for a daily note whose body has no Topics marker yet (e.g. the
  /// virtual Today note): its body is saved as the person text alone.
  late bool _withFooter;

  /// [join] of the segments as they are now.
  String _joined = '';
  bool _removing = false;
  String? _error;

  FocusNode get _primary =>
      widget.primaryFocusNode ??
      (_ownPrimary ??= FocusNode(debugLabel: 'editor-body'));

  @override
  void initState() {
    super.initState();
    _isDaily = widget.note.role == 'daily';
    _resplit(widget.content);
  }

  @override
  void didUpdateWidget(SegmentedBody old) {
    super.didUpdateWidget(old);
    if (old.note.id != widget.note.id) _error = null;
    final isDaily = widget.note.role == 'daily';
    final content = widget.content;
    if (isDaily != _isDaily || content != _joined) {
      // A server write to the loaded note (a polled update, a merged save)
      // keeps the selection; loading a note puts the caret at the end.
      final serverWrite =
          old.note.id == widget.note.id &&
          isDaily == _isDaily &&
          old.savedVersion != null;
      _isDaily = isDaily;
      _resplit(content, keepCaret: serverWrite);
    } else if (widget.savedVersion != old.savedVersion) {
      _resplit(_joined, keepCaret: true);
    }
  }

  @override
  void dispose() {
    _disposeSegs(_segs);
    _ownPrimary?.dispose();
    _kindChips.dispose();
    super.dispose();
  }

  void _disposeSegs(List<_Seg> segs) {
    for (final s in segs) {
      if (s is _TextSeg) {
        s.gate.dispose();
        s.ctrl.dispose();
        if (s.ownsFocus) s.focus.dispose();
      }
    }
  }

  /// Rebuilds the segments from [text]. When the new split has the same
  /// shape (same kinds, same cards) the text controllers are kept and only
  /// their text is replaced; otherwise new segments are built and focus moves
  /// to the text segment holding the caret's position. A replaced text puts
  /// the caret at its end, or keeps the selection (both ends, clamped to the
  /// new text) with [keepCaret].
  void _resplit(String text, {bool keepCaret = false}) {
    final next = split(text, isDaily: _isDaily);
    _withFooter = !_isDaily || splitDailyBody(text).person != text;
    if (_sameShape(next)) {
      // A segment's rows re-derive from its new text without reporting it
      // (SegmentView).
      for (var i = 0; i < next.length; i++) {
        final seg = _segs[i];
        final n = next[i];
        if (seg is _TextSeg && n is TextSegment && seg.ctrl.text != n.text) {
          seg.ctrl.value = TextEditingValue(
            text: n.text,
            selection: keepCaret
                ? _clampSelection(seg.ctrl.selection, n.text.length)
                : TextSelection.collapsed(offset: n.text.length),
          );
        }
      }
      _segs = [
        for (var i = 0; i < next.length; i++)
          switch (next[i]) {
            final FooterSegment f => _FooterSeg(f),
            _ => _segs[i],
          },
      ];
    } else {
      final caret = _focusedOffset();
      final old = _segs;
      // Every text segment is rebuilt with new rows: the kind chip must not
      // point into a row field that goes away.
      _kindChips.clear();
      // split() always starts with a text segment: the primary field.
      _segs = [
        for (var i = 0; i < next.length; i++)
          switch (next[i]) {
            TextSegment(:final text) when i == 0 => _TextSeg(
              text,
              _primary,
              ownsFocus: false,
            ),
            TextSegment(:final text) => _TextSeg(
              text,
              FocusNode(debugLabel: 'text-segment'),
              ownsFocus: true,
            ),
            final TransclusionSegment t => _CardSeg(t),
            final FooterSegment f => _FooterSeg(f),
          },
      ];
      // The old fields still use their controllers until this frame ends.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _disposeSegs(old);
        if (caret != null && mounted) _focusAt(caret);
      });
    }
    _joined = _joinOf(_segs);
  }

  /// [selection] with both ends clamped to `0..length`.
  static TextSelection _clampSelection(TextSelection selection, int length) =>
      selection.copyWith(
        baseOffset: selection.baseOffset.clamp(0, length),
        extentOffset: selection.extentOffset.clamp(0, length),
      );

  /// The daily person field's [rows] with the capture gutter beside them
  /// (WI #28), measuring the rows' line [boxes].
  Widget _withGutter(
    _TextSeg seg,
    Widget rows,
    LineBoxSource? Function() boxes,
  ) => Stack(
    children: [
      Padding(
        padding: const EdgeInsets.only(left: captureGutterWidth),
        child: rows,
      ),
      Positioned(
        left: 0,
        top: 0,
        bottom: 0,
        width: captureGutterWidth,
        child: CaptureGutter(
          noteId: widget.note.id,
          controller: seg.ctrl,
          boxes: boxes,
        ),
      ),
    ],
  );

  /// True when [next] has the current segments' shape: the same cards (raw
  /// token lines) at the same positions. split() alternates text segments
  /// and cards, and a daily split is always text then footer, so equal card
  /// positions mean equal kinds everywhere.
  bool _sameShape(List<Segment> next) => listEquals(
    [for (final s in _segs) s is _CardSeg ? s.segment.raw : null],
    [for (final n in next) n is TransclusionSegment ? n.raw : null],
  );

  /// The markdown of text segment [i] of [segs] as [join] gets it: a
  /// non-empty text right before a card always ends its line, so the card's
  /// token stays a line of its own (and a card) after the save.
  String _textOf(List<_Seg> segs, int i) {
    final text = (segs[i] as _TextSeg).ctrl.text;
    final beforeCard = i + 1 < segs.length && segs[i + 1] is _CardSeg;
    return beforeCard && text.isNotEmpty && !text.endsWith('\n')
        ? '$text\n'
        : text;
  }

  String _joinOf(List<_Seg> segs) {
    final parts = <Segment>[
      for (var i = 0; i < segs.length; i++)
        switch (segs[i]) {
          _TextSeg() => TextSegment(_textOf(segs, i)),
          _CardSeg(:final segment) => segment,
          _FooterSeg(:final segment) => segment,
        },
    ];
    if (!_withFooter) parts.removeWhere((s) => s is FooterSegment);
    return join(parts);
  }

  /// The caret's offset in [_joined] when a text segment has focus.
  int? _focusedOffset() {
    var at = 0;
    for (var i = 0; i < _segs.length; i++) {
      switch (_segs[i]) {
        case _TextSeg(:final ctrl, :final focus):
          if (focus.hasFocus) {
            return at + ctrl.selection.baseOffset.clamp(0, ctrl.text.length);
          }
          at += _textOf(_segs, i).length;
        case _CardSeg(:final segment):
          at += segment.raw.length;
        case _FooterSeg():
          break;
      }
    }
    return null;
  }

  /// Focus the text segment holding [offset] of [_joined]; an offset inside
  /// a card lands at the start of the text segment after it.
  void _focusAt(int offset) {
    var at = 0;
    for (final s in _segs) {
      switch (s) {
        case _TextSeg(:final ctrl, :final focus):
          final len = ctrl.text.length;
          if (offset <= at + len) {
            focus.requestFocus();
            ctrl.selection = TextSelection.collapsed(
              offset: (offset - at).clamp(0, len),
            );
            return;
          }
          at += len;
        case _CardSeg(:final segment):
          at += segment.raw.length;
        case _FooterSeg():
          break;
      }
    }
  }

  void _onTextChanged() {
    final joined = _joinOf(_segs);
    if (joined == _joined) return;
    _joined = joined;
    widget.onContentChanged(joined);
  }

  /// The focus node of the text segment after ([forward]) or before [from],
  /// skipping cards, with its caret put at its start going forward and at
  /// its end going back; null when there is none.
  FocusNode? _neighbour(_TextSeg from, {required bool forward}) {
    var j = _segs.indexOf(from);
    while (true) {
      j = forward ? j + 1 : j - 1;
      if (j < 0 || j >= _segs.length) return null;
      final s = _segs[j];
      if (s is _TextSeg) {
        s.ctrl.selection = TextSelection.collapsed(
          offset: forward ? 0 : s.ctrl.text.length,
        );
        return s.focus;
      }
    }
  }

  Future<void> _remove(_CardSeg card) async {
    final access = ref.read(vaultAccessProvider);
    if (access == null || !access.canWrite) return;
    final noteId = widget.note.id;
    final revision = ref.read(vaultRevisionProvider.notifier);
    setState(() {
      _removing = true;
      _error = null;
    });
    final ExcerptRemoveResult? removed;
    try {
      // An unreachable vault server shows the guard's snackbar and changes
      // nothing (L17); other failures keep today's inline error.
      removed = await guardVaultWrite(
        context,
        () => access.daily.removeExcerpt(
          topicNoteId: noteId,
          date: card.segment.date,
          fromBlockId: card.segment.from,
          toBlockId: card.segment.to,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _removing = false;
        if (widget.note.id == noteId) {
          _error = e is MemexException ? e.message : e.toString();
        }
      });
      return;
    }
    if (removed == null) {
      if (mounted) setState(() => _removing = false);
      return;
    }
    final result = removed;
    revision.state++;
    if (!mounted) return;
    setState(() => _removing = false);
    if (widget.note.id != noteId) return;
    // Drop the card locally too (the first card with that token line, as
    // the server did), keeping any unsaved text around it.
    final raw = card.segment.raw;
    final at = _segs.indexWhere((s) => s is _CardSeg && s.segment.raw == raw);
    if (at != -1) {
      setState(() => _resplit(_joinOf([..._segs]..removeAt(at))));
    }
    // The server removed the token line: its body and the returned version
    // become the editor's base; unsaved edits (and title) are re-applied
    // on top and saved against that version.
    rebaseEditorOnVersion(
      ref,
      fallback: widget.note,
      version: result.version,
      content: _joined,
    );
  }

  /// True for a daily note that is in the vault (not the virtual Today
  /// note): the only kind a footer chip can be added to.
  bool get _isSavedDaily =>
      _isDaily && VirtualTodayTab.dateOf(widget.note.id) == null;

  /// `memex footer add` changed this daily note on the server (its new
  /// version is [version]): rebase the editor on it.
  void _onTopicLinked(int version) {
    if (!mounted) return;
    rebaseEditorOnVersion(
      ref,
      fallback: widget.note,
      version: version,
      content: _joined,
    );
  }

  void _onCreateError(String message) {
    if (mounted) setState(() => _error = message);
  }

  /// A row field went away: the kind chip must not point into it.
  void _onRowRemoved(TextEditingController row) {
    if (identical(row, _kindChips.target)) _kindChips.clear();
  }

  @override
  Widget build(BuildContext context) {
    final texts = _segs.whereType<_TextSeg>().toList();
    final single = texts.length == 1;
    final error = _error;
    return EditorPage(
      header: widget.header,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (error != null)
            InlineError(
              message: error,
              onDismiss: () => setState(() => _error = null),
            ),
          if (widget.errorMessage case final saveError?)
            InlineError(
              message: saveError,
              onDismiss: () => widget.onDismissError?.call(),
            ),
          for (var i = 0; i < _segs.length; i++)
            switch (_segs[i]) {
              final _TextSeg t => KeyedSubtree(
                key: ValueKey('text-segment-$i'),
                child: SegmentView(
                  key: ObjectKey(t.ctrl),
                  index: i,
                  controller: t.ctrl,
                  focusNode: t.focus,
                  revealGate: t.gate,
                  minLines: single ? 12 : (identical(t, texts.last) ? 4 : 1),
                  hintText: single
                      ? 'type [[ to link a note · write markdown…'
                      : null,
                  onChanged: _onTextChanged,
                  onRowRemoved: _onRowRemoved,
                  fieldBuilder: (context, row) => TextSegmentField(
                    controller: row.controller,
                    focusNode: row.focusNode,
                    kindChips: _kindChips,
                    hintText: row.hintText,
                    // Tight glyph boxes (design A); the row paints the
                    // selection itself, as one block (EditorRow).
                    selectionHeightStyle: ui.BoxHeightStyle.tight,
                    paintsSelection: false,
                    onMoveUp: row.first
                        ? () => _neighbour(t, forward: false)
                        : null,
                    onMoveDown: row.last
                        ? () => _neighbour(t, forward: true)
                        : null,
                    dailyNoteId: _isSavedDaily ? widget.note.id : null,
                    onTopicLinked: _onTopicLinked,
                    onCreateError: _onCreateError,
                  ),
                  builder: (context, rows, boxes) =>
                      _primaryKeyed(i == 0, t, rows, boxes),
                ),
              ),
              final _CardSeg c => ExcerptCard(
                index: i,
                segment: c.segment,
                onRemove: _removing ? null : () => _remove(c),
              ),
              _FooterSeg() => FooterChipBar(dailyNoteId: widget.note.id),
            },
        ],
      ),
      overlays: [KindChipLayer(host: _kindChips)],
    );
  }

  /// The first text segment is also the editor's body field (Key
  /// `editor-body`), where launch focus goes; a daily note's (the person
  /// field) has the capture gutter beside it.
  Widget _primaryKeyed(
    bool primary,
    _TextSeg seg,
    Widget rows,
    LineBoxSource? Function() boxes,
  ) => primary
      ? KeyedSubtree(
          key: const Key('editor-body'),
          child: _isDaily ? _withGutter(seg, rows, boxes) : rows,
        )
      : rows;
}
