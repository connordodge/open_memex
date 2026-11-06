// SKELETON (WI #265, red mode): signatures and neutral stubs only. The
// implementer replaces every body. Imports nothing, so the file stays free of
// Flutter and Riverpod.

/// The most entries one tab keeps; a push past it drops the oldest.
const int kMaxTabHistoryEntries = 100;

/// What one tab has shown: an immutable list of targets, a current index and a
/// scroll offset per entry.
class TabHistory<T> {
  TabHistory.initial(T target) : this._([(target, null)], 0);

  const TabHistory._(this._entries, this._index);

  final List<(T, double?)> _entries;
  final int _index;

  T get current => _entries[_index].$1;
  int get index => _index;
  List<T> get entries => [for (final e in _entries) e.$1];
  bool get canGoBack => false;
  bool get canGoForward => false;
  double? get scrollOffset => null;

  TabHistory<T> push(T target) => this;
  TabHistory<T> back() => this;
  TabHistory<T> forward() => this;
  TabHistory<T> withScrollOffset(double offset) => this;
  TabHistory<T> rewrite(T from, T to) => this;
  TabHistory<T> remove(int index) => this;
}
