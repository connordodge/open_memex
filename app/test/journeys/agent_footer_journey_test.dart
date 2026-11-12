// WI #456 (390-A5) journey: the sidebar's live agents footer over a real
// local vault.
//
// The vault is a temp folder with a real presence file in
// `.memex/agents/<ulid>.json` (snake_case keys, Spec req 3) and
// `agent_activity` rows in the schema the regenerated `vault_schema_v5.sql`
// fixture gives (FakeVaultDb). The real app reads both through
// LocalAgentsAccess (A2) and the presence tick (A4); only the clock is
// faked, so advancing it past `expires_at` is what ends the connection. The
// presence file is never touched after it is written.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:path/path.dart' as p;

import '../support/fake_clock.dart';
import '../support/fake_vault_db.dart';
import '../support/font_fetch_hold.dart';
import '../support/journey_harness.dart';
import '../support/vault_folders.dart';

const _session = '01JAGENTJOURNEY0000000000A';

/// Writes the presence file of one agent into [vault], times relative to
/// [nowMs].
void _writePresence(Directory vault, int nowMs) {
  final dir = Directory(p.join(vault.path, '.memex', 'agents'))
    ..createSync(recursive: true);
  File(p.join(dir.path, '$_session.json')).writeAsStringSync(
    jsonEncode({
      'session_id': _session,
      'client_name': 'claude-code',
      'client_version': '1.0.0',
      'transport': 'stdio',
      'started_at': nowMs - 60000,
      'last_seen_at': nowMs - 1000,
      'last_request_at': nowMs - 1000,
      'last_tool_at': nowMs - 2000,
      'expires_at': nowMs + 15000,
      'embeddings': false,
    }),
  );
}

/// Inserts one `agent_activity` row.
void _writeActivity(
  FakeVaultDb db, {
  required String id,
  required String summary,
  required int createdAt,
}) {
  db.db.execute(
    'INSERT INTO agent_activity (id, session_id, client_name, tool, summary, '
    'note_id, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)',
    [id, _session, 'claude-code', 'add_excerpt', summary, null, createdAt],
  );
}

Finder _key(String k) => find.byKey(Key(k));

Finder _textIn(String k, String text) =>
    find.descendant(of: _key(k), matching: find.text(text), matchRoot: true);

String _plain(WidgetTester tester, String k) => tester
    .widgetList<Text>(
      find.descendant(
        of: _key(k),
        matching: find.byType(Text),
        matchRoot: true,
      ),
    )
    .map((w) => w.data ?? w.textSpan?.toPlainText() ?? '')
    .join(' ');

void main() {
  holdFontFetches();

  testWidgets(
    'a real presence file and activity rows show the agent and the feed and advancing the clock past expires_at shows no agents connected with last agent write',
    (tester) async {
      final vault = createVaultFolder('om456_vault_');
      final clock = FakeClock(DateTime(2026, 10, 19, 9));
      final nowMs = clock.now().millisecondsSinceEpoch;
      _writePresence(vault, nowMs);
      final db = FakeVaultDb.v5();
      _writeActivity(
        db,
        id: '01JAGENTACTIVITY00000000A1',
        summary: 'filed 4 blocks → Rest & Recharge',
        createdAt: nowMs - 180000,
      );
      _writeActivity(
        db,
        id: '01JAGENTACTIVITY00000000A2',
        summary: 'added a link between two notes',
        createdAt: nowMs - 3600000,
      );

      final app = await pumpJourneyApp(
        tester,
        db: db,
        clock: clock,
        recents: [LocalVaultRef(vault.path)],
        lastVault: LocalVaultRef(vault.path),
      );
      expect(app.read(currentVaultProvider), LocalVaultRef(vault.path));

      // Connected: the agent row, working, and the feed, unprefixed (one
      // agent connected and it wrote every shown entry).
      expect(_key('agent-footer'), findsOneWidget);
      expect(_key('agent-footer-agent-0'), findsOneWidget);
      expect(_textIn('agent-footer-agent-0', 'claude-code'), findsOneWidget);
      expect(_textIn('agent-footer-agent-0', 'working'), findsOneWidget);
      expect(_key('agent-footer-empty'), findsNothing);
      expect(_key('agent-footer-activity-0'), findsOneWidget);
      expect(_key('agent-footer-activity-1'), findsOneWidget);
      final first = _plain(tester, 'agent-footer-activity-0');
      expect(first, contains('filed 4 blocks → Rest & Recharge'));
      expect(first, contains('3m'));
      expect(first, isNot(contains('claude-code')), reason: 'unprefixed');
      final second = _plain(tester, 'agent-footer-activity-1');
      expect(second, contains('added a link between two notes'));
      expect(second, contains('1h'));

      // 11 s on: the tool call is 13 s old, so the agent is idle, still
      // connected.
      await app.advance(const Duration(seconds: 11));
      expect(_textIn('agent-footer-agent-0', 'working'), findsNothing);
      expect(_textIn('agent-footer-agent-0', 'idle · now'), findsOneWidget);
      expect(_key('agent-footer-empty'), findsNothing);

      // Past expires_at (15 s): disconnected, with the last write.
      await app.advance(const Duration(seconds: 9));
      expect(_key('agent-footer-agent-0'), findsNothing);
      expect(_key('agent-footer-activity-0'), findsNothing);
      expect(
        _textIn('agent-footer-empty', 'no agents connected'),
        findsOneWidget,
      );
      expect(
        _textIn('agent-footer-last-write', 'last agent write 3m ago'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'a vault with no presence file and no activity shows no agents connected and the hint without a last agent write',
    (tester) async {
      final vault = createVaultFolder('om456_empty_');
      final clock = FakeClock(DateTime(2026, 10, 19, 9));
      final app = await pumpJourneyApp(
        tester,
        db: FakeVaultDb.v5(),
        clock: clock,
        recents: [LocalVaultRef(vault.path)],
        lastVault: LocalVaultRef(vault.path),
      );
      expect(app.read(currentVaultProvider), LocalVaultRef(vault.path));

      expect(
        _textIn('agent-footer-empty', 'no agents connected'),
        findsOneWidget,
      );
      expect(
        find.textContaining('wire memex serve into Claude Desktop'),
        findsOneWidget,
      );
      expect(_key('agent-footer-last-write'), findsNothing);
      expect(_key('agent-footer-agent-0'), findsNothing);
      expect(
        Directory(p.join(vault.path, '.memex', 'agents')).existsSync(),
        isFalse,
        reason: 'the app never creates the presence directory',
      );
    },
  );
}
