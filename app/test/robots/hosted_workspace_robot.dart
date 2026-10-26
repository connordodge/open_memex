import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';

import '../support/journey_harness.dart';
import '../support/segment_editing_finder.dart';

/// Ids of the fixture vault's notes (test/fixtures/api_v1, vault `seed`).
const seedLooseThoughtId = '01M5DQAYZ4RYSGA8T0YEEF8QRS';
const seedBrokenFrontmatterId = '01M5DQAYZ5RH88SRZGPY15XXVM';
const seedPacingNotesId = '01M5DQAYZ4YAPYMEDWXP8WCNGJ';
const seedPlayerLoopId = '01M5DQAYZ3WP7H0NXZZV9M2315';
const seedCanvasId = '01M5DQAYZJET989N2YR8341XAN';

/// Robot for a hosted vault's workspace (WI #105 journeys). Finds widgets
/// by the stable Keys of H2 and H7 to H9 only:
/// - banners (#101): `hosted-banner-unreachable`, `hosted-banner-retry`,
///   `hosted-banner-unauthorized`, `hosted-banner-update-token`,
///   `hosted-banner-vault-gone`; the not-loaded state `tab-not-loaded`;
/// - editor (#102): `text-segment-<i>`, `pending-save-label`,
///   `save-indicator`, tab chips `tab-<tabId>` and their ring
///   `tab-pending-<tabId>`;
/// - sidebar: `sidebar-mode-topics`, `topics-unsorted-<noteId>`,
///   `topics-new-folder`, `folder-name-field`, `folder-name-confirm`,
///   vault pills `vault-pill-<serverId>-<vault>`, `pill-open-failed-snackbar`;
/// - leave confirm (#103): `leave-confirm`, `leave-confirm-cancel`,
///   `leave-confirm-proceed`.
class HostedWorkspaceRobot {
  HostedWorkspaceRobot(this.app);

  final JourneyApp app;

  WidgetTester get tester => app.tester;

  // ---------------------------------------------------------------- finders

  Finder key(String k) => find.byKey(Key(k));

  Finder get unreachableBanner => key('hosted-banner-unreachable');
  Finder get retryNow => key('hosted-banner-retry');
  Finder get unauthorizedBanner => key('hosted-banner-unauthorized');
  Finder get bannerUpdateToken => key('hosted-banner-update-token');
  Finder get vaultGoneBanner => key('hosted-banner-vault-gone');
  Finder get notLoaded => key('tab-not-loaded');
  Finder segment(int i) => key('text-segment-$i');
  Finder get pendingLabel => key('pending-save-label');
  Finder get saveIndicator => key('save-indicator');
  Finder noteTab(String noteId) => key('tab-note-$noteId');
  Finder noteTabRing(String noteId) => key('tab-pending-note-$noteId');
  Finder unsorted(String noteId) => key('topics-unsorted-$noteId');
  Finder pill(String serverId, String vault) =>
      key('vault-pill-$serverId-$vault');
  Finder get pillSnackbar => key('pill-open-failed-snackbar');
  Finder get leaveConfirm => key('leave-confirm');
  Finder get leaveCancel => key('leave-confirm-cancel');
  Finder get leaveProceed => key('leave-confirm-proceed');

  bool saveIndicatorShows(String text) => find
      .descendant(of: saveIndicator, matching: find.text(text))
      .evaluate()
      .isNotEmpty;

  // ------------------------------------------------------------------ state

  /// The text of segment [i] of the open note.
  String segmentText(int i) => segmentEditingAt(tester, i).text;

  String? get activeTabId => app.read(activeTabProvider)?.tabId;

  VaultRef? get currentVault => app.read(currentVaultProvider);

  // ---------------------------------------------------------------- actions

  Future<void> tap(Finder f) async {
    await tester.ensureVisible(f);
    await tester.tap(f);
    await app.settle();
  }

  /// Shows the Topics mode of the sidebar (its unsorted list holds Loose
  /// Thought and Broken Frontmatter).
  Future<void> showTopics() => tap(key('sidebar-mode-topics'));

  /// Opens note [noteId] from the Topics pane's unsorted list.
  Future<void> openUnsorted(String noteId) => tap(unsorted(noteId));

  /// Opens note [noteId] in a tab (content the sidebar does not list).
  Future<void> openNoteTab(String noteId) async {
    app.read(tabsProvider.notifier).openOrFocus(NoteTab(noteId));
    await app.settle();
  }

  /// Types [text] as the open note's first segment and lets the 500 ms save
  /// debounce fire and the save's request answer (or fail).
  Future<void> typeAndSave(String text) async {
    // TEST-CHANGE (#167): through the segment's handle (editor rows).
    await typeSegmentText(tester, segment(0), text);
    await app.advance(const Duration(milliseconds: 600));
  }

  /// "+ New Smart Folder" in the Topics header with [name] (a folder write,
  /// Req 50: not queued, not retried).
  Future<void> newSmartFolder(String name) async {
    await tap(key('topics-new-folder'));
    await tester.enterText(key('folder-name-field'), name);
    await tester.pump();
    await tap(key('folder-name-confirm'));
  }
}
