// WI #78 (56-A4, Spec #59 req 28; architect D2, D3): choosing a passage.
//
// - The passage chooser navigates (or, with ⌘, `openOrFocus`es) the hit's
//   note FIRST, then asks `noteRevealProvider` for `RevealAtByte(startByte)`,
//   `RevealThird()`, `flash: true`, `leaveSource: true`. A null byte offset
//   asks for `RevealAtByte(null)` (54-R0 lands it at the top).
// - A passage in the note already shown lands in that editor, exactly where
//   the same reveal request made directly lands, with the arrival highlight
//   and no request left held (54-R0's same-note rule; this WI never edits
//   note_editor.dart).
//
// Seams: palette_pump.dart (real TabsNotifier with a TabsRecorder) for the
// order and fields; note_reveal_pump.dart (the workspace with a long note)
// for the same-note landing. The chooser is #78's, from
// `palettePassagesOverrides`.
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/command_palette_state.dart';
import 'package:open_memex_app/src/state/note_reveal.dart';
import 'package:open_memex_app/src/state/palette_passages.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/vault_access/search_access.dart';

import '../../support/font_fetch_hold.dart';
import '../../support/note_reveal_pump.dart';
import '../../support/palette_pump.dart';

PassageItem _wi78Passage(String noteId, {int? startByte, String? title}) =>
    PassageItem(
      SearchHit(
        noteId: [noteId].join(),
        noteTitle: [title ?? 'Pricing model'].join(),
        chunkId: ['c-78', noteId].join('-'),
        snippet: ['the refund window is 30 days'].join(),
        startByte: startByte,
        noteUpdatedAt: paletteHoursAgo(2),
      ),
      meta: 'note · 2 h ago',
    );

/// What the tabs looked like when each reveal request arrived.
typedef _Wi78Seen = ({
  NoteRevealRequest request,
  WorkspaceTab? active,
  List<WorkspaceTab> tabs,
});

List<_Wi78Seen> _wi78WatchRequests(ProviderContainer container) {
  final seen = <_Wi78Seen>[];
  final sub = container.listen<PendingReveal?>(noteRevealProvider, (_, next) {
    if (next == null) return;
    final tabs = container.read(tabsProvider);
    seen.add((
      request: next.request,
      active: tabs.activeTab,
      tabs: [...tabs.tabs],
    ));
  });
  addTearDown(sub.close);
  return seen;
}

/// Pumps zero-length frames until the arrival highlight shows.
Future<bool> _wi78UntilHighlight(
  WidgetTester tester,
  NoteRevealHarness h,
) async {
  for (var i = 0; i < 20; i++) {
    if (h.highlight.evaluate().isNotEmpty) return true;
    await tester.pump();
  }
  return h.highlight.evaluate().isNotEmpty;
}

void main() {
  holdFontFetches();

  testWidgets(
    'choosing a passage navigates to its note first and then requests the byte reveal a third down with flash and leaveSource, and with cmd it calls openOrFocus first',
    (tester) async {
      final h = await pumpPaletteHost(
        tester,
        overrides: palettePassagesOverrides,
      );
      final seen = _wi78WatchRequests(h.container);
      final choose = h.read(palettePassageChooserProvider);

      choose(
        _wi78Passage(PaletteSeeds.pricingModel, startByte: 240),
        newTab: false,
      );
      await tester.pump();

      expect(h.tabs.navigated, [const NoteTab(PaletteSeeds.pricingModel)]);
      expect(seen, hasLength(1));
      final first = seen.single;
      expect(
        first.active,
        const NoteTab(PaletteSeeds.pricingModel),
        reason: 'navigate runs before the request',
      );
      expect(first.request.noteId, PaletteSeeds.pricingModel);
      expect(
        first.request.at,
        isA<RevealAtByte>().having((a) => a.startByte, 'startByte', 240),
      );
      expect(first.request.placement, isA<RevealThird>());
      expect(first.request.flash, isTrue);
      expect(first.request.leaveSource, isTrue);

      // With cmd: openOrFocus a new tab first, never navigate this one.
      h
          .read(tabsProvider.notifier)
          .navigate(const NoteTab(PaletteSeeds.backlog));
      h.tabs.navigated.clear();
      seen.clear();
      choose(
        _wi78Passage(PaletteSeeds.feedbackLog, startByte: 12),
        newTab: true,
      );
      await tester.pump();

      expect(h.tabs.navigated, isEmpty, reason: 'the current tab stays');
      expect(seen, hasLength(1));
      final second = seen.single;
      expect(second.active, const NoteTab(PaletteSeeds.feedbackLog));
      expect(second.tabs, [
        const NoteTab(PaletteSeeds.backlog),
        const NoteTab(PaletteSeeds.feedbackLog),
      ], reason: 'openOrFocus opened a tab before the request');
      expect(second.request.noteId, PaletteSeeds.feedbackLog);
      expect(
        second.request.at,
        isA<RevealAtByte>().having((a) => a.startByte, 'startByte', 12),
      );
      expect(second.request.placement, isA<RevealThird>());
      expect(second.request.flash, isTrue);
      expect(second.request.leaveSource, isTrue);
    },
  );

  testWidgets(
    'choosing a passage with no byte offset requests a reveal with a null byte',
    (tester) async {
      final h = await pumpPaletteHost(
        tester,
        overrides: palettePassagesOverrides,
      );
      final seen = _wi78WatchRequests(h.container);

      h.read(palettePassageChooserProvider)(
        _wi78Passage(PaletteSeeds.backlog),
        newTab: false,
      );
      await tester.pump();

      expect(h.tabs.navigated, [const NoteTab(PaletteSeeds.backlog)]);
      expect(seen, hasLength(1));
      expect(seen.single.active, const NoteTab(PaletteSeeds.backlog));
      expect(
        seen.single.request.at,
        isA<RevealAtByte>().having((a) => a.startByte, 'startByte', isNull),
      );
      expect(seen.single.request.placement, isA<RevealThird>());
    },
  );

  testWidgets(
    'choosing a passage in the note already shown lands on it in that editor',
    (tester) async {
      final h = await pumpNoteReveal(
        tester,
        overrides: palettePassagesOverrides,
      );
      final at = revealLongBody.indexOf('line 200\n');
      final byte = utf8.encode(revealLongBody.substring(0, at)).length;
      expect(h.pixels(), 0);
      final tabsBefore = [...h.tabState.tabs];

      h.read(palettePassageChooserProvider)(
        _wi78Passage(revealLongId, startByte: byte, title: 'Long'),
        newTab: false,
      );
      expect(await _wi78UntilHighlight(tester, h), isTrue);
      await pumpFrames(tester);

      final landed = h.pixels();
      expect(landed, greaterThan(0), reason: 'the editor scrolled to it');
      expect(h.pending, isNull, reason: 'no reveal target left held');
      expect(h.tabState.tabs, tabsBefore, reason: 'same tab, no new one');
      expect(h.tabState.activeTab, const NoteTab(revealLongId));

      // Control: the same request made directly lands in the same place.
      await tester.pump(const Duration(milliseconds: 1300));
      await h.scrollTo(0);
      h.request(
        NoteRevealRequest(
          revealLongId,
          RevealAtByte(byte),
          const RevealThird(),
          flash: true,
          leaveSource: true,
        ),
      );
      expect(await _wi78UntilHighlight(tester, h), isTrue);
      await pumpFrames(tester);
      expect(h.pixels(), landed);
    },
  );
}
