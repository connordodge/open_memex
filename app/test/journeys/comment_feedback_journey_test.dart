// WI #261 (F9) AC13: the comment journey in the Activity tab, on the whole
// workspace with a stateful memex fake: write a comment on an entry, edit
// it, delete it; and the agent handling a comment turns its row read only.
import 'package:flutter_test/flutter_test.dart';

import '../support/comment_activity_harness.dart';

void main() {
  testWidgets(
    'the person writes a comment on an entry then edits it then deletes it',
    (tester) async {
      final r = await pumpActivityRig(tester);

      // Write.
      await r.openComment(newerEntryId);
      await r.type('coyote time is game feel');
      await r.save();
      expect(r.rowText('fb-new-1'), contains('You: coyote time is game feel'));
      expect(r.status('fb-new-1'), 'Open');
      expect(r.cli.callsFor('feedback add'), hasLength(1));

      // Edit.
      await r.tap('feedback-edit-fb-new-1');
      expect(r.fieldText(), 'coyote time is game feel');
      await r.type('coyote time is the whole game');
      await r.save();
      expect(
        r.rowText('fb-new-1'),
        contains('You: coyote time is the whole game'),
      );
      expect(r.rowText('fb-new-1'), isNot(contains('game feel')));
      expect(r.status('fb-new-1'), 'Open');
      expect(r.cli.callsFor('feedback edit'), hasLength(1));
      expect(r.cli.callsFor('feedback edit').single.flag('id'), 'fb-new-1');

      // Delete.
      await r.tap('feedback-delete-fb-new-1');
      expect(r.key('feedback-fb-new-1'), findsNothing);
      expect(find.textContaining('coyote time'), findsNothing);
      expect(r.cli.callsFor('feedback rm'), hasLength(1));
      expect(r.cli.callsFor('feedback rm').single.flag('id'), 'fb-new-1');
      // The entry itself is still there, ready for another comment.
      expect(r.key('activity-comment-$newerEntryId'), findsOneWidget);
      expect(
        r.db.db.select('SELECT id FROM feedback'),
        isEmpty,
        reason: 'the comment is gone from the vault',
      );
    },
  );

  testWidgets(
    'a comment the agent handles while the Activity tab is open turns read only',
    (tester) async {
      final r = await pumpActivityRig(tester);

      await r.openComment(olderEntryId);
      await r.type('please move this to Player Feel');
      await r.save();
      expect(r.status('fb-new-1'), 'Open');
      expect(r.key('feedback-edit-fb-new-1'), findsOneWidget);
      expect(r.key('feedback-delete-fb-new-1'), findsOneWidget);

      r.agentHandles('fb-new-1', 'moved it to Player Feel');
      bumpRevision(r);
      await r.settle();

      expect(r.status('fb-new-1'), 'Handled: moved it to Player Feel');
      expect(r.key('feedback-edit-fb-new-1'), findsNothing);
      expect(r.key('feedback-delete-fb-new-1'), findsNothing);
      expect(
        r.rowText('fb-new-1'),
        contains('You: please move this to Player Feel'),
      );
    },
  );
}
