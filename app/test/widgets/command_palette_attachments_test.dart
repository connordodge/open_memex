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

import 'dart:async';

import 'package:flutter/material.dart' show SnackBar, TextField;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:open_memex_app/src/state/attachments_state.dart';
import 'package:open_memex_app/src/state/command_palette_state.dart';
import 'package:open_memex_app/src/state/note_reveal.dart';
import 'package:open_memex_app/src/state/palette_passages.dart';
import 'package:open_memex_app/src/state/settings.dart' show settingsProvider;
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/ui_state_store.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/vault_access/attachments_access.dart';
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
  ValueNotifier<bool>? hostShown,
  FakeAttachmentsAccess? access,
  FocusNode? hostFocus,
}) async {
  final settings = await _wi148Settings();
  final fake = access ?? FakeAttachmentsAccess();
  final h = await pumpPaletteHost(
    tester,
    size: size,
    textScale: textScale,
    search: FakeSearchAccess(
      vaultPath: paletteVaultPath,
      result: answer ?? _wi148Answer(),
    ),
    child: ValueListenableBuilder<bool>(
      valueListenable: hostShown ?? ValueNotifier(true),
      builder: (_, shown, _) {
        if (!shown) return const SizedBox.expand();
        return Builder(
          builder: (context) {
            _wi148HostContext = context;
            if (hostFocus == null) return const SizedBox.expand();
            return Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 200,
                child: TextField(focusNode: hostFocus, autofocus: true),
              ),
            );
          },
        );
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

/// An attachments domain whose `open` waits for [answer]: the file is
/// still opening (a hosted download) until the test completes it.
class _Wi148HeldAttachments extends FakeAttachmentsAccess {
  final answer = Completer<AttachmentActionResult>();

  @override
  Future<AttachmentActionResult> open(String path) {
    openCalls.add(path);
    return answer.future;
  }
}

/// The same answer as [_wi148Answer], from a vault whose meaning model is
/// not downloaded.
SearchReady _wi148KeywordOnlyAnswer() {
  final base = _wi148Answer();
  return SearchReady(
    base.hits,
    semantic: Semantic.modelNotDownloaded,
    truncated: false,
    attachments: base.attachments,
  );
}

/// The words drawn in the mark highlight under [within].
List<String> _wi148MarkedWords(Finder within) {
  final marked = <String>[];
  for (final e
      in find
          .descendant(of: within, matching: find.byType(RichText))
          .evaluate()) {
    (e.widget as RichText).text.visitChildren((span) {
      if (span is TextSpan &&
          span.style?.backgroundColor == OmColors.accentMark) {
        marked.add(span.text ?? '');
      }
      return true;
    });
  }
  return marked;
}

/// The Opacity(0.5) the dimmed rows are wrapped in, around row [id].
Finder _wi148DimmedAround(PaletteItemId id) => find.ancestor(
  of: _wi148Row(id),
  matching: find.byWidgetPredicate((w) => w is Opacity && w.opacity == 0.5),
);

/// The icon the row [id] draws.
IconData _wi148RowIcon(WidgetTester tester, PaletteItemId id) => tester
    .widget<Icon>(
      find.descendant(
        of: _wi148Row(id),
        matching: find.byType(Icon, skipOffstage: false),
      ),
    )
    .icon!;

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

    testWidgets('an attachments row draws the icon for its file type', (
      tester,
    ) async {
      final script = _wi148Attachment(
        'deploy.sh',
        type: 'text/x-sh',
        h2: 'd4',
        snippet: 'revenue sync',
      );
      final p = await _wi148Open(
        tester,
        answer: _wi148Answer(attachments: [_q3, _plan, script]),
      );

      await p.searchFor('revenue');

      expect(
        _wi148RowIcon(tester, _wi148AttachmentId(_plan)),
        LucideIcons.fileImage,
      );
      expect(_wi148RowIcon(tester, _wi148AttachmentId(_q3)), LucideIcons.file);
      expect(
        _wi148RowIcon(tester, _wi148AttachmentId(script)),
        LucideIcons.fileCode,
      );
      expect(
        _wi148RowIcon(tester, _q3PassageId),
        LucideIcons.textQuote,
        reason: 'the passage row keeps its own icon',
      );
    });

    testWidgets(
      'the typed words are marked in a content match snippet and a name only row marks nothing',
      (tester) async {
        final p = await _wi148Open(tester);

        await p.searchFor('revenue');

        expect(_wi148MarkedWords(_wi148Row(_wi148AttachmentId(_q3))), [
          'revenue',
        ]);
        expect(
          _wi148MarkedWords(_wi148Row(_wi148AttachmentId(_plan))),
          isEmpty,
        );
      },
    );

    testWidgets(
      'a model not downloaded answer still draws the attachments group beside the download button',
      (tester) async {
        final p = await _wi148Open(tester, answer: _wi148KeywordOnlyAnswer());

        await p.searchFor('revenue');

        expect(find.byKey(PaletteKeys.download), findsOneWidget);
        expect(_wi148Group(PaletteGroupKind.attachments), findsOneWidget);
        expect(_wi148Row(_wi148AttachmentId(_q3)), findsOneWidget);
        expect(_wi148Row(_wi148AttachmentId(_plan)), findsOneWidget);
      },
    );

    testWidgets(
      'attachments rows are dimmed after a keystroke until the debounce answers',
      (tester) async {
        final q3 = _wi148AttachmentId(_q3);
        final plan = _wi148AttachmentId(_plan);
        final p = await _wi148Open(tester);
        await p.searchFor('revenue');
        expect(_wi148DimmedAround(q3), findsNothing, reason: 'a shown answer');
        expect(_wi148DimmedAround(plan), findsNothing);

        await p.type('revenue g');

        expect(_wi148DimmedAround(q3), findsOneWidget);
        expect(_wi148DimmedAround(plan), findsOneWidget);
        expect(
          _wi148DimmedAround(_q3PassageId),
          findsOneWidget,
          reason: 'the passages rows dim with them',
        );

        await p.wait(passagesDebounce.inMilliseconds);

        expect(_wi148Row(q3), findsOneWidget);
        expect(_wi148DimmedAround(q3), findsNothing);
        expect(_wi148DimmedAround(plan), findsNothing);
      },
    );
  });

  group('choosing an attachment closes the palette first', () {
    testWidgets(
      'a click on an attachments row closes the palette and calls open',
      (tester) async {
        final p = await _wi148Open(tester);
        await p.searchFor('revenue');
        expect(find.byKey(PaletteKeys.palette), findsOneWidget);

        await tester.ensureVisible(_wi148Row(_wi148AttachmentId(_q3)));
        await tester.pump();
        await tester.tap(_wi148Row(_wi148AttachmentId(_q3)));
        await pumpFrames(tester);

        expect(find.byKey(PaletteKeys.palette), findsNothing);
        expect(p.attachments.openCalls, [_q3.path]);
      },
    );

    testWidgets(
      'choosing an attachments row closes the palette before the file open answers',
      (tester) async {
        final held = _Wi148HeldAttachments();
        final p = await _wi148Open(tester, access: held);
        await p.searchFor('revenue');
        await p.downTo(_wi148AttachmentId(_plan));

        await p.key(LogicalKeyboardKey.enter);
        await pumpFrames(tester);

        expect(held.openCalls, [_plan.path]);
        expect(held.answer.isCompleted, isFalse, reason: 'still opening');
        expect(
          find.byKey(PaletteKeys.palette),
          findsNothing,
          reason: 'req 8: the palette closes first, then the file opens',
        );
        expect(find.byType(SnackBar), findsNothing);
        held.answer.complete(const AttachmentActionDone());
        await pumpFrames(tester);
        expect(find.byType(SnackBar), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'an offline open that answers after the palette closed still shows the toast',
      (tester) async {
        final held = _Wi148HeldAttachments();
        final p = await _wi148Open(tester, access: held);
        await p.searchFor('revenue');
        await p.downTo(_wi148AttachmentId(_plan));
        await p.key(LogicalKeyboardKey.enter);
        await pumpFrames(tester);
        expect(find.byKey(PaletteKeys.palette), findsNothing);
        expect(find.byType(SnackBar), findsNothing, reason: 'not yet');

        held.answer.complete(
          const AttachmentActionFailed(AttachmentLookupFailure.offline),
        );
        await pumpFrames(tester);

        expect(
          find.text(
            "Couldn't open Revenue plan.png: the vault server can't be reached.",
            skipOffstage: false,
          ),
          findsOneWidget,
        );
        expect(find.byType(SnackBar), findsOneWidget);
      },
    );

    testWidgets(
      'choosing an attachments row gives the focus back to where it was before the palette opened',
      (tester) async {
        final hostFocus = FocusNode();
        addTearDown(hostFocus.dispose);
        final p = await _wi148Open(tester, hostFocus: hostFocus);
        expect(hostFocus.hasFocus, isFalse, reason: 'the palette has it');
        await p.searchFor('revenue');
        await p.downTo(_wi148AttachmentId(_plan));

        await p.key(LogicalKeyboardKey.enter);
        await pumpFrames(tester);

        expect(find.byKey(PaletteKeys.palette), findsNothing);
        expect(p.attachments.openCalls, [_plan.path]);
        expect(
          hostFocus.hasFocus,
          isTrue,
          reason: 'the file opens in another app, so the focus returns',
        );
      },
    );
  });

  group('the preview of an attachments row', () {
    testWidgets(
      'selecting an attachments row on the wide card shows no loading line and clears the preview at once',
      (tester) async {
        final p = await _wi148Open(tester);
        await p.searchFor('revenue');
        await p.downTo(_q3PassageId);
        await p.wait(300);
        expect(p.state.preview, isA<PreviewPassage>());
        final seen = <PreviewView>[];
        final sub = p.h.container.listen<PreviewView>(
          palettePreviewProvider,
          (_, next) => seen.add(next),
        );
        addTearDown(sub.close);

        await p.key(LogicalKeyboardKey.arrowDown);

        expect(p.selectedRows, [_wi148AttachmentId(_q3)]);
        expect(p.state.preview, isA<PreviewNone>(), reason: 'at once');
        expect(find.text('loading…'), findsNothing);
        await p.wait(500);
        expect(p.state.preview, isA<PreviewNone>());
        expect(find.text('loading…'), findsNothing);
        expect(seen, isNotEmpty);
        expect(seen, everyElement(isA<PreviewNone>()));
      },
    );

    testWidgets(
      'the preview band for an attachment hit covers only the attachment line',
      (tester) async {
        const noteId = 'n-148-band';
        const lead = 'Intro line\n';
        const attachmentLine = 'Attached Q3 report.pdf here';
        const body =
            '$lead$attachmentLine\nSecond line below the attachment\n'
            'Third line below it';
        final answer = SearchReady(
          [
            SearchHit(
              noteId: noteId,
              noteTitle: ['Q3 review'].join(),
              chunkId: ['c-148-band'].join(),
              snippet: [
                'Q3 report.pdf · …revenue grew 12% across every region and ',
                'every product line this quarter, led by the new tier…',
              ].join(),
              startByte: lead.length,
              noteUpdatedAt: paletteHoursAgo(3),
              attachment: SearchHitAttachment(name: _q3.name, path: _q3.path),
            ),
          ],
          semantic: Semantic.on,
          truncated: false,
          attachments: [_q3],
        );
        final p = await _wi148Open(tester, answer: answer);
        p.h.db.seedNote(
          id: noteId,
          title: 'Q3 review',
          content: body,
          updatedAt: paletteHoursAgo(3),
        );
        await p.searchFor('revenue');
        await p.downTo(
          const PaletteItemId(PaletteItemKind.passage, 'c-148-band'),
        );
        await p.wait(300);

        final band = find.descendant(
          of: find.byKey(PaletteKeys.preview),
          matching: find.byWidgetPredicate(
            (w) =>
                w is DecoratedBox &&
                w.decoration is BoxDecoration &&
                (w.decoration as BoxDecoration).color == OmColors.surface3,
          ),
        );
        expect(band, findsOneWidget);
        Finder inBand(String text) => find.descendant(
          of: band,
          matching: find.textContaining(text, findRichText: true),
        );
        expect(inBand(attachmentLine), findsOneWidget);
        expect(inBand('Second line'), findsNothing);
        expect(inBand('Third line'), findsNothing);
        expect(
          find.descendant(
            of: find.byKey(PaletteKeys.preview),
            matching: find.textContaining('Second line', findRichText: true),
          ),
          findsOneWidget,
          reason: 'the following lines are drawn outside the band',
        );
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

  group('a failed open shows the R42 toast', () {
    const offlineToast =
        "Couldn't open Revenue plan.png: the vault server can't be reached.";

    Future<_Wi148Palette> openAndChoosePlan(
      WidgetTester tester,
      AttachmentActionResult? result, {
      ValueNotifier<bool>? hostShown,
    }) async {
      final p = await _wi148Open(tester, hostShown: hostShown);
      if (result != null) p.attachments.openResults.add(result);
      await p.searchFor('revenue');
      await p.downTo(_wi148AttachmentId(_plan));
      return p;
    }

    testWidgets(
      'an offline open from an attachments row shows the offline toast once',
      (tester) async {
        final p = await openAndChoosePlan(
          tester,
          const AttachmentActionFailed(AttachmentLookupFailure.offline),
        );
        expect(find.byType(SnackBar), findsNothing, reason: 'none before');

        await p.key(LogicalKeyboardKey.enter);
        await pumpFrames(tester);

        expect(p.attachments.openCalls, [_plan.path]);
        expect(find.text(offlineToast, skipOffstage: false), findsOneWidget);
        expect(find.byType(SnackBar), findsOneWidget);
      },
    );

    testWidgets('a missing open from an attachments row shows no toast', (
      tester,
    ) async {
      final p = await openAndChoosePlan(
        tester,
        const AttachmentActionFailed(AttachmentLookupFailure.missing),
      );

      await p.key(LogicalKeyboardKey.enter);
      await pumpFrames(tester);

      expect(p.attachments.openCalls, [_plan.path]);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets(
      'a server too old open from an attachments row shows no toast',
      (tester) async {
        final p = await openAndChoosePlan(
          tester,
          const AttachmentActionFailed(AttachmentLookupFailure.serverTooOld),
        );

        await p.key(LogicalKeyboardKey.enter);
        await pumpFrames(tester);

        expect(p.attachments.openCalls, [_plan.path]);
        expect(find.byType(SnackBar), findsNothing);
      },
    );

    testWidgets('an unsupported open from an attachments row shows no toast', (
      tester,
    ) async {
      final p = await openAndChoosePlan(
        tester,
        const AttachmentActionFailed(AttachmentLookupFailure.unsupported),
      );

      await p.key(LogicalKeyboardKey.enter);
      await pumpFrames(tester);

      expect(p.attachments.openCalls, [_plan.path]);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('a successful open from an attachments row shows no toast', (
      tester,
    ) async {
      final p = await openAndChoosePlan(tester, const AttachmentActionDone());

      await p.key(LogicalKeyboardKey.enter);
      await pumpFrames(tester);

      expect(p.attachments.openCalls, [_plan.path]);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('the offline toast names the chosen row', (tester) async {
      final p = await _wi148Open(tester);
      p.attachments.openResults.add(
        const AttachmentActionFailed(AttachmentLookupFailure.offline),
      );
      await p.searchFor('revenue');
      await p.downTo(_wi148AttachmentId(_q3));

      await p.key(LogicalKeyboardKey.enter);
      await pumpFrames(tester);

      expect(
        find.text(
          "Couldn't open Q3 report.pdf: the vault server can't be reached.",
          skipOffstage: false,
        ),
        findsOneWidget,
      );
    });

    testWidgets(
      'an offline open that answers after the host is gone shows no toast and no error',
      (tester) async {
        final hostShown = ValueNotifier(true);
        addTearDown(hostShown.dispose);
        final p = await openAndChoosePlan(
          tester,
          const AttachmentActionFailed(AttachmentLookupFailure.offline),
          hostShown: hostShown,
        );
        hostShown.value = false;
        await pumpFrames(tester);
        expect(
          _wi148HostContext.mounted,
          isFalse,
          reason: 'the context the palette opened over is unmounted',
        );

        await p.key(LogicalKeyboardKey.enter);
        await pumpFrames(tester);

        expect(p.attachments.openCalls, [_plan.path]);
        expect(find.byType(SnackBar), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'an offline open chosen with no palette session shows no toast and no error',
      (tester) async {
        final settings = await _wi148Settings();
        final fake = FakeAttachmentsAccess();
        fake.openResults.add(
          const AttachmentActionFailed(AttachmentLookupFailure.offline),
        );
        final h = await pumpPaletteHost(
          tester,
          overrides: [
            settings,
            uiStateStoreProvider.overrideWithValue(null),
            ...paletteShellOverrides,
            ...palettePassagesOverrides,
            attachmentsProvider.overrideWithValue(fake),
          ],
        );

        h.read(paletteAttachmentChooserProvider)(
          AttachmentItem(_plan, notesLine: 'in Bay'),
          newTab: false,
        );
        await pumpFrames(tester);

        expect(fake.openCalls, [_plan.path]);
        expect(find.byType(SnackBar), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  });
}
