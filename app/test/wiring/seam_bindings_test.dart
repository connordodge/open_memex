// WI #105 (F1): the seams the UI WIs left unbound are bound to the real
// state. Each seam is read with no override:
// - #101 `hostedServerNameProvider` (state/hosted_identity.dart) gives the
//   saved server's name (#91 SavedServer.name), the id for an id with no
//   saved server;
// - #103 `hasUnsentHostedTextProvider` / `unsentHostedTextProvider`
//   (state/unsent_hosted_text.dart) follow #102's `pendingSavesProvider`:
//   PendingSave{title, since} -> UnsentHostedNote{title, since}, with the
//   open hosted vault's server name and vault name;
// - #101 `hostedClientForServerProvider` gives a client that reaches that
//   saved server ("retry now" sends one request through it);
// - #101 `hostedVaultGoneProvider` is set when a request to the open vault
//   gets C1 `vault_not_found`.
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/hosted_identity.dart';
import 'package:open_memex_app/src/state/pending_saves.dart';
import 'package:open_memex_app/src/state/settings.dart';
import 'package:open_memex_app/src/state/unsent_hosted_text.dart';
import 'package:open_memex_app/src/state/vault_state.dart';

import '../robots/hosted_workspace_robot.dart';
import '../support/fake_vault_server.dart';
import '../support/hosted_harness.dart';
import '../support/journey_harness.dart';
import '../support/vault_picker_harness.dart' show wi97HoldFontFetches;

/// Queues a save of [noteId] ([title]) in [vault] that couldn't reach the
/// server at [since], as #102's editor does.
void _queue(
  HostedHarness h,
  HostedVaultRef vault,
  String noteId,
  String title,
  DateTime since,
) => h
    .read(pendingSaveQueueProvider.notifier)
    .put(
      vault: vault,
      noteId: noteId,
      title: title,
      text: 'typed while $title was unreachable',
      baseVersion: 1,
      now: since,
      serverName: 'nas',
    );

void main() {
  wi97HoldFontFetches();

  group('hostedServerNameProvider is bound to the saved servers', () {
    test(
      'hostedServerNameProvider gives the saved server name for its id',
      () async {
        final studio = journeyStudio();
        final h = await hostedContainer(
          servers: [HostedServerFixture(), studio],
        );

        expect(h.read(hostedServerNameProvider(fakeServerId)), 'nas');
        expect(h.read(hostedServerNameProvider(studio.id)), 'studio');
      },
    );

    test(
      'hostedServerNameProvider follows a rename of the saved server',
      () async {
        final h = await hostedContainer();
        expect(h.read(hostedServerNameProvider(fakeServerId)), 'nas');

        await h
            .read(settingsProvider.notifier)
            .updateServer(fakeServerId, name: 'attic');

        expect(h.read(hostedServerNameProvider(fakeServerId)), 'attic');
      },
    );

    test(
      'hostedServerNameProvider gives the id for an id with no saved server',
      () async {
        final h = await hostedContainer();

        expect(h.read(hostedServerNameProvider('srv-gone')), 'srv-gone');
      },
    );
  });

  group('the unsent text seams are bound to the pending save queue', () {
    test(
      'with nothing queued there is no unsent hosted text on an open hosted vault',
      () async {
        final h = await hostedContainer();
        await h.controller.openVault(seedHostedRef);
        expect(h.read(currentVaultProvider), seedHostedRef);

        expect(h.read(pendingSavesProvider), isEmpty);
        expect(h.read(hasUnsentHostedTextProvider), isFalse);
        expect(h.read(unsentHostedTextProvider).notes, isEmpty);
      },
    );

    test(
      'a queued save makes hasUnsentHostedTextProvider true and lists the note with its since time',
      () async {
        final h = await hostedContainer();
        await h.controller.openVault(seedHostedRef);
        final first = DateTime(2026, 10, 19, 14, 32);
        final second = DateTime(2026, 10, 19, 14, 40);

        _queue(h, seedHostedRef, seedLooseThoughtId, 'Loose Thought', first);
        _queue(
          h,
          seedHostedRef,
          seedBrokenFrontmatterId,
          'Broken Frontmatter',
          second,
        );

        expect(h.read(hasUnsentHostedTextProvider), isTrue);
        final text = h.read(unsentHostedTextProvider);
        expect(text.serverName, 'nas');
        expect(text.vaultName, 'seed');
        expect(
          [for (final n in text.notes) (n.title, n.since)],
          [('Loose Thought', first), ('Broken Frontmatter', second)],
        );
      },
    );

    test(
      'the unsent text follows the queue when a queued save lands',
      () async {
        final h = await hostedContainer();
        await h.controller.openVault(seedHostedRef);
        _queue(
          h,
          seedHostedRef,
          seedLooseThoughtId,
          'Loose Thought',
          DateTime(2026, 10, 19, 14, 32),
        );
        expect(h.read(hasUnsentHostedTextProvider), isTrue);

        h
            .read(pendingSaveQueueProvider.notifier)
            .remove(seedHostedRef, seedLooseThoughtId);

        expect(h.read(hasUnsentHostedTextProvider), isFalse);
        expect(h.read(unsentHostedTextProvider).notes, isEmpty);
      },
    );

    test(
      'a queued save of another hosted vault is not unsent text of the open vault',
      () async {
        final h = await hostedContainer();
        await h.controller.openVault(seedHostedRef);
        _queue(
          h,
          const HostedVaultRef(fakeServerId, 'work'),
          seedLooseThoughtId,
          'Loose Thought',
          DateTime(2026, 10, 19, 14, 32),
        );

        expect(h.read(hasUnsentHostedTextProvider), isFalse);
        expect(h.read(unsentHostedTextProvider).notes, isEmpty);
      },
    );
  });

  group('hostedClientForServerProvider is bound', () {
    test(
      'the open vault server client reaches that server with its saved token',
      () async {
        final h = await hostedContainer();
        await h.controller.openVault(seedHostedRef);
        final before = h.first.server.requests.length;

        final client = h.read(hostedClientForServerProvider(fakeServerId));
        expect(client, isNotNull);
        await client!.probeServer();

        final sent = h.first.server.requests.skip(before).toList();
        expect(sent, hasLength(1));
        expect(sent.single.url.path, '/api/v1/info');
        expect(sent.single.headers['authorization'], 'Bearer $fakeServerToken');
      },
    );

    test(
      'hostedClientForServerProvider gives no client for an id with no saved server',
      () async {
        final h = await hostedContainer();
        await h.controller.openVault(seedHostedRef);

        expect(h.read(hostedClientForServerProvider('srv-gone')), isNull);
      },
    );
  });

  group('hostedVaultGoneProvider is set on vault_not_found', () {
    testWidgets(
      'a revision poll that gets vault_not_found sets the vault gone flag for the open vault',
      (tester) async {
        final app = await pumpJourneyApp(
          tester,
          servers: [HostedServerFixture()],
          recents: [seedHostedRef],
          lastVault: seedHostedRef,
        );
        expect(app.read(currentVaultProvider), seedHostedRef);
        expect(app.read(hostedVaultGoneProvider(seedHostedRef)), isFalse);

        app.first.server.removeVault('seed');
        await app.pollTick();

        expect(app.read(hostedVaultGoneProvider(seedHostedRef)), isTrue);
        expect(
          app.read(
            hostedVaultGoneProvider(const HostedVaultRef(fakeServerId, 'work')),
          ),
          isFalse,
        );
      },
    );
  });
}
