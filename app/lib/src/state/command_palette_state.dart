// WI #76 (56-A2, Spec #59 reqs 12-15, 18-19, 25-26, 30-33, 40; architect
// D17): the Command palette's frozen seam. #77 (shell, Commands, Notes,
// Recent) and #78 (Passages, preview) fill it in parallel: each replaces one
// provider below in its own file, with no edit here.
import 'dart:math' show max, min;
import 'dart:ui' show TextRange;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../vault_access/search_access.dart';

/// The palette's commands, in requirement 19's fixed order. The enum name is
/// the row key's suffix (`palette-row-command-<name>`).
enum PaletteCommand {
  newNote,
  newCanvas,

  /// `Attach file…` (Spec #123 R10, R11): only while a note is open on a
  /// vault the app can write.
  attachFile,
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
  String label({bool rightPanelOpen = false}) => switch (this) {
    newNote => 'New note',
    newCanvas => 'New canvas',
    attachFile => 'Attach file…',
    openToday => 'Open today',
    openVaultGraph => 'Open vault graph',
    switchVault => 'Switch vault…',
    vaultSettings => 'Vault settings',
    backups => 'Backups',
    agents => 'Agents',
    rightPanel => rightPanelOpen ? 'Hide right panel' : 'Show right panel',
    showDays => 'Show Days',
    showTopics => 'Show Topics',
    showTags => 'Show Tags',
  };

  /// The one-line description shown in the preview pane, verbatim from
  /// Sketch board C5 (design pack 76), with [vaultName] and [today] (ISO
  /// date) interpolated. [rightPanel]'s follows [rightPanelOpen].
  String description({
    required String vaultName,
    required String today,
    bool rightPanelOpen = false,
  }) => switch (this) {
    newNote =>
      'Makes an untitled note in $vaultName and shows it in this tab, '
          'ready to type.',
    newCanvas =>
      'Makes an empty canvas in $vaultName and shows it in this tab.',
    attachFile =>
      'Opens the file picker to add files to the open note, at the caret.',
    openToday => 'Shows today’s daily note, $today, in this tab.',
    openVaultGraph => 'Shows how the notes in $vaultName link to each other.',
    switchVault =>
      'Opens the vault picker, to switch to another vault or a vault server.',
    vaultSettings => 'Opens the settings for $vaultName.',
    backups =>
      'Opens the backups for $vaultName: make one now, or restore an earlier '
          'one.',
    agents =>
      'Opens the agents sheet: who is connected to $vaultName, and what they '
          'did.',
    rightPanel =>
      rightPanelOpen
          ? 'Hides the right panel, so the note has the full width.'
          : 'Shows the right panel beside the note.',
    showDays => 'Switches the sidebar to Days, newest first.',
    showTopics => 'Switches the sidebar to Topics, notes grouped by subject.',
    showTags => 'Switches the sidebar to Tags, with a count for each.',
  };
}

/// What a palette row is, for its stable [PaletteItemId] and row key.
enum PaletteItemKind { command, note, daily, canvas, passage, attachment }

/// The kind of a [NoteItem]: a note, a daily note or a canvas.
enum PaletteNoteKind { note, daily, canvas }

/// A row's stable identity: [kind] plus [id] (the command's enum name, the
/// note or canvas id, or the passage's chunk id). Value equality.
class PaletteItemId {
  const PaletteItemId(this.kind, this.id);

  final PaletteItemKind kind;
  final String id;

  @override
  bool operator ==(Object other) =>
      other is PaletteItemId && other.kind == kind && other.id == id;

  @override
  int get hashCode => Object.hash(kind, id);

  @override
  String toString() => 'PaletteItemId(${kind.name}, $id)';
}

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
  PaletteItemId get id => PaletteItemId(PaletteItemKind.command, command.name);

  /// The [label].
  @override
  String get title => label;
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
  PaletteItemId get id => PaletteItemId(switch (kind) {
    PaletteNoteKind.note => PaletteItemKind.note,
    PaletteNoteKind.daily => PaletteItemKind.daily,
    PaletteNoteKind.canvas => PaletteItemKind.canvas,
  }, noteId);
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
  PaletteItemId get id => PaletteItemId(PaletteItemKind.passage, hit.chunkId);

  /// The hit's note title.
  @override
  String get title => hit.noteTitle;

  /// Passage titles carry no matched characters.
  @override
  List<int> get matched => const [];
}

/// An Attachments row (Spec #123 R47): one matching attachment of the
/// search answer. Its id is `(attachment, attachment.path)`; its title is
/// the attachment's name. [notesLine] is `in <title>, <title>, <title>`
/// with ` +N` past three; [marks] are the ranges of `attachment.snippet`
/// drawn in the mark highlight.
class AttachmentItem extends PaletteItem {
  const AttachmentItem(
    this.attachment, {
    required this.notesLine,
    this.marks = const [],
  });

  final SearchAttachment attachment;
  final String notesLine;
  final List<TextRange> marks;

  @override
  PaletteItemId get id =>
      PaletteItemId(PaletteItemKind.attachment, attachment.path);

  /// The attachment's name.
  @override
  String get title => attachment.name;

  @override
  String? get meta => null;

  /// Attachment titles carry no matched characters.
  @override
  List<int> get matched => const [];
}

/// A result group, in the fixed order commands, recent (empty input) or
/// commands, notes, passages, attachments (typed).
enum PaletteGroupKind { commands, notes, recent, passages, attachments }

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

  /// The Attachments rows the same search answer lists (Spec #123 R47).
  List<AttachmentItem> get attachments => const [];
}

const _hintKeywordMeaning = 'keyword + meaning';
const _hintKeywordOnly = 'keyword only';

/// Passages don't run for this input (empty, or under 2 characters).
class PassagesIdle extends PassagesView {
  const PassagesIdle();
}

/// After a keystroke and until the debounce fires: the previous answer's
/// [rows] and [attachments], dimmed, with that answer's [hint].
class PassagesDimmed extends PassagesView {
  const PassagesDimmed(this.rows, {this.hint, this.attachments = const []});

  @override
  final List<PassageItem> rows;

  @override
  final String? hint;

  @override
  final List<AttachmentItem> attachments;
}

/// A search is running: `searching note text…`.
class PassagesSearching extends PassagesView {
  const PassagesSearching();
}

/// The latest input's answer: [rows] (may be empty) and whether meaning
/// search ran ([semantic]); the footer follows [semantic].
class PassagesShown extends PassagesView {
  const PassagesShown({
    required this.rows,
    required this.semantic,
    this.attachments = const [],
  });

  @override
  final List<PassageItem> rows;

  @override
  final List<AttachmentItem> attachments;

  final Semantic semantic;

  /// `keyword + meaning` when [semantic] is [Semantic.on], else
  /// `keyword only` (req 30).
  @override
  String? get hint =>
      semantic == Semantic.on ? _hintKeywordMeaning : _hintKeywordOnly;
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

/// The model download runs: keyword [rows] and the downloading footer,
/// with the same answer's [attachments].
class PassagesDownloading extends PassagesView {
  const PassagesDownloading(this.rows, {this.attachments = const []});

  @override
  final List<PassageItem> rows;

  @override
  final List<AttachmentItem> attachments;

  /// `keyword only`.
  @override
  String? get hint => _hintKeywordOnly;
}

/// The model download failed: keyword [rows] and the model-not-downloaded
/// footer and button again, with the same answer's [attachments].
class PassagesDownloadFailed extends PassagesView {
  const PassagesDownloadFailed(this.rows, {this.attachments = const []});

  @override
  final List<PassageItem> rows;

  @override
  final List<AttachmentItem> attachments;

  /// `keyword only`.
  @override
  String? get hint => _hintKeywordOnly;
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

/// Chooser for Attachments rows (Spec #123 R47). Default: does nothing.
final paletteAttachmentChooserProvider =
    Provider.autoDispose<PaletteChooser<AttachmentItem>>(
      (ref) => (item, {required newTab}) {},
    );

/// The palette's notifier (Spec #59 TD4). Selection rules (reqs 25, 26):
/// - typing ([setQuery]) selects the first row of the new groups;
/// - a regroup (a source rebuilding, Passages answering) keeps the selected
///   item while it is still listed, and otherwise selects the first row;
/// - when the first rows arrive, the first one is selected;
/// - with no rows nothing is selected and [choose] does nothing.
///
/// Each build is one palette session: `ref.invalidate(paletteProvider)`
/// starts a fresh one (empty input, first row selected, [choose] armed again,
/// the preview source told the selection again), also while an old route
/// still listens.
class PaletteNotifier extends AutoDisposeNotifier<PaletteState> {
  /// Set while [setQuery] forwards the input to the Passages source: a
  /// Passages answer then doesn't regroup by itself (setQuery regroups once).
  var _forwardingQuery = false;

  /// Set by the first choice and by [close]: [choose] runs at most once.
  var _done = false;

  /// The id the preview source last heard (null: none, or nothing yet).
  PaletteItemId? _previewed;

  /// Counts builds. Riverpod keeps this instance across a rebuild (e.g.
  /// `ref.invalidate(paletteProvider)`), so each build's microtask and
  /// dispose callback act only while their build is the current one.
  var _build = 0;

  /// Set when the current build is disposed (the provider disposed, or is
  /// about to rebuild).
  var _disposed = false;

  @override
  PaletteState build() {
    // A rebuild starts a fresh session on this same instance: clear every
    // latch the previous build left behind.
    _forwardingQuery = false;
    _done = false;
    _previewed = null;
    _disposed = false;
    final build = ++_build;
    // Listen, never watch: a rebuild here would lose the query.
    ref.listen(paletteCommandsSourceProvider, (_, _) => _regroup());
    ref.listen(paletteTitlesSourceProvider, (_, _) => _regroup());
    ref.listen(palettePassagesProvider, (_, _) => _regroup());
    ref.listen(palettePreviewProvider, (_, view) => state = _withPreview(view));
    ref.onDispose(() {
      if (build == _build) _disposed = true;
    });
    // A provider can't change another while it builds: the preview source
    // hears the first selection a microtask later.
    Future.microtask(() {
      if (build == _build) _syncPreview();
    });
    return _compose(
      query: '',
      keep: null,
      preview: ref.read(palettePreviewProvider),
    );
  }

  /// The input changed to [query] (as typed). The sources hear it trimmed.
  void setQuery(String query) {
    _forwardingQuery = true;
    try {
      ref.read(palettePassagesProvider.notifier).setQuery(query.trim());
    } finally {
      _forwardingQuery = false;
    }
    _apply(_compose(query: query, keep: null, preview: state.preview));
  }

  /// Moves the selection by [delta] rows through every group in display
  /// order, stopping at the first and last rows.
  void move(int delta) {
    final ids = _ids(state.groups);
    if (ids.isEmpty) return;
    final at = ids.indexWhere((id) => id == state.selected);
    _select(ids[max(0, min(ids.length - 1, at + delta))]);
  }

  /// Pointer hover: selects [id] when it is listed.
  void hover(PaletteItemId id) {
    if (_ids(state.groups).contains(id)) _select(id);
  }

  /// Runs the selected row's chooser with [newTab]. Does nothing with no
  /// rows, and after a choice or [close].
  void choose({required bool newTab}) {
    if (_done) return;
    final item = _itemFor(state.selected);
    if (item == null) return;
    _done = true;
    switch (item) {
      case CommandItem():
        ref.read(paletteCommandChooserProvider)(item, newTab: newTab);
      case NoteItem():
        ref.read(paletteNoteChooserProvider)(item, newTab: newTab);
      case PassageItem():
        ref.read(palettePassageChooserProvider)(item, newTab: newTab);
      case AttachmentItem():
        ref.read(paletteAttachmentChooserProvider)(item, newTab: newTab);
    }
  }

  /// The palette closes: forwards `close()` to the Passages and preview
  /// sources.
  void close() {
    _done = true;
    ref.read(palettePassagesProvider.notifier).close();
    ref.read(palettePreviewProvider.notifier).close();
  }

  /// A source answered again: the same input, keeping the selection while
  /// it is still listed.
  void _regroup() {
    if (_forwardingQuery) return;
    _apply(
      _compose(
        query: state.query,
        keep: state.selected,
        preview: state.preview,
      ),
    );
  }

  /// The groups for [query] from every source, selecting [keep] when it is
  /// listed and otherwise the first row.
  PaletteState _compose({
    required String query,
    required PaletteItemId? keep,
    required PreviewView preview,
  }) {
    final trimmed = query.trim();
    final typed = trimmed.isNotEmpty;
    final commands = ref.read(paletteCommandsSourceProvider)(trimmed);
    final titles = ref.read(paletteTitlesSourceProvider)(trimmed);
    final passages = ref.read(palettePassagesProvider);
    final groups = [
      if (commands.isNotEmpty)
        PaletteGroup(PaletteGroupKind.commands, commands),
      if (titles.isNotEmpty)
        PaletteGroup(
          typed ? PaletteGroupKind.notes : PaletteGroupKind.recent,
          titles,
        ),
      if (typed && passages.rows.isNotEmpty)
        PaletteGroup(
          PaletteGroupKind.passages,
          passages.rows,
          hint: passages.hint,
        ),
      if (typed && passages.attachments.isNotEmpty)
        PaletteGroup(PaletteGroupKind.attachments, passages.attachments),
    ];
    final ids = _ids(groups);
    return PaletteState(
      query: query,
      groups: groups,
      selected: ids.contains(keep) ? keep : ids.firstOrNull,
      passages: passages,
      preview: preview,
      noMatches:
          typed &&
          ids.isEmpty &&
          (passages is PassagesIdle || passages is PassagesShown),
    );
  }

  void _select(PaletteItemId id) {
    if (id == state.selected) return;
    final s = state;
    _apply(
      PaletteState(
        query: s.query,
        groups: s.groups,
        selected: id,
        passages: s.passages,
        preview: s.preview,
        noMatches: s.noMatches,
      ),
    );
  }

  PaletteState _withPreview(PreviewView preview) {
    final s = state;
    return PaletteState(
      query: s.query,
      groups: s.groups,
      selected: s.selected,
      passages: s.passages,
      preview: preview,
      noMatches: s.noMatches,
    );
  }

  void _apply(PaletteState next) {
    state = next;
    _syncPreview();
  }

  /// Tells the preview source the selected row, when it changed.
  void _syncPreview() {
    if (_disposed) return;
    final selected = state.selected;
    if (selected == _previewed) return;
    _previewed = selected;
    ref.read(palettePreviewProvider.notifier).select(_itemFor(selected));
  }

  PaletteItem? _itemFor(PaletteItemId? id) {
    for (final group in state.groups) {
      for (final row in group.rows) {
        if (row.id == id) return row;
      }
    }
    return null;
  }

  static List<PaletteItemId> _ids(List<PaletteGroup> groups) => [
    for (final group in groups)
      for (final row in group.rows) row.id,
  ];
}

final paletteProvider =
    NotifierProvider.autoDispose<PaletteNotifier, PaletteState>(
      PaletteNotifier.new,
    );
