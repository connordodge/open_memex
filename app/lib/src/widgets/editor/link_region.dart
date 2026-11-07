import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../db.dart';
import '../../editor/markdown_inline.dart';
import '../../editor/markdown_lines.dart';
import '../../editor/markdown_table.dart';
import '../../editor/tag_grammar.dart' show fencedMdLines, normalizeTagName;
import '../../state/tabs_state.dart';
import '../../state/tags_browse_state.dart';
import '../../state/url_opener.dart';
import '../../state/vault_access_state.dart';
import '../../state/vault_state.dart';
import '../../vault_access/vault_scoped.dart';
import 'line_boxes.dart';
import 'live_preview_controller.dart';

/// The most titles `noteTitlesAsyncProvider` loads: a list this long may be
/// cut short, so no wikilink renders as a ghost (D14).
const int _titlesCap = 1000;

/// The URL schemes a click opens (D14, Spec #232 R13).
const Set<String> _openableSchemes = {'http', 'https', 'mailto'};

/// Whether a plain click follows [token] (Spec #232 R8, rulings D19, D19a):
/// the press path's one test of token kind. Whether the token resolves or
/// opens is a separate question (`_actionable`).
bool isPlainClickFollowable(InlineToken token) => switch (token) {
  WikilinkToken() || TransclusionLinkToken() || LinkToken() => true,
  InlineToken(kind: InlineTokenKind.tag) => true,
  _ => false,
};

/// Link hit-testing over one field (D7, D14, B3).
///
/// - Ghosts: sets [controller]'s `isResolved` from `noteTitlesAsyncProvider`
///   (a target resolves when a note's title equals it). Every target
///   resolves until the titles load and while the list holds 1,000 titles.
/// - Hovering the shown text of a resolved wikilink or transclusion token, or
///   of an http, https or mailto link, shows [SystemMouseCursors.click] and
///   sets [controller]'s `cmdHover` to the whole token, with Cmd held or on a
///   line whose markup is hidden; anything else keeps the field's cursor and
///   no hover.
/// - Cmd+click on such a token follows it: a wikilink's note or a transclusion
///   token's daily note through `TabsNotifier`, or a link's URL through
///   `urlOpenerProvider`.
/// - A rendered `#tag` is such a token too, unless its line is fenced code on
///   the server (rulings D19a, D51): following it opens Tags mode on its
///   normalized name through `revealTag`, with no navigation. A plain hover
///   over it shows the cursor only; `cmdHover` is set only with Cmd held
///   (ruling D52).
/// - A plain press on such a token, on a line whose markup is hidden, is
///   marked on [controller] (Spec #232 TD6) with the token it captured; the
///   segment's pointer layer follows it on a release inside the slop. Every
///   other plain click is the field's own.
/// - On a rendered table grid (Spec #197 R22, ruling D14) a Cmd or marked
///   press on such a token wins the gesture arena, so the segment's pointer
///   layer doesn't reveal the table; any other press there is the layer's
///   plain click.
///
/// Hit-tests the field's text through [boxes] and `tokenizeInline`; a
/// table line's links are found per cell through `splitTableLine` (D10).
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

  /// The hovered token's span, or null.
  TextRange? _hover;

  /// The selection [_refresh] last saw: a moved selection can reveal the
  /// hovered line, or hide it.
  TextSelection? _refreshedSelection;

  /// The token a Cmd+press went down on, or null.
  _Link? _pressed;

  /// The resolution map the controller last rendered with (see [_apply]).
  Map<String, String>? _appliedIds;

  bool _applyScheduled = false;

  // Tokens of the controller's text, cached by text and line props.
  String? _tokensText;
  bool? _tokensItemText;
  bool? _tokensAtStart;
  List<bool>? _tokensFenced;
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

  /// Applies the resolution map after the current frame (never while
  /// widgets build: the controller's `isResolved` setter notifies its
  /// listeners).
  void _scheduleApply() {
    if (_applyScheduled) return;
    _applyScheduled = true;
    SchedulerBinding.instance
      ..addPostFrameCallback((_) {
        _applyScheduled = false;
        if (!mounted) return;
        _apply();
        _refresh();
      })
      ..ensureVisualUpdate();
  }

  /// Whether [target] resolves under the current titles: every target does
  /// until they load and while the list is at its cap.
  bool _resolves(String target) => _ids?.containsKey(target) ?? true;

  /// Installs [_resolves] as the controller's `isResolved` once, then sets
  /// it again (to re-render) only when a link target in the text resolves
  /// differently under the new titles. The setter notifies the controller's
  /// listeners, and a notification with unchanged text is not free: the
  /// wikilink popover re-opens on any notification while the caret sits in
  /// an unclosed `[[`, so a titles reload after a Create must not send one.
  void _apply() {
    final controller = widget.controller;
    final before = _appliedIds;
    final after = _ids;
    _appliedIds = after;
    if (controller.isResolved != _resolves) {
      controller.isResolved = _resolves;
      return;
    }
    if (identical(before, after)) return;
    bool resolves(Map<String, String>? ids, String target) =>
        ids?.containsKey(target) ?? true;
    for (final link in _linksOf(controller)) {
      final target = switch (link.token) {
        WikilinkToken(:final target) => target,
        TransclusionLinkToken(:final date) => date,
        _ => null,
      };
      if (target != null &&
          resolves(before, target) != resolves(after, target)) {
        controller.isResolved = _resolves;
        return;
      }
    }
  }

  bool _onKey(KeyEvent event) {
    if (_pointer != null) _refresh();
    return false;
  }

  void _onControllerChanged() {
    final controller = widget.controller;
    // An edit under a resting pointer (Cmd+Z, Cmd+V) moves the tokens.
    final edited = _hover != null && controller.text != _tokensText;
    final moved =
        _pointer != null && controller.selection != _refreshedSelection;
    if (edited || moved) _scheduleApply();
  }

  void _pointerAt(Offset? global) {
    _pointer = global;
    _refresh();
  }

  /// Recomputes the hovered token under the pointer.
  void _refresh() {
    final at = _pointer;
    _refreshedSelection = widget.controller.selection;
    final link = at == null ? null : _actionableAt(at);
    final cmd = HardwareKeyboard.instance.isMetaPressed;
    final hover = link != null && (cmd || _plainFollows(link))
        ? link.span
        : null;
    if (hover != _hover) setState(() => _hover = hover);
    // A plain hover over a tag is the click cursor alone (D52).
    final inked = link?.token.kind == InlineTokenKind.tag && !cmd
        ? null
        : hover;
    if (widget.controller.cmdHover != inked) {
      widget.controller.cmdHover = inked;
    }
  }

  void _onPointerDown(PointerDownEvent event) {
    final keyboard = HardwareKeyboard.instance;
    final primary = event.buttons == kPrimaryButton;
    final cmd = keyboard.isMetaPressed;
    _pressed = primary && cmd ? _actionableAt(event.position) : null;
    final marked = primary && !cmd && !keyboard.isShiftPressed
        ? _markedAt(event)
        : null;
    final controller = widget.controller;
    // The state before the press decides, and the layer sees the press next.
    controller.markedPress = marked == null
        ? null
        : MarkedPress(event.pointer, () {
            if (mounted) _open(marked);
          });
    // On a rendered table grid the segment's pointer layer owns every other
    // press (D14): winning the arena keeps it from revealing the table.
    if ((_pressed != null || marked != null) &&
        controller.tableRow &&
        !controller.tableRevealed) {
      GestureBinding.instance.gestureArena
          .add(event.pointer, const _LinkPress())
          .resolve(GestureDisposition.accepted);
    }
  }

  void _onPointerUp(PointerUpEvent event) {
    final pressed = _pressed;
    _pressed = null;
    if (pressed == null) return;
    final up = _actionableAt(event.position);
    if (up == null || up.span != pressed.span) return;
    _open(up);
  }

  /// The link a mouse press at [event] marks, or null: a touch press never
  /// marks, since the pointer layer ignores it.
  _Link? _markedAt(PointerDownEvent event) {
    if (event.kind != PointerDeviceKind.mouse) return null;
    final link = _actionableAt(event.position);
    return link != null && _plainFollows(link) ? link : null;
  }

  /// Whether a plain click follows [link] (one [_actionableAt] returned): its
  /// kind follows and its line's markup is hidden.
  bool _plainFollows(_Link link) {
    if (!isPlainClickFollowable(link.token)) return false;
    final controller = widget.controller;
    final lines = classifyLines(
      controller.text,
      atSegmentStart: controller.atSegmentStart,
    );
    final revealed = revealedLines(
      lines,
      controller.selection,
      forceHidden: !controller.revealGate.value,
      itemText: controller.itemText,
    );
    final start = link.span.start;
    return !revealed[lines.indexWhere((line) => start < line.end)];
  }

  /// Follows [link] (one [_actionableAt] returned).
  void _open(_Link link) {
    switch (link.token) {
      case WikilinkToken(:final target):
        final id = _ids?[target];
        if (id == null) return;
        ref.read(tabsProvider.notifier).follow(NoteTab(id));
      case TransclusionLinkToken(:final date):
        unawaited(_openDay(date));
      case LinkToken(:final url):
        unawaited(ref.read(urlOpenerProvider).open(url));
      case InlineToken(kind: InlineTokenKind.tag):
        revealTag(ref, link.tag!);
      default:
        break;
    }
  }

  /// Follows to the daily note of [date], as `ExcerptCard._openDay` does;
  /// nothing when there is none. The modifier and the tab are read at the
  /// click, so a late answer for a plain click is dropped once the tab moved
  /// on.
  Future<void> _openDay(String date) async {
    final access = ref.read(vaultAccessProvider);
    if (access == null) return;
    final follow = ref.read(tabsProvider.notifier).followLater();
    final row = await access.daily.dailyNoteForDate(date);
    if (row == null) return;
    follow(NoteTab(row.noteId));
  }

  /// The innermost link whose shown text is under global [at] and that a
  /// click can follow, or null.
  _Link? _actionableAt(Offset at) {
    final source = widget.boxes?.call();
    if (source == null || !source.box.attached) return null;
    final local = source.box.globalToLocal(at);
    final offset = source.offsetAt(local);
    for (final link in _linksOf(widget.controller).reversed) {
      final shown = link.shown;
      if (offset < shown.start || offset > shown.end) continue;
      if (!_actionable(link)) continue;
      if (source.boxesFor(shown).any((r) => r.contains(local))) return link;
    }
    return null;
  }

  /// Whether a click can follow [link].
  bool _actionable(_Link link) => switch (link.token) {
    WikilinkToken(:final target) => _ids?.containsKey(target) ?? false,
    TransclusionLinkToken(:final date) => _ids?.containsKey(date) ?? false,
    LinkToken(:final url) => _openable(url),
    InlineToken(kind: InlineTokenKind.tag) => !link.fenced,
    _ => false,
  };

  /// The links of [controller]'s text, on the lines live preview tokenizes
  /// (as `buildLivePreviewSpan`: never fenced code), sorted by start.
  List<_Link> _linksOf(LivePreviewController controller) {
    final text = controller.text;
    if (text == _tokensText &&
        controller.itemText == _tokensItemText &&
        controller.atSegmentStart == _tokensAtStart &&
        identical(controller.fenced, _tokensFenced)) {
      return _links;
    }
    final lines = classifyLines(
      text,
      atSegmentStart: controller.atSegmentStart,
    );
    // As `buildLivePreviewSpan` judges them: item text is cut from a line that
    // starts with a marker, which opens no fence.
    final fenced =
        controller.fenced ??
        (controller.itemText ? const <bool>[] : fencedMdLines(text, lines));
    final links = <_Link>[];
    var lineFenced = false;
    void tokenize(int start, int end) {
      final stretch = text.substring(start, end);
      for (final t in tokenizeInline(
        stretch,
        before: unitBeforeInLine(text, start),
      )) {
        if (t is WikilinkToken ||
            t is TransclusionLinkToken ||
            t is LinkToken) {
          links.add(_Link(t, start));
        } else if (t.kind == InlineTokenKind.tag) {
          links.add(
            _Link(
              t,
              start,
              tag: normalizeTagName(stretch.substring(t.start + 1, t.end)),
              fenced: lineFenced,
            ),
          );
        }
      }
    }

    for (final (i, line) in lines.indexed) {
      lineFenced = fenced.elementAtOrNull(i) ?? false;
      switch (controller.itemText ? MdLineKind.plain : line.kind) {
        case MdLineKind.heading ||
            MdLineKind.bullet ||
            MdLineKind.numbered ||
            MdLineKind.task ||
            MdLineKind.quote:
          tokenize(line.textStart, line.contentEnd);
        case MdLineKind.plain:
          tokenize(line.start, line.contentEnd);
        // A table line's links are found per cell (Spec #197 R22, D10).
        case MdLineKind.tableHeader || MdLineKind.tableBody:
          final split = splitTableLine(
            text,
            start: line.start,
            end: line.contentEnd,
          );
          for (final cell in split.cells) {
            tokenize(cell.start, cell.end);
          }
        default:
          break;
      }
    }
    _tokensText = text;
    _tokensItemText = controller.itemText;
    _tokensAtStart = controller.atSegmentStart;
    _tokensFenced = controller.fenced;
    return _links = links;
  }
}

/// Whether a click opens [url]: its scheme (case-insensitive) is http, https
/// or mailto.
bool _openable(String url) {
  final colon = url.indexOf(':');
  return colon > 0 &&
      _openableSchemes.contains(url.substring(0, colon).toLowerCase());
}

/// A Cmd or marked press on a link of a rendered table grid in the gesture
/// arena: it wins at once, and the link is followed on pointer up.
final class _LinkPress implements GestureArenaMember {
  const _LinkPress();

  @override
  void acceptGesture(int pointer) {}

  @override
  void rejectGesture(int pointer) {}
}

/// A link [token] of a field's text, tokenized from the line (or table
/// cell) text starting at [base].
final class _Link {
  const _Link(this.token, this.base, {this.tag, this.fenced = false});

  final InlineToken token;
  final int base;

  /// A tag token's normalized name, else null.
  final String? tag;

  /// Whether a tag token's line is fenced code on the server: the tokenizer
  /// still finds the token there and only its ink is dropped.
  final bool fenced;

  /// The whole token in the field's text, markers included.
  TextRange get span =>
      TextRange(start: base + token.start, end: base + token.end);

  /// The token's shown text in the field's text.
  TextRange get shown => TextRange(
    start: base + token.content.start,
    end: base + token.content.end,
  );
}
