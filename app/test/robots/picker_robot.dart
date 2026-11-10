import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/widgets/atoms.dart';
import 'package:open_memex_app/src/widgets/backups/backup_keys.dart';

import '../support/journey_harness.dart';

/// Robot for the vault picker and its hosted dialogs (WI #105 journeys).
/// Finds widgets by the stable Keys of G1 and H3 to H6 only:
/// - picker: `picker-servers-connect`, `picker-no-servers-connect`,
///   `picker-no-servers-setup`, `vault-picker-open`, `vault-picker-create`,
///   `vault-picker-open-on-server`, `vault-picker-create-on-server`,
///   `server-row-<id>`, `server-row-edit-<id>`, `server-row-remove-<id>`,
///   `remove-server-confirm`, `remove-server-cancel`, `recent-row-<i>`,
///   `recent-row-retry-<i>`, `recent-row-update-token-<i>`,
///   `recent-row-remove-from-recents-<i>`, `recent-row-remove-<i>`;
/// - vault picker modal (#362, frozen for #363): `vault-picker-modal`,
///   `vault-picker-modal-close`, and in its RECENT rows (#361)
///   `recent-row-open-tag-<i>`, `recent-row-finder-<i>`,
///   `recent-row-delete-<i>`;
/// - connect / edit-server dialog (#98): `connect-server-dialog`,
///   `connect-name`, `connect-url`, `connect-token`, `connect-submit`,
///   `connect-cancel`, `connect-setup-link`, `connect-error`;
/// - open / create on a server (#99): `open-on-server-dialog`,
///   `open-on-server-vault-<name>`, `open-on-server-open`,
///   `open-on-server-empty-create`, `open-on-server-create-link`,
///   `open-on-server-server-menu`, `server-select-connect`,
///   `server-dialog-error`, `server-dialog-update-token`,
///   `create-on-server-dialog`, `create-on-server-name`,
///   `create-on-server-submit`, `create-on-server-error`;
/// - set-up sheet (#100): `setup-sheet`, `setup-connect`, `setup-close`;
/// - refusals (#92): `network-drive-refusal`, `network-drive-refusal-setup`,
///   `network-drive-refusal-connect`, `network-drive-refusal-cancel`,
///   `memex-too-old-refusal`, `memex-too-old-locate`;
/// - restore from backup (#327): `vault-picker-restore`, `restore-dialog`,
///   `restore-name`, `restore-folder`, `restore-submit`, `restore-error`
///   (frozen, `backup_keys.dart`) and the dialog's local `restore-cancel`,
///   `restore-file`, `restore-meta`, `restore-target`.
class PickerRobot {
  PickerRobot(this.app);

  final JourneyApp app;

  WidgetTester get tester => app.tester;

  // ---------------------------------------------------------------- finders

  Finder key(String k) => find.byKey(Key(k));

  Finder get serversConnect => key('picker-servers-connect');
  Finder get noServersConnect => key('picker-no-servers-connect');
  Finder get noServersSetUp => key('picker-no-servers-setup');
  Finder get openLocal => key('vault-picker-open');
  Finder get createLocal => key('vault-picker-create');
  Finder get openOnServer => key('vault-picker-open-on-server');
  Finder get createOnServer => key('vault-picker-create-on-server');
  Finder serverRow(String id) => key('server-row-$id');
  Finder serverEdit(String id) => key('server-row-edit-$id');
  Finder serverRemove(String id) => key('server-row-remove-$id');
  Finder get removeConfirm => key('remove-server-confirm');
  Finder get removeCancel => key('remove-server-cancel');
  Finder recentRow(int i) => key('recent-row-$i');
  Finder recentRetry(int i) => key('recent-row-retry-$i');
  Finder recentUpdateToken(int i) => key('recent-row-update-token-$i');
  Finder recentRemoveFromRecents(int i) =>
      key('recent-row-remove-from-recents-$i');
  Finder recentRemove(int i) => key('recent-row-remove-$i');

  Finder get modal => key('vault-picker-modal');
  Finder get modalClose => key('vault-picker-modal-close');
  Finder recentOpenTag(int i) => key('recent-row-open-tag-$i');
  Finder recentFinder(int i) => key('recent-row-finder-$i');
  Finder recentDelete(int i) => key('recent-row-delete-$i');

  /// [matching] inside the vault picker modal.
  Finder inModal(Finder matching) =>
      find.descendant(of: modal, matching: matching);

  /// The RECENT row [i] inside the vault picker modal.
  Finder modalRecentRow(int i) => inModal(recentRow(i));

  Finder get connectDialog => key('connect-server-dialog');
  Finder get connectName => key('connect-name');
  Finder get connectUrl => key('connect-url');
  Finder get connectToken => key('connect-token');
  Finder get connectSubmit => key('connect-submit');
  Finder get connectCancel => key('connect-cancel');
  Finder get connectSetUpLink => key('connect-setup-link');
  Finder get connectError => key('connect-error');

  Finder get openDialog => key('open-on-server-dialog');
  Finder openVaultRow(String name) => key('open-on-server-vault-$name');
  Finder get openButton => key('open-on-server-open');
  Finder get openEmptyCreate => key('open-on-server-empty-create');
  Finder get openCreateLink => key('open-on-server-create-link');
  Finder get serverMenu => key('open-on-server-server-menu');
  Finder get serverSelectConnect => key('server-select-connect');
  Finder get serverDialogError => key('server-dialog-error');
  Finder get serverDialogUpdateToken => key('server-dialog-update-token');
  Finder get createDialog => key('create-on-server-dialog');
  Finder get createName => key('create-on-server-name');
  Finder get createSubmit => key('create-on-server-submit');
  Finder get createError => key('create-on-server-error');

  Finder get setUpSheet => key('setup-sheet');
  Finder get setUpConnect => key('setup-connect');
  Finder get setUpClose => key('setup-close');

  Finder get networkRefusal => key('network-drive-refusal');
  Finder get networkRefusalSetUp => key('network-drive-refusal-setup');
  Finder get networkRefusalConnect => key('network-drive-refusal-connect');
  Finder get tooOldRefusal => key('memex-too-old-refusal');
  Finder get tooOldLocate => key('memex-too-old-locate');

  Finder get restoreFromBackup => find.byKey(vaultPickerRestoreKey);
  Finder get restoreDialog => find.byKey(restoreDialogKey);
  Finder get restoreName => find.byKey(restoreNameKey);
  Finder get restoreFolder => find.byKey(restoreFolderKey);
  Finder get restoreSubmit => find.byKey(restoreSubmitKey);
  Finder get restoreError => find.byKey(restoreErrorKey);
  Finder get restoreCancel => key('restore-cancel');
  Finder get restoreFile => key('restore-file');
  Finder get restoreMeta => key('restore-meta');
  Finder get restoreTarget => key('restore-target');

  /// [matching] inside the widget keyed [k].
  Finder inside(String k, Finder matching) =>
      find.descendant(of: key(k), matching: matching);

  /// [matching] inside [of].
  Finder within(Finder of, Finder matching) =>
      find.descendant(of: of, matching: matching);

  // ------------------------------------------------------------------ state

  /// The text in the field keyed [field] (an EditableText under it).
  String fieldText(Finder field) => tester
      .widget<EditableText>(
        find.descendant(of: field, matching: find.byType(EditableText)),
      )
      .controller
      .text;

  /// The connect dialog shows as the edit-server dialog for [serverName]
  /// at [url] (A5 state 6).
  void expectEditServerDialog(String serverName, String url) {
    expect(connectDialog, findsOneWidget);
    expect(
      within(connectDialog, find.text('EDIT ${serverName.toUpperCase()}')),
      findsOneWidget,
    );
    expect(fieldText(connectUrl), url);
  }

  /// The connect dialog shows in its connect form (A4).
  void expectConnectDialog() {
    expect(connectDialog, findsOneWidget);
    expect(
      within(connectDialog, find.text('CONNECT TO A VAULT SERVER')),
      findsOneWidget,
    );
  }

  /// The state of the single StatusDot inside the widget keyed [k].
  StatusDotState dotIn(String k) =>
      tester.widget<StatusDot>(inside(k, find.byType(StatusDot))).state;

  /// The text [text] shows inside [of].
  bool shows(Finder of, String text) =>
      within(of, find.text(text)).evaluate().isNotEmpty;

  /// The OmButton at or under the widget keyed [k].
  OmButton button(String k) {
    final self = key(k);
    final w = tester.widget(self);
    if (w is OmButton) return w;
    return tester.widget<OmButton>(inside(k, find.byType(OmButton)).first);
  }

  /// Every text under [of] (itself included): each RichText's plain text
  /// and each EditableText's value, joined by a space.
  String textIn(Finder of) => [
    for (final e
        in find
            .descendant(
              of: of,
              matching: find.byType(RichText),
              matchRoot: true,
            )
            .evaluate())
      (e.widget as RichText).text.toPlainText(),
    for (final e
        in find
            .descendant(
              of: of,
              matching: find.byType(EditableText),
              matchRoot: true,
            )
            .evaluate())
      (e.widget as EditableText).controller.text,
  ].join(' ');

  // ---------------------------------------------------------------- actions

  Future<void> tap(Finder f) async {
    await tester.ensureVisible(f);
    await tester.tap(f);
    await app.settle();
  }

  Future<void> enter(Finder field, String text) async {
    await tester.enterText(
      find.descendant(of: field, matching: find.byType(EditableText)),
      text,
    );
    await tester.pump();
  }

  /// Fills the connect form and submits it; the probe's answer lands.
  Future<void> connectWith({
    String? name,
    required String url,
    required String token,
  }) async {
    if (name != null) await enter(connectName, name);
    await enter(connectUrl, url);
    await enter(connectToken, token);
    await tap(connectSubmit);
  }

  /// Opens the server menu of an open/create dialog and picks "connect to
  /// a vault server…".
  Future<void> pickConnectInServerMenu() async {
    await tap(serverMenu);
    await tap(serverSelectConnect);
  }

  /// "restore from backup…" in the picker; the native file picker answers
  /// whatever the test queued (nothing: cancelled).
  Future<void> openRestore() => _tapOne(restoreFromBackup);

  /// The Restore dialog's "choose…": the native folder picker answers
  /// whatever the test queued.
  Future<void> chooseRestoreFolder() => _tapOne(restoreFolder);

  /// Types [name] into the Restore dialog's vault-name field.
  Future<void> enterRestoreName(String name) => enter(restoreName, name);

  /// Presses the Restore dialog's "restore".
  Future<void> submitRestore() => _tapOne(restoreSubmit);

  // ------------------------------------------------------- picker modal

  /// Whether the vault picker modal shows.
  bool get modalShows => modal.evaluate().isNotEmpty;

  /// The vault picker modal shows, with the open vault [openName] first
  /// in RECENT under the OPEN tag (when given).
  void expectModalOpen({String? openName}) {
    expect(modal, findsOneWidget, reason: 'the vault picker modal shows');
    if (openName == null) return;
    expect(inModal(recentOpenTag(0)), findsOneWidget);
    expect(
      within(modalRecentRow(0), find.text(openName)),
      findsOneWidget,
      reason: 'the open vault is the first RECENT row',
    );
  }

  /// The vault picker modal is gone.
  void expectModalClosed() =>
      expect(modal, findsNothing, reason: 'the vault picker modal closed');

  /// The modal's x.
  Future<void> closeModal() => _tapOne(modalClose);

  /// Esc while the modal shows.
  Future<void> escapeModal() async {
    expect(modal, findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await app.settle();
  }

  /// A click on the scrim, halfway between the window's left edge and the
  /// dialog's.
  Future<void> tapScrim() async {
    final dialog = tester.getRect(modal);
    await tester.tapAt(Offset(dialog.left / 2, dialog.center.dy));
    await app.settle();
  }

  /// Clicks the RECENT row [i] in the modal (the open row closes it; any
  /// other row asks the leave guard, then opens that vault).
  Future<void> openRecentInModal(int i) => _tapOne(modalRecentRow(i));

  /// The delete button of the RECENT row [i] in the modal: the delete
  /// vault dialog opens.
  Future<void> deleteRecentInModal(int i) => _tapOne(inModal(recentDelete(i)));

  /// [tap] after checking [f] is on screen, so a missing control fails by
  /// name.
  Future<void> _tapOne(Finder f) async {
    expect(f, findsOneWidget);
    await tap(f);
  }
}
