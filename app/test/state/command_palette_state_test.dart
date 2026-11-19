// WI #76 (56-A2, Spec #59 reqs 13-14, 19, 21, 25-26, 30, 33; D17): the
// Command palette's state seam.
//
// - `PaletteCommand` lists requirement 19's 12 commands with their labels
//   and Sketch board C5 descriptions (design pack 76), verbatim.
// - `PaletteNotifier` groups the seams' rows in the fixed order (commands,
//   recent for the empty input; commands, notes, passages typed), leaves
//   empty groups out, and keeps the selection rules: typing selects the
//   first row; a regroup keeps the selected item while it is listed;
//   the first rows to arrive select the first one; `move` stops at both
//   ends; with no rows nothing is chosen.
// - `choose(newTab:)` runs the selected kind's chooser with the flag it was
//   given, never `HardwareKeyboard`'s, and at most once per palette.
// - Every seam is a provider overridden here from this file only, the way
//   #77 and #78 fill them.
//
// Seams: a plain ProviderContainer; the sources read mutable rig fields and
// rebuild when `_wi76Revision` bumps (a title read answering); the Passages
// and preview sources are notifiers that subclass the defaults.
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/command_palette_state.dart';
import 'package:open_memex_app/src/vault_access/search_access.dart';

/// Bumped to rebuild the overridden sources (a regroup).
final _wi76Revision = StateProvider<int>((_) => 0);

/// The Passages seam as #78 fills it: records the queries it hears and
/// shows whatever the test emits.
class _Wi76FakePassages extends PalettePassagesNotifier {
  final queries = <String>[];
  var closes = 0;

  @override
  PassagesView build() => const PassagesIdle();

  @override
  void setQuery(String query) => queries.add(query);

  @override
  void close() => closes++;

  void emit(PassagesView view) => state = view;
}

/// The preview seam as #78 fills it: shows a view naming the selected row.
class _Wi76FakePreview extends PalettePreviewNotifier {
  final selections = <PaletteItem?>[];
  var closes = 0;

  @override
  PreviewView build() => const PreviewNone();

  @override
  void select(PaletteItem? item) {
    selections.add(item);
    state = item == null
        ? const PreviewNone()
        : PreviewNote(noteId: item.id.id, title: 'preview', contentMd: '');
  }

  @override
  void close() => closes++;
}

class _Wi76Rig {
  _Wi76Rig({
    List<CommandItem> commands = const [],
    List<NoteItem> titles = const [],
  }) : commandsFor = ((_) => commands),
       titlesFor = ((_) => titles);

  late final ProviderContainer container;

  /// What the commands source answers for a trimmed query.
  List<CommandItem> Function(String query) commandsFor;

  /// What the titles source answers for a trimmed query.
  List<NoteItem> Function(String query) titlesFor;

  final commandQueries = <String>[];
  final titleQueries = <String>[];
  final commandChoices = <(CommandItem, bool)>[];
  final noteChoices = <(NoteItem, bool)>[];
  final passageChoices = <(PassageItem, bool)>[];

  int get choices =>
      commandChoices.length + noteChoices.length + passageChoices.length;

  PaletteNotifier get palette => container.read(paletteProvider.notifier);
  PaletteState get state => container.read(paletteProvider);
  _Wi76FakePassages get passages =>
      container.read(palettePassagesProvider.notifier) as _Wi76FakePassages;
  _Wi76FakePreview get preview =>
      container.read(palettePreviewProvider.notifier) as _Wi76FakePreview;

  /// The sources rebuild (e.g. the title read answered).
  void regroup() => container.read(_wi76Revision.notifier).state++;

  /// Every selectable row id, in display order.
  List<PaletteItemId> get rowIds => [
    for (final g in state.groups)
      for (final r in g.rows) r.id,
  ];

  List<PaletteGroupKind> get kinds => [for (final g in state.groups) g.kind];
}

/// A rig with the palette alive (a listener holds it, as the dialog does).
_Wi76Rig _rig({
  List<CommandItem> commands = const [],
  List<NoteItem> titles = const [],
  _Wi76FakePassages Function() makePassages = _Wi76FakePassages.new,
}) {
  final rig = _Wi76Rig(commands: commands, titles: titles);
  final container = ProviderContainer(
    overrides: [
      paletteCommandsSourceProvider.overrideWith((ref) {
        ref.watch(_wi76Revision);
        return (q) {
          rig.commandQueries.add(q);
          return rig.commandsFor(q);
        };
      }),
      paletteTitlesSourceProvider.overrideWith((ref) {
        ref.watch(_wi76Revision);
        return (q) {
          rig.titleQueries.add(q);
          return rig.titlesFor(q);
        };
      }),
      palettePassagesProvider.overrideWith(makePassages),
      palettePreviewProvider.overrideWith(_Wi76FakePreview.new),
      paletteCommandChooserProvider.overrideWith(
        (ref) =>
            (item, {required newTab}) => rig.commandChoices.add((item, newTab)),
      ),
      paletteNoteChooserProvider.overrideWith(
        (ref) =>
            (item, {required newTab}) => rig.noteChoices.add((item, newTab)),
      ),
      palettePassageChooserProvider.overrideWith(
        (ref) =>
            (item, {required newTab}) => rig.passageChoices.add((item, newTab)),
      ),
    ],
  );
  rig.container = container;
  addTearDown(container.dispose);
  container.listen(palettePassagesProvider, (_, _) {});
  container.listen(palettePreviewProvider, (_, _) {});
  container.listen(paletteProvider, (_, _) {}, fireImmediately: true);
  return rig;
}

// Rows built from run-time values (never canonicalised consts).
CommandItem _cmd(PaletteCommand c, {String? label}) =>
    CommandItem(c, label: label ?? ['cmd', c.name].join(' '));

NoteItem _note(
  String id, {
  PaletteNoteKind kind = PaletteNoteKind.note,
  String? title,
}) => NoteItem(
  noteId: id,
  kind: kind,
  title: title ?? ['Note', id].join(' '),
  meta: '${kind.name} · 2 h ago',
);

SearchHit _hit(String chunk) => SearchHit(
  noteId: ['n', chunk].join('-'),
  noteTitle: ['Passage note', chunk].join(' '),
  chunkId: chunk,
  snippet: ['so we pushed back', chunk].join(' '),
  noteUpdatedAt: 1763460000000 + chunk.length,
);

PassageItem _passage(String chunk) =>
    PassageItem(_hit(chunk), meta: 'note · 1 d ago');

PaletteItemId _id(PaletteItemKind kind, String id) =>
    PaletteItemId(kind, [id].join());

PaletteItemId _cmdId(PaletteCommand c) => _id(PaletteItemKind.command, c.name);
PaletteItemId _noteId(String id) => _id(PaletteItemKind.note, id);
PaletteItemId _passageId(String chunk) => _id(PaletteItemKind.passage, chunk);

final _threeCommands = [
  _cmd(PaletteCommand.newNote),
  _cmd(PaletteCommand.newCanvas),
  _cmd(PaletteCommand.openToday),
];

/// A Passages source that answers during `setQuery` itself.
class _Wi76AnsweringPassages extends _Wi76FakePassages {
  @override
  void setQuery(String query) {
    super.setQuery(query);
    emit(PassagesShown(rows: [_passage('p1')], semantic: Semantic.on));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PaletteCommand', () {
    test(
      'PaletteCommand values list the 13 commands in requirement 19 order with labels and C5 descriptions',
      () {
        const vault = 'field-notes';
        const today = '2026-11-18';
        final expected = <(PaletteCommand, String, String)>[
          (
            PaletteCommand.newNote,
            'New note',
            'Makes an untitled note in field-notes and shows it in this tab, '
                'ready to type.',
          ),
          (
            PaletteCommand.newCanvas,
            'New canvas',
            'Makes an empty canvas in field-notes and shows it in this tab.',
          ),
          // WI #146 (Spec #123 R10): proposed copy, pending the lead's ruling.
          (
            PaletteCommand.attachFile,
            'Attach file…',
            'Opens the file picker to add files to the open note, at the '
                'caret.',
          ),
          (
            PaletteCommand.openToday,
            'Open today',
            'Shows today’s daily note, 2026-11-18, in this tab.',
          ),
          (
            PaletteCommand.openVaultGraph,
            'Open vault graph',
            'Shows how the notes in field-notes link to each other.',
          ),
          (
            PaletteCommand.switchVault,
            'Switch vault…',
            'Opens the vault picker, to switch to another vault or a vault '
                'server.',
          ),
          (
            PaletteCommand.vaultSettings,
            'Vault settings',
            'Opens the settings for field-notes.',
          ),
          (
            PaletteCommand.backups,
            'Backups',
            'Opens the backups for field-notes: make one now, or restore an '
                'earlier one.',
          ),
          (
            PaletteCommand.agents,
            'Agents',
            'Opens the agents sheet: who is connected to field-notes, and what '
                'they did.',
          ),
          (
            PaletteCommand.rightPanel,
            'Show right panel',
            'Shows the right panel beside the note.',
          ),
          (
            PaletteCommand.showDays,
            'Show Days',
            'Switches the sidebar to Days, newest first.',
          ),
          (
            PaletteCommand.showTopics,
            'Show Topics',
            'Switches the sidebar to Topics, notes grouped by subject.',
          ),
          (
            PaletteCommand.showTags,
            'Show Tags',
            'Switches the sidebar to Tags, with a count for each.',
          ),
        ];
        expect(PaletteCommand.values, [for (final e in expected) e.$1]);
        for (final (command, label, description) in expected) {
          expect(command.label(), label, reason: command.name);
          expect(
            command.description(vaultName: vault, today: today),
            description,
            reason: command.name,
          );
        }
      },
    );

    test(
      'the right panel command reads Hide right panel while the panel shows',
      () {
        final open = [true].first;
        expect(
          PaletteCommand.rightPanel.label(rightPanelOpen: open),
          'Hide right panel',
        );
        expect(
          PaletteCommand.rightPanel.description(
            vaultName: 'field-notes',
            today: '2026-11-18',
            rightPanelOpen: open,
          ),
          'Hides the right panel, so the note has the full width.',
        );
        expect(
          PaletteCommand.rightPanel.label(rightPanelOpen: !open),
          'Show right panel',
        );
        // Only the right-panel command follows the panel.
        expect(
          PaletteCommand.showDays.label(rightPanelOpen: open),
          'Show Days',
        );
        expect(
          PaletteCommand.backups.description(
            vaultName: 'field-notes',
            today: '2026-11-18',
            rightPanelOpen: open,
          ),
          'Opens the backups for field-notes: make one now, or restore an '
          'earlier one.',
        );
      },
    );

    test('command descriptions interpolate the vault name and today', () {
      final vault = ['My', 'Vault'].join(' ');
      final today = ['2027', '01', '02'].join('-');
      expect(
        PaletteCommand.openToday.description(vaultName: vault, today: today),
        'Shows today’s daily note, 2027-01-02, in this tab.',
      );
      expect(
        PaletteCommand.vaultSettings.description(
          vaultName: vault,
          today: today,
        ),
        'Opens the settings for My Vault.',
      );
      expect(
        PaletteCommand.newNote.description(vaultName: vault, today: today),
        'Makes an untitled note in My Vault and shows it in this tab, ready '
        'to type.',
      );
    });
  });

  group('PaletteItemId', () {
    test('PaletteItemId has value equality', () {
      final a = _id(PaletteItemKind.note, 'n1');
      final b = _id(PaletteItemKind.note, 'n1');
      expect(identical(a, b), isFalse);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a == _id(PaletteItemKind.daily, 'n1'), isFalse);
      expect(a == _id(PaletteItemKind.note, 'n2'), isFalse);
    });

    test('each item kind derives its id and title', () {
      final cmd = _cmd(PaletteCommand.backups, label: 'Backups');
      expect(cmd.id, _cmdId(PaletteCommand.backups));
      expect(cmd.title, 'Backups');

      expect(_note('n1').id, _noteId('n1'));
      expect(
        _note('d1', kind: PaletteNoteKind.daily).id,
        _id(PaletteItemKind.daily, 'd1'),
      );
      expect(
        _note('c1', kind: PaletteNoteKind.canvas).id,
        _id(PaletteItemKind.canvas, 'c1'),
      );

      final passage = _passage('ch-1');
      expect(passage.id, _passageId('ch-1'));
      expect(passage.title, 'Passage note ch-1');
      expect(passage.matched, isEmpty);
    });
  });

  group('groups', () {
    test(
      'empty groups are left out of PaletteState groups and the groups keep the fixed order',
      () {
        final rig = _rig(commands: _threeCommands, titles: [_note('n1')]);
        rig.palette.setQuery('no');
        rig.passages.emit(
          PassagesShown(rows: [_passage('p1')], semantic: Semantic.on),
        );
        expect(rig.kinds, [
          PaletteGroupKind.commands,
          PaletteGroupKind.notes,
          PaletteGroupKind.passages,
        ]);

        // No commands match: the group is left out, the rest keep their order.
        rig.commandsFor = (_) => const [];
        rig.regroup();
        expect(rig.kinds, [PaletteGroupKind.notes, PaletteGroupKind.passages]);

        // No notes either.
        rig.titlesFor = (_) => const [];
        rig.regroup();
        expect(rig.kinds, [PaletteGroupKind.passages]);

        // Commands back, passages answer with no hits.
        rig.commandsFor = (_) => _threeCommands;
        rig.regroup();
        rig.passages.emit(const PassagesShown(rows: [], semantic: Semantic.on));
        expect(rig.kinds, [PaletteGroupKind.commands]);
        expect(rig.state.groups.every((g) => g.rows.isNotEmpty), isTrue);
      },
    );

    test('the empty input lists commands then recent and no passages', () {
      final rig = _rig(commands: _threeCommands, titles: [_note('n1')]);
      expect(rig.kinds, [PaletteGroupKind.commands, PaletteGroupKind.recent]);
      expect(rig.state.groups.first.rows, hasLength(3));

      // Passages rows never show for the empty input.
      rig.passages.emit(
        PassagesShown(rows: [_passage('p1')], semantic: Semantic.on),
      );
      expect(rig.kinds, [PaletteGroupKind.commands, PaletteGroupKind.recent]);

      // Whitespace only is the empty input too.
      rig.palette.setQuery('   ');
      expect(rig.kinds, [PaletteGroupKind.commands, PaletteGroupKind.recent]);
      expect(rig.titleQueries.last, '');
      expect(rig.commandQueries.last, '');

      // Typed: the titles become Notes.
      rig.palette.setQuery('n');
      expect(rig.kinds, [
        PaletteGroupKind.commands,
        PaletteGroupKind.notes,
        PaletteGroupKind.passages,
      ]);
    });

    test(
      'setQuery passes the trimmed input to every source and keeps the typed query',
      () {
        final rig = _rig(commands: _threeCommands);
        rig.palette.setQuery('  Pri ');
        expect(rig.state.query, '  Pri ');
        expect(rig.commandQueries.last, 'Pri');
        expect(rig.titleQueries.last, 'Pri');
        expect(rig.passages.queries.last, 'Pri');
      },
    );

    test('the passages group carries the header hint of the passages view', () {
      final rig = _rig(commands: _threeCommands);
      rig.palette.setQuery('pr');
      rig.passages.emit(
        PassagesShown(rows: [_passage('p1')], semantic: Semantic.on),
      );
      expect(rig.kinds, [PaletteGroupKind.commands, PaletteGroupKind.passages]);
      expect(rig.state.groups.last.hint, 'keyword + meaning');
      expect(rig.state.groups.first.hint, isNull);

      rig.passages.emit(
        PassagesShown(
          rows: [_passage('p1')],
          semantic: Semantic.modelNotDownloaded,
        ),
      );
      expect(rig.state.groups.last.hint, 'keyword only');
    });

    test('a passages view gives its rows and header hint', () {
      final rows = [_passage('p1'), _passage('p2')];
      for (final semantic in Semantic.values) {
        final view = PassagesShown(rows: rows, semantic: semantic);
        expect(view.rows, rows);
        expect(
          view.hint,
          semantic == Semantic.on ? 'keyword + meaning' : 'keyword only',
          reason: semantic.name,
        );
      }
      expect(PassagesDownloading(rows).rows, rows);
      expect(PassagesDownloading(rows).hint, 'keyword only');
      expect(PassagesDownloadFailed(rows).rows, rows);
      expect(PassagesDownloadFailed(rows).hint, 'keyword only');
      final hint = ['keyword', 'only'].join(' ');
      expect(PassagesDimmed(rows, hint: hint).rows, rows);
      expect(PassagesDimmed(rows, hint: hint).hint, hint);
      for (final view in <PassagesView>[
        const PassagesIdle(),
        const PassagesSearching(),
        const PassagesError(),
        const PassagesUnavailable(SearchNoCli()),
      ]) {
        expect(view.rows, isEmpty, reason: '$view');
        expect(view.hint, isNull, reason: '$view');
      }
    });
  });

  group('selection', () {
    test('the palette opens with the first row selected', () {
      final rig = _rig(commands: _threeCommands, titles: [_note('n1')]);
      expect(rig.state.selected, _cmdId(PaletteCommand.newNote));
    });

    test('move stops at the last notes row and at the first commands row', () {
      final rig = _rig(
        commands: _threeCommands,
        titles: [_note('n1'), _note('n2')],
      );
      rig.palette.setQuery('o');
      expect(rig.rowIds, [
        _cmdId(PaletteCommand.newNote),
        _cmdId(PaletteCommand.newCanvas),
        _cmdId(PaletteCommand.openToday),
        _noteId('n1'),
        _noteId('n2'),
      ]);
      // The first commands row: move(-1) keeps it.
      expect(rig.state.selected, _cmdId(PaletteCommand.newNote));
      rig.palette.move(-1);
      expect(rig.state.selected, _cmdId(PaletteCommand.newNote));

      for (var i = 0; i < 4; i++) {
        rig.palette.move(1);
      }
      expect(rig.state.selected, _noteId('n2'));
      // The last notes row: move(1) keeps it.
      rig.palette.move(1);
      expect(rig.state.selected, _noteId('n2'));
    });

    test('move steps through every group in display order', () {
      final rig = _rig(commands: _threeCommands, titles: [_note('n1')]);
      rig.palette.setQuery('o');
      rig.passages.emit(
        PassagesShown(rows: [_passage('p1')], semantic: Semantic.on),
      );
      final seen = [rig.state.selected];
      for (var i = 0; i < 4; i++) {
        rig.palette.move(1);
        seen.add(rig.state.selected);
      }
      expect(seen, [
        _cmdId(PaletteCommand.newNote),
        _cmdId(PaletteCommand.newCanvas),
        _cmdId(PaletteCommand.openToday),
        _noteId('n1'),
        _passageId('p1'),
      ]);
      final back = <PaletteItemId?>[];
      for (var i = 0; i < 4; i++) {
        rig.palette.move(-1);
        back.add(rig.state.selected);
      }
      expect(back, seen.reversed.skip(1).toList());
    });

    test('move with no rows selects nothing', () {
      final rig = _rig();
      rig.palette.move(1);
      rig.palette.move(-1);
      expect(rig.state.selected, isNull);
      expect(rig.state.groups, isEmpty);
    });

    test('setQuery selects the first row of the new groups', () {
      final rig = _rig(
        commands: _threeCommands,
        titles: [_note('n1'), _note('n2')],
      );
      rig.palette.setQuery('o');
      rig.palette.move(1);
      rig.palette.move(1);
      rig.palette.move(1);
      expect(rig.state.selected, _noteId('n1'));

      // n1 is still listed after typing, but typing re-selects the first row.
      rig.palette.setQuery('ot');
      expect(rig.rowIds, contains(_noteId('n1')));
      expect(rig.state.selected, _cmdId(PaletteCommand.newNote));

      // New groups whose first row is a note.
      rig.commandsFor = (_) => const [];
      rig.titlesFor = (q) => q == 'xyz' ? [_note('n9'), _note('n1')] : [];
      rig.palette.setQuery('xyz');
      expect(rig.state.selected, _noteId('n9'));
    });

    test('a regroup that still lists the selected item keeps it selected', () {
      final rig = _rig(
        commands: _threeCommands,
        titles: [_note('n1'), _note('n2')],
      );
      rig.palette.setQuery('o');
      for (var i = 0; i < 4; i++) {
        rig.palette.move(1);
      }
      expect(rig.state.selected, _noteId('n2'));

      // The title read answers again with a new note ahead of n2.
      rig.titlesFor = (_) => [_note('n0'), _note('n1'), _note('n2')];
      rig.regroup();
      expect(rig.rowIds.indexOf(_noteId('n2')), 5);
      expect(rig.state.selected, _noteId('n2'));
      // The regroup kept the typed query.
      expect(rig.state.query, 'o');

      // Passages arriving is a regroup too.
      rig.passages.emit(
        PassagesShown(rows: [_passage('p1')], semantic: Semantic.on),
      );
      expect(rig.state.selected, _noteId('n2'));
    });

    test('a regroup that drops the selected item selects the first row', () {
      final rig = _rig(
        commands: _threeCommands,
        titles: [_note('n1'), _note('n2')],
      );
      rig.palette.setQuery('o');
      for (var i = 0; i < 4; i++) {
        rig.palette.move(1);
      }
      expect(rig.state.selected, _noteId('n2'));

      rig.titlesFor = (_) => [_note('n1')];
      rig.regroup();
      expect(rig.state.selected, _cmdId(PaletteCommand.newNote));

      // A passage dropped by a newer answer, with no other rows.
      rig.commandsFor = (_) => const [];
      rig.titlesFor = (_) => const [];
      rig.regroup();
      rig.passages.emit(
        PassagesShown(
          rows: [_passage('p1'), _passage('p2')],
          semantic: Semantic.on,
        ),
      );
      rig.palette.move(1);
      expect(rig.state.selected, _passageId('p2'));
      rig.passages.emit(
        PassagesShown(
          rows: [_passage('p3'), _passage('p1')],
          semantic: Semantic.on,
        ),
      );
      expect(rig.state.selected, _passageId('p3'));
    });

    test(
      'when the groups go from no rows to some rows the first row becomes selected',
      () {
        final rig = _rig();
        rig.palette.setQuery('ba');
        expect(rig.state.groups, isEmpty);
        expect(rig.state.selected, isNull);

        // Passages answer first.
        rig.passages.emit(
          PassagesShown(rows: [_passage('p1')], semantic: Semantic.on),
        );
        expect(rig.state.selected, _passageId('p1'));

        // Back to no rows, then the title read answers.
        rig.passages.emit(const PassagesShown(rows: [], semantic: Semantic.on));
        expect(rig.state.selected, isNull);
        rig.titlesFor = (_) => [_note('n1'), _note('n2')];
        rig.regroup();
        expect(rig.state.selected, _noteId('n1'));
      },
    );

    test('hover selects a listed row and ignores an id that is not listed', () {
      final rig = _rig(commands: _threeCommands, titles: [_note('n1')]);
      rig.palette.setQuery('o');
      rig.palette.hover(_noteId('n1'));
      expect(rig.state.selected, _noteId('n1'));
      rig.palette.hover(_cmdId(PaletteCommand.newCanvas));
      expect(rig.state.selected, _cmdId(PaletteCommand.newCanvas));
      rig.palette.hover(_noteId('not-listed'));
      expect(rig.state.selected, _cmdId(PaletteCommand.newCanvas));
      rig.palette.hover(_cmdId(PaletteCommand.backups));
      expect(rig.state.selected, _cmdId(PaletteCommand.newCanvas));
    });
  });

  group('choose', () {
    test('with no rows choose calls no chooser', () {
      final rig = _rig(commands: _threeCommands);
      // Rows listed, then typing leaves none.
      expect(rig.state.selected, _cmdId(PaletteCommand.newNote));
      rig.commandsFor = (q) => q == 'zz' ? const [] : _threeCommands;
      rig.palette.setQuery('zz');
      expect(rig.state.groups, isEmpty);
      expect(rig.state.selected, isNull);
      rig.palette.choose(newTab: false);
      rig.palette.choose(newTab: true);
      expect(rig.choices, 0);
      // Rows again: the same palette still chooses.
      rig.palette.setQuery('z');
      rig.palette.choose(newTab: false);
      expect(rig.commandChoices, hasLength(1));
      expect(rig.commandChoices.single.$1.command, PaletteCommand.newNote);
    });

    test(
      'choose with newTab true passes newTab true to the chooser for the selected kind with no HardwareKeyboard read',
      () {
        final keyboard = HardwareKeyboard.instance;
        // No key is held: the flag passed in is what the chooser gets.
        expect(keyboard.isMetaPressed, isFalse);
        final plain = _rig(commands: _threeCommands);
        plain.palette.move(1);
        plain.palette.choose(newTab: true);
        expect(plain.commandChoices, hasLength(1));
        expect(
          plain.commandChoices.single.$1.command,
          PaletteCommand.newCanvas,
        );
        expect(plain.commandChoices.single.$2, isTrue);

        // Cmd is held, but the flag passed in is false: never re-read.
        keyboard.handleKeyEvent(
          const KeyDownEvent(
            physicalKey: PhysicalKeyboardKey.metaLeft,
            logicalKey: LogicalKeyboardKey.metaLeft,
            timeStamp: Duration.zero,
          ),
        );
        final metaHeld = keyboard.isMetaPressed;
        final held = _rig(commands: _threeCommands);
        held.palette.choose(newTab: false);
        keyboard.handleKeyEvent(
          const KeyUpEvent(
            physicalKey: PhysicalKeyboardKey.metaLeft,
            logicalKey: LogicalKeyboardKey.metaLeft,
            timeStamp: Duration.zero,
          ),
        );
        expect(metaHeld, isTrue);
        expect(keyboard.isMetaPressed, isFalse);
        expect(held.commandChoices, hasLength(1));
        expect(held.commandChoices.single.$1.command, PaletteCommand.newNote);
        expect(held.commandChoices.single.$2, isFalse);
      },
    );

    test('choose routes each item kind to its own chooser', () {
      for (final kind in PaletteNoteKind.values) {
        final rig = _rig(titles: [_note('x1', kind: kind)]);
        rig.palette.setQuery('x');
        rig.palette.choose(newTab: true);
        expect(rig.noteChoices, hasLength(1), reason: kind.name);
        expect(rig.noteChoices.single.$1.noteId, 'x1');
        expect(rig.noteChoices.single.$1.kind, kind);
        expect(rig.noteChoices.single.$2, isTrue);
        expect(rig.commandChoices, isEmpty);
        expect(rig.passageChoices, isEmpty);
      }

      final passage = _rig();
      passage.palette.setQuery('pushed back');
      passage.passages.emit(
        PassagesShown(rows: [_passage('p7')], semantic: Semantic.on),
      );
      passage.palette.choose(newTab: false);
      expect(passage.passageChoices, hasLength(1));
      expect(passage.passageChoices.single.$1.hit.chunkId, 'p7');
      expect(passage.passageChoices.single.$2, isFalse);
      expect(passage.noteChoices, isEmpty);
      expect(passage.commandChoices, isEmpty);

      final command = _rig(commands: [_cmd(PaletteCommand.agents)]);
      command.palette.choose(newTab: false);
      expect(command.commandChoices.single.$1.command, PaletteCommand.agents);
      expect(command.noteChoices, isEmpty);
      expect(command.passageChoices, isEmpty);
    });

    test('a second choose after a choice calls no chooser', () {
      final rig = _rig(commands: _threeCommands);
      rig.palette.choose(newTab: false);
      rig.palette.move(1);
      rig.palette.choose(newTab: true);
      expect(rig.commandChoices, hasLength(1));
      expect(rig.commandChoices.single.$1.command, PaletteCommand.newNote);
    });

    test(
      'close forwards close to the passages and preview sources and later choose calls no chooser',
      () {
        final rig = _rig(commands: _threeCommands);
        expect(rig.passages.closes, 0);
        expect(rig.preview.closes, 0);
        rig.palette.close();
        expect(rig.passages.closes, 1);
        expect(rig.preview.closes, 1);
        rig.palette.choose(newTab: false);
        expect(rig.choices, 0);
      },
    );
  });

  group('preview seam', () {
    test(
      'the preview source hears each change of the selected row and its view is the palette preview',
      () async {
        final rig = _rig(commands: _threeCommands, titles: [_note('n1')]);
        // Opening selects the first row; a provider can't change another
        // while it builds, so the source may hear it a microtask later.
        await Future<void>.delayed(Duration.zero);
        expect(rig.preview.selections.map((i) => i?.id), [
          _cmdId(PaletteCommand.newNote),
        ]);
        expect(
          rig.state.preview,
          same(rig.container.read(palettePreviewProvider)),
        );
        expect((rig.state.preview as PreviewNote).noteId, 'newNote');

        rig.palette.move(1);
        expect(
          rig.preview.selections.last?.id,
          _cmdId(PaletteCommand.newCanvas),
        );
        expect((rig.state.preview as PreviewNote).noteId, 'newCanvas');

        // A regroup that keeps the selection doesn't re-select.
        final before = rig.preview.selections.length;
        rig.regroup();
        expect(rig.state.selected, _cmdId(PaletteCommand.newCanvas));
        expect(rig.preview.selections, hasLength(before));

        // Moving at the last row changes nothing either.
        rig.palette.hover(_noteId('n1'));
        expect(rig.preview.selections.last?.id, _noteId('n1'));
        final atEnd = rig.preview.selections.length;
        rig.palette.move(1);
        expect(rig.preview.selections, hasLength(atEnd));

        // No rows: the source hears null.
        rig.commandsFor = (_) => const [];
        rig.titlesFor = (_) => const [];
        rig.palette.setQuery('zz');
        expect(rig.preview.selections.last, isNull);
        expect(rig.state.preview, isA<PreviewNone>());
      },
    );
  });

  group('no matches', () {
    test(
      'no matches shows straight away for a one character input with no rows',
      () {
        final rig = _rig();
        rig.palette.setQuery('z');
        // Passages don't run under 2 characters: the source stays idle.
        expect(rig.state.passages, isA<PassagesIdle>());
        expect(rig.state.noMatches, isTrue);
      },
    );

    test(
      'no matches waits while passages search and shows once passages answer with no hits',
      () {
        final rig = _rig();
        rig.palette.setQuery('zzz');
        rig.passages.emit(const PassagesSearching());
        expect(rig.state.passages, isA<PassagesSearching>());
        expect(rig.state.noMatches, isFalse);
        rig.passages.emit(const PassagesDimmed([]));
        expect(rig.state.noMatches, isFalse);
        rig.passages.emit(const PassagesShown(rows: [], semantic: Semantic.on));
        expect(rig.state.noMatches, isTrue);
        // A state row shows instead of no matches.
        rig.passages.emit(const PassagesError());
        expect(rig.state.noMatches, isFalse);
        rig.passages.emit(const PassagesUnavailable(SearchNoCli()));
        expect(rig.state.noMatches, isFalse);
      },
    );

    test(
      'no matches is false with the empty input or while any group has rows',
      () {
        final empty = _rig();
        expect(empty.state.query, '');
        expect(empty.state.noMatches, isFalse);
        empty.palette.setQuery('  ');
        expect(empty.state.noMatches, isFalse);

        final rig = _rig(titles: [_note('n1')]);
        rig.palette.setQuery('z');
        expect(rig.state.noMatches, isFalse);
        rig.titlesFor = (_) => const [];
        rig.regroup();
        expect(rig.state.noMatches, isTrue);
        // Passage rows count as rows.
        rig.palette.setQuery('zz');
        rig.passages.emit(
          PassagesShown(rows: [_passage('p1')], semantic: Semantic.on),
        );
        expect(rig.state.noMatches, isFalse);
      },
    );
  });

  group('seam defaults', () {
    test('the default seams answer no rows, idle passages and no preview', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.listen(paletteProvider, (_, _) {}, fireImmediately: true);
      container.listen(palettePassagesProvider, (_, _) {});
      container.listen(palettePreviewProvider, (_, _) {});
      expect(container.read(paletteCommandsSourceProvider)('back'), isEmpty);
      expect(container.read(paletteTitlesSourceProvider)(''), isEmpty);
      expect(container.read(palettePassagesProvider), isA<PassagesIdle>());
      expect(container.read(palettePreviewProvider), isA<PreviewNone>());
      final cmd = _cmd(PaletteCommand.backups);
      container.read(paletteCommandChooserProvider)(cmd, newTab: true);
      container.read(paletteNoteChooserProvider)(_note('n1'), newTab: false);
      container.read(palettePassageChooserProvider)(
        _passage('p1'),
        newTab: false,
      );
      final palette = container.read(paletteProvider.notifier);
      palette.setQuery('back');
      palette.move(1);
      palette.choose(newTab: true);
      palette.close();
      final state = container.read(paletteProvider);
      expect(state.groups, isEmpty);
      expect(state.selected, isNull);
      expect(state.passages, isA<PassagesIdle>());
      expect(state.preview, isA<PreviewNone>());
    });

    test('the palette data classes carry run time values', () {
      final hit = _hit('ch-9');
      final title = ['Q3', 'planning'].join(' ');
      final command = PreviewCommand(
        PaletteCommand.backups,
        label: ['Back', 'ups'].join(),
        description: title,
      );
      expect(command.command, PaletteCommand.backups);
      expect(command.label, 'Backups');
      expect(command.description, title);
      final note = PreviewNote(
        noteId: hit.noteId,
        title: title,
        contentMd: title,
      );
      expect(
        [note.noteId, note.title, note.contentMd],
        ['n-ch-9', title, title],
      );
      final passage = PreviewPassage(hit, contentMd: title);
      expect(passage.hit, hit);
      expect(passage.contentMd, title);
      final canvas = PreviewCanvas(
        canvasId: hit.chunkId,
        title: title,
        cardCount: title.length,
        cardTitles: [title],
      );
      expect(canvas.canvasId, 'ch-9');
      expect(canvas.cardCount, 11);
      expect(canvas.cardTitles, [title]);
      expect(const PreviewLoading(), isA<PreviewView>());
      expect(const PreviewFailed(), isA<PreviewView>());
      final unavailable = PassagesUnavailable([const ServerOutdated()].first);
      expect(unavailable.reason, const ServerOutdated());
      final marks = [TextRange(start: title.length - 8, end: title.length)];
      final item = PassageItem(hit, meta: title, marks: marks);
      expect(item.marks, marks);
      expect(item.meta, title);
      final group = PaletteGroup(PaletteGroupKind.passages, [
        item,
      ], hint: title);
      expect(group.rows, [item]);
      expect(group.hint, title);
      final state = PaletteState(
        query: title,
        groups: [group],
        selected: item.id,
        passages: PassagesDimmed([item]),
        preview: passage,
        noMatches: title.isEmpty,
      );
      expect(state.query, title);
      expect(state.groups.single.kind, PaletteGroupKind.passages);
      expect(state.passages.rows, [item]);
      expect(state.preview, same(passage));
      expect(state.noMatches, isFalse);
      final cmd = CommandItem(
        PaletteCommand.openToday,
        label: title,
        meta: hit.noteId,
        matched: [title.length - 1],
      );
      expect(cmd.meta, 'n-ch-9');
      expect(cmd.matched, [10]);
      expect(cmd.label, title);
    });
  });

  group('verify contracts', () {
    test('hover on the selected row does not notify listeners', () {
      final rig = _rig(commands: _threeCommands);
      var notified = 0;
      rig.container.listen(paletteProvider, (_, _) => notified++);
      rig.palette.hover(_cmdId(PaletteCommand.newNote));
      expect(notified, 0);
      rig.palette.hover(_cmdId(PaletteCommand.newCanvas));
      expect(notified, greaterThan(0));
      final after = notified;
      rig.palette.move(0);
      expect(notified, after);
    });

    test(
      'setQuery regroups once when the passages source answers mid call',
      () {
        final rig = _rig(
          commands: _threeCommands,
          makePassages: _Wi76AnsweringPassages.new,
        );
        rig.palette.hover(_cmdId(PaletteCommand.newCanvas));
        var regroups = 0;
        rig.container.listen(paletteProvider, (prev, next) {
          if (!identical(prev?.groups, next.groups)) regroups++;
        });
        final before = rig.commandQueries.length;
        rig.palette.setQuery('o');
        expect(regroups, 1);
        expect(rig.commandQueries.length - before, 1);
        expect(rig.passages.queries, ['o']);
        // The answer is listed and typing selects the first row.
        expect(rig.kinds, [
          PaletteGroupKind.commands,
          PaletteGroupKind.passages,
        ]);
        expect(rig.state.selected, _cmdId(PaletteCommand.newNote));
      },
    );

    test(
      'the preview source hears nothing when the palette opens with no rows',
      () async {
        final rig = _rig();
        await Future<void>.delayed(Duration.zero);
        expect(rig.state.selected, isNull);
        expect(rig.preview.selections, isEmpty);
        rig.palette.setQuery('zz');
        expect(rig.preview.selections, isEmpty);
      },
    );

    test(
      'a palette disposed before its first preview sync never calls the preview source',
      () async {
        final rig = _rig(commands: _threeCommands);
        final preview = rig.preview;
        rig.container.dispose();
        await Future<void>.delayed(Duration.zero);
        expect(preview.selections, isEmpty);
      },
    );

    test(
      'invalidating the palette starts a fresh session where choose and the preview sync work again',
      () async {
        final rig = _rig(commands: _threeCommands);
        await Future<void>.delayed(Duration.zero);
        expect(rig.preview.selections, hasLength(1));
        rig.palette.hover(_cmdId(PaletteCommand.newCanvas));
        expect(rig.preview.selections, hasLength(2));
        rig.palette.choose(newTab: false);
        rig.palette.choose(newTab: false);
        expect(rig.commandChoices, hasLength(1), reason: 'once per session');

        rig.container.invalidate(paletteProvider);
        // A fresh session: empty input, the first row selected.
        expect(rig.state.query, '');
        expect(rig.state.selected, _cmdId(PaletteCommand.newNote));
        // The preview source hears the first selection again.
        await Future<void>.delayed(Duration.zero);
        expect(rig.preview.selections, hasLength(3));
        expect(rig.preview.selections.last?.id, _cmdId(PaletteCommand.newNote));
        // The preview still follows the selection (not latched disposed).
        rig.palette.move(1);
        expect(rig.preview.selections, hasLength(4));
        expect(
          rig.preview.selections.last?.id,
          _cmdId(PaletteCommand.newCanvas),
        );
        // Choosing is armed again, and runs once more.
        rig.palette.choose(newTab: true);
        rig.palette.choose(newTab: true);
        expect(rig.commandChoices, hasLength(2));
        expect(rig.commandChoices.last.$1.command, PaletteCommand.newCanvas);
        expect(rig.commandChoices.last.$2, isTrue);
      },
    );

    test('a palette closed then invalidated chooses again', () {
      final rig = _rig(commands: _threeCommands);
      rig.palette.close();
      rig.palette.choose(newTab: false);
      expect(rig.choices, 0, reason: 'closed');
      rig.container.invalidate(paletteProvider);
      expect(rig.state.selected, _cmdId(PaletteCommand.newNote));
      rig.palette.choose(newTab: false);
      expect(rig.commandChoices, hasLength(1));
      expect(rig.commandChoices.single.$1.command, PaletteCommand.newNote);
    });

    test(
      'a palette rebuilt before its first preview sync tells the preview source once',
      () async {
        final rig = _rig(commands: _threeCommands);
        // Rebuilt in the same turn the first build's microtask is pending.
        rig.container.invalidate(paletteProvider);
        expect(rig.state.selected, _cmdId(PaletteCommand.newNote));
        await Future<void>.delayed(Duration.zero);
        expect(rig.preview.selections, hasLength(1));
        expect(
          rig.preview.selections.single?.id,
          _cmdId(PaletteCommand.newNote),
        );
      },
    );

    test(
      'a palette rebuilt and then disposed before the preview sync never calls the preview source',
      () async {
        final rig = _rig(commands: _threeCommands);
        final preview = rig.preview;
        rig.container.invalidate(paletteProvider);
        expect(rig.state.selected, _cmdId(PaletteCommand.newNote));
        rig.container.dispose();
        await Future<void>.delayed(Duration.zero);
        expect(preview.selections, isEmpty);
      },
    );
  });
}
