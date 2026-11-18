// WI #78 (56-A4, Spec #59 reqs 17-18, 28, 30-33, 42): the Command palette's
// Passages runner, passage chooser and the overrides that fill #76's seam.
import 'dart:async';
import 'dart:math' show max;
import 'dart:ui' show TextRange;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../vault_access/search_access.dart';
import 'clock.dart';
import 'command_palette_state.dart';
import 'note_reveal.dart';
import 'palette_preview_state.dart';
import 'search_model_download.dart';
import 'tabs_state.dart';
import 'vault_access_state.dart';
import 'vault_state.dart';

/// How long the input rests before Passages searches (req 17).
const passagesDebounce = Duration(milliseconds: 250);

/// The shortest trimmed input Passages searches for (req 17).
const passagesMinQuery = 2;

/// One search the runner started.
class _Run {
  _Run(this.query, this.session, this.vault);

  final String query;
  final int session;
  final VaultRef? vault;
}

/// Fills `palettePassagesProvider` (#76's seam): the debounced, queued
/// `search` runs behind the Passages group.
///
/// - Only a trimmed input of [passagesMinQuery]+ characters searches,
///   [passagesDebounce] after the last [setQuery].
/// - One search runs at a time, plus one queued input that a newer one
///   replaces; only the latest input's answer shows.
/// - Between a keystroke and the debounce the previous answer's rows stay
///   ([PassagesDimmed]); then [PassagesSearching] until the answer.
/// - [close] cancels the debounce and drops the queue; a search still in
///   flight ends, and its answer is discarded.
/// - It never watches `vaultRevisionProvider` (R42), and drops an answer for
///   a vault that is no longer open.
/// - A `model_not_downloaded` answer follows the vault's
///   `searchModelDownloadProvider`: [PassagesDownloading] while it runs,
///   [PassagesDownloadFailed] after a failure, and a success re-runs the
///   current input.
class PalettePassagesRunner extends PalettePassagesNotifier {
  /// The latest trimmed input, or null before the first.
  String? _query;
  Timer? _timer;
  _Run? _inFlight;
  String? _queued;
  var _closed = false;

  /// Bumped by [close] and each build: a run from an older session never
  /// shows.
  var _session = 0;

  /// The rows the last answer listed, kept dimmed after a keystroke.
  List<PassageItem> _lastRows = const [];
  String? _lastHint;

  @override
  PassagesView build() {
    _timer?.cancel();
    _timer = null;
    _query = null;
    _inFlight = null;
    _queued = null;
    _closed = false;
    _session++;
    _lastRows = const [];
    _lastHint = null;
    final vault = ref.watch(currentVaultProvider);
    if (vault != null) {
      ref.listen(searchModelDownloadProvider(vault), (_, s) => _onDownload(s));
    }
    ref.onDispose(() {
      _timer?.cancel();
      _timer = null;
      _queued = null;
    });
    return const PassagesIdle();
  }

  @override
  void setQuery(String query) {
    _closed = false;
    if (query == _query) return;
    _query = query;
    _timer?.cancel();
    _timer = null;
    if (query.length < passagesMinQuery) {
      _queued = null;
      state = const PassagesIdle();
      return;
    }
    state = PassagesDimmed(_lastRows, hint: _lastHint);
    _timer = ref.read(clockProvider).after(passagesDebounce, _fire);
  }

  @override
  void close() {
    _closed = true;
    _session++;
    _timer?.cancel();
    _timer = null;
    _queued = null;
    _query = null;
    _lastRows = const [];
    _lastHint = null;
  }

  void _fire() {
    _timer = null;
    final query = _query;
    if (_closed || query == null) return;
    state = const PassagesSearching();
    _request(query);
  }

  /// Runs [query] now, or queues it behind the search in flight. A search
  /// in flight for the same input serves it, unless [again] (the model just
  /// arrived, so an answer started before it is stale).
  void _request(String query, {bool again = false}) {
    final running = _inFlight;
    if (running != null) {
      final served =
          !again && running.query == query && running.session == _session;
      _queued = served ? null : query;
      return;
    }
    _run(query);
  }

  Future<void> _run(String query) async {
    final vault = ref.read(currentVaultProvider);
    final search = ref.read(vaultAccessProvider)?.search;
    if (search == null) {
      state = const PassagesIdle();
      return;
    }
    final run = _Run(query, _session, vault);
    _inFlight = run;
    Object answer;
    try {
      answer = await search.search(query);
    } catch (e) {
      answer = e;
    }
    if (!identical(_inFlight, run)) return;
    _inFlight = null;
    if (_shows(run)) _show(run, answer);
    final next = _queued;
    _queued = null;
    if (next != null && !_closed && next == _query) _run(next);
  }

  /// Whether [run]'s answer is the one to show now.
  bool _shows(_Run run) =>
      !_closed &&
      run.session == _session &&
      run.query == _query &&
      run.vault == ref.read(currentVaultProvider);

  void _show(_Run run, Object answer) {
    switch (answer) {
      case SearchReady(:final hits, :final semantic):
        final now = ref.read(clockProvider).now();
        final rows = [
          for (final hit in hits)
            PassageItem(
              hit,
              meta: passageMeta(hit, now),
              marks: passageMarks(hit.snippet, run.query),
            ),
        ];
        final shown = PassagesShown(rows: rows, semantic: semantic);
        _lastRows = rows;
        _lastHint = shown.hint;
        state = semantic == Semantic.modelNotDownloaded
            ? _withDownload(rows, shown)
            : shown;
      case SearchUnavailable(:final reason):
        _lastRows = const [];
        _lastHint = null;
        state = PassagesUnavailable(reason);
      default:
        _lastRows = const [];
        _lastHint = null;
        state = const PassagesError();
    }
  }

  /// A model-not-downloaded answer's view for the vault's download state.
  PassagesView _withDownload(List<PassageItem> rows, PassagesView shown) {
    final vault = ref.read(currentVaultProvider);
    if (vault == null) return shown;
    return switch (ref.read(searchModelDownloadProvider(vault))) {
      SearchModelDownloadStatus.downloading => PassagesDownloading(rows),
      SearchModelDownloadStatus.failed => PassagesDownloadFailed(rows),
      _ => shown,
    };
  }

  void _onDownload(SearchModelDownloadStatus status) {
    if (_closed) return;
    final view = state;
    switch (status) {
      case SearchModelDownloadStatus.downloading:
        if (_wantsModel(view)) state = PassagesDownloading(view.rows);
      case SearchModelDownloadStatus.failed:
        if (view is PassagesDownloading) {
          state = PassagesDownloadFailed(view.rows);
        }
      case SearchModelDownloadStatus.succeeded:
        // Meaning search is on now: search the current input again,
        // keeping the rows on screen until it answers.
        final query = _query;
        if (query != null && query.length >= passagesMinQuery) {
          _request(query, again: true);
        }
      case SearchModelDownloadStatus.idle:
        break;
    }
  }

  static bool _wantsModel(PassagesView view) =>
      view is PassagesDownloadFailed ||
      (view is PassagesShown && view.semantic == Semantic.modelNotDownloaded);
}

/// A passage row's meta: `via <YYYY-MM-DD>` for a transcluded hit, else
/// `daily · <age> ago` for a daily note and `note · <age> ago` otherwise
/// (pack 76), with the age from [now].
String passageMeta(SearchHit hit, DateTime now) {
  final via = hit.via;
  if (via != null) return 'via $via';
  final kind = hit.noteRole == 'daily' ? 'daily' : 'note';
  return '$kind · ${paletteAge(hit.noteUpdatedAt, now)}';
}

/// How long before [now] the ms-epoch [updatedAt] was, as pack 76 draws it:
/// `<n> h ago` under a day, `<n> d ago` under a week, else `<n> w ago`;
/// under an hour `just now` (pack 76 draws no smaller unit).
String paletteAge(int updatedAt, DateTime now) {
  final ago = now.difference(DateTime.fromMillisecondsSinceEpoch(updatedAt));
  if (ago.inHours < 1) return 'just now';
  if (ago.inHours < 24) return '${ago.inHours} h ago';
  if (ago.inDays < 7) return '${ago.inDays} d ago';
  return '${ago.inDays ~/ 7} w ago';
}

/// Every case-insensitive occurrence in [text] of each whitespace-separated
/// word of [query], in order, overlapping ranges merged.
List<TextRange> passageMarks(String text, String query) {
  final found = <TextRange>[];
  for (final word in query.split(RegExp(r'\s+'))) {
    if (word.isEmpty) continue;
    final pattern = RegExp(
      RegExp.escape(word),
      caseSensitive: false,
      unicode: true,
    );
    for (final m in pattern.allMatches(text)) {
      if (m.end > m.start) found.add(TextRange(start: m.start, end: m.end));
    }
  }
  found.sort((a, b) => a.start.compareTo(b.start));
  final merged = <TextRange>[];
  for (final r in found) {
    final last = merged.isEmpty ? null : merged.last;
    if (last != null && r.start < last.end) {
      merged[merged.length - 1] = TextRange(
        start: last.start,
        end: max(last.end, r.end),
      );
    } else {
      merged.add(r);
    }
  }
  return merged;
}

/// Chooses a passage (D2, D3): first `navigate(NoteTab(noteId))`, or with
/// [newTab] `openOrFocus`, then asks `noteRevealProvider` to land on the
/// hit's byte offset a third of the way down, with the arrival flash and
/// leaving Source mode. 54-R0 owns the landing (same note, stale target,
/// null offset at the top).
PaletteChooser<PassageItem> _passageChooser(Ref ref) =>
    (item, {required newTab}) {
      final hit = item.hit;
      final tab = NoteTab(hit.noteId);
      final tabs = ref.read(tabsProvider.notifier);
      if (newTab) {
        tabs.openOrFocus(tab);
      } else {
        tabs.navigate(tab);
      }
      ref
          .read(noteRevealProvider.notifier)
          .request(
            NoteRevealRequest(
              hit.noteId,
              RevealAtByte(hit.startByte),
              const RevealThird(),
              flash: true,
              leaveSource: true,
            ),
          );
    };

/// The overrides that fill #76's Passages, preview and passage chooser
/// seams, spread into `appRootOverrides` (lead ruling W1).
final List<Override> palettePassagesOverrides = [
  palettePassagesProvider.overrideWith(PalettePassagesRunner.new),
  palettePreviewProvider.overrideWith(PalettePreviewReader.new),
  palettePassageChooserProvider.overrideWith(_passageChooser),
];
