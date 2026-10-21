// WI #87 (W3, verify): the folder menu runs its dialogs on the Topics pane's
// context (`hostContext`). A rename or delete answered after the pane left the
// tree (the sidebar was switched away while the dialog was open) must write
// nothing: the writes need a live context for the unreachable snackbar.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/sidebar_mode_state.dart';
import 'package:open_memex_app/src/state/topics_state.dart';

import '../support/topics_access_doubles.dart';
import '../support/topics_launch.dart';
import '../support/topics_seed.dart';

void main() {
  testWidgets(
    'a rename confirmed after the Topics pane was unmounted writes nothing',
    (tester) async {
      final doubles = AccessDoubles();
      final r = await launchTopics(tester, doubles);
      await r.openFolderMenu(TP.health);
      await r.tap(r.menuRename);
      await r.enterName('renamed');
      final topicsBefore = doubles.topicsAt(r.h.vaultPath);
      final writesBefore = topicsBefore.callsTo('updateFolder').length;
      unawaited(
        r.h.container
            .read(sidebarModeProvider.notifier)
            .select(SidebarMode.days),
      );
      await r.tester.pump();
      expect(r.pane, findsNothing, reason: 'the pane left the tree');

      await r.tap(r.nameConfirm);

      expect(
        topicsBefore.callsTo('updateFolder'),
        hasLength(writesBefore),
        reason: 'no write after the host context unmounted',
      );
      expect(
        r.h
            .read(smartFolderTreeProvider)
            .folders
            .any((f) => f.name == 'renamed'),
        isFalse,
      );
    },
  );

  testWidgets(
    'a delete confirmed after the Topics pane was unmounted writes nothing',
    (tester) async {
      final doubles = AccessDoubles();
      final r = await launchTopics(tester, doubles);
      await r.openFolderMenu(TP.health);
      await r.tap(r.menuDelete);
      expect(r.deleteDialog, findsOneWidget);
      final topicsBefore = doubles.topicsAt(r.h.vaultPath);
      unawaited(
        r.h.container
            .read(sidebarModeProvider.notifier)
            .select(SidebarMode.days),
      );
      await r.tester.pump();
      expect(r.pane, findsNothing, reason: 'the pane left the tree');

      await r.tap(r.deleteConfirm);

      expect(
        topicsBefore.callsTo('deleteFolder'),
        isEmpty,
        reason: 'no write after the host context unmounted',
      );
      expect(
        r.h.read(smartFolderTreeProvider).folders.any((f) => f.id == TP.health),
        isTrue,
      );
    },
  );
}
