// WI #148 (Spec #123 R46-R48, A3; D10): the Command palette's Attachments
// group, at the state layer.
//
// - The Attachments group comes right after Passages, from the search
//   answer's top-level `attachments` (never counted from passage hits): one
//   row per attachment, id `(attachment, path)`, titled by its name, with the
//   notes line `in <t1>, <t2>, <t3>` then ` +N` past three.
// - It is left out when the answer has no attachments (field absent or an
//   empty list), and for an empty or 1-character input.
// - It rides the Passages run: one `search` call feeds both groups, with
//   Passages' 250 ms debounce and 2-character minimum.
// - Choosing a row calls the attachments domain's `open` with its path, with
//   or without the Cmd flag; an executable is still `open`ed (the domain
//   reveals it, R33). Arrow selection runs from the last Passages row into
//   the first Attachments row.
//
// Seams: palette_pump.dart (FakeSearchAccess, FakeClock, TabsRecorder);
// #76's real PaletteNotifier with `palettePassagesOverrides` (#78's runner
// plus this WI's attachment chooser); `attachmentsProvider` overridden with
// #141's FakeAttachmentsAccess.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/attachments_state.dart';
import 'package:open_memex_app/src/state/command_palette_state.dart';
import 'package:open_memex_app/src/state/palette_attachments.dart';
import 'package:open_memex_app/src/state/palette_passages.dart';
import 'package:open_memex_app/src/vault_access/search_access.dart';

import '../support/attachments_fakes.dart';
import '../support/font_fetch_hold.dart';
import '../support/palette_pump.dart';
import '../support/search_fakes.dart';

/// The palette session, its sources and the fake domain under test.
class _Wi148Rig {
  _Wi148Rig(this.tester, this.h, this.attachments);

  final WidgetTester tester;
  final PaletteHarness h;
  final FakeAttachmentsAccess attachments;

  FakeSearchAccess get search => h.search;
  PaletteNotifier get palette => h.read(paletteProvider.notifier);
  PaletteState get state => h.read(paletteProvider);

  List<PaletteGroupKind> get kinds => [for (final g in state.groups) g.kind];

  PaletteGroup? group(PaletteGroupKind kind) {
    for (final g in state.groups) {
      if (g.kind == kind) return g;
    }
    return null;
  }

  /// The Attachments rows, in order (empty when the group is left out).
  List<AttachmentItem> get attachmentRows => [
    for (final row
        in group(PaletteGroupKind.attachments)?.rows ?? const <PaletteItem>[])
      row as AttachmentItem,
  ];

  Future<void> type(String query) async {
    palette.setQuery(query);
    await tester.pump();
  }

  /// Moves the fake clock on by [ms] and lets answers land.
  Future<void> wait(int ms) async {
    h.clock.advance(Duration(milliseconds: ms));
    await tester.pump();
    await tester.pump();
  }

  /// Types [query] and waits out the debounce.
  Future<void> searchFor(String query) async {
    await type(query);
    await wait(passagesDebounce.inMilliseconds);
  }
}

Future<_Wi148Rig> _wi148Pump(
  WidgetTester tester, {
  SearchResult? answer,
}) async {
  final fake = FakeAttachmentsAccess();
  final h = await pumpPaletteHost(
    tester,
    search: FakeSearchAccess(
      vaultPath: paletteVaultPath,
      result: answer ?? _wi148Answer(),
    ),
    overrides: [
      ...palettePassagesOverrides,
      attachmentsProvider.overrideWithValue(fake),
    ],
  );
  h.container.invalidate(paletteProvider);
  final sub = h.container.listen(
    paletteProvider,
    (_, _) {},
    fireImmediately: true,
  );
  addTearDown(sub.close);
  await tester.pump();
  await tester.pump();
  return _Wi148Rig(tester, h, fake);
}

// Values built at run time (never canonicalised consts).
String _wi148Path(String name, {String h2 = 'b2'}) =>
    ['objects', h2, '$h2${'0' * 62}', name].join('/');

SearchAttachmentNote _wi148Note(String title) =>
    SearchAttachmentNote(id: ['n-148', title].join('-'), title: [title].join());

SearchAttachment _wi148Attachment(
  String name, {
  String? snippet,
  List<String> notes = const ['Planning notes', '2026-11-18'],
  String type = 'application/pdf',
  String h2 = 'b2',
}) => SearchAttachment(
  name: [name].join(),
  path: _wi148Path(name, h2: h2),
  size: 1024 * 3,
  type: [type].join(),
  snippet: snippet,
  notes: [for (final t in notes) _wi148Note(t)],
);

SearchHit _wi148Hit(
  String chunk, {
  String title = 'Planning notes',
  String snippet = 'Saw a heron at dawn.',
  SearchHitAttachment? attachment,
  int startByte = 0,
}) => SearchHit(
  noteId: ['n-148', chunk].join('-'),
  noteTitle: [title].join(),
  chunkId: [chunk].join(),
  snippet: [snippet].join(),
  startByte: startByte,
  noteUpdatedAt: paletteHoursAgo(2),
  attachment: attachment,
);

final _q3 = _wi148Attachment('Q3 report.pdf', snippet: '…revenue grew 12%…');
final _plan = _wi148Attachment(
  'Revenue plan.png',
  type: 'image/png',
  h2: 'c3',
  notes: const ['Bay', 'Cove', 'Dune', 'Fen'],
);

/// Two passages (the second from Q3 report.pdf) and two attachments: a
/// content match with two notes, a name-only match with four.
SearchReady _wi148Answer({
  List<SearchHit>? hits,
  List<SearchAttachment>? attachments,
}) => SearchReady(
  hits ??
      [
        _wi148Hit('c-148-walk', title: 'Alpha walk'),
        _wi148Hit(
          'c-148-q3',
          snippet: 'Q3 report.pdf · …revenue grew 12%…',
          attachment: SearchHitAttachment(name: _q3.name, path: _q3.path),
          startByte: 84,
        ),
      ],
  semantic: Semantic.on,
  truncated: false,
  attachments: attachments ?? [_q3, _plan],
);

PaletteItemId _wi148AttachmentId(SearchAttachment a) =>
    PaletteItemId(PaletteItemKind.attachment, a.path);

void main() {
  holdFontFetches();

  group('the notes line', () {
    final cases = <(String, List<String>, String)>[
      (
        'one referencing note reads in and its title',
        ['Planning notes'],
        'in Planning notes',
      ),
      (
        'two referencing notes are joined with a comma',
        ['Planning notes', '2026-11-18'],
        'in Planning notes, 2026-11-18',
      ),
      (
        'three referencing notes show all three titles and no count',
        ['Bay', 'Cove', 'Dune'],
        'in Bay, Cove, Dune',
      ),
      (
        'four referencing notes show three titles and plus one',
        ['Bay', 'Cove', 'Dune', 'Fen'],
        'in Bay, Cove, Dune +1',
      ),
      (
        'six referencing notes show three titles and plus three',
        ['Bay', 'Cove', 'Dune', 'Fen', 'Glen', 'Heath'],
        'in Bay, Cove, Dune +3',
      ),
    ];
    for (final (name, titles, line) in cases) {
      test(name, () {
        expect(
          attachmentNotesLine([for (final t in titles) _wi148Note(t)]),
          line,
        );
      });
    }
  });

  group('the attachment item', () {
    test(
      'an attachment row is identified by its path and titled by its name',
      () {
        final item = AttachmentItem(_q3, notesLine: 'in Planning notes');
        expect(item.id, PaletteItemId(PaletteItemKind.attachment, _q3.path));
        expect(item.title, 'Q3 report.pdf');
        expect(item.matched, isEmpty);

        final other = AttachmentItem(_plan, notesLine: 'in Bay');
        expect(other.id, isNot(item.id));
        expect(other.title, 'Revenue plan.png');
      },
    );
  });

  group('the attachments group', () {
    testWidgets(
      'the attachments group follows passages with one row per attachment of the answer',
      (tester) async {
        final rig = await _wi148Pump(tester);

        await rig.searchFor('revenue');

        expect(rig.kinds, [
          PaletteGroupKind.passages,
          PaletteGroupKind.attachments,
        ]);
        final rows = rig.attachmentRows;
        expect(
          [for (final r in rows) r.id],
          [_wi148AttachmentId(_q3), _wi148AttachmentId(_plan)],
        );
        expect(
          [for (final r in rows) r.title],
          ['Q3 report.pdf', 'Revenue plan.png'],
        );
        expect(rows[0].attachment.snippet, '…revenue grew 12%…');
        expect(rows[0].notesLine, 'in Planning notes, 2026-11-18');
        expect(rows[1].attachment.snippet, isNull);
        expect(rows[1].notesLine, 'in Bay, Cove, Dune +1');
        // The Passages rows are unchanged by the new group.
        expect(
          [
            for (final r in rig.group(PaletteGroupKind.passages)!.rows)
              (r as PassageItem).hit.chunkId,
          ],
          ['c-148-walk', 'c-148-q3'],
        );
      },
    );

    testWidgets(
      'the attachments group is built from the attachments list and never from passage hits',
      (tester) async {
        // Three hits from Q3 report.pdf, but the answer lists only Plan:
        // the group has one row, Plan's.
        final q3Ref = SearchHitAttachment(name: _q3.name, path: _q3.path);
        final rig = await _wi148Pump(
          tester,
          answer: _wi148Answer(
            hits: [
              for (final c in ['c-148-a', 'c-148-b', 'c-148-c'])
                _wi148Hit(c, attachment: q3Ref, snippet: 'Q3 report.pdf'),
            ],
            attachments: [_plan],
          ),
        );

        await rig.searchFor('revenue');

        expect(
          [for (final r in rig.attachmentRows) r.id],
          [_wi148AttachmentId(_plan)],
        );
      },
    );

    testWidgets(
      'one search answer feeds both passages and attachments with no second search',
      (tester) async {
        final rig = await _wi148Pump(tester);

        await rig.searchFor('revenue');
        await rig.wait(2000);

        expect(rig.attachmentRows, hasLength(2));
        expect([for (final c in rig.search.calls) c.query], ['revenue']);
      },
    );

    testWidgets(
      'the attachments group waits for the passages debounce of 250 ms',
      (tester) async {
        final rig = await _wi148Pump(tester);

        await rig.type('revenue');
        await rig.wait(249);
        expect(rig.search.calls, isEmpty);
        expect(rig.kinds, isNot(contains(PaletteGroupKind.attachments)));

        await rig.wait(1);
        expect(rig.search.calls, hasLength(1));
        expect(rig.kinds, contains(PaletteGroupKind.attachments));
        expect(rig.attachmentRows, hasLength(2));
      },
    );

    testWidgets(
      'a one character input shows no attachments group and a two character input does',
      (tester) async {
        final rig = await _wi148Pump(tester);

        await rig.type('r');
        await rig.wait(1000);
        expect(rig.search.calls, isEmpty);
        expect(rig.kinds, isNot(contains(PaletteGroupKind.attachments)));

        await rig.type(' re ');
        await rig.wait(250);
        expect([for (final c in rig.search.calls) c.query], ['re']);
        expect(rig.kinds.last, PaletteGroupKind.attachments);
      },
    );

    testWidgets('clearing the input drops the attachments group', (
      tester,
    ) async {
      final rig = await _wi148Pump(tester);
      await rig.searchFor('revenue');
      expect(rig.kinds, contains(PaletteGroupKind.attachments));

      await rig.type('');
      await rig.wait(1000);

      expect(rig.kinds, isNot(contains(PaletteGroupKind.attachments)));
      expect(rig.kinds, isNot(contains(PaletteGroupKind.passages)));
    });

    final absent = <(String, SearchResult)>[
      (
        'an answer with no attachments field shows no attachments group',
        searchReadyFromJson({
          'query': 'heron',
          'semantic': 'on',
          'truncated': false,
          'hits': [
            {
              'note_id': 'n-148-walk',
              'note_title': 'Alpha walk',
              'chunk_id': 'c-148-walk',
              'snippet': 'Saw a heron at dawn.',
              'start_byte': 0,
              'note_updated_at': paletteHoursAgo(2),
            },
          ],
        }),
      ),
      (
        'an answer with an empty attachments list shows no attachments group',
        _wi148Answer(attachments: []),
      ),
    ];
    for (final (name, answer) in absent) {
      testWidgets(name, (tester) async {
        // Control: an answer that lists attachments shows the group.
        final rig = await _wi148Pump(tester);
        await rig.searchFor('revenue');
        expect(rig.kinds, [
          PaletteGroupKind.passages,
          PaletteGroupKind.attachments,
        ]);

        rig.search.result = answer;
        await rig.searchFor('heron');

        expect(
          [for (final c in rig.search.calls) c.query],
          ['revenue', 'heron'],
        );
        expect(rig.kinds, [PaletteGroupKind.passages]);
        expect(rig.attachmentRows, isEmpty);
        expect(rig.state.noMatches, isFalse);
      });
    }

    testWidgets(
      'an answer with attachments and no passage hits shows only the attachments group',
      (tester) async {
        final rig = await _wi148Pump(
          tester,
          answer: _wi148Answer(hits: [], attachments: [_q3]),
        );

        await rig.searchFor('revenue');

        expect(rig.kinds, [PaletteGroupKind.attachments]);
        expect(rig.state.selected, _wi148AttachmentId(_q3));
        expect(rig.state.noMatches, isFalse);
      },
    );

    testWidgets(
      'the attachments group comes after commands notes and passages',
      (tester) async {
        final fake = FakeAttachmentsAccess();
        final h = await pumpPaletteHost(
          tester,
          search: FakeSearchAccess(
            vaultPath: paletteVaultPath,
            result: _wi148Answer(),
          ),
          overrides: [
            ...palettePassagesOverrides,
            attachmentsProvider.overrideWithValue(fake),
            paletteCommandsSourceProvider.overrideWith(
              (ref) =>
                  (q) => [
                    CommandItem(
                      PaletteCommand.backups,
                      label: ['Backups'].join(),
                    ),
                  ],
            ),
            paletteTitlesSourceProvider.overrideWith(
              (ref) =>
                  (q) => [
                    NoteItem(
                      noteId: PaletteSeeds.backlog,
                      kind: PaletteNoteKind.note,
                      title: ['Backlog'].join(),
                      meta: 'note · 4 d ago',
                    ),
                  ],
            ),
          ],
        );
        final sub = h.container.listen(
          paletteProvider,
          (_, _) {},
          fireImmediately: true,
        );
        addTearDown(sub.close);
        await tester.pump();
        final rig = _Wi148Rig(tester, h, fake);

        await rig.searchFor('revenue');

        expect(rig.kinds, [
          PaletteGroupKind.commands,
          PaletteGroupKind.notes,
          PaletteGroupKind.passages,
          PaletteGroupKind.attachments,
        ]);
      },
    );
  });

  group('choosing and selection', () {
    testWidgets(
      'choosing an attachments row calls open with its path through the attachments domain',
      (tester) async {
        final rig = await _wi148Pump(tester);
        await rig.searchFor('revenue');
        rig.palette.hover(_wi148AttachmentId(_q3));
        expect(rig.state.selected, _wi148AttachmentId(_q3));

        rig.palette.choose(newTab: false);
        await tester.pump();

        expect(rig.attachments.openCalls, [_q3.path]);
        expect(rig.attachments.revealCalls, isEmpty);
        expect(rig.h.tabs.navigated, isEmpty, reason: 'no note opens');
      },
    );

    testWidgets(
      'the attachment chooser opens the path with or without the cmd flag',
      (tester) async {
        final rig = await _wi148Pump(tester);
        final choose = rig.h.read(paletteAttachmentChooserProvider);

        choose(
          AttachmentItem(_q3, notesLine: 'in Planning notes'),
          newTab: false,
        );
        await tester.pump();
        choose(AttachmentItem(_plan, notesLine: 'in Bay'), newTab: true);
        await tester.pump();

        expect(rig.attachments.openCalls, [_q3.path, _plan.path]);
        expect(rig.attachments.revealCalls, isEmpty);
      },
    );

    testWidgets(
      'choosing an executable attachment still calls open and leaves the reveal to the domain',
      (tester) async {
        final script = _wi148Attachment(
          'deploy.sh',
          type: 'text/x-sh',
          h2: 'd4',
          snippet: 'revenue sync',
        );
        final rig = await _wi148Pump(
          tester,
          answer: _wi148Answer(attachments: [script]),
        );
        await rig.searchFor('revenue');
        rig.palette.hover(_wi148AttachmentId(script));

        rig.palette.choose(newTab: false);
        await tester.pump();

        expect(rig.attachments.openCalls, [script.path]);
        expect(rig.attachments.revealCalls, isEmpty);
      },
    );

    testWidgets(
      'moving down from the last passages row selects the first attachments row and choose opens it',
      (tester) async {
        final rig = await _wi148Pump(tester);
        await rig.searchFor('revenue');
        const lastPassage = PaletteItemId(PaletteItemKind.passage, 'c-148-q3');
        rig.palette.hover(lastPassage);
        expect(rig.state.selected, lastPassage);

        rig.palette.move(1);
        expect(rig.state.selected, _wi148AttachmentId(_q3));
        rig.palette.move(1);
        expect(rig.state.selected, _wi148AttachmentId(_plan));
        rig.palette.move(1);
        expect(
          rig.state.selected,
          _wi148AttachmentId(_plan),
          reason: 'the last row stops the selection',
        );
        rig.palette.move(-1);
        expect(rig.state.selected, _wi148AttachmentId(_q3));
        rig.palette.move(-1);
        expect(rig.state.selected, lastPassage);
        rig.palette.move(1);

        rig.palette.choose(newTab: false);
        await tester.pump();

        expect(rig.attachments.openCalls, [_q3.path]);
        expect(rig.h.tabs.navigated, isEmpty);
      },
    );

    testWidgets(
      'a selected attachments row stays selected when the same answer regroups',
      (tester) async {
        final rig = await _wi148Pump(tester);
        await rig.searchFor('revenue');
        rig.palette.hover(_wi148AttachmentId(_plan));

        // A source rebuilding regroups the same input: the attachment is
        // still listed, so the selection stays on it.
        rig.h.container.invalidate(paletteTitlesSourceProvider);
        await tester.pump();

        expect(rig.kinds, contains(PaletteGroupKind.attachments));
        expect(rig.state.selected, _wi148AttachmentId(_plan));
      },
    );
  });
}
