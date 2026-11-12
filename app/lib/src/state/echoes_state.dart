import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../vault_access/vault_access.dart';
import 'clock.dart';
import 'right_panel_tab.dart';
import 'tabs_state.dart' show VirtualTodayTab;
import 'vault_access_state.dart';
import 'vault_state.dart'
    show
        currentVaultProvider,
        rightPanelOpenProvider,
        selectedNoteIdProvider,
        vaultRevisionProvider;

/// What the echoes tab shows (Spec #391 req 34). Every variant has value
/// equality.
sealed class EchoesViewState {
  const EchoesViewState();
}

/// No note is selected, or a canvas is: `select a note to see its echoes.`
class EchoesNoNote extends EchoesViewState {
  const EchoesNoNote();

  @override
  bool operator ==(Object other) => other is EchoesNoNote;

  @override
  int get hashCode => (EchoesNoNote).hashCode;

  @override
  String toString() => 'EchoesNoNote()';
}

/// The virtual Today note, or a note whose read came back `emptyNote`:
/// `write something and echoes will surface here.`
class EchoesNothingWritten extends EchoesViewState {
  const EchoesNothingWritten();

  @override
  bool operator ==(Object other) => other is EchoesNothingWritten;

  @override
  int get hashCode => (EchoesNothingWritten).hashCode;

  @override
  String toString() => 'EchoesNothingWritten()';
}

/// The first read of this note is in flight and there is nothing to show
/// yet (the tab shows `listening for echoes…` after 400 ms).
class EchoesFirstLoad extends EchoesViewState {
  const EchoesFirstLoad();

  @override
  bool operator ==(Object other) => other is EchoesFirstLoad;

  @override
  int get hashCode => (EchoesFirstLoad).hashCode;

  @override
  String toString() => 'EchoesFirstLoad()';
}

/// A read answered [result] (its list may be empty; `pending` drives the
/// `still indexing` line). [refreshing] is true while a re-run is in flight
/// and this previous result stays shown.
class EchoesShown extends EchoesViewState {
  const EchoesShown(this.result, {this.refreshing = false});

  final EchoesReady result;
  final bool refreshing;

  @override
  bool operator ==(Object other) =>
      other is EchoesShown &&
      other.result == result &&
      other.refreshing == refreshing;

  @override
  int get hashCode => Object.hash(EchoesShown, result, refreshing);

  @override
  String toString() => 'EchoesShown($result, refreshing: $refreshing)';
}

/// Echoes are unavailable for [reason] (each reason has its own copy).
class EchoesUnavailableView extends EchoesViewState {
  const EchoesUnavailableView(this.reason);

  final EchoesUnavailableReason reason;

  @override
  bool operator ==(Object other) =>
      other is EchoesUnavailableView && other.reason == reason;

  @override
  int get hashCode => Object.hash(EchoesUnavailableView, reason);

  @override
  String toString() => 'EchoesUnavailableView($reason)';
}

/// The model download run is in flight: `downloading the model…`.
class EchoesDownloading extends EchoesViewState {
  const EchoesDownloading();

  @override
  bool operator ==(Object other) => other is EchoesDownloading;

  @override
  int get hashCode => (EchoesDownloading).hashCode;

  @override
  String toString() => 'EchoesDownloading()';
}

/// A read threw [error]. [lastGood] is the last ready result for this note,
/// still shown above the error, or null when there was none.
class EchoesError extends EchoesViewState {
  const EchoesError(this.error, {this.lastGood});

  final Object error;
  final EchoesReady? lastGood;

  @override
  bool operator ==(Object other) =>
      other is EchoesError &&
      other.error == error &&
      other.lastGood == lastGood;

  @override
  int get hashCode => Object.hash(EchoesError, error, lastGood);

  @override
  String toString() => 'EchoesError($error, lastGood: $lastGood)';
}

/// The least time between the starts of two spaced runs (a revision change
/// or an L8 `pending` re-run).
const _spacing = Duration(seconds: 10);

/// What a run asks the CLI for: a normal read, or one that may download the
/// embedding model (`allowDownload: true`).
enum _RunKind { normal, download }

/// One `echoes` read: the note it read, its kind, the `linkCompleted()`
/// count its result belongs to, the revision-change count when it started,
/// and when it started.
class _Run {
  _Run(this.noteId, this.kind, this.linkEpoch, this.revision, this.startedAt);

  final String noteId;
  final _RunKind kind;

  /// Starts as the `linkCompleted()` count when the run started; a link that
  /// keeps the run (ruling D46) re-tags it to the new count.
  int linkEpoch;
  final int revision;
  final DateTime startedAt;
}

/// The echoes tab's state for the selected note (`selectedNoteIdProvider`:
/// a canvas zoomed into a note counts as that note, a plain canvas is no
/// note), and the runs of `memex echoes` behind it (Spec #391 reqs 22-24,
/// 32, 34; Interview Ledger L5, L8):
///
/// - It runs only while the echoes tab is visible (`rightPanelOpenProvider`
///   and `rightPanelTabProvider == RightPanelTab.echoes`) on a real note:
///   never for no note, a plain canvas or the virtual Today note. Becoming
///   visible on a note runs once.
/// - A revision change runs no sooner than 10 s after the previous run
///   started, through one timer (changes inside the window give one run). A
///   note switch, `linkCompleted()`, `download()` and `retry()` run at once.
/// - L8: while visible, an applied ready result with `pending > 0` runs
///   again 10 s after its run started; hiding the tab or switching notes
///   cancels it.
/// - One run in flight per vault and at most one queued; a newer request
///   replaces the queued one. The run state is kept per open vault
///   (`currentVaultProvider`), not per `vaultAccessProvider` object: a new
///   access for the same vault (a settings write rebuilds it) keeps the run
///   in flight, the spacing and the shown result, and each run reads the
///   current access when it starts. A result applies only while its note is still
///   selected and when its run started after the last `linkCompleted()`.
/// - Ruling D46: `linkCompleted()` keeps a run in flight for the selected
///   note that started at or after the latest `vaultRevisionProvider` change
///   (the link's own bump), so its result applies and no second run is
///   queued. Order is a per-runner revision count, not the wall clock, so a
///   clock that jumps back never keeps an older run. With no revision change
///   since the runner was built, the link discards the run in flight.
/// - A re-run keeps the previous result shown; a thrown error keeps the last
///   ready result for the same note next to it.
class EchoesNotifier extends Notifier<EchoesViewState> {
  _EchoesRunner? _runner;

  @override
  EchoesViewState build() {
    // Only the open vault's identity resets the run state; the access object
    // is read per run (see the class doc).
    ref.watch(currentVaultProvider);
    final runner = _EchoesRunner(ref, (view) => state = view);
    _runner = runner;
    ref.onDispose(runner.dispose);
    ref.listen<bool>(
      vaultAccessProvider.select((access) => access != null),
      (_, _) => runner.inputsChanged(),
    );
    ref.listen<String?>(
      selectedNoteIdProvider,
      (_, _) => runner.inputsChanged(),
    );
    ref.listen<bool>(rightPanelOpenProvider, (_, _) => runner.inputsChanged());
    ref.listen<RightPanelTab>(
      rightPanelTabProvider,
      (_, _) => runner.inputsChanged(),
    );
    ref.listen<int>(vaultRevisionProvider, (_, _) => runner.revisionChanged());
    return runner.start();
  }

  /// The `Download model (130 MB)` button (req 22): runs with
  /// `allowDownload: true` at once (after the run in flight, if any) and
  /// shows [EchoesDownloading] until that run answers. A failure shows
  /// `EmbedderUnavailable` with its cause. Later normal runs do not download.
  Future<void> download() async => _runner?.download();

  /// The `retry` action (req 34): repeats the kind of the last run whose
  /// result is shown (a download after a failed download), at once.
  Future<void> retry() async => _runner?.retry();

  /// A row's `link` finished (req 32): discards the result of any run that
  /// started before it and re-reads at once. A run in flight that started at
  /// or after the latest revision change (the link's bump) is kept instead
  /// and its result applies (ruling D46).
  Future<void> linkCompleted() async => _runner?.linkCompleted();
}

/// The run state of one [EchoesNotifier] build (one open vault). A vault
/// change disposes it, and its in-flight result is then dropped.
class _EchoesRunner {
  _EchoesRunner(this._ref, this._emit);

  final Ref _ref;
  final void Function(EchoesViewState view) _emit;

  bool _disposed = false;
  EchoesViewState? _emitted;

  String? _noteId;
  bool _visible = false;
  bool _hasAccess = false;

  // What the selected note shows. Reset on a note switch.
  EchoesResult? _result;
  Object? _error;
  EchoesReady? _lastGood;
  _RunKind _lastKind = _RunKind.normal;

  _Run? _inFlight;
  _RunKind? _queued;
  Timer? _timer;
  DateTime? _lastStart;
  int _linkEpoch = 0;
  // Revision changes seen by this runner; 0 means none yet.
  int _revision = 0;

  AppClock get _clock => _ref.read(clockProvider);

  bool get _active {
    final id = _noteId;
    return _visible &&
        _hasAccess &&
        id != null &&
        VirtualTodayTab.dateOf(id) == null;
  }

  EchoesAccess? _readAccess() => _ref.read(vaultAccessProvider)?.echoes;

  bool _readVisible() =>
      _ref.read(rightPanelOpenProvider) &&
      _ref.read(rightPanelTabProvider) == RightPanelTab.echoes;

  EchoesViewState start() {
    _noteId = _ref.read(selectedNoteIdProvider);
    _visible = _readVisible();
    _hasAccess = _readAccess() != null;
    if (_active) {
      scheduleMicrotask(() {
        if (_disposed || _lastStart != null || _inFlight != null) return;
        _request(_RunKind.normal);
        _publish();
      });
    }
    return _emitted = _view();
  }

  void dispose() {
    _disposed = true;
    _cancelTimer();
    _queued = null;
  }

  void inputsChanged() {
    if (_disposed) return;
    final noteId = _ref.read(selectedNoteIdProvider);
    final switched = noteId != _noteId;
    final wasActive = _active;
    _noteId = noteId;
    _visible = _readVisible();
    _hasAccess = _readAccess() != null;
    if (switched) {
      _result = null;
      _error = null;
      _lastGood = null;
      _lastKind = _RunKind.normal;
      _queued = null;
      _cancelTimer();
    }
    if (!_active) {
      _cancelTimer();
      _queued = null;
    } else if (switched || !wasActive) {
      _request(_RunKind.normal);
    }
    _publish();
  }

  void revisionChanged() {
    if (_disposed) return;
    // Counted before the run it may start, so that run is at or after it.
    _revision++;
    _requestSpaced();
    _publish();
  }

  void download() {
    if (_disposed || !_active) return;
    _request(_RunKind.download);
    _publish();
  }

  void retry() {
    if (_disposed || !_active) return;
    _request(_lastKind);
    _publish();
  }

  void linkCompleted() {
    if (_disposed) return;
    _linkEpoch++;
    final run = _inFlight;
    if (run != null &&
        run.noteId == _noteId &&
        run.revision > 0 &&
        run.revision == _revision) {
      // D46: the run started at or after the link's revision bump, so it read
      // the linked vault. Keep it for this link instead of running again.
      run.linkEpoch = _linkEpoch;
    } else if (_active) {
      _cancelTimer();
      _request(_RunKind.normal);
    }
    _publish();
  }

  /// A run no sooner than [_spacing] after the previous run started. One
  /// timer serves every spaced request; a wall clock that jumps back never
  /// makes the wait longer than [_spacing].
  void _requestSpaced() {
    if (!_active || _timer != null) return;
    final last = _lastStart;
    var wait = Duration.zero;
    if (last != null) {
      wait = _spacing - _clock.now().difference(last);
      if (wait > _spacing) wait = _spacing;
    }
    if (wait <= Duration.zero) {
      _request(_RunKind.normal);
      return;
    }
    _timer = _clock.after(wait, () {
      _timer = null;
      if (_disposed) return;
      _request(_RunKind.normal);
      _publish();
    });
  }

  /// Starts a run now, or queues it behind the run in flight. The queued
  /// request is replaced, except that a queued download stays a download.
  void _request(_RunKind kind) {
    if (!_active) return;
    if (_inFlight != null) {
      _queued = _queued == _RunKind.download ? _RunKind.download : kind;
      return;
    }
    _start(kind);
  }

  void _start(_RunKind kind) {
    final access = _readAccess();
    if (access == null) return;
    _cancelTimer();
    final run = _Run(_noteId!, kind, _linkEpoch, _revision, _clock.now());
    _lastStart = run.startedAt;
    _inFlight = run;
    unawaited(_execute(run, access));
  }

  Future<void> _execute(_Run run, EchoesAccess access) async {
    EchoesResult? result;
    Object? error;
    try {
      result = await access.echoes(
        run.noteId,
        allowDownload: run.kind == _RunKind.download,
      );
    } catch (e) {
      if (run.kind == _RunKind.download) {
        result = EchoesUnavailable(EmbedderUnavailable(e.toString()));
      } else {
        error = e;
      }
    }
    if (_disposed) return;
    _inFlight = null;
    final applies = run.noteId == _noteId && run.linkEpoch == _linkEpoch;
    if (applies) {
      _lastKind = run.kind;
      _error = error;
      if (result != null) {
        _result = result;
        if (result is EchoesReady) _lastGood = result;
      }
    }
    final next = _queued;
    _queued = null;
    if (next != null) {
      _request(next);
    } else if (applies && result is EchoesReady && result.pending > 0) {
      _requestSpaced();
    }
    _publish();
  }

  void _cancelTimer() {
    _timer?.cancel();
    _timer = null;
  }

  bool get _downloading {
    if (_queued == _RunKind.download) return true;
    final run = _inFlight;
    return run != null &&
        run.kind == _RunKind.download &&
        run.noteId == _noteId &&
        run.linkEpoch == _linkEpoch;
  }

  EchoesViewState _view() {
    final id = _noteId;
    if (id == null) return const EchoesNoNote();
    if (VirtualTodayTab.dateOf(id) != null) return const EchoesNothingWritten();
    if (_downloading) return const EchoesDownloading();
    final error = _error;
    if (error != null) return EchoesError(error, lastGood: _lastGood);
    return switch (_result) {
      null => const EchoesFirstLoad(),
      EchoesReady(emptyNote: true) => const EchoesNothingWritten(),
      final EchoesReady ready => EchoesShown(
        ready,
        refreshing: _inFlight != null,
      ),
      EchoesUnavailable(:final reason) => EchoesUnavailableView(reason),
    };
  }

  void _publish() {
    if (_disposed) return;
    final view = _view();
    if (view == _emitted) return;
    _emitted = view;
    _emit(view);
  }
}

final echoesAsyncProvider = NotifierProvider<EchoesNotifier, EchoesViewState>(
  EchoesNotifier.new,
);
