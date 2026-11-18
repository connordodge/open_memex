// WI #76 (56-A2, Spec #59 reqs 12-15, 18-19, 25-26, 30-33, 40; architect
// D17): the Command palette's frozen seam. #77 (shell, Commands, Notes,
// Recent) and #78 (Passages, preview) fill it in parallel: each replaces one
// provider below in its own file, with no edit here.
import 'dart:ui' show TextRange;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../vault_access/search_access.dart';

/// The palette's commands, in requirement 19's fixed order. The enum name is
/// the row key's suffix (`palette-row-command-<name>`).
enum PaletteCommand {
  newNote,
  newCanvas,
  openToday,
  openVaultGraph,
  switchVault,
  vaultSettings,
  backups,
  agents,

  /// `Show right panel` / `Hide right panel` (req 21).
  rightPanel,
  showDays,
  showTopics,
  showTags;

  /// The row label (req 19). [rightPanel] reads `Hide right panel` while
  /// [rightPanelOpen], `Show right panel` otherwise.
  String label({bool rightPanelOpen = false}) => '';

  /// The one-line description shown in the preview pane, verbatim from
  /// Sketch board C5 (design pack 76), with [vaultName] and [today] (ISO
  /// date) interpolated. [rightPanel]'s follows [rightPanelOpen].
  String description({
    required String vaultName,
    required String today,
    bool rightPanelOpen = false,
  }) => '';
}

/// What a palette row is, for its stable [PaletteItemId] and row key.
enum PaletteItemKind { command, note, daily, canvas, passage }

/// The kind of a [NoteItem]: a note, a daily note or a canvas.
enum PaletteNoteKind { note, daily, canvas }

/// A row's stable identity: [kind] plus [id] (the command's enum name, the
/// note or canvas id, or the passage's chunk id). Value equality.
class PaletteItemId {
  const PaletteItemId(this.kind, this.id);

  final PaletteItemKind kind;
  final String id;
}

const _noId = PaletteItemId(PaletteItemKind.command, '');

/// One selectable palette row.
sealed class PaletteItem {
  const PaletteItem();

  /// The row's stable identity.
  PaletteItemId get id;

  /// The row's title: a command's label, a note's or canvas's title, a
  /// passage's note title.
  String get title;

  /// The meta text drawn at the row's right (e.g. `note · 2 h ago`), or null.
  String? get meta;

  /// The title's matched character indices (`fuzzyMatchPositions`), drawn in
  /// `accent`.
  List<int> get matched;
}

/// A command row. Its id is `(command, command.name)`.
class CommandItem extends PaletteItem {
  const CommandItem(
    this.command, {
    required this.label,
    this.meta,
    this.matched = const [],
  });

  final PaletteCommand command;
  final String label;

  @override
  final String? meta;

  @override
  final List<int> matched;

  @override
  PaletteItemId get id => _noId;

  /// The [label].
  @override
  String get title => '';
}

/// A note, daily note or canvas row. Its id is `(note|daily|canvas,
/// noteId)` after [kind].
class NoteItem extends PaletteItem {
  const NoteItem({
    required this.noteId,
    required this.kind,
    required this.title,
    required this.meta,
    this.matched = const [],
  });

  /// The note's or canvas's id.
  final String noteId;
  final PaletteNoteKind kind;

  @override
  final String title;

  @override
  final String meta;

  @override
  final List<int> matched;

  @override
  PaletteItemId get id => _noId;
}

/// A passage row. Its id is `(passage, hit.chunkId)`; its title is the hit's
/// note title. [marks] are the ranges of `hit.snippet` drawn in the mark
/// highlight (none for a meaning-only hit).
class PassageItem extends PaletteItem {
  const PassageItem(this.hit, {required this.meta, this.marks = const []});

  final SearchHit hit;

  @override
  final String meta;

  final List<TextRange> marks;

  @override
  PaletteItemId get id => _noId;

  /// The hit's note title.
  @override
  String get title => '';

  /// Passage titles carry no matched characters.
  @override
  List<int> get matched => const [];
}

/// A result group, in the fixed order commands, recent (empty input) or
/// commands, notes, passages (typed).
enum PaletteGroupKind { commands, notes, recent, passages }

/// One group of selectable rows. [hint] is the Passages header's right-hand
/// hint (`keyword + meaning` / `keyword only`); null for the other groups.
class PaletteGroup {
  const PaletteGroup(this.kind, this.rows, {this.hint});

  final PaletteGroupKind kind;
  final List<PaletteItem> rows;
  final String? hint;
}

/// What the Passages part of the palette shows (reqs 17, 30-33). #78's
/// passages source moves through these.
sealed class PassagesView {
  const PassagesView();

  /// The selectable passage rows this view lists (none for a state row).
  List<PassageItem> get rows => const [];

  /// The Passages group's header hint, or null.
  String? get hint => null;
}

/// Passages don't run for this input (empty, or under 2 characters).
class PassagesIdle extends PassagesView {
  const PassagesIdle();
}

/// After a keystroke and until the debounce fires: the previous answer's
/// [rows], dimmed, with that answer's [hint].
class PassagesDimmed extends PassagesView {
  const PassagesDimmed(this.rows, {this.hint});

  @override
  final List<PassageItem> rows;

  @override
  final String? hint;
}

/// A search is running: `searching note text…`.
class PassagesSearching extends PassagesView {
  const PassagesSearching();
}

/// The latest input's answer: [rows] (may be empty) and whether meaning
/// search ran ([semantic]); the footer follows [semantic].
class PassagesShown extends PassagesView {
  const PassagesShown({required this.rows, required this.semantic});

  @override
  final List<PassageItem> rows;

  final Semantic semantic;

  /// `keyword + meaning` when [semantic] is [Semantic.on], else
  /// `keyword only` (req 30).
  @override
  String? get hint => null;
}

/// Search can't run on this vault: one state row for [reason].
class PassagesUnavailable extends PassagesView {
  const PassagesUnavailable(this.reason);

  final SearchUnavailableReason reason;
}

/// The search threw or timed out: `couldn't search note text.`.
class PassagesError extends PassagesView {
  const PassagesError();
}

/// The model download runs: keyword [rows] and the downloading footer.
class PassagesDownloading extends PassagesView {
  const PassagesDownloading(this.rows);

  @override
  final List<PassageItem> rows;

  /// `keyword only`.
  @override
  String? get hint => null;
}

/// The model download failed: keyword [rows] and the model-not-downloaded
/// footer and button again.
class PassagesDownloadFailed extends PassagesView {
  const PassagesDownloadFailed(this.rows);

  @override
  final List<PassageItem> rows;

  /// `keyword only`.
  @override
  String? get hint => null;
}

/// What the preview pane shows for the selected row (req 29). #78's preview
/// source moves through these.
sealed class PreviewView {
  const PreviewView();
}

/// No row is selected, or the window is narrow (no preview pane).
class PreviewNone extends PreviewView {
  const PreviewNone();
}

/// A preview read is in flight: `loading…`.
class PreviewLoading extends PreviewView {
  const PreviewLoading();
}

/// The preview read failed: `couldn't load the preview.`.
class PreviewFailed extends PreviewView {
  const PreviewFailed();
}

/// A command: its [label] and [description].
class PreviewCommand extends PreviewView {
  const PreviewCommand(
    this.command, {
    required this.label,
    required this.description,
  });

  final PaletteCommand command;
  final String label;
  final String description;
}

/// A note or daily note: its [title] and [contentMd], from the top.
class PreviewNote extends PreviewView {
  const PreviewNote({
    required this.noteId,
    required this.title,
    required this.contentMd,
  });

  final String noteId;
  final String title;
  final String contentMd;
}

/// A passage: its note's [contentMd], placed at the [hit]'s `startByte`.
class PreviewPassage extends PreviewView {
  const PreviewPassage(this.hit, {required this.contentMd});

  final SearchHit hit;
  final String contentMd;
}

/// A canvas: its [title], [cardCount] and up to 8 [cardTitles].
class PreviewCanvas extends PreviewView {
  const PreviewCanvas({
    required this.canvasId,
    required this.title,
    required this.cardCount,
    required this.cardTitles,
  });

  final String canvasId;
  final String title;
  final int cardCount;
  final List<String> cardTitles;
}

/// The palette's state.
class PaletteState {
  const PaletteState({
    this.query = '',
    this.groups = const [],
    this.selected,
    this.passages = const PassagesIdle(),
    this.preview = const PreviewNone(),
    this.noMatches = false,
  });

  /// The input as typed (untrimmed).
  final String query;

  /// The groups with rows, in the fixed order; an empty group is left out.
  final List<PaletteGroup> groups;

  /// The selected row, or null when no group has rows.
  final PaletteItemId? selected;

  /// The Passages source's view.
  final PassagesView passages;

  /// The preview source's view.
  final PreviewView preview;

  /// `no matches for “<query>”` shows (req 33).
  final bool noMatches;
}

// ---------------------------------------------------------------------------
// Fill seams. Each is an overridable provider with a neutral default; a
// filler overrides one in its own file.
// ---------------------------------------------------------------------------

/// The Commands rows for a trimmed input (empty for the empty input), best
/// match first. Filled by #77. A rebuild of the provider regroups.
typedef PaletteCommandsSource = List<CommandItem> Function(String query);

/// The Notes rows for a trimmed input, or the Recent rows for the empty
/// input. Filled by #77. A rebuild of the provider (e.g. the title read
/// answering) regroups.
typedef PaletteTitlesSource = List<NoteItem> Function(String query);

/// Runs the chosen row's action. [newTab] is the ⌘ flag captured at the key
/// or click; a chooser never reads `HardwareKeyboard`.
typedef PaletteChooser<T extends PaletteItem> =
    void Function(T item, {required bool newTab});

/// Commands source (#77). Default: no rows.
final paletteCommandsSourceProvider =
    Provider.autoDispose<PaletteCommandsSource>(
      (ref) =>
          (_) => const [],
    );

/// Titles source for Notes and Recent (#77). Default: no rows.
final paletteTitlesSourceProvider = Provider.autoDispose<PaletteTitlesSource>(
  (ref) =>
      (_) => const [],
);

/// The Passages source (#78). The palette calls [setQuery] with every
/// trimmed input and [close] when it closes, and regroups on every new
/// [PassagesView]. Default: always [PassagesIdle].
class PalettePassagesNotifier extends AutoDisposeNotifier<PassagesView> {
  @override
  PassagesView build() => const PassagesIdle();

  /// The palette's trimmed input changed.
  void setQuery(String query) {}

  /// The palette closed: cancel timers, drop the queue.
  void close() {}
}

final palettePassagesProvider =
    NotifierProvider.autoDispose<PalettePassagesNotifier, PassagesView>(
      PalettePassagesNotifier.new,
    );

/// The preview source (#78). The palette calls [select] whenever the
/// selected row changes (null for none), never for a regroup that keeps it,
/// and [close] when it closes, and shows every new [PreviewView]. The first
/// selection after opening may arrive a microtask after the palette builds
/// (a provider can't change another while it builds). Default: always
/// [PreviewNone].
class PalettePreviewNotifier extends AutoDisposeNotifier<PreviewView> {
  @override
  PreviewView build() => const PreviewNone();

  /// The selected row changed to [item].
  void select(PaletteItem? item) {}

  /// The palette closed: cancel the preview timer.
  void close() {}
}

final palettePreviewProvider =
    NotifierProvider.autoDispose<PalettePreviewNotifier, PreviewView>(
      PalettePreviewNotifier.new,
    );

/// Chooser for command rows (#77). Default: does nothing.
final paletteCommandChooserProvider =
    Provider.autoDispose<PaletteChooser<CommandItem>>(
      (ref) => (item, {required newTab}) {},
    );

/// Chooser for note, daily note and canvas rows (#77). Default: does
/// nothing.
final paletteNoteChooserProvider =
    Provider.autoDispose<PaletteChooser<NoteItem>>(
      (ref) => (item, {required newTab}) {},
    );

/// Chooser for passage rows (#78). Default: does nothing.
final palettePassageChooserProvider =
    Provider.autoDispose<PaletteChooser<PassageItem>>(
      (ref) => (item, {required newTab}) {},
    );

/// The palette's notifier (Spec #59 TD4). Selection rules (reqs 25, 26):
/// - typing ([setQuery]) selects the first row of the new groups;
/// - a regroup (a source rebuilding, Passages answering) keeps the selected
///   item while it is still listed, and otherwise selects the first row;
/// - when the first rows arrive, the first one is selected;
/// - with no rows nothing is selected and [choose] does nothing.
class PaletteNotifier extends AutoDisposeNotifier<PaletteState> {
  @override
  PaletteState build() => const PaletteState();

  /// The input changed to [query] (as typed).
  void setQuery(String query) {}

  /// Moves the selection by [delta] rows through every group in display
  /// order, stopping at the first and last rows.
  void move(int delta) {}

  /// Pointer hover: selects [id] when it is listed.
  void hover(PaletteItemId id) {}

  /// Runs the selected row's chooser with [newTab]. Does nothing with no
  /// rows, and after a choice or [close].
  void choose({required bool newTab}) {}

  /// The palette closes: forwards `close()` to the Passages and preview
  /// sources.
  void close() {}
}

final paletteProvider =
    NotifierProvider.autoDispose<PaletteNotifier, PaletteState>(
      PaletteNotifier.new,
    );
