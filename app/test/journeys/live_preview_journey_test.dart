// WI #169 (C2, Spec #157 D16, D17, TS3): the live-preview journey. On
// today's daily note the person types a heading, a list, a blank line, a
// task and a wikilink with the keys of the editor rows (Enter continues and
// ends lists), and the save sends exactly the markdown typed through the
// fake MemexCli. Reopening the note without editing sends no update.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/editor/segments.dart';

import '../robots/segmented_editor_robot.dart';
import '../robots/today_robot.dart';
import '../support/daily_seed.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/mac_editing.dart';
import '../support/today_cli_fakes.dart';

/// Today's daily note (the FakeClock's date, 2026-10-03), empty.
const _wi169DailyId = 'daily-2026-10-03';

/// A topic note the wikilink links to.
const _wi169IdeasId = 'topic-ideas';

/// The person part the journey types.
const _wi169Typed = '# Plan\n- one\n- two\n\n- [ ] call\nsee [[Ideas]]';

void main() {
  testWidgets(
    'live preview journey typing a heading a list a task and a wikilink with Enter saves exactly the typed markdown and reopening sends no update',
    (tester) async {
      final db = FakeVaultDb.v5()
        ..seedNote(
          id: _wi169DailyId,
          title: '2026-10-03',
          role: 'daily',
          version: 1,
        )
        ..seedTopicNote(_wi169IdeasId, 'Ideas');
      final cli = FakeMemexCli()..onUpdateWrites(db);
      final today = TodayRobot(tester);
      final h = await today.launch(db: db, cli: cli);
      final r = SegmentedEditorRobot(tester, h);

      r.expectActiveNote(_wi169DailyId);
      expect(r.segmentText(0), isEmpty);
      expect(r.segmentHasFocus(0), isTrue, reason: 'launch focuses the body');

      await r.typeChars('# Plan');
      await r.pressEnter();
      expect(r.segmentText(0), '# Plan\n');

      await r.typeChars('- one');
      expect(r.segmentText(0), '# Plan\n- one');
      await r.pressEnter();
      expect(r.segmentText(0), '# Plan\n- one\n- ', reason: 'Enter continues');

      await r.typeChars('two');
      await r.pressEnter();
      expect(r.segmentText(0), '# Plan\n- one\n- two\n- ');

      await r.pressEnter();
      expect(
        r.segmentText(0),
        '# Plan\n- one\n- two\n',
        reason: 'Enter on the empty item ends the list',
      );

      await r.pressEnter();
      expect(r.segmentText(0), '# Plan\n- one\n- two\n\n');

      await r.typeChars('- [ ] call');
      await r.pressEnter();
      expect(r.segmentText(0), '# Plan\n- one\n- two\n\n- [ ] call\n- [ ] ');

      await r.pressEnter();
      expect(r.segmentText(0), '# Plan\n- one\n- two\n\n- [ ] call\n');

      await r.typeChars('see [[Ide');
      await tester.pump();
      expect(r.popover, findsOneWidget);
      final handled = await r.pressEnter();
      expect(handled, isTrue, reason: 'the popover takes Enter');
      expect(r.popover, findsNothing);
      expect(r.segmentText(0), _wi169Typed);
      expect(r.updates, isEmpty, reason: 'nothing saves before the debounce');

      await r.waitForSave();

      expect(r.updates, hasLength(1));
      final saved = r.updates.single.stdinBody ?? '';
      expect(splitDailyBody(saved).person, _wi169Typed);

      // Reopening the note without editing sends no update (D17).
      await r.closeAndReopen(_wi169DailyId);
      r.expectActiveNote(_wi169DailyId);
      expect(r.segmentText(0), _wi169Typed);
      await r.waitForSave();
      expect(r.updates, hasLength(1));
      expect(tester.takeException(), isNull);
    },
    variant: macOnly,
  );
}
