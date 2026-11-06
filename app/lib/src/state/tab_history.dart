import 'dart:math' as math;

/// The most entries one tab keeps; a push past it drops the oldest.
const int kMaxTabHistoryEntries = 100;

/// What one tab has shown: an immutable list of targets, a current index and a
/// scroll offset per entry.
///
/// Generic so this file imports nothing from Flutter or Riverpod. Every
/// operation returns a new instance and leaves the receiver untouched.
class TabHistory<T> {
  /// A history with one entry, current, never scrolled.
  TabHistory.initial(T target) : this._([(target, null)], 0);

  const TabHistory._(this._entries, this._index);

  final List<(T, double?)> _entries;
  final int _index;

  /// The target of the current entry.
  T get current => _entries[_index].$1;

  /// The position of the current entry in [entries].
  int get index => _index;

  /// The targets, oldest first. Unmodifiable.
  List<T> get entries => List.unmodifiable([for (final e in _entries) e.$1]);

  /// Whether an entry precedes the current one.
  bool get canGoBack => _index > 0;

  /// Whether an entry follows the current one.
  bool get canGoForward => _index < _entries.length - 1;

  /// The scroll offset of the current entry, or null when never scrolled.
  double? get scrollOffset => _entries[_index].$2;

  /// Drops the Forward entries, appends [target] with no offset and makes it
  /// current. Past [kMaxTabHistoryEntries] the oldest entry goes.
  TabHistory<T> push(T target) {
    final kept = [..._entries.sublist(0, _index + 1), (target, null)];
    final drop = math.max(0, kept.length - kMaxTabHistoryEntries);
    final next = kept.sublist(drop);
    return TabHistory._(next, next.length - 1);
  }

  /// Moves one entry toward the first; on the first entry, an equal history.
  TabHistory<T> back() =>
      canGoBack ? TabHistory._(List.of(_entries), _index - 1) : this;

  /// Moves one entry toward the last; on the last entry, an equal history.
  TabHistory<T> forward() =>
      canGoForward ? TabHistory._(List.of(_entries), _index + 1) : this;

  /// Sets the current entry's scroll offset; other entries are unchanged.
  TabHistory<T> withScrollOffset(double offset) {
    final next = List.of(_entries);
    next[_index] = (next[_index].$1, offset);
    return TabHistory._(next, _index);
  }

  /// Replaces the current entry with [target], which has no scroll offset.
  /// Other entries, the index and the Forward entries stay.
  TabHistory<T> replaceCurrent(T target) {
    final next = List.of(_entries);
    next[_index] = (target, null);
    return TabHistory._(next, _index);
  }

  /// Replaces every entry whose target equals [from] with [to], keeping each
  /// offset and the index.
  TabHistory<T> rewrite(T from, T to) => TabHistory._([
    for (final e in _entries) e.$1 == from ? (to, e.$2) : e,
  ], _index);

  /// Drops the entry at [index]. The current entry stays current; removing the
  /// current entry makes the entry that took its place current, or the new
  /// last entry when there is none.
  ///
  /// Throws [RangeError] when [index] is out of range and [StateError] when
  /// it would remove the only entry.
  TabHistory<T> remove(int index) {
    RangeError.checkValidIndex(index, _entries, 'index', _entries.length);
    if (_entries.length == 1) {
      throw StateError('Cannot remove the only entry of a TabHistory');
    }
    final next = List.of(_entries)..removeAt(index);
    final nextIndex = index < _index ? _index - 1 : _index;
    return TabHistory._(next, math.min(nextIndex, next.length - 1));
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! TabHistory || other._index != _index) return false;
    if (other._entries.length != _entries.length) return false;
    for (var i = 0; i < _entries.length; i++) {
      if (other._entries[i] != _entries[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(_index, Object.hashAll(_entries));
}
