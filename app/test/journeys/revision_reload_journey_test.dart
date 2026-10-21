// WI #105 (F1) AC "sidebar lists reload without a flash" (D14a, Req 23 to
// 26, 33): a change made elsewhere reloads the sidebar lists (days,
// canvases, Smart Folders, unsorted) within one 2 s revision poll tick, the
// previous list stays on screen while the reload is in flight, and the
// loading state never shows. On a hosted vault the change is a fake server
// revision bump; on a local vault it is the revision-reader seam.
// (The notes rail is not mounted in the sidebar today: Days and Topics are
// its modes, so its list has no on-screen reader to check here.)
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/vault_access/vault_async_view.dart';
import 'package:path/path.dart' as p;

import '../robots/hosted_workspace_robot.dart';
import '../support/api_fixtures.dart';
import '../support/canvas_seeds.dart';
import '../support/daily_seed.dart';
import '../support/fake_vault_db.dart';
import '../support/hosted_harness.dart';
import '../support/journey_harness.dart';
import '../support/poll_fakes.dart';
import '../support/vault_folders.dart';
import '../support/vault_picker_harness.dart' show wi97HoldFontFetches;

const _newCanvasId = '01M5DQAYZJET989N2YR8341XAB';
const _newDailyId = '01M5DQAYZ592W2515HPSDF5Q14';
const _newFolderId = '01M5DQAYZHJTTW6PPF4P7GNCHZ';
const _newTopicId = '01M5DQAYZ4RYSGA8T0YEEF8QRZ';

final _loading = find.byKey(vaultAsyncLoadingKey);
Finder _key(String k) => find.byKey(Key(k));

Map<String, Object?> _fixture(String domain, String file) =>
    jsonDecode(File(p.join(apiV1FixturesDir, domain, file)).readAsStringSync())
        as Map<String, Object?>;

/// The fixture list [key] of [domain]/[file] with [extra] appended.
Map<String, Object?> _plus(
  String domain,
  String file,
  String key,
  Map<String, Object?> extra,
) {
  final json = _fixture(domain, file);
  return {
    ...json,
    key: [...(json[key]! as List), extra],
  };
}

/// Holds the fake server once the vault revision moves, so the reloads the
/// bump starts stay in flight.
void _holdOnBump(JourneyApp app) {
  var held = false;
  app.container.listen<int>(vaultRevisionProvider, (_, _) {
    if (held) return;
    held = true;
    app.first.server.hold();
  });
}

/// The seed vault of nas open at launch.
Future<HostedWorkspaceRobot> _hosted(WidgetTester tester) async {
  final app = await pumpJourneyApp(
    tester,
    servers: [HostedServerFixture()],
    recents: [seedHostedRef],
    lastVault: seedHostedRef,
  );
  final w = HostedWorkspaceRobot(app);
  expect(w.currentVault, seedHostedRef);
  return w;
}

void main() {
  wi97HoldFontFetches();

  group('hosted vault (fake server revision bump)', () {
    testWidgets(
      'a revision bump on the server reloads the days and canvases lists within one poll tick and the previous rows stay with no loading state',
      (tester) async {
        final w = await _hosted(tester);
        final server = w.app.first.server;
        expect(_key('days-row-2026-10-18'), findsOneWidget);
        expect(_key('canvas-row-$seedCanvasId'), findsOneWidget);

        server
          ..route(
            'GET',
            '/vaults/seed/api/v1/daily-notes',
            json: _plus('daily', 'daily_notes.json', 'daily_notes', {
              'date': '2026-10-14',
              'note_id': _newDailyId,
              'preview': 'Written on another mac.',
              'review_state': 'Unreviewed',
            }),
          )
          ..route(
            'GET',
            '/vaults/seed/api/v1/canvases',
            json: _plus('canvas', 'list_canvases.json', 'canvases', {
              'canvas_id': _newCanvasId,
              'created_at': 1760001000000,
              'node_count': 0,
              'title': 'Second Map',
              'updated_at': 1760001000000,
              'version': 1,
            }),
          )
          ..route(
            'GET',
            '/vaults/seed/api/v1/revision',
            json: {'revision': 'elsewhere-1'},
          );
        _holdOnBump(w.app);

        await w.app.pollTick();

        // The reload is in flight: the previous rows stay, no spinner.
        expect(_key('days-row-2026-10-18'), findsOneWidget);
        expect(_key('canvas-row-$seedCanvasId'), findsOneWidget);
        expect(_key('days-row-2026-10-14'), findsNothing);
        expect(_loading, findsNothing);

        server.release();
        await w.app.settle();

        expect(_key('days-row-2026-10-14'), findsOneWidget);
        expect(_key('canvas-row-$_newCanvasId'), findsOneWidget);
        expect(_key('days-row-2026-10-18'), findsOneWidget);
        expect(_loading, findsNothing);
      },
    );

    testWidgets(
      'a revision bump on the server reloads the Smart Folders and unsorted lists within one poll tick and the previous rows stay with no loading state',
      (tester) async {
        final w = await _hosted(tester);
        await w.showTopics();
        final server = w.app.first.server;
        expect(_key('topics-unsorted-$seedLooseThoughtId'), findsOneWidget);
        final rootFolder = _key('topics-folder-01M5DQAYZHJGKWXCJHR5FSDFA0');
        expect(rootFolder, findsOneWidget);

        server
          ..route(
            'GET',
            '/vaults/seed/api/v1/smart-folders',
            json: _plus('topics', 'smart_folders.json', 'folders', {
              'id': _newFolderId,
              'name': 'Archive',
              'parent_id': null,
              'pinned': false,
            }),
          )
          ..route(
            'GET',
            '/vaults/seed/api/v1/unsorted',
            json: _plus('topics', 'unsorted.json', 'notes', {
              'note_id': _newTopicId,
              'role': 'topic',
              'title': 'Fresh Topic',
            }),
          )
          ..route(
            'GET',
            '/vaults/seed/api/v1/revision',
            json: {'revision': 'elsewhere-2'},
          );
        _holdOnBump(w.app);

        await w.app.pollTick();

        expect(_key('topics-unsorted-$seedLooseThoughtId'), findsOneWidget);
        expect(rootFolder, findsOneWidget);
        expect(_key('topics-folder-$_newFolderId'), findsNothing);
        expect(_loading, findsNothing);

        server.release();
        await w.app.settle();

        expect(_key('topics-folder-$_newFolderId'), findsOneWidget);
        expect(_key('topics-unsorted-$_newTopicId'), findsOneWidget);
        expect(_key('topics-unsorted-$seedLooseThoughtId'), findsOneWidget);
        expect(_loading, findsNothing);
      },
    );
  });

  group('local vault (revision reader seam)', () {
    /// A local vault open at launch over [db], its revision read through
    /// [revision].
    Future<HostedWorkspaceRobot> local(
      WidgetTester tester,
      FakeVaultDb db,
      ScriptedRevisionReader revision,
    ) async {
      final vault = createVaultFolder('om105_reload_');
      final app = await pumpJourneyApp(
        tester,
        db: db,
        revisionReader: revision.read,
        recents: [LocalVaultRef(vault.path)],
        lastVault: LocalVaultRef(vault.path),
      );
      final w = HostedWorkspaceRobot(app);
      expect(w.currentVault, LocalVaultRef(vault.path));
      return w;
    }

    testWidgets(
      'a local revision change reloads the days and canvases lists within one poll tick with no loading state',
      (tester) async {
        final db = FakeVaultDb.v5()
          ..seedNote(id: 'day-18', title: '2026-10-18', role: 'daily')
          ..seedCanvas('canvas-a', 'First Map', updatedAt: 1760000900000);
        final revision = ScriptedRevisionReader();
        final w = await local(tester, db, revision);
        expect(_key('days-row-2026-10-18'), findsOneWidget);
        expect(_key('canvas-row-canvas-a'), findsOneWidget);

        db
          ..seedNote(id: 'day-14', title: '2026-10-14', role: 'daily')
          ..seedCanvas('canvas-b', 'Second Map', updatedAt: 1760001000000);
        revision.revision = 'rev-1';
        await w.app.pollTick();

        expect(_key('days-row-2026-10-14'), findsOneWidget);
        expect(_key('canvas-row-canvas-b'), findsOneWidget);
        expect(_key('days-row-2026-10-18'), findsOneWidget);
        expect(_key('canvas-row-canvas-a'), findsOneWidget);
        expect(_loading, findsNothing);
      },
    );

    testWidgets(
      'a local revision change reloads the Smart Folders and unsorted lists within one poll tick with no loading state',
      (tester) async {
        final db = FakeVaultDb.v5()
          ..seedSmartFolder('f-first', 'First')
          ..seedNote(id: 'topic-a', title: 'Alpha Topic', role: 'topic');
        final revision = ScriptedRevisionReader();
        final w = await local(tester, db, revision);
        await w.showTopics();
        expect(_key('topics-folder-f-first'), findsOneWidget);
        expect(_key('topics-unsorted-topic-a'), findsOneWidget);

        db
          ..seedSmartFolder('f-second', 'Second')
          ..seedNote(id: 'topic-b', title: 'Beta Topic', role: 'topic');
        revision.revision = 'rev-1';
        await w.app.pollTick();

        expect(_key('topics-folder-f-second'), findsOneWidget);
        expect(_key('topics-unsorted-topic-b'), findsOneWidget);
        expect(_key('topics-folder-f-first'), findsOneWidget);
        expect(_key('topics-unsorted-topic-a'), findsOneWidget);
        expect(_loading, findsNothing);
      },
    );
  });
}
