// WI #80 (Spec #61 F1, TD1): the one app-wide Find in note state and the
// native menu's action dispatch. F2 (Find bar), F5 (native menu) and F6
// (editor integration) drive these commands; the rules are the pure
// functions of `editor/find_in_note.dart`. No widgets (state imports none).
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../editor/find_in_note.dart';

/// The Find in note state (TD1). Held in memory only: nothing here is ever
/// persisted, so [lastQuery] is empty at launch (Req 12).
final class FindInNoteState {
  const FindInNoteState({
    this.open = false,
    this.query = '',
    this.lastQuery = '',
    this.sources = const [],
    this.matches = const [],
    this.current,
    this.caret,
    this.focusRequest = 0,
  });

  /// Whether the Find bar shows.
  final bool open;

  /// The Find field's query.
  final String query;

  /// The app-wide last query: follows every query change and survives
  /// closing and note changes (Reqs 12, 40, 42).
  final String lastQuery;

  /// The searched text of the shown note, as last given to
  /// [FindInNoteNotifier.setSources].
  final List<FindSource> sources;

  /// The matches of [query] in [sources] (empty while closed), in document
  /// order.
  final List<FindMatch> matches;

  /// The index of the current match in [matches]; null when there is none.
  final int? current;

  /// The caret anchor for the first current match (null: never placed in
  /// this note, so the note top).
  final FindCaret? caret;

  /// Bumped when the Find bar should focus its field and select all of it.
  final int focusRequest;

  /// The current match, or null when there is none.
  FindMatch? get currentMatch => current == null ? null : matches[current!];

  /// This state with the given fields replaced. [current] and [caret] are
  /// nullable, so they are replaced only when their `set` flag is true.
  FindInNoteState copyWith({
    bool? open,
    String? query,
    String? lastQuery,
    List<FindSource>? sources,
    List<FindMatch>? matches,
    int? current,
    bool setCurrent = false,
    FindCaret? caret,
    bool setCaret = false,
    int? focusRequest,
  }) => FindInNoteState(
    open: open ?? this.open,
    query: query ?? this.query,
    lastQuery: lastQuery ?? this.lastQuery,
    sources: sources ?? this.sources,
    matches: matches ?? this.matches,
    current: setCurrent ? current : this.current,
    caret: setCaret ? caret : this.caret,
    focusRequest: focusRequest ?? this.focusRequest,
  );
}

/// The commands on [FindInNoteState] (Reqs 12-15, 18-19, 37-42).
class FindInNoteNotifier extends Notifier<FindInNoteState> {
  @override
  FindInNoteState build() => const FindInNoteState();

  /// Closed: opens with [FindInNoteState.lastQuery] as the query, its
  /// matches, the current match from `firstAtOrAfter(caret)`, and bumps
  /// `focusRequest`. Open: only bumps `focusRequest` (Reqs 12-13).
  void show() {
    if (state.open) {
      state = state.copyWith(focusRequest: state.focusRequest + 1);
      return;
    }
    _openWith(state.lastQuery, focusRequest: state.focusRequest + 1);
  }

  /// Opens with [query] as the query and last query, its matches, and the
  /// current match from `firstAtOrAfter(caret)`.
  void _openWith(String query, {int? focusRequest}) {
    final matches = findMatches(state.sources, query);
    state = state.copyWith(
      open: true,
      query: query,
      lastQuery: query,
      matches: matches,
      current: firstAtOrAfter(matches, state.caret),
      setCurrent: true,
      focusRequest: focusRequest,
    );
  }

  /// Uses the editor's selection [text] as the query (each line break,
  /// `\n`, `\r\n` or `\r`, becomes one space), opening the bar without bumping `focusRequest` (focus stays
  /// in the editor). An empty [text] changes nothing (Req 14).
  void useSelection(String text) {
    if (text.isEmpty) return;
    _openWith(text.replaceAll(RegExp('\r\n|\r|\n'), ' '));
  }

  /// Sets the query and the last query, then recomputes the matches and
  /// sets the current match from `firstAtOrAfter(caret)` (Req 18).
  void setQuery(String query) {
    final matches = findMatches(state.sources, query);
    state = state.copyWith(
      query: query,
      lastQuery: query,
      matches: matches,
      current: firstAtOrAfter(matches, state.caret),
      setCurrent: true,
    );
  }

  /// Replaces the searched sources. While open, recomputes the matches and
  /// keeps the current match through `carryCurrent` when [carry]; otherwise,
  /// or when there was no current match, it comes from
  /// `firstAtOrAfter(caret)` (Reqs 37-38). While open, `current` is null
  /// exactly when `matches` is empty.
  /// While closed, only stores [sources].
  void setSources(List<FindSource> sources, {bool carry = true}) {
    if (!state.open) {
      state = state.copyWith(sources: sources);
      return;
    }
    final matches = findMatches(sources, state.query);
    final carried = carry
        ? carryCurrent(
            before: state.sources,
            oldMatches: state.matches,
            oldCurrent: state.current,
            after: sources,
            newMatches: matches,
          )
        : null;
    state = state.copyWith(
      sources: sources,
      matches: matches,
      current: carried ?? firstAtOrAfter(matches, state.caret),
      setCurrent: true,
    );
  }

  /// Source mode toggled (Req 39): [sources] are the searched text of the
  /// mode being entered. While open, keeps the query, recomputes the
  /// matches and maps the current match with `mapCurrentAcrossMode` through
  /// [tokenOffset] (the Source-field offset where `split()` segment
  /// `segment` starts). While closed, only stores [sources].
  void switchMode(
    List<FindSource> sources, {
    required int Function(int segment) tokenOffset,
  }) {
    if (!state.open) {
      state = state.copyWith(sources: sources);
      return;
    }
    final matches = findMatches(sources, state.query);
    state = state.copyWith(
      sources: sources,
      matches: matches,
      current: mapCurrentAcrossMode(
        from: state.matches,
        current: state.current,
        to: matches,
        tokenOffset: tokenOffset,
      ),
      setCurrent: true,
    );
  }

  /// Sets the caret anchor. Never moves the current match.
  void setCaret(FindCaret? caret) {
    state = state.copyWith(caret: caret, setCaret: true);
  }

  /// Open: steps forward with wrap (Req 19). Closed with a non-empty last
  /// query: opens with it at `firstAtOrAfter(caret)`, without bumping
  /// `focusRequest` (Req 15). Closed with an empty last query: nothing.
  /// Returns the new current match, or null.
  FindMatch? next() => _step(forward: true);

  /// As [next], stepping back; a closed bar opens at `lastBefore(caret)`.
  FindMatch? previous() => _step(forward: false);

  FindMatch? _step({required bool forward}) {
    if (!state.open) {
      final query = state.lastQuery;
      if (query.isEmpty) return null;
      final matches = findMatches(state.sources, query);
      state = state.copyWith(
        open: true,
        query: query,
        matches: matches,
        current: forward
            ? firstAtOrAfter(matches, state.caret)
            : lastBefore(matches, state.caret),
        setCurrent: true,
      );
      return state.currentMatch;
    }
    final current = state.current;
    if (current == null) return null;
    state = state.copyWith(
      current: stepIndex(current, state.matches.length, forward: forward),
      setCurrent: true,
    );
    return state.currentMatch;
  }

  /// Closes: returns the current match (or null) so the editor can select
  /// it, clears the matches and the current match, keeps the last query
  /// (Req 40).
  FindMatch? close() {
    final current = state.currentMatch;
    state = state.copyWith(
      open: false,
      matches: const [],
      current: null,
      setCurrent: true,
    );
    return current;
  }

  /// Another note shows: closes as [close] does and forgets the caret
  /// anchor and the sources, keeping the last query (Req 42).
  void noteChanged() {
    state = FindInNoteState(
      lastQuery: state.lastQuery,
      focusRequest: state.focusRequest,
    );
  }
}

/// The one app-wide Find in note state (TD1).
final findInNoteProvider =
    NotifierProvider<FindInNoteNotifier, FindInNoteState>(
      FindInNoteNotifier.new,
    );

/// The native Edit > Find items (TD5).
enum FindMenuAction { show, next, previous, useSelection }

/// One dispatched [FindMenuAction] and its sequence number: every dispatch
/// raises [seq] by one, so two equal actions are two notifications.
final class FindMenuDispatch {
  const FindMenuDispatch(this.action, this.seq);

  /// The dispatched action.
  final FindMenuAction action;

  /// 1 for the first dispatch, then one more per dispatch.
  final int seq;

  @override
  bool operator ==(Object other) =>
      other is FindMenuDispatch && other.action == action && other.seq == seq;

  @override
  int get hashCode => Object.hash(action, seq);

  @override
  String toString() => 'FindMenuDispatch(${action.name}, $seq)';
}

/// The last dispatched menu action (null before the first). F5 dispatches
/// from the native menu; F6's editor listens and performs it.
class FindMenuActionsNotifier extends Notifier<FindMenuDispatch?> {
  @override
  FindMenuDispatch? build() => null;

  /// Dispatches [action] with the next sequence number.
  void dispatch(FindMenuAction action) {
    state = FindMenuDispatch(action, (state?.seq ?? 0) + 1);
  }
}

/// The native menu's Find actions (F5 dispatches, F6 performs).
final findMenuActionsProvider =
    NotifierProvider<FindMenuActionsNotifier, FindMenuDispatch?>(
      FindMenuActionsNotifier.new,
    );
