// WI #452 (390-A1): `agents` on the VaultAccess composites (#390 req 14, 15;
// D22). Local: a `LocalAgentsAccess? agents` replacement argument defaulting
// to `LocalAgentsAccess(vaultPath:, db:)`. Hosted: a `HostedAgentsAccess`
// over the composite client for the composite's vault.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/hosted_connection_state.dart';
import 'package:open_memex_app/src/vault_access/hosted/agents.dart';
import 'package:open_memex_app/src/vault_access/hosted/hosted_vault_access.dart';
import 'package:open_memex_app/src/vault_access/local/local_vault_access.dart';
import 'package:open_memex_app/src/vault_access/vault_access.dart';

import '../support/agents_fakes.dart';
import '../support/fake_clock.dart';
import '../support/fake_vault_db.dart';
import '../support/fake_vault_server.dart';

const _vault = '/tmp/om-452-vault';

void main() {
  test(
    'LocalVaultAccess agents defaults to a LocalAgentsAccess and takes a replacement',
    () {
      final plain = LocalVaultAccess(vaultPath: _vault);
      expect(plain.agents, isA<LocalAgentsAccess>());
      expect(plain.agents.vaultPath, _vault);
      expect(plain.agents.db, isNull);

      final db = FakeVaultDb.v6();
      addTearDown(db.close);
      final withDb = LocalVaultAccess(vaultPath: _vault, db: db);
      expect(withDb.agents.db, same(db));
      expect(withDb.agents.vaultPath, _vault);

      final fake = FakeAgentsAccess(vaultPath: _vault);
      final replaced = LocalVaultAccess(
        vaultPath: _vault,
        db: db,
        agents: fake,
      );
      expect(replaced.agents, same(fake));

      // Through the interface, as providers read it.
      final VaultAccess asInterface = replaced;
      expect(asInterface.agents, same(fake));
    },
  );

  test(
    'LocalVaultAccess agents replacement leaves the other domains alone',
    () {
      final fake = FakeAgentsAccess(vaultPath: _vault);
      final access = LocalVaultAccess(vaultPath: _vault, agents: fake);
      expect(access.agents, same(fake));
      expect(access.notes, isA<LocalNotesAccess>());
      expect(access.tags, isA<LocalTagsAccess>());
      expect(access.notes.vaultPath, _vault);
    },
  );

  test(
    'HostedVaultAccess agents is a HostedAgentsAccess for its vault over the composite client',
    () async {
      final container = ProviderContainer(
        overrides: [
          clockProvider.overrideWithValue(FakeClock()),
          utcOffsetProvider.overrideWithValue(() => Duration.zero),
        ],
      );
      addTearDown(container.dispose);
      final server = FakeVaultServer();
      final access = HostedVaultAccess(
        client: server.connect(container),
        vaultName: 'seed',
      );

      expect(access.agents, isA<HostedAgentsAccess>());
      expect(access.agents.vaultName, 'seed');
      final VaultAccess asInterface = access;
      expect(asInterface.agents, same(access.agents));

      // The composite client: once the composite is disposed it refuses
      // without sending, like every other hosted domain.
      access.dispose();
      final sent = server.requests.length;
      await expectLater(
        access.agents.client.vaultRequest(
          'GET',
          'seed',
          '/agents',
          operation: 'agents',
        ),
        throwsStateError,
      );
      expect(server.requests, hasLength(sent));
    },
  );
}
