// WI #80 (Spec #61 F1): the shared Find in note test pump for F2 (Find
// bar), F3 (highlight painter) and F6 (integration). Helper requests go to
// lead-55; nobody forks it.
//
// Widget tests that use it call `holdFontFetches()` (test/support/
// font_fetch_hold.dart) once at the top of `main()`, so text lays out in the
// flutter_test fallback font and no google_fonts fetch reaches a test zone.
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/find_in_note.dart';
import 'package:open_memex_app/src/state/find_in_note_state.dart';
import 'package:open_memex_app/src/theme/app_theme.dart';

/// The body width [pumpFind] lays the child out in unless told otherwise:
/// design B2's narrow editor body (box 372).
const double findPumpBodyWidth = 532;

/// The body height [pumpFind] lays the child out in unless told otherwise.
const double findPumpBodyHeight = 400;

/// Key of the sized host box that holds the child (bodyWidth x bodyHeight).
const Key findPumpHostKey = Key('find-pump-host');

/// Everything a test needs after [pumpFind].
class FindPumpHarness {
  FindPumpHarness(this.container, this.tester);

  /// The container behind the pumped `ProviderScope`.
  final ProviderContainer container;

  final WidgetTester tester;

  /// The Find in note state now.
  FindInNoteState get state => container.read(findInNoteProvider);

  /// The Find in note commands.
  FindInNoteNotifier get notifier =>
      container.read(findInNoteProvider.notifier);

  /// The last native menu dispatch (null before the first).
  FindMenuDispatch? get lastMenuDispatch =>
      container.read(findMenuActionsProvider);

  /// Dispatches [action] on `findMenuActionsProvider` as F5's native menu
  /// does, then pumps one frame.
  Future<void> dispatch(FindMenuAction action) async {
    container.read(findMenuActionsProvider.notifier).dispatch(action);
    await tester.pump();
  }

  /// Reads any other provider from the pumped scope.
  T read<T>(ProviderListenable<T> provider) => container.read(provider);
}

/// Pump [child] under a `ProviderScope` whose `findInNoteProvider` starts
/// seeded, inside a top-left host box [bodyWidth] x [bodyHeight] (Key
/// [findPumpHostKey]) on the app theme. The view is sized to the host at a
/// device pixel ratio of 1 (reset after the test).
///
/// The seed: [sources], [query] (also the last query unless [lastQuery] is
/// given), the matches `findMatches(sources, query)` (none while not
/// [open]), the [caret] anchor, and the current match [current] (an index
/// into those matches), or `firstAtOrAfter(matches, caret)` when [current]
/// is null. [focusRequest] seeds the focus counter. [overrides] are appended
/// (they must not repeat `findInNoteProvider`).
Future<FindPumpHarness> pumpFind(
  WidgetTester tester, {
  required Widget child,
  List<FindSource> sources = const [],
  String query = '',
  String? lastQuery,
  bool open = true,
  int? current,
  FindCaret? caret,
  int focusRequest = 0,
  double bodyWidth = findPumpBodyWidth,
  double bodyHeight = findPumpBodyHeight,
  List<Override> overrides = const [],
}) async {
  final matches = open ? findMatches(sources, query) : const <FindMatch>[];
  final seed = FindInNoteState(
    open: open,
    query: query,
    lastQuery: lastQuery ?? query,
    sources: sources,
    matches: matches,
    current: open ? (current ?? firstAtOrAfter(matches, caret)) : null,
    caret: caret,
    focusRequest: focusRequest,
  );

  tester.view.physicalSize = Size(bodyWidth, bodyHeight);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final container = ProviderContainer(
    overrides: [
      findInNoteProvider.overrideWith(() => _SeededFindInNote(seed)),
      ...overrides,
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildOmTheme(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              key: findPumpHostKey,
              width: bodyWidth,
              height: bodyHeight,
              child: child,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return FindPumpHarness(container, tester);
}

/// The real notifier with a seeded first state: every command behaves as
/// in the app.
class _SeededFindInNote extends FindInNoteNotifier {
  _SeededFindInNote(this._seed);

  final FindInNoteState _seed;

  @override
  FindInNoteState build() => _seed;
}
