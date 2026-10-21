// WI #90 (W6): agentChangesAsyncProvider reads through VaultAccess.graph
// (D11, D14a); a reader of it (`readScoped`) never shows another vault's
// entries.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/db/activity_reads.dart';
import 'package:open_memex_app/src/state/activity_state.dart';
import 'package:open_memex_app/src/state/vault_access_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/vault_access/local/local_vault_access.dart';
import 'package:open_memex_app/src/vault_access/vault_scoped.dart';

import '../support/activity_seeds.dart';
import '../support/daily_seed.dart';
import '../support/fake_vault_db.dart';
import '../support/links_seeds.dart';
import '../support/vault_scoped_reads.dart';

const _vaultA = LocalVaultRef('/tmp/om-90-vault-a');
const _vaultB = LocalVaultRef('/tmp/om-90-vault-b');

AgentChangeRow _change(String id, {String note = 'n1', int at = 1000}) =>
    AgentChangeRow(
      id: id,
      noteId: note,
      day: '2026-09-05',
      createdAt: at,
      bullets: ['bullet $id'],
    );

List<String> _ids(List<AgentChangeRow> rows) => [for (final r in rows) r.id];

ProviderContainer _switching(Map<VaultRef, LocalGraphAccess> graph) {
  final c = ProviderContainer(
    overrides: [
      currentVaultProvider.overrideWith((_) => _vaultA),
      vaultDbProvider.overrideWithValue(null),
      memexCliProvider.overrideWithValue(null),
      vaultAccessProvider.overrideWith((ref) {
        final vault = ref.watch(currentVaultProvider);
        final path = vault.localPath;
        if (path == null) return null;
        return LocalVaultAccess(vaultPath: path, graph: graph[vault]);
      }),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

void main() {
  group('agentChangesAsyncProvider', () {
    test(
      'agentChangesAsyncProvider is stamped with the current vault and matches the seeded rows',
      () async {
        final db = FakeVaultDb.v5();
        addTearDown(db.close);
        db.seedDailyNote('2026-09-05', id: 'n1');
        db.seedAgentChange(
          'ac-1',
          'n1',
          day: '2026-09-05',
          createdAt: 1000,
          bullets: ['one'],
        );
        final c = ProviderContainer(
          overrides: [
            currentVaultProvider.overrideWith((_) => _vaultA),
            vaultDbProvider.overrideWithValue(db),
            memexCliProvider.overrideWithValue(null),
          ],
        );
        addTearDown(c.dispose);

        final scoped = await c.read(agentChangesAsyncProvider('n1').future);

        expect(scoped.vault, _vaultA);
        expect(_ids(scoped.value), ['ac-1']);
        expect(scoped.value.single.bullets, ['one']);
      },
    );

    test(
      'agentChangesAsyncProvider yields an empty list stamped with no vault when none is open',
      () async {
        final c = ProviderContainer(
          overrides: [
            currentVaultProvider.overrideWith((_) => null),
            vaultDbProvider.overrideWithValue(null),
            memexCliProvider.overrideWithValue(null),
          ],
        );
        addTearDown(c.dispose);

        final scoped = await c.read(agentChangesAsyncProvider('n1').future);

        expect(scoped.value, isEmpty);
        expect(scoped.vault, isNull);
        expect(
          readScoped(
            c,
            agentChangesAsyncProvider('n1'),
            const <AgentChangeRow>[],
          ),
          isEmpty,
        );
      },
    );
  });

  group('the agent changes read', () {
    test(
      'the agent changes read is empty before the first load completes and equals the rows after',
      () async {
        final c = _switching({
          _vaultA: Wi90GatedGraph(
            vaultPath: _vaultA.path,
            gate: Wi90Gate(),
            changes: [_change('new', at: 2000), _change('old')],
          ),
        });

        expect(
          readScoped(
            c,
            agentChangesAsyncProvider('n1'),
            const <AgentChangeRow>[],
          ),
          isEmpty,
        );

        await c.read(agentChangesAsyncProvider('n1').future);

        expect(
          _ids(
            readScoped(
              c,
              agentChangesAsyncProvider('n1'),
              const <AgentChangeRow>[],
            ),
          ),
          ['new', 'old'],
        );
      },
    );

    test(
      'the agent changes read keeps its previous entries while a reload is pending',
      () async {
        final gate = Wi90Gate();
        final graph = Wi90GatedGraph(
          vaultPath: _vaultA.path,
          gate: gate,
          changes: [_change('first')],
        );
        final c = _switching({_vaultA: graph});
        await c.read(agentChangesAsyncProvider('n1').future);
        expect(
          _ids(
            readScoped(
              c,
              agentChangesAsyncProvider('n1'),
              const <AgentChangeRow>[],
            ),
          ),
          ['first'],
        );

        gate.close();
        graph.changes = [_change('second')];
        c.read(vaultRevisionProvider.notifier).state++;
        await pumpEventQueue();

        expect(c.read(agentChangesAsyncProvider('n1')).isLoading, isTrue);
        expect(
          _ids(
            readScoped(
              c,
              agentChangesAsyncProvider('n1'),
              const <AgentChangeRow>[],
            ),
          ),
          ['first'],
        );

        gate.open();
        await c.read(agentChangesAsyncProvider('n1').future);
        expect(
          _ids(
            readScoped(
              c,
              agentChangesAsyncProvider('n1'),
              const <AgentChangeRow>[],
            ),
          ),
          ['second'],
        );
      },
    );

    test(
      'the agent changes read switching vaults never shows the previous vault rows',
      () async {
        final gateB = Wi90Gate(open: false);
        final c = _switching({
          _vaultA: Wi90GatedGraph(
            vaultPath: _vaultA.path,
            gate: Wi90Gate(),
            changes: [_change('from-a')],
          ),
          _vaultB: Wi90GatedGraph(
            vaultPath: _vaultB.path,
            gate: gateB,
            changes: [_change('from-b')],
          ),
        });
        await c.read(agentChangesAsyncProvider('n1').future);
        expect(
          _ids(
            readScoped(
              c,
              agentChangesAsyncProvider('n1'),
              const <AgentChangeRow>[],
            ),
          ),
          ['from-a'],
        );

        c.read(currentVaultProvider.notifier).state = _vaultB;
        await pumpEventQueue();

        expect(
          readScoped(
            c,
            agentChangesAsyncProvider('n1'),
            const <AgentChangeRow>[],
          ),
          isEmpty,
        );
        expect(
          currentVaultData(c.read(agentChangesAsyncProvider('n1')), _vaultB),
          isNull,
        );

        gateB.open();
        final scoped = await c.read(agentChangesAsyncProvider('n1').future);
        expect(scoped.vault, _vaultB);
        expect(
          _ids(
            readScoped(
              c,
              agentChangesAsyncProvider('n1'),
              const <AgentChangeRow>[],
            ),
          ),
          ['from-b'],
        );
      },
    );
  });
}
