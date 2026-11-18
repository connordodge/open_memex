import 'package:flutter/rendering.dart' show RenderAbstractViewport;
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../db.dart';
import '../../editor/outline.dart';
import '../../state/outline_section.dart';
import '../../state/tabs_state.dart' show tabsProvider;
import '../editor/echo_arrival_highlight.dart';
import '../editor/note_reveal.dart';
import '../editor/segmented_body.dart';
import 'outline_jump.dart' show outlineJumpInset;

// The editor side of the Outline's current section (#69, Spec #58 R22-R26,
// R41, TD6), plugged in through `NoteEditor._trackSections`.

/// How far from the mark a heading line still counts as on it: line tops
/// come from float32 text layout and reach the viewport through transforms
/// (as `note_reveal.dart`'s Within edge).
const double _edge = 1e-6;

/// Wraps the segmented body of [note] and reports its current section to
/// `outlineSectionProvider` while that provider is watched.
///
/// The current section is the last heading whose heading line top (its own
/// visual line, not its row's top: `revealAnchorRect`) is at or above the
/// viewport top + 16 px; none above the first heading. Right after an
/// Outline jump it is the jumped-to entry while the page stays where the
/// jump put it (Spec #58 R22), even when the jump clamped. Computed at most
/// once per frame, after layout, on a scroll, a rebuild of the body (text
/// change, note change), a jump and when the provider gains a listener;
/// never while nothing watches it.
class SectionTracker extends ConsumerStatefulWidget {
  const SectionTracker({super.key, required this.note, required this.child});

  final Note note;
  final Widget child;

  /// How many times a tracker computed the current section (a test probe).
  @visibleForTesting
  static int debugPasses = 0;

  @override
  ConsumerState<SectionTracker> createState() => _SectionTrackerState();
}

class _SectionTrackerState extends ConsumerState<SectionTracker> {
  late final OutlineSectionHub _hub;

  /// A pass waits for the end of a frame.
  bool _scheduled = false;

  /// The entries and anchors of the body last computed over; reset when the
  /// body, its note or its text changes.
  _Shown? _shown;

  @override
  void initState() {
    super.initState();
    _hub = ref.read(outlineSectionHubProvider)..addListener(_schedule);
  }

  @override
  void dispose() {
    // No `ref` here: it is gone in teardown.
    _hub
      ..removeListener(_schedule)
      ..leave(this);
    super.dispose();
  }

  /// Computes the current section after this frame's layout, once.
  void _schedule() {
    if (_scheduled || !_hub.watched) return;
    _scheduled = true;
    SchedulerBinding.instance
      ..addPostFrameCallback(_pass)
      ..ensureVisualUpdate();
  }

  void _pass(Duration _) {
    _scheduled = false;
    if (!mounted || !_hub.watched) return;
    SectionTracker.debugPasses++;
    _hub.report(this, _current());
  }

  bool _onNotification(Notification n) {
    if (n is ViewportNotificationMixin && n.depth != 0) {
      return false;
    }
    if (n is ScrollUpdateNotification &&
        SchedulerBinding.instance.schedulerPhase !=
            SchedulerPhase.postFrameCallbacks &&
        _hub.jumpLanded) {
      // A scroll from outside a frame's end (a person's: the seam lands
      // only from there) after the jump landed: the normal rule decides
      // again, also while nothing watches, so scrolling back onto the
      // landing never brings the jump back. Before it lands such a scroll
      // keeps it: the seam still lands it.
      _hub.dropJump();
    }
    if (n is ScrollNotification || n is ScrollMetricsNotification) {
      _schedule();
    }
    return false;
  }

  /// The segmented body under this tracker, if built.
  Element? _bodyElement() {
    Element? found;
    void visit(Element e) {
      if (found != null) return;
      if (e.widget is SegmentedBody) {
        found = e;
      } else {
        e.visitChildren(visit);
      }
    }

    context.visitChildElements(visit);
    return found;
  }

  /// The editor page's scroll under [body]: the outermost Scrollable.
  static ScrollPosition? _positionUnder(Element body) {
    ScrollableState? found;
    void visit(Element e) {
      if (found != null) return;
      if (e is StatefulElement && e.state is ScrollableState) {
        found = e.state as ScrollableState;
      } else {
        e.visitChildren(visit);
      }
    }

    body.visitChildren(visit);
    return found?.position;
  }

  OutlineEntry? _current() {
    final element = _bodyElement();
    if (element == null) return null;
    final body = element.widget as SegmentedBody;
    final note = body.note;
    // Until the editor's body shows [widget.note], no entry of the note it
    // still shows counts.
    if (note.id != widget.note.id) return null;
    final position = _positionUnder(element);
    if (position == null ||
        !position.hasPixels ||
        !position.hasContentDimensions) {
      return null;
    }
    var shown = _shown;
    if (shown == null || !shown.matches(element, note, body.content)) {
      shown = _shown = _Shown(element, note, body.content);
    }
    final entries = shown.entries;

    /// The offset that puts entry [i]'s heading line at the viewport top.
    double? reveal(int i) {
      final at = shown!.anchor(context, i);
      if (at == null) return null;
      final viewport = RenderAbstractViewport.maybeOf(at.row);
      if (viewport == null) return null;
      final rect = revealAnchorRect(at.row, at.arrival);
      return viewport.getOffsetToReveal(at.row, 0.0, rect: rect).offset;
    }

    final jumped = _jumped(note.id, body.content, entries);
    if (jumped != null) {
      final to = reveal(jumped);
      if (to == null) {
        _hub.dropJump();
      } else {
        final landing = (to - outlineJumpInset).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        );
        if ((position.pixels - landing).abs() <= _edge) {
          _hub.markLanded();
          return entries[jumped];
        }
        // Moved off the landing by a scroll the jump did not cause.
        if (_hub.jumpLanded) _hub.dropJump();
      }
    }

    // Heading lines go down the page in entry order: the last one at or
    // above the mark, by bisection.
    final mark = position.pixels + outlineJumpInset + _edge;
    var lo = 0;
    var hi = entries.length - 1;
    var last = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      final to = reveal(mid);
      if (to != null && to <= mark) {
        last = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return last < 0 ? null : entries[last];
  }

  /// The index in [entries] of the Outline jump still standing for note
  /// [noteId] with text [content]; drops a jump that no longer can be.
  int? _jumped(String noteId, String content, List<OutlineEntry> entries) {
    final jump = _hub.jump;
    if (jump == null) return null;
    final arrivals = ref.exists(tabsProvider)
        ? ref.read(tabsProvider).arrivals
        : null;
    final i =
        jump.noteId == noteId &&
            jump.arrivals == arrivals &&
            jump.content == content
        ? entries.indexOf(jump.entry)
        : -1;
    if (i < 0) {
      _hub.dropJump();
      return null;
    }
    return i;
  }

  @override
  Widget build(BuildContext context) {
    // A rebuild of the body (its text, its note) lays it out anew.
    _schedule();
    return NotificationListener<Notification>(
      onNotification: _onNotification,
      child: widget.child,
    );
  }
}

/// The Outline entries of the body [element] shows ([note] with [content])
/// and, found as needed, where each heading is.
class _Shown {
  _Shown(this.element, this.note, this.content)
    : entries = outlineEntries(content, role: note.role);

  final Element element;
  final Note note;
  final String content;
  final List<OutlineEntry> entries;
  final _arrivals = <int, EchoArrival?>{};
  final _rows = <int, RenderBox>{};

  bool matches(Element e, Note n, String c) =>
      identical(e, element) &&
      n.id == note.id &&
      n.role == note.role &&
      (identical(c, content) || c == content);

  /// Entry [i]'s row and its place in it, or null when not laid out.
  ({RenderBox row, EchoArrival arrival})? anchor(BuildContext context, int i) {
    final arrival = _arrivals.putIfAbsent(i, () {
      final e = entries[i];
      return locateInSegment(content, e.segment, e.local, role: note.role);
    });
    if (arrival == null) return null;
    var row = _rows[i];
    if (row == null || !row.attached || !row.hasSize) {
      final found = revealRow(context, note.id, content, arrival)?.row;
      if (found == null) {
        _rows.remove(i);
        return null;
      }
      row = _rows[i] = found;
    }
    return (row: row, arrival: arrival);
  }
}
