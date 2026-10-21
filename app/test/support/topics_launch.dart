// WI #87 (W3): launches the whole workspace on a Topics vault with recording
// domain doubles served through `vaultAccessProvider`.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/vault_state.dart';

import '../robots/smart_folder_robot.dart';
import 'app_harness.dart';
import 'fake_memex_cli.dart';
import 'fake_vault_db.dart';
import 'folder_cli_fakes.dart';
import 'topics_access_doubles.dart';
import 'topics_seed.dart';

/// Launches the app on [db] (default: the Topics fixture) with [doubles] as
/// the vault access, the folder / settings server fake installed on [cli],
/// and the sidebar in Topics mode. With [memexConfigured] false no CLI is
/// configured. [robot] reuses a robot (e.g. one that already mocked the
/// clipboard). [overrides] go after the harness seams.
Future<SmartFolderRobot> launchTopics(
  WidgetTester tester,
  AccessDoubles doubles, {
  FakeVaultDb? db,
  FakeMemexCli? cli,
  bool memexConfigured = true,
  bool topicsMode = true,
  SmartFolderRobot? robot,
  List<Override> overrides = const [],
}) async {
  final r = robot ?? SmartFolderRobot(tester);
  final database = db ?? (FakeVaultDb.v5()..seedTopicsFixture());
  final fakeCli = cli ?? FakeMemexCli();
  r.server = FolderCliFake(database)..install(fakeCli);
  r.h = await pumpWorkspace(
    tester,
    db: database,
    cli: fakeCli,
    memexConfigured: memexConfigured,
    surfaceSize: const Size(1600, 1400),
    overrides: [doubles.override, ...overrides],
  );
  r.topics.h = r.h;
  if (topicsMode) await r.topics.chooseTopics();
  return r;
}

/// Counts `vaultRevisionProvider` bumps from [watchRevisions] on.
class RevisionCounter {
  RevisionCounter(WorkspaceHarness h) {
    _last = h.read(vaultRevisionProvider);
    _sub = h.container.listen<int>(vaultRevisionProvider, (_, next) {
      bumps += next - _last;
      _last = next;
    });
    addTearDown(_sub.close);
  }

  late int _last;
  late final ProviderSubscription<int> _sub;
  int bumps = 0;
}
