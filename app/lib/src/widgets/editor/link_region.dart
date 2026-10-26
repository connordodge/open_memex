import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../db.dart';
import '../../editor/markdown_inline.dart';
import '../../editor/markdown_lines.dart';
import '../../state/editor_controller.dart';
import '../../state/tabs_state.dart';
import '../../state/url_opener.dart';
import '../../state/vault_access_state.dart';
import '../../state/vault_state.dart';
import '../../vault_access/vault_scoped.dart';
import 'line_boxes.dart';
import 'live_preview_controller.dart';

/// The most titles `noteTitlesAsyncProvider` loads: a list this long may be
/// cut short, so no wikilink renders as a ghost (D14).
const int _titlesCap = 1000;

/// The URL schemes a Cmd+click opens (D14).
const Set<String> _openableSchemes = {'http', 'https', 'mailto'};

/// Link hit-testing over one field (D7, D14, B3).
///
/// - Ghosts: sets [controller]'s `isResolved` from `noteTitlesAsyncProvider`
///   (a target resolves when a note's title equals it). Every target
///   resolves until the titles load and while the list holds 1,000 titles.
/// - With Cmd held, hovering the shown text of a resolved wikilink or
///   transclusion token, or of an http, https or mailto link, shows
///   [SystemMouseCursors.click] and sets [controller]'s `cmdHover` to the
///   whole token; anything else keeps the field's cursor and no hover.
/// - Cmd+click on such a token opens it: a wikilink's note (after
///   `EditorController.flushPendingSave`), a transclusion token's daily
///   note, or a link's URL through `urlOpenerProvider`. A plain click is the
///   field's own.
///
/// Hit-tests the field's text through [boxes] and `tokenizeInline`.
class LinkRegion extends ConsumerStatefulWidget {
  const LinkRegion({
    super.key,
    required this.controller,
    this.boxes,
    required this.child,
  });

  /// The field's controller.
  final LivePreviewController controller;

  /// The field's line boxes once laid out (null before layout).
  final LineBoxSource? Function()? boxes;

  final Widget child;

  @override
  ConsumerState<LinkRegion> createState() => _LinkRegionState();
}

class _LinkRegionState extends ConsumerState<LinkRegion> {
  /// The loaded titles the resolution map was built from.
  List<NoteTitle>? _titles;

  /// Note id by title, or null while every target resolves (titles not
  /// loaded, or the list at its cap).
  Map<String, String>? _ids;

  /// The mouse's global position while it is over the field, else null.
  Offset? _pointer;

  /// The Cmd-hovered token's span, or null.
  TextRange? _hover;

  /// The token a Cmd+press went down on, or null.
  _Link? _pressed;

  bool _applyScheduled = false;

  // Tokens of the controller's text, cached by text and line props.
  String? _tokensText;
  bool? _tokensItemText;
  bool? _tokensAtStart;
  List<_Link> _links = const [];

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
    widget.controller.addListener(_onControllerChanged);
  }

  @override
  void didUpdateWidget(LinkRegion old) {
    super.didUpdateWidget(old);
    if (!identical(old.controller, widget.controller)) {
      old.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
      _scheduleApply();
    }
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    widget.controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final titles = currentVaultData(
      ref.watch(noteTitlesAsyncProvider),
      ref.watch(currentVaultProvider),
    )?.value;
    if (!identical(titles, _titles)) {
      _titles = titles;
      _ids = titles == null || titles.length >= _titlesCap
          ? null
          : {for (final t in titles.reversed) t.title: t.id};
      _scheduleApply();
    }
    return Stack(
      fit: StackFit.passthrough,
      children: [
        widget.child,
        Positioned.fill(
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: _onPointerDown,
            onPointerUp: _onPointerUp,
            onPointerCancel: (_) => _pressed = null,
            child: MouseRegion(
              opaque: false,
              cursor: _hover == null
                  ? MouseCursor.defer
                  : SystemMouseCursors.click,
              onHover: (event) => _pointerAt(event.position),
              onExit: (_) => _pointerAt(null),
            ),
          ),
        ),
      ],
    );
  }

  /// Sets the controller's `isResolved` after the current frame (never
  /// while widgets build: it notifies the controller's listeners).
  void _scheduleApply() {
    if (_applyScheduled) return;
    _applyScheduled = true;
    SchedulerBinding.instance
      ..addPostFrameCallback((_) {
        _applyScheduled = false;
        if (!mounted) return;
        widget.controller.isResolved = _ids?.containsKey;
        _refresh();
      })
      ..ensureVisualUpdate();
  }

  bool _onKey(KeyEvent event) {
    if (_pointer != null) _refresh();
    return false;
  }

  void _onControllerChanged() {
    // An edit under a resting pointer (Cmd+Z, Cmd+V) moves the tokens.
    if (_hover != null && widget.controller.text != _tokensText) {
      _scheduleApply();
    }
  }

  void _pointerAt(Offset? global) {
    _pointer = global;
    _refresh();
  }

  /// Recomputes the Cmd-hovered token under the pointer.
  void _refresh() {
    final at = _pointer;
    final hover = at != null && HardwareKeyboard.instance.isMetaPressed
        ? _actionableAt(at)?.span
        : null;
    if (hover != _hover) setState(() => _hover = hover);
    if (widget.controller.cmdHover != hover) {
      widget.controller.cmdHover = hover;
    }
  }

  void _onPointerDown(PointerDownEvent event) {
    _pressed =
        event.buttons == kPrimaryButton &&
            HardwareKeyboard.instance.isMetaPressed
        ? _actionableAt(event.position)
        : null;
  }

  void _onPointerUp(PointerUpEvent event) {
    final pressed = _pressed;
    _pressed = null;
    if (pressed == null) return;
    final up = _actionableAt(event.position);
    if (up == null || up.span != pressed.span) return;
    _open(up);
  }

  /// Opens [link] (one [_actionableAt] returned).
  void _open(_Link link) {
    switch (link.token) {
      case WikilinkToken(:final target):
        final id = _ids?[target];
        if (id == null) return;
        ref.read(editorControllerProvider.notifier).flushPendingSave();
        ref.read(tabsProvider.notifier).openOrFocus(NoteTab(id));
      case TransclusionLinkToken(:final date):
        ref.read(editorControllerProvider.notifier).flushPendingSave();
        unawaited(_openDay(date));
      case LinkToken(:final url):
        unawaited(ref.read(urlOpenerProvider).open(url));
      default:
        break;
    }
  }

  /// Opens the daily note of [date], as `ExcerptCard._openDay` does; nothing
  /// when there is none.
  Future<void> _openDay(String date) async {
    final access = ref.read(vaultAccessProvider);
    if (access == null) return;
    final tabs = ref.read(tabsProvider.notifier);
    final row = await access.daily.dailyNoteForDate(date);
    if (row == null || !tabs.mounted) return;
    tabs.openOrFocus(NoteTab(row.noteId));
  }

  /// The innermost link whose shown text is under global [at] and that a
  /// Cmd+click opens, or null.
  _Link? _actionableAt(Offset at) {
    final source = widget.boxes?.call();
    if (source == null || !source.box.attached) return null;
    final local = source.box.globalToLocal(at);
    final offset = source.offsetAt(local);
    for (final link in _linksOf(widget.controller).reversed) {
      final shown = link.shown;
      if (offset < shown.start || offset > shown.end) continue;
      if (!_actionable(link.token)) continue;
      if (source.boxesFor(shown).any((r) => r.contains(local))) return link;
    }
    return null;
  }

  /// Whether a Cmd+click opens [token].
  bool _actionable(InlineToken token) => switch (token) {
    WikilinkToken(:final target) => _ids?.containsKey(target) ?? false,
    TransclusionLinkToken(:final date) => _ids?.containsKey(date) ?? false,
    LinkToken(:final url) => _openable(url),
    _ => false,
  };

  /// The links of [controller]'s text, on the lines live preview tokenizes
  /// (as `buildLivePreviewSpan`: never fenced code), sorted by start.
  List<_Link> _linksOf(LivePreviewController controller) {
    final text = controller.text;
    if (text == _tokensText &&
        controller.itemText == _tokensItemText &&
        controller.atSegmentStart == _tokensAtStart) {
      return _links;
    }
    final links = <_Link>[];
    void tokenize(int start, int end) {
      for (final t in tokenizeInline(text.substring(start, end))) {
        if (t is WikilinkToken ||
            t is TransclusionLinkToken ||
            t is LinkToken) {
          links.add(_Link(t, start));
        }
      }
    }

    for (final line in classifyLines(
      text,
      atSegmentStart: controller.atSegmentStart,
    )) {
      switch (controller.itemText ? MdLineKind.plain : line.kind) {
        case MdLineKind.heading ||
            MdLineKind.bullet ||
            MdLineKind.numbered ||
            MdLineKind.task ||
            MdLineKind.quote:
          tokenize(line.textStart, line.contentEnd);
        case MdLineKind.plain:
          tokenize(line.start, line.contentEnd);
        default:
          break;
      }
    }
    _tokensText = text;
    _tokensItemText = controller.itemText;
    _tokensAtStart = controller.atSegmentStart;
    return _links = links;
  }
}

/// Whether a Cmd+click opens [url]: its scheme (case-insensitive) is http,
/// https or mailto.
bool _openable(String url) {
  final colon = url.indexOf(':');
  return colon > 0 &&
      _openableSchemes.contains(url.substring(0, colon).toLowerCase());
}

/// A link [token] of a field's text, tokenized from the line text starting
/// at [base].
final class _Link {
  const _Link(this.token, this.base);

  final InlineToken token;
  final int base;

  /// The whole token in the field's text, markers included.
  TextRange get span =>
      TextRange(start: base + token.start, end: base + token.end);

  /// The token's shown text in the field's text.
  TextRange get shown => TextRange(
    start: base + token.content.start,
    end: base + token.content.end,
  );
}
