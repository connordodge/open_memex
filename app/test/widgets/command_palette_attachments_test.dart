// WI #148 (Spec #123 R46, R47; D10; L13): attachment results in the shown
// Command palette.
//
// - A Passages row for a hit from an attachment shows the answer's snippet
//   `<name> · <matching text>`; choosing it opens the note and reveals at the
//   hit's `start_byte` (the attachment line), through #78's passage reveal.
// - An ATTACHMENTS group follows PASSAGES, one row per entry of the answer's
//   `attachments`: an icon, the name, the matching text for a content match
//   (nothing for a name-only match) and `in <t1>, <t2>, <t3>` then ` +N`.
// - The group is left out when the answer lists no attachments, and waits
//   for Passages' 250 ms debounce and 2-character minimum.
// - A click or Enter on an Attachments row calls the attachments domain's
//   `open` with its path (an executable too: the domain reveals it, R33).
//   Arrow keys run from the last Passages row into the first Attachments row.
// - Rows keep the palette's row layout (L13): a selectable button in the
//   semantics tree, no overflow in the narrow card at text scale 1.5.
//
// Seams: palette_pump.dart (FakeSearchAccess, FakeClock, TabsRecorder) with
// the real shell (`showCommandPalette`, `paletteShellOverrides`) and #78's
// runner (`palettePassagesOverrides`); `attachmentsProvider` overridden with
// #141's FakeAttachmentsAccess.

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/attachments_state.dart';
import 'package:open_memex_app/src/state/command_palette_state.dart';
import 'package:open_memex_app/src/state/note_reveal.dart';
import 'package:open_memex_app/src/state/palette_passages.dart';
import 'package:open_memex_app/src/state/settings.dart' show settingsProvider;
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/ui_state_store.dart';
import 'package:open_memex_app/src/vault_access/search_access.dart';
import 'package:open_memex_app/src/widgets/command_palette/command_palette.dart';
import 'package:open_memex_app/src/widgets/command_palette/palette_row.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/app_harness.dart' show pumpFrames;
import '../support/attachments_fakes.dart';
import '../support/font_fetch_hold.dart';
import '../support/palette_pump.dart';
import '../support/search_fakes.dart';
import '../support/token_store_fakes.dart';

/// The host body's context: the palette opens over it.
late BuildContext _wi148HostContext;

/// The shown palette, its fakes and its keys.
class _Wi148Palette {
  _Wi148Palette(this.tester, this.h, this.attachments);

  final WidgetTester tester;
  final PaletteHarness h;
  final FakeAttachmentsAccess attachments;

  FakeSearchAccess get search => h.search;
  PaletteState get state => h.read(paletteProvider);

  /// Types [text] into the palette's input (one frame after).
  Future<void> type(String text) async {
    await tester.enterText(find.byKey(PaletteKeys.input), text);
    await tester.pump();
  }

  /// Moves the fake clock on by [ms] and lets the answer land.
  Future<void> wait(int ms) async {
    h.clock.advance(Duration(milliseconds: ms));
    await pumpFrames(tester);
  }

  Future<void> searchFor(String text) async {
    await type(text);
    await wait(passagesDebounce.inMilliseconds);
  }

  Future<void> key(LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key, platform: 'macos');
    await tester.pump();
  }

  /// The selected row ids the shown PaletteRows draw.
  List<PaletteItemId> get selectedRows => [
    for (final e in find.byType(PaletteRow, skipOffstage: false).evaluate())
      if ((e.widget as PaletteRow).selected) (e.widget as PaletteRow).item.id,
  ];

  /// Presses Down until [id] is selected (at most [max] times).
  Future<void> downTo(PaletteItemId id, {int max = 12}) async {
    for (var i = 0; i < max && !selectedRows.contains(id); i++) {
      await key(LogicalKeyboardKey.arrowDown);
    }
    expect(selectedRows, [id]);
  }
}

Future<Override> _wi148Settings() async {
  SharedPreferences.setMockInitialValues({
    'memex.binary_path': 'fake-memex',
    'memex.recent_vaults': <String>[paletteVaultPath],
    'memex.last_vault': paletteVaultPath,
  });
  final settings = await loadSettingsKeepingPickedBinary();
  return settingsProvider.overrideWith((_) => settings);
}

/// Pumps the host over [answer] and opens the palette.
Future<_Wi148Palette> _wi148Open(
  WidgetTester tester, {
  SearchResult? answer,
  Size size = paletteWideSize,
  double textScale = 1.0,
}) async {
  final settings = await _wi148Settings();
  final fake = FakeAttachmentsAccess();
  final h = await pumpPaletteHost(
    tester,
    size: size,
    textScale: textScale,
    search: FakeSearchAccess(
      vaultPath: paletteVaultPath,
      result: answer ?? _wi148Answer(),
    ),
    child: Builder(
      builder: (context) {
        _wi148HostContext = context;
        return const SizedBox.expand();
      },
    ),
    overrides: [
      settings,
      uiStateStoreProvider.overrideWithValue(null),
      ...paletteShellOverrides,
      ...palettePassagesOverrides,
      attachmentsProvider.overrideWithValue(fake),
    ],
  );
  h.read(tabsProvider);
  await pumpFrames(tester);
  unawaited(showCommandPalette(_wi148HostContext));
  await pumpFrames(tester);
  expect(find.byKey(PaletteKeys.palette), findsOneWidget);
  return _Wi148Palette(tester, h, fake);
}

// Values built at run time (never canonicalised consts).
String _wi148Path(String name, {String h2 = 'b2'}) =>
    ['objects', h2, '$h2${'0' * 62}', name].join('/');

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
  notes: [
    for (final t in notes)
      SearchAttachmentNote(id: ['n-148', t].join('-'), title: [t].join()),
  ],
);

final _q3 = _wi148Attachment('Q3 report.pdf', snippet: '…revenue grew 12%…');
final _plan = _wi148Attachment(
  'Revenue plan.png',
  type: 'image/png',
  h2: 'c3',
  notes: const ['Bay', 'Cove', 'Dune', 'Fen'],
);

const _q3Chunk = 'c-148-q3';
const _walkChunk = 'c-148-walk';

/// Two passages (the second from Q3 report.pdf, in Pricing model at byte
/// 84) and two attachments: a content match with two notes, a name-only
/// match with four.
SearchReady _wi148Answer({List<SearchAttachment>? attachments}) => SearchReady(
  [
    SearchHit(
      noteId: [PaletteSeeds.backlog].join(),
      noteTitle: ['Backlog'].join(),
      chunkId: [_walkChunk].join(),
      snippet: ['The revenue walk for October.'].join(),
      startByte: 0,
      noteUpdatedAt: paletteHoursAgo(96),
    ),
    SearchHit(
      noteId: [PaletteSeeds.pricingModel].join(),
      noteTitle: ['Pricing model'].join(),
      chunkId: [_q3Chunk].join(),
      snippet: ['Q3 report.pdf', '…revenue grew 12%…'].join(' · '),
      startByte: 84,
      noteUpdatedAt: paletteHoursAgo(2),
      attachment: SearchHitAttachment(name: _q3.name, path: _q3.path),
    ),
  ],
  semantic: Semantic.on,
  truncated: false,
  attachments: attachments ?? [_q3, _plan],
);

PaletteItemId _wi148AttachmentId(SearchAttachment a) =>
    PaletteItemId(PaletteItemKind.attachment, a.path);

const _q3PassageId = PaletteItemId(PaletteItemKind.passage, _q3Chunk);

Finder _wi148Row(PaletteItemId id) =>
    find.byKey(PaletteKeys.row(id), skipOffstage: false);

Finder _wi148Group(PaletteGroupKind kind) =>
    find.byKey(PaletteKeys.group(kind), skipOffstage: false);

/// [text] (plain or rich) inside the row [id].
Finder _wi148InRow(PaletteItemId id, String text) => find.descendant(
  of: _wi148Row(id),
  matching: find.text(text, findRichText: true, skipOffstage: false),
);

/// Text containing [text] inside the row [id].
Finder _wi148ContainingInRow(PaletteItemId id, Pattern text) => find.descendant(
  of: _wi148Row(id),
  matching: find.textContaining(text, findRichText: true, skipOffstage: false),
);

/// The plain text of every RichText the row [id] draws.
List<String> _wi148RowTexts(WidgetTester tester, PaletteItemId id) => [
  for (final e
      in find
          .descendant(
            of: _wi148Row(id),
            matching: find.byType(RichText, skipOffstage: false),
          )
          .evaluate())
    (e.widget as RichText).text.toPlainText(),
];

void main() {
  holdFontFetches();

  group('passages from attachments', () {
    testWidgets(
      'a passages row for an attachment hit shows the name and matching text and choosing it reveals at its start byte',
      (tester) async {
        final p = await _wi148Open(tester);
        final seen = <NoteRevealRequest>[];
        final sub = p.h.container.listen<PendingReveal?>(noteRevealProvider, (
          _,
          next,
        ) {
          if (next != null) seen.add(next.request);
        });
        addTearDown(sub.close);

        await p.searchFor('revenue');

        expect(_wi148Row(_q3PassageId), findsOneWidget);
        expect(
          _wi148InRow(_q3PassageId, 'Q3 report.pdf · …revenue grew 12%…'),
          findsOneWidget,
        );
        expect(_wi148InRow(_q3PassageId, 'Pricing model'), findsOneWidget);

        await p.downTo(_q3PassageId);
        await p.key(LogicalKeyboardKey.enter);
        await pumpFrames(tester);

        expect(p.h.tabs.navigated, [const NoteTab(PaletteSeeds.pricingModel)]);
        expect(seen, hasLength(1));
        expect(seen.single.noteId, PaletteSeeds.pricingModel);
        expect(
          seen.single.at,
          isA<RevealAtByte>().having((a) => a.startByte, 'startByte', 84),
        );
        expect(
          p.attachments.openCalls,
          isEmpty,
          reason: 'a passage opens no file',
        );
      },
    );
  });

  group('the attachments group', () {
    testWidgets(
      'the attachments header follows the passages group with a row per attachment',
      (tester) async {
        final p = await _wi148Open(tester);

        await p.searchFor('revenue');

        expect(_wi148Group(PaletteGroupKind.passages), findsOneWidget);
        expect(_wi148Group(PaletteGroupKind.attachments), findsOneWidget);
        expect(
          find.descendant(
            of: _wi148Group(PaletteGroupKind.attachments),
            matching: find.text('ATTACHMENTS · 2', skipOffstage: false),
          ),
          findsOneWidget,
        );
        final passagesTop = tester
            .getTopLeft(_wi148Group(PaletteGroupKind.passages))
            .dy;
        final attachmentsTop = tester
            .getTopLeft(_wi148Group(PaletteGroupKind.attachments))
            .dy;
        final lastPassageBottom = tester
            .getBottomLeft(_wi148Row(_q3PassageId))
            .dy;
        expect(attachmentsTop, greaterThan(passagesTop));
        expect(attachmentsTop, greaterThanOrEqualTo(lastPassageBottom));
        final q3Top = tester.getTopLeft(_wi148Row(_wi148AttachmentId(_q3))).dy;
        final planTop = tester
            .getTopLeft(_wi148Row(_wi148AttachmentId(_plan)))
            .dy;
        expect(q3Top, greaterThan(attachmentsTop));
        expect(planTop, greaterThan(q3Top), reason: 'the answer order');
      },
    );

    testWidgets(
      'a content match row shows an icon the name the matching text and the notes line',
      (tester) async {
        final p = await _wi148Open(tester);

        await p.searchFor('revenue');

        final id = _wi148AttachmentId(_q3);
        expect(_wi148Row(id), findsOneWidget);
        expect(
          find.descendant(
            of: _wi148Row(id),
            matching: find.byType(Icon, skipOffstage: false),
          ),
          findsAtLeastNWidgets(1),
        );
        expect(_wi148InRow(id, 'Q3 report.pdf'), findsOneWidget);
        expect(_wi148ContainingInRow(id, '…revenue grew 12%…'), findsOneWidget);
        expect(
          _wi148ContainingInRow(id, 'in Planning notes, 2026-11-18'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'a name only row shows the name and notes line and no matching text',
      (tester) async {
        final p = await _wi148Open(tester);

        await p.searchFor('revenue');

        final plan = _wi148AttachmentId(_plan);
        final q3 = _wi148AttachmentId(_q3);
        expect(_wi148InRow(plan, 'Revenue plan.png'), findsOneWidget);
        expect(
          _wi148ContainingInRow(plan, 'in Bay, Cove, Dune +1'),
          findsOneWidget,
        );
        final planTexts = _wi148RowTexts(tester, plan);
        final q3Texts = _wi148RowTexts(tester, q3);
        expect(
          planTexts,
          everyElement(isNot(anyOf(isEmpty, contains('null')))),
          reason: 'no empty or null snippet line',
        );
        expect(
          planTexts.length,
          q3Texts.length - 1,
          reason: 'the content match draws one more text, its snippet',
        );
        expect(planTexts.where((t) => t.contains('revenue grew')), isEmpty);
      },
    );

    testWidgets(
      'three referencing notes show three titles and four show three titles and plus one',
      (tester) async {
        final three = _wi148Attachment(
          'Three.pdf',
          h2: 'e5',
          notes: const ['Bay', 'Cove', 'Dune'],
        );
        final four = _wi148Attachment(
          'Four.pdf',
          h2: 'f6',
          notes: const ['Bay', 'Cove', 'Dune', 'Fen'],
        );
        final p = await _wi148Open(
          tester,
          answer: _wi148Answer(attachments: [three, four]),
        );

        await p.searchFor('revenue');

        final threeId = _wi148AttachmentId(three);
        final fourId = _wi148AttachmentId(four);
        expect(
          _wi148ContainingInRow(threeId, 'in Bay, Cove, Dune'),
          findsOneWidget,
        );
        expect(_wi148ContainingInRow(threeId, '+'), findsNothing);
        expect(_wi148ContainingInRow(threeId, 'Fen'), findsNothing);
        expect(
          _wi148ContainingInRow(fourId, 'in Bay, Cove, Dune +1'),
          findsOneWidget,
        );
        expect(_wi148ContainingInRow(fourId, 'Fen'), findsNothing);
      },
    );

    final absent = <(String, SearchReady)>[
      (
        'the attachments group is absent when the answer has no attachments field',
        searchReadyFromJson({
          'query': 'revenue',
          'semantic': 'on',
          'truncated': false,
          'hits': [
            {
              'note_id': PaletteSeeds.backlog,
              'note_title': 'Backlog',
              'chunk_id': _walkChunk,
              'snippet': 'The revenue walk for October.',
              'start_byte': 0,
              'note_updated_at': paletteHoursAgo(96),
            },
          ],
        }),
      ),
      (
        'the attachments group is absent when the answer lists no attachments',
        _wi148Answer(attachments: []),
      ),
    ];
    for (final (name, answer) in absent) {
      testWidgets(name, (tester) async {
        // Control: an answer that lists attachments shows the group.
        final p = await _wi148Open(tester);
        await p.searchFor('revenue');
        expect(_wi148Group(PaletteGroupKind.attachments), findsOneWidget);

        p.search.result = answer;
        await p.searchFor('revenue grew');

        expect(_wi148Group(PaletteGroupKind.passages), findsOneWidget);
        expect(_wi148Group(PaletteGroupKind.attachments), findsNothing);
        expect(_wi148Row(_wi148AttachmentId(_q3)), findsNothing);
        expect(_wi148Row(_wi148AttachmentId(_plan)), findsNothing);
      });
    }

    testWidgets(
      'the attachments group shows after the 250 ms debounce and not for one character',
      (tester) async {
        final p = await _wi148Open(tester);

        await p.type('r');
        await p.wait(1000);
        expect(p.search.calls, isEmpty);
        expect(_wi148Group(PaletteGroupKind.attachments), findsNothing);

        await p.type('re');
        await p.wait(249);
        expect(p.search.calls, isEmpty);
        expect(_wi148Group(PaletteGroupKind.attachments), findsNothing);

        await p.wait(1);
        expect([for (final c in p.search.calls) c.query], ['re']);
        expect(_wi148Group(PaletteGroupKind.attachments), findsOneWidget);
      },
    );
  });

  group('choosing an attachment', () {
    testWidgets(
      'a click on an attachments row calls open with its path through the attachments domain',
      (tester) async {
        final p = await _wi148Open(tester);
        await p.searchFor('revenue');

        await tester.ensureVisible(_wi148Row(_wi148AttachmentId(_plan)));
        await tester.pump();
        await tester.tap(_wi148Row(_wi148AttachmentId(_plan)));
        await pumpFrames(tester);

        expect(p.attachments.openCalls, [_plan.path]);
        expect(p.attachments.revealCalls, isEmpty);
        expect(p.h.tabs.navigated, isEmpty, reason: 'no note opens');
      },
    );

    testWidgets(
      'enter on an executable attachments row calls open and leaves the reveal to the domain',
      (tester) async {
        final script = _wi148Attachment(
          'deploy.sh',
          type: 'text/x-sh',
          h2: 'd4',
          snippet: 'revenue sync',
        );
        final p = await _wi148Open(
          tester,
          answer: _wi148Answer(attachments: [script]),
        );
        await p.searchFor('revenue');

        await p.downTo(_wi148AttachmentId(script));
        await p.key(LogicalKeyboardKey.enter);
        await pumpFrames(tester);

        expect(p.attachments.openCalls, [script.path]);
        expect(p.attachments.revealCalls, isEmpty);
      },
    );

    testWidgets(
      'arrow down from the last passages row selects the first attachments row and enter opens it',
      (tester) async {
        final p = await _wi148Open(tester);
        await p.searchFor('revenue');

        await p.downTo(_q3PassageId);
        await p.key(LogicalKeyboardKey.arrowDown);
        expect(p.selectedRows, [_wi148AttachmentId(_q3)]);
        expect(p.state.selected, _wi148AttachmentId(_q3));

        await p.key(LogicalKeyboardKey.arrowUp);
        expect(p.selectedRows, [_q3PassageId]);
        await p.key(LogicalKeyboardKey.arrowDown);
        expect(p.selectedRows, [_wi148AttachmentId(_q3)]);

        await p.key(LogicalKeyboardKey.enter);
        await pumpFrames(tester);

        expect(p.attachments.openCalls, [_q3.path]);
        expect(
          p.h.tabs.navigated,
          isEmpty,
          reason: 'the passage is not chosen',
        );
      },
    );
  });

  group('row layout', () {
    testWidgets(
      'an attachments row is a selectable button labelled with its name',
      (tester) async {
        final semantics = tester.ensureSemantics();
        final p = await _wi148Open(tester);
        await p.searchFor('revenue');
        await p.downTo(_wi148AttachmentId(_q3));

        final selected = tester.getSemantics(
          _wi148Row(_wi148AttachmentId(_q3)),
        );
        expect(selected, isSemantics(isButton: true, isSelected: true));
        expect(selected.label, contains('Q3 report.pdf'));
        final other = tester.getSemantics(_wi148Row(_wi148AttachmentId(_plan)));
        expect(other, isSemantics(isButton: true, isSelected: false));
        expect(other.label, contains('Revenue plan.png'));
        semantics.dispose();
      },
    );

    testWidgets(
      'attachments rows with long names and titles do not overflow the narrow card at text scale 1.5',
      (tester) async {
        final long = _wi148Attachment(
          '${List.filled(6, 'Quarterly revenue report').join(' ')}.pdf',
          snippet: List.filled(12, '…revenue grew 12% across regions…').join(),
          notes: [
            for (var i = 0; i < 5; i++)
              List.filled(4, 'Planning notes for the quarter').join(' '),
          ],
        );
        final p = await _wi148Open(
          tester,
          answer: _wi148Answer(attachments: [long, _plan]),
          size: paletteNarrowSize,
          textScale: 1.5,
        );

        await p.searchFor('revenue');

        expect(_wi148Row(_wi148AttachmentId(long)), findsOneWidget);
        expect(tester.takeException(), isNull);
        await p.downTo(_wi148AttachmentId(_plan));
        await pumpFrames(tester);
        expect(tester.takeException(), isNull);
      },
    );
  });
}
