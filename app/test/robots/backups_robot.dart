import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/backup_models.dart';
import 'package:open_memex_app/src/widgets/backups/backup_keys.dart';

import '../support/journey_harness.dart';

/// Robot for the backups journeys (WI #326, Spec #315 robot journey 1).
/// Finds widgets by Key only:
/// - the sidebar row (#326): `backups-entry`, `backups-entry-warning`;
/// - the Backups sheet (#325, frozen Keys of A0): `backups-sheet`,
///   `backups-toggle`, `backups-destination-<provider>-<i>`,
///   `backups-destination-choose`, `backups-now`, `backups-retry`,
///   `backups-status`;
/// - the sheet's own Keys (pack 325): `backups-turn-on`, `backups-close`.
class BackupsRobot {
  BackupsRobot(this.app);

  final JourneyApp app;

  WidgetTester get tester => app.tester;

  // ---------------------------------------------------------------- finders

  Finder key(String k) => find.byKey(Key(k));

  Finder get entry => find.byKey(backupsEntryKey);
  Finder get warning => find.byKey(backupsEntryWarningKey);
  Finder get sheet => find.byKey(backupsSheetKey);
  Finder get toggle => find.byKey(backupsToggleKey);
  Finder get turnOn => key('backups-turn-on');
  Finder get close => key('backups-close');
  Finder get backUpNowButton => find.byKey(backupsNowKey);
  Finder get retry => find.byKey(backupsRetryKey);
  Finder get status => find.byKey(backupsStatusKey);
  Finder destination(BackupProvider provider, int index) =>
      find.byKey(backupDestinationKey(provider, index));

  // ------------------------------------------------------------------ reads

  /// All text under [f], one paragraph per line.
  String textIn(Finder f) => tester
      .widgetList<RichText>(
        find.descendant(of: f, matching: find.byType(RichText)),
      )
      .map((w) => w.text.toPlainText())
      .join('\n');

  /// The sidebar row's text.
  String get entryText {
    expect(entry, findsOneWidget, reason: 'the backups row shows');
    return textIn(entry);
  }

  /// The sheet's status column text.
  String get statusText {
    expect(status, findsOneWidget, reason: 'the sheet status shows');
    return textIn(status);
  }

  // ---------------------------------------------------------------- actions

  Future<void> tap(Finder f) async {
    expect(f, findsOneWidget, reason: '$f');
    await tester.ensureVisible(f);
    await tester.tap(f);
    await app.settle();
  }

  /// Presses the sidebar row: the sheet opens.
  Future<void> openSheet() async {
    await tap(entry);
    expect(sheet, findsOneWidget, reason: 'the row opens the sheet');
  }

  /// "turn on backups…", picks [option], then "turn on backups".
  Future<void> turnOnWith(Finder option) async {
    await tap(toggle);
    await tap(option);
    await tap(turnOn);
  }

  /// "back up now" in the sheet.
  Future<void> backUpNow() => tap(backUpNowButton);

  /// Closes the sheet with its close button.
  Future<void> closeSheet() async {
    await tap(close);
    expect(sheet, findsNothing, reason: 'the sheet closed');
  }
}
