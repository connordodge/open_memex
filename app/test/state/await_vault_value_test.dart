// WI #105 (PR A fix round, verify mode): `awaitVaultValue` (note_state.dart)
// contracts the implementer listed as unpinned: it returns `empty` when the
// awaited data was loaded for another vault than the one open at the call,
// and when the read throws an Exception. Its fresh-read contract (a dirty,
// unlistened read reloads first) is pinned here and by
// create_topic_test.dart's after-midnight journey.
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/vault_access/vault_scoped.dart';

const _wi105VaultA = LocalVaultRef('/tmp/om-105-await-vault-a');
const _wi105VaultB = LocalVaultRef('/tmp/om-105-await-vault-b');

/// What the test read loads, and for which vault (set per test).
final _wi105LoadedFor = StateProvider<CurrentVault>((_) => _wi105VaultA);
final _wi105Value = StateProvider<int>((_) => 7);
final _wi105Fails = StateProvider<bool>((_) => false);

/// An async vault read whose vault and value the test controls.
final _wi105Read = FutureProvider<VaultScoped<int>>((ref) async {
  final vault = ref.watch(_wi105LoadedFor);
  final value = ref.watch(_wi105Value);
  if (ref.watch(_wi105Fails)) {
    throw MemexException('read failed: database is locked');
  }
  return VaultScoped(vault, value);
});

/// Mounts a Consumer in [c] with [open] as the open vault and returns its
/// `WidgetRef`, the ref event handlers pass to `awaitVaultValue`.
Future<WidgetRef> _wi105Ref(
  WidgetTester tester,
  ProviderContainer c,
  CurrentVault open,
) async {
  c.read(currentVaultProvider.notifier).state = open;
  late WidgetRef captured;
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: Consumer(
        builder: (context, ref, _) {
          captured = ref;
          return const SizedBox.shrink();
        },
      ),
    ),
  );
  return captured;
}

ProviderContainer _wi105Container() {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  return c;
}

void main() {
  group('awaitVaultValue (note_state.dart contract)', () {
    testWidgets(
      'awaitVaultValue returns the awaited data when it was loaded for the open vault',
      (tester) async {
        final c = _wi105Container();
        final ref = await _wi105Ref(tester, c, _wi105VaultA);

        final value = await tester.runAsync(
          () => awaitVaultValue(ref, _wi105Read.future, -1),
        );

        expect(value, 7);
      },
    );

    testWidgets(
      'awaitVaultValue returns empty when the awaited data belongs to another vault than the one open at the call',
      (tester) async {
        final c = _wi105Container();
        c.read(_wi105LoadedFor.notifier).state = _wi105VaultB;
        final ref = await _wi105Ref(tester, c, _wi105VaultA);

        final value = await tester.runAsync(
          () => awaitVaultValue(ref, _wi105Read.future, -1),
        );

        expect(value, -1, reason: 'vault B data must never reach vault A');
      },
    );

    testWidgets(
      'awaitVaultValue returns empty when the awaited data was loaded with no vault open but a vault is open now',
      (tester) async {
        final c = _wi105Container();
        c.read(_wi105LoadedFor.notifier).state = null;
        final ref = await _wi105Ref(tester, c, _wi105VaultA);

        final value = await tester.runAsync(
          () => awaitVaultValue(ref, _wi105Read.future, -1),
        );

        expect(value, -1);
      },
    );

    testWidgets(
      'awaitVaultValue returns empty when the read throws an Exception',
      (tester) async {
        final c = _wi105Container();
        c.read(_wi105Fails.notifier).state = true;
        final ref = await _wi105Ref(tester, c, _wi105VaultA);

        final value = await tester.runAsync(
          () => awaitVaultValue(ref, _wi105Read.future, -1),
        );

        expect(value, -1);
      },
    );

    testWidgets(
      'awaitVaultValue reloads a read nothing listens to when its inputs changed since it last loaded',
      (tester) async {
        final c = _wi105Container();
        final ref = await _wi105Ref(tester, c, _wi105VaultA);
        final first = await tester.runAsync(
          () => awaitVaultValue(ref, _wi105Read.future, -1),
        );
        expect(first, 7);

        c.read(_wi105Value.notifier).state = 8;
        final fresh = await tester.runAsync(
          () => awaitVaultValue(ref, _wi105Read.future, -1),
        );

        expect(fresh, 8, reason: 'the cached 7 is stale once the input moved');
      },
    );
  });
}
