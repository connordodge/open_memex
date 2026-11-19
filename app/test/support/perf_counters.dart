// WI #125 (Spec #122 Technical Decision 8; rulings D8, D9): every perf work
// counter of the editor, reset and read in one place. Exported for #122's
// call-count gates and #123's 0-count criteria (a gesture or an attach that
// must not rebuild, repaint, measure or re-lay out the long note).
//
// Counters count work, never time. Each is one increment in the function it
// names and is never read by production code. [PerfCounters.snapshot]
// returns every counter by [PerfCounters.names]; [PerfCounters.delta] is the
// work done since an earlier snapshot.
import 'package:open_memex_app/src/editor/editor_rows.dart' as rows;
import 'package:open_memex_app/src/editor/markdown_inline.dart' as inline;
import 'package:open_memex_app/src/editor/markdown_lines.dart' as lines;
import 'package:open_memex_app/src/state/spell_check_controller.dart';
import 'package:open_memex_app/src/widgets/editor/editor_row.dart' as row;
import 'package:open_memex_app/src/widgets/editor/line_boxes.dart';
import 'package:open_memex_app/src/widgets/editor/live_preview_controller.dart';
import 'package:open_memex_app/src/widgets/editor/live_preview_decorations.dart'
    as decorations;
import 'package:open_memex_app/src/widgets/editor/marker_column.dart' as marker;
import 'package:open_memex_app/src/widgets/editor/paragraph_line_boxes.dart';
import 'package:open_memex_app/src/widgets/editor/segment_view.dart';
import 'package:open_memex_app/src/widgets/editor/spell_check_host.dart'
    as host;
import 'package:open_memex_app/src/widgets/editor/spell_squiggles.dart'
    as squiggles;
import 'package:open_memex_app/src/widgets/find/find_highlights.dart' as find;
import 'package:open_memex_app/src/widgets/outline/section_tracker.dart';

/// The editor's perf counters.
abstract final class PerfCounters {
  /// Every counter's name, in [snapshot] order.
  static const List<String> names = [
    // Pure parsing (plain top-level ints, ruling D9).
    'tokenizeInline',
    'classifyLines',
    'splitRows',
    // Line-box measuring: `*Measures` is every fresh whole-field text
    // layout; `*LineWalks` is every whole-text line walk. A single-line or
    // range-local measure raises only `*Measures`.
    'editableLineMeasures',
    'editableLineWalks',
    'paragraphLineMeasures',
    'paragraphLineWalks',
    // Decorations and spans.
    'layoutDecorations',
    'buildTextSpan',
    // Rows, segments, marker columns.
    'rowBuilds',
    'rowSelectionPaints',
    'segmentBuilds',
    'segmentSetStates',
    'markerColumnBuilds',
    'markerColumnSetStates',
    'markerColumnPaints',
    // Outline.
    'sectionTrackerPasses',
    // Spelling.
    'spellEvaluations',
    'spellHostLineCalls',
    'spellHostRectCalls',
    'spellSquigglePaints',
    // Find.
    'findHighlightUpdates',
    'findHighlightPaints',
  ];

  /// Every counter's current value, by [names].
  static Map<String, int> snapshot() => {
    'tokenizeInline': inline.debugTokenizeInlineCalls,
    'classifyLines': lines.debugClassifyLinesCalls,
    'splitRows': rows.debugSplitRowsCalls,
    'editableLineMeasures': RenderEditableLineBoxes.debugMeasures,
    'editableLineWalks': RenderEditableLineBoxes.debugLineWalks,
    'paragraphLineMeasures': RenderParagraphLineBoxes.debugMeasures,
    'paragraphLineWalks': RenderParagraphLineBoxes.debugLineWalks,
    'layoutDecorations': decorations.debugLayoutDecorationsCalls,
    'buildTextSpan': LivePreviewController.debugBuildTextSpans,
    'rowBuilds': row.EditorRow.debugBuilds,
    'rowSelectionPaints': row.debugEditorRowSelectionPaints,
    'segmentBuilds': SegmentViewState.debugBuilds,
    'segmentSetStates': SegmentViewState.debugSetStates,
    'markerColumnBuilds': marker.debugMarkerColumnBuilds,
    'markerColumnSetStates': marker.debugMarkerColumnSetStates,
    'markerColumnPaints': marker.debugMarkerColumnPaints,
    'sectionTrackerPasses': SectionTracker.debugPasses,
    'spellEvaluations': SpellCheckController.debugEvaluations,
    'spellHostLineCalls': host.debugSpellHostLineCalls,
    'spellHostRectCalls': host.debugSpellHostRectCalls,
    'spellSquigglePaints': squiggles.debugSpellSquigglePaints,
    'findHighlightUpdates': find.debugFindHighlightUpdates,
    'findHighlightPaints': find.debugFindHighlightPaints,
  };

  /// Sets every counter to 0.
  static void reset() {
    inline.debugTokenizeInlineCalls = 0;
    lines.debugClassifyLinesCalls = 0;
    rows.debugSplitRowsCalls = 0;
    RenderEditableLineBoxes.debugMeasures = 0;
    RenderEditableLineBoxes.debugLineWalks = 0;
    RenderParagraphLineBoxes.debugMeasures = 0;
    RenderParagraphLineBoxes.debugLineWalks = 0;
    decorations.debugLayoutDecorationsCalls = 0;
    LivePreviewController.debugBuildTextSpans = 0;
    row.EditorRow.debugBuilds = 0;
    row.debugEditorRowSelectionPaints = 0;
    SegmentViewState.debugBuilds = 0;
    SegmentViewState.debugSetStates = 0;
    marker.debugMarkerColumnBuilds = 0;
    marker.debugMarkerColumnSetStates = 0;
    marker.debugMarkerColumnPaints = 0;
    SectionTracker.debugPasses = 0;
    SpellCheckController.debugEvaluations = 0;
    host.debugSpellHostLineCalls = 0;
    host.debugSpellHostRectCalls = 0;
    squiggles.debugSpellSquigglePaints = 0;
    find.debugFindHighlightUpdates = 0;
    find.debugFindHighlightPaints = 0;
  }

  /// The work done since [before] (a [snapshot]): each counter's value now
  /// minus its value then.
  static Map<String, int> delta(Map<String, int> before) {
    final now = snapshot();
    return {for (final name in names) name: now[name]! - (before[name] ?? 0)};
  }
}
