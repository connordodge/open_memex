// WI #261 (F9) verify: ruling D40. Only the emptiness check trims; the 2,000
// limit counts the RAW text in Unicode code points (core's Rust chars()), so
// padding spaces count and emoji count once each.
import 'package:flutter_test/flutter_test.dart';

import '../support/comment_activity_harness.dart';
import '../support/feedback_seeds.dart';

String _emoji(int n) => List.filled(n, '\u{1F600}').join();

void main() {
  testWidgets(
    'Save with 2000 emoji is accepted because the limit counts code points',
    (tester) async {
      final r = await pumpActivityRig(tester);

      await r.openComment(olderEntryId);
      await r.type(_emoji(2000));
      await r.save();

      expect(r.calls('addComment'), hasLength(1));
      expect(r.calls('addComment').single.args['text'], _emoji(2000));
    },
  );

  testWidgets('Save with 2001 emoji is refused with no call', (tester) async {
    final r = await pumpActivityRig(tester);

    await r.openComment(olderEntryId);
    await r.type(_emoji(2001));
    await r.save();

    expect(r.calls('addComment'), isEmpty);
    expect(r.field, findsOneWidget);
  });

  testWidgets(
    'Save with spaces padding the raw text past 2000 characters is refused with no call',
    (tester) async {
      final r = await pumpActivityRig(tester);

      await r.openComment(olderEntryId);
      await r.type('${' ' * 1995}hello world');
      await r.save();

      expect(r.calls('addComment'), isEmpty);
      expect(r.field, findsOneWidget);
    },
  );

  testWidgets(
    'Save with padding and text totalling exactly 2000 raw characters sends the trimmed text',
    (tester) async {
      final r = await pumpActivityRig(tester);

      await r.openComment(olderEntryId);
      await r.type('${' ' * 1990}0123456789');
      await r.save();

      expect(r.calls('addComment').single.args['text'], '0123456789');
    },
  );

  testWidgets(
    'Edit with spaces padding the raw text past 2000 characters is refused with no call',
    (tester) async {
      final db = seedCommentVault();
      db.seedFeedback(
        'fb-open',
        noteId: commentNoteId,
        day: olderEntryDay,
        agentChangeId: olderEntryId,
        text: 'short',
        createdAt: 1000,
      );
      final r = await pumpActivityRig(tester, db: db);

      await r.tap('feedback-edit-fb-open');
      await r.type('${' ' * 1995}hello world');
      await r.save();

      expect(r.calls('editComment'), isEmpty);
      expect(r.field, findsOneWidget);
    },
  );
}
