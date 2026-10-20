// WI #70 (W0a) AC11 + D14a: a vault switch never renders the previous
// vault's data. Reads are stamped with the vault they were loaded for
// (VaultScoped); VaultAsyncView and vaultFacadeValue treat data stamped with
// another vault as no data (local: empty state, hosted: A12 loading state).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/state/vault_access_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/theme/app_theme.dart';
import 'package:open_memex_app/src/vault_access/local/local_vault_access.dart';
import 'package:open_memex_app/src/vault_access/vault_async_view.dart';
import 'package:open_memex_app/src/vault_access/vault_scoped.dart';

const _vaultA = '/tmp/om-70-vault-a';
const _vaultB = '/tmp/om-70-vault-b';
const _emptyText = 'no notes yet';
const _facadeKey = Key('wi70-facade');

/// A notes domain for one vault whose `listNotes` waits on a gate per call
/// (D21: doubles extend the local domain class).
class _Wi70SwitchGatedNotes extends LocalNotesAccess {
  _Wi70SwitchGatedNotes(String vault) : super(vaultPath: vault);

  final gates = <Completer<List<NoteListItem>>>[];

  @override
  Future<List<NoteListItem>> listNotes({int limit = 200}) {
    final gate = Completer<List<NoteListItem>>();
    gates.add(gate);
    return gate.future;
  }
}

/// A reader as #86–#90 will write it: re-reads on every revision and on a
/// vault switch, and stamps its result with the vault it read.
final _wi70SwitchNotesProvider =
    FutureProvider<VaultScoped<List<NoteListItem>>>((ref) async {
      ref.watch(vaultRevisionProvider);
      final vault = ref.watch(currentVaultProvider);
      final access = ref.watch(vaultAccessProvider);
      if (access == null) return VaultScoped(vault, const <NoteListItem>[]);
      return VaultScoped(vault, await access.notes.listNotes());
    });

/// A D14a synchronous facade over [_wi70SwitchNotesProvider].
final _wi70SwitchFacadeProvider = Provider<List<NoteListItem>>(
  (ref) => vaultFacadeValue(
    ref,
    ref.watch(_wi70SwitchNotesProvider),
    const <NoteListItem>[],
  ),
);

/// Backs `vaultIsHostedProvider` so a test can flip it.
final _wi70HostedState = StateProvider<bool>((_) => false);

/// A value that never re-reads: lets a test switch the vault while the
/// value handed to the view and the facade stays the same object.
final _wi70FixedValue =
    StateProvider<AsyncValue<VaultScoped<List<NoteListItem>>>>(
      (_) => const AsyncLoading(),
    );

final _wi70FixedFacadeProvider = Provider<List<NoteListItem>>(
  (ref) =>
      vaultFacadeValue(ref, ref.watch(_wi70FixedValue), const <NoteListItem>[]),
);

List<NoteListItem> _notes(List<String> titles) => [
  for (final (i, t) in titles.indexed)
    NoteListItem(
      id: 'n$i',
      title: t,
      snippet: '',
      version: 1,
      updatedAt: 1759500000000 + i,
    ),
];

class _Wi70Switch {
  _Wi70Switch(this.container, this.notes);

  final ProviderContainer container;
  final Map<String, _Wi70SwitchGatedNotes> notes;

  _Wi70SwitchGatedNotes get a => notes[_vaultA]!;
  _Wi70SwitchGatedNotes get b => notes[_vaultB]!;

  void switchTo(String? vault) =>
      container.read(currentVaultProvider.notifier).state = vault;

  AsyncValue<VaultScoped<List<NoteListItem>>> get value =>
      container.read(_wi70SwitchNotesProvider);
}

/// Pumps a view and a facade line over the reader for [_vaultA]. With
/// [fixed] both read [_wi70FixedValue] instead of the reader.
Future<_Wi70Switch> _pump(
  WidgetTester tester, {
  required bool hosted,
  bool fixed = false,
}) async {
  final notes = {
    _vaultA: _Wi70SwitchGatedNotes(_vaultA),
    _vaultB: _Wi70SwitchGatedNotes(_vaultB),
  };
  final container = ProviderContainer(
    overrides: [
      currentVaultProvider.overrideWith((_) => _vaultA),
      vaultDbProvider.overrideWithValue(null),
      memexCliProvider.overrideWithValue(null),
      vaultAccessProvider.overrideWith((ref) {
        final vault = ref.watch(currentVaultProvider);
        if (vault == null) return null;
        return LocalVaultAccess(vaultPath: vault, notes: notes[vault]);
      }),
      _wi70HostedState.overrideWith((_) => hosted),
      vaultIsHostedProvider.overrideWith((ref) => ref.watch(_wi70HostedState)),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildOmTheme(),
        home: Scaffold(
          // Two Consumers, so the view never rebuilds just because the
          // facade line did (and the reverse).
          body: Column(
            children: [
              Expanded(
                child: Consumer(
                  builder: (context, ref, _) =>
                      VaultAsyncView<List<NoteListItem>>(
                        value: fixed
                            ? ref.watch(_wi70FixedValue)
                            : ref.watch(_wi70SwitchNotesProvider),
                        empty: const [],
                        builder: (context, notes) => notes.isEmpty
                            ? const Text(_emptyText)
                            : Column(
                                children: [
                                  for (final n in notes) Text(n.title),
                                ],
                              ),
                      ),
                ),
              ),
              Consumer(
                builder: (context, ref, _) {
                  final facade = fixed
                      ? ref.watch(_wi70FixedFacadeProvider)
                      : ref.watch(_wi70SwitchFacadeProvider);
                  return Text(
                    'facade:${[for (final n in facade) n.title].join(',')}',
                    key: _facadeKey,
                  );
                },
              ),
            ],
          ),
        ),
      ),
    ),
  );
  // Never pumpAndSettle: the hosted spinner animates continuously.
  await tester.pump();
  return _Wi70Switch(container, notes);
}

/// Lets a completed read or a state change reach the screen.
Future<void> _drain(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

String _facadeText(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(_facadeKey)).data!;

void _expectNoSpinner() {
  expect(find.byKey(vaultAsyncLoadingKey), findsNothing);
  expect(find.byIcon(LucideIcons.loader2), findsNothing);
}

/// Loads vault A's rows, then switches to vault B (whose read stays pending).
Future<_Wi70Switch> _loadAThenSwitch(
  WidgetTester tester, {
  required bool hosted,
}) async {
  final s = await _pump(tester, hosted: hosted);
  s.a.gates.single.complete(_notes(['Alpha from A', 'Beta from A']));
  await _drain(tester);
  expect(find.text('Alpha from A'), findsOneWidget);
  expect(_facadeText(tester), 'facade:Alpha from A,Beta from A');

  s.switchTo(_vaultB);
  await _drain(tester);
  expect(s.b.gates, hasLength(1), reason: 'the switch started a read of B');
  // The reader still carries A's value while B loads: the case under test.
  expect(s.value.isLoading, isTrue);
  expect(s.value.valueOrNull?.vault, _vaultA);
  return s;
}

void _expectNoVaultARows(WidgetTester tester) {
  expect(find.text('Alpha from A'), findsNothing);
  expect(find.text('Beta from A'), findsNothing);
  expect(_facadeText(tester), 'facade:', reason: 'the facade gives empty');
}

void main() {
  group('vault switch while the new read is pending', () {
    testWidgets(
      'a local vault switch while the new read is pending shows the empty state and never the previous vault rows',
      (tester) async {
        final s = await _loadAThenSwitch(tester, hosted: false);

        _expectNoVaultARows(tester);
        expect(find.text(_emptyText), findsOneWidget);
        _expectNoSpinner();

        s.b.gates.single.complete(_notes(['Gamma from B']));
        await _drain(tester);
        expect(find.text('Gamma from B'), findsOneWidget);
        expect(find.text(_emptyText), findsNothing);
        expect(_facadeText(tester), 'facade:Gamma from B');
      },
    );

    testWidgets(
      'a hosted vault switch while the new read is pending shows the loading state and never the previous vault rows',
      (tester) async {
        final s = await _loadAThenSwitch(tester, hosted: true);

        _expectNoVaultARows(tester);
        expect(find.byKey(vaultAsyncLoadingKey), findsOneWidget);
        expect(find.text(_emptyText), findsNothing);

        s.b.gates.single.complete(_notes(['Gamma from B']));
        await _drain(tester);
        expect(find.text('Gamma from B'), findsOneWidget);
        _expectNoSpinner();
        expect(_facadeText(tester), 'facade:Gamma from B');
      },
    );
  });

  for (final (name, hosted) in [
    (
      'a failed first read of the new local vault shows the empty state and never the previous vault rows',
      false,
    ),
    (
      'a failed first read of the new hosted vault shows the empty state and never the previous vault rows',
      true,
    ),
  ]) {
    testWidgets(name, (tester) async {
      final s = await _loadAThenSwitch(tester, hosted: hosted);

      s.b.gates.single.completeError(StateError('read of B failed'));
      await _drain(tester);

      // The error still carries A's value: the view must not render it.
      expect(s.value.hasError, isTrue);
      expect(s.value.valueOrNull?.vault, _vaultA);
      _expectNoVaultARows(tester);
      expect(find.text(_emptyText), findsOneWidget);
      _expectNoSpinner();
    });
  }

  for (final (name, hosted) in [
    (
      'a same vault reload keeps the previous value in the view and the facade on a local vault',
      false,
    ),
    (
      'a same vault reload keeps the previous value in the view and the facade on a hosted vault',
      true,
    ),
  ]) {
    testWidgets(name, (tester) async {
      final s = await _pump(tester, hosted: hosted);
      s.a.gates.single.complete(_notes(['Alpha from A']));
      await _drain(tester);

      s.container.read(vaultRevisionProvider.notifier).state++;
      await _drain(tester);

      expect(s.a.gates, hasLength(2), reason: 'the bump started a new read');
      expect(s.value.isLoading, isTrue);
      expect(find.text('Alpha from A'), findsOneWidget);
      expect(find.text(_emptyText), findsNothing);
      _expectNoSpinner();
      expect(_facadeText(tester), 'facade:Alpha from A');
      expect(
        [for (final n in s.container.read(_wi70SwitchFacadeProvider)) n.title],
        ['Alpha from A'],
      );
    });
  }

  testWidgets(
    'vaultFacadeValue gives the empty value on first load and the data once loaded',
    (tester) async {
      final s = await _pump(tester, hosted: true);

      expect(s.container.read(_wi70SwitchFacadeProvider), isEmpty);
      expect(_facadeText(tester), 'facade:');

      s.a.gates.single.complete(_notes(['Alpha from A']));
      await _drain(tester);
      expect(_facadeText(tester), 'facade:Alpha from A');
    },
  );

  testWidgets(
    'vaultFacadeValue gives the empty value after a failed first load',
    (tester) async {
      final s = await _pump(tester, hosted: false);

      s.a.gates.single.completeError(StateError('read failed'));
      await _drain(tester);

      expect(s.value.hasError, isTrue);
      expect(s.container.read(_wi70SwitchFacadeProvider), isEmpty);
      expect(_facadeText(tester), 'facade:');
    },
  );

  testWidgets(
    'the view and the facade drop an unchanged value once the vault switches',
    (tester) async {
      final s = await _pump(tester, hosted: false, fixed: true);
      s.container.read(_wi70FixedValue.notifier).state = AsyncData(
        VaultScoped(_vaultA, _notes(['Alpha from A'])),
      );
      await _drain(tester);
      expect(find.text('Alpha from A'), findsOneWidget);
      expect(_facadeText(tester), 'facade:Alpha from A');

      // Only the vault changes; the value handed to both stays the same.
      s.switchTo(_vaultB);
      await _drain(tester);

      _expectNoVaultARows(tester);
      expect(find.text(_emptyText), findsOneWidget);

      // And back: A's data is the current vault's data again.
      s.switchTo(_vaultA);
      await _drain(tester);
      expect(find.text('Alpha from A'), findsOneWidget);
      expect(_facadeText(tester), 'facade:Alpha from A');
    },
  );

  testWidgets(
    'VaultAsyncView follows vaultIsHostedProvider while the first load is pending',
    (tester) async {
      final s = await _pump(tester, hosted: false);
      expect(s.a.gates, hasLength(1), reason: 'the first read is pending');
      expect(find.text(_emptyText), findsOneWidget);
      _expectNoSpinner();

      s.container.read(_wi70HostedState.notifier).state = true;
      await _drain(tester);
      expect(find.byKey(vaultAsyncLoadingKey), findsOneWidget);
      expect(find.text(_emptyText), findsNothing);

      s.container.read(_wi70HostedState.notifier).state = false;
      await _drain(tester);
      expect(find.text(_emptyText), findsOneWidget);
      _expectNoSpinner();
    },
  );

  group('currentVaultData', () {
    // Built from run-time values so the VaultScoped constructor runs.
    final vaultA = [_vaultA].join();
    final scopedA = VaultScoped<List<String>>(vaultA, ['row from A']);

    test('currentVaultData is null when there is no data', () {
      expect(
        currentVaultData<List<String>>(const AsyncLoading(), _vaultA),
        isNull,
      );
      expect(
        currentVaultData<List<String>>(
          AsyncError(StateError('x'), StackTrace.empty),
          _vaultA,
        ),
        isNull,
      );
    });

    test(
      'currentVaultData is null when the data was loaded for another vault',
      () {
        expect(scopedA.vault, _vaultA);
        expect(currentVaultData(AsyncData(scopedA), _vaultB), isNull);
        expect(currentVaultData(AsyncData(scopedA), null), isNull);
        expect(
          currentVaultData(
            AsyncData(const VaultScoped<List<String>>(null, [])),
            _vaultA,
          ),
          isNull,
        );
        // Still null while B loads or after B failed, with A's value carried.
        expect(
          currentVaultData(
            const AsyncLoading<VaultScoped<List<String>>>().copyWithPrevious(
              AsyncData(scopedA),
            ),
            _vaultB,
          ),
          isNull,
        );
        expect(
          currentVaultData(
            AsyncError<VaultScoped<List<String>>>(
              StateError('x'),
              StackTrace.empty,
            ).copyWithPrevious(AsyncData(scopedA)),
            _vaultB,
          ),
          isNull,
        );
      },
    );

    test(
      'currentVaultData returns the data loaded for the current vault also during a reload or after a reload error',
      () {
        expect(currentVaultData(AsyncData(scopedA), _vaultA), same(scopedA));
        expect(
          currentVaultData(
            const AsyncLoading<VaultScoped<List<String>>>().copyWithPrevious(
              AsyncData(scopedA),
            ),
            _vaultA,
          ),
          same(scopedA),
        );
        expect(
          currentVaultData(
            AsyncError<VaultScoped<List<String>>>(
              StateError('x'),
              StackTrace.empty,
            ).copyWithPrevious(AsyncData(scopedA)),
            _vaultA,
          ),
          same(scopedA),
        );
        expect(scopedA.value, ['row from A']);
      },
    );
  });
}
