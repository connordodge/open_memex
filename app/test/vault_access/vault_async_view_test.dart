// WI #70 (W0a) AC11: the async-view helper (D13, D14a, Req 33; design pack
// 70: hosted first-load state = A12 loader2 16 px + centred fg2 "loading…").
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:open_memex_app/src/db.dart';
import 'package:open_memex_app/src/state/vault_access_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/theme/app_theme.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/vault_access/local/local_vault_access.dart';
import 'package:open_memex_app/src/vault_access/vault_async_view.dart';
import 'package:open_memex_app/src/vault_access/vault_scoped.dart';

const _vault = '/tmp/om-70-vault';
const _emptyText = 'no notes yet';

/// A notes domain whose `listNotes` waits on a gate per call (D21: doubles
/// extend the local domain class).
class _Wi70GatedNotesAccess extends LocalNotesAccess {
  _Wi70GatedNotesAccess() : super(vaultPath: _vault);

  final gates = <Completer<List<NoteListItem>>>[];

  @override
  Future<List<NoteListItem>> listNotes({int limit = 200}) {
    final gate = Completer<List<NoteListItem>>();
    gates.add(gate);
    return gate.future;
  }
}

/// A reader as #86–#90 will write it: an async provider that re-reads on
/// every vault revision and stamps its result with the vault it read.
final _wi70NotesAsyncProvider = FutureProvider<VaultScoped<List<NoteListItem>>>(
  (ref) async {
    ref.watch(vaultRevisionProvider);
    final vault = ref.watch(currentVaultProvider);
    final access = ref.watch(vaultAccessProvider);
    if (access == null) return VaultScoped(vault, const <NoteListItem>[]);
    return VaultScoped(vault, await access.notes.listNotes());
  },
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

Future<(ProviderContainer, _Wi70GatedNotesAccess)> _pump(
  WidgetTester tester, {
  required bool hosted,
}) async {
  final gated = _Wi70GatedNotesAccess();
  final container = ProviderContainer(
    overrides: [
      currentVaultProvider.overrideWith((_) => _vault),
      vaultDbProvider.overrideWithValue(null),
      memexCliProvider.overrideWithValue(null),
      vaultAccessProvider.overrideWithValue(
        LocalVaultAccess(vaultPath: _vault, notes: gated),
      ),
      vaultIsHostedProvider.overrideWithValue(hosted),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildOmTheme(),
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => VaultAsyncView<List<NoteListItem>>(
              value: ref.watch(_wi70NotesAsyncProvider),
              empty: const [],
              builder: (context, notes) => notes.isEmpty
                  ? const Text(_emptyText)
                  : Column(children: [for (final n in notes) Text(n.title)]),
            ),
          ),
        ),
      ),
    ),
  );
  // Never pumpAndSettle: the hosted spinner animates continuously.
  await tester.pump();
  return (container, gated);
}

/// Lets a completed read reach the screen: the future's callback, then the
/// provider notification, then the rebuilt frame.
Future<void> _drain(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

void _expectNoSpinner() {
  expect(find.byKey(vaultAsyncLoadingKey), findsNothing);
  expect(find.byIcon(LucideIcons.loader2), findsNothing);
  expect(find.text('loading…'), findsNothing);
  expect(find.byType(CircularProgressIndicator), findsNothing);
}

void main() {
  testWidgets('local first load renders the empty state with no spinner', (
    tester,
  ) async {
    final (_, gated) = await _pump(tester, hosted: false);

    expect(gated.gates, hasLength(1), reason: 'the read is still in flight');
    expect(find.text(_emptyText), findsOneWidget);
    _expectNoSpinner();

    gated.gates.single.complete(_notes(['Alpha']));
    await _drain(tester);
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text(_emptyText), findsNothing);
  });

  testWidgets('hosted first load renders the loading state', (tester) async {
    final (_, gated) = await _pump(tester, hosted: true);

    expect(gated.gates, hasLength(1));
    expect(find.byKey(vaultAsyncLoadingKey), findsOneWidget);
    expect(find.text(_emptyText), findsNothing, reason: 'in place of the list');
    expect(find.byType(CircularProgressIndicator), findsNothing);

    // A12 "opening" spinner: Lucide loader2, 16 px, fg2.
    final spinner = find.descendant(
      of: find.byKey(vaultAsyncLoadingKey),
      matching: find.byIcon(LucideIcons.loader2),
    );
    expect(spinner, findsOneWidget);
    final icon = tester.widget<Icon>(spinner);
    expect(icon.size, 16);
    expect(icon.color, OmColors.fg2);

    // Centred fg2 "loading…" line, 13 px.
    final label = find.descendant(
      of: find.byKey(vaultAsyncLoadingKey),
      matching: find.text('loading…'),
    );
    expect(label, findsOneWidget);
    final text = tester.widget<Text>(label);
    expect(text.style?.fontSize, 13);
    expect(text.style?.color, OmColors.fg2);
    expect(
      find.ancestor(of: label, matching: find.byType(Center)),
      findsWidgets,
    );

    gated.gates.single.complete(_notes(['Alpha']));
    await _drain(tester);
    expect(find.text('Alpha'), findsOneWidget);
    _expectNoSpinner();
  });

  testWidgets(
    'after a revision bump the previous value stays rendered until the new read completes',
    (tester) async {
      final (container, gated) = await _pump(tester, hosted: false);
      gated.gates.single.complete(_notes(['Alpha', 'Beta']));
      await _drain(tester);
      expect(find.text('Alpha'), findsOneWidget);

      container.read(vaultRevisionProvider.notifier).state++;
      await tester.pump();
      await tester.pump();

      expect(gated.gates, hasLength(2), reason: 'the bump started a new read');
      expect(find.text('Alpha'), findsOneWidget);
      expect(find.text('Beta'), findsOneWidget);
      expect(find.text(_emptyText), findsNothing, reason: 'no empty flash');
      _expectNoSpinner();

      gated.gates.last.complete(_notes(['Gamma']));
      await _drain(tester);
      expect(find.text('Gamma'), findsOneWidget);
      expect(find.text('Alpha'), findsNothing);
    },
  );

  testWidgets('hosted reload keeps the previous value with no spinner', (
    tester,
  ) async {
    final (container, gated) = await _pump(tester, hosted: true);
    gated.gates.single.complete(_notes(['Alpha']));
    await _drain(tester);
    expect(find.text('Alpha'), findsOneWidget);

    container.read(vaultRevisionProvider.notifier).state++;
    await tester.pump();
    await tester.pump();

    expect(gated.gates, hasLength(2));
    expect(find.text('Alpha'), findsOneWidget);
    _expectNoSpinner();

    gated.gates.last.complete(_notes(['Beta']));
    await _drain(tester);
    expect(find.text('Beta'), findsOneWidget);
  });

  for (final (name, hosted) in [
    (
      'local first load error with no previous value renders the empty state',
      false,
    ),
    (
      'hosted first load error with no previous value renders the empty state',
      true,
    ),
  ]) {
    testWidgets(name, (tester) async {
      final (container, gated) = await _pump(tester, hosted: hosted);
      if (hosted) {
        expect(find.byKey(vaultAsyncLoadingKey), findsOneWidget);
      }

      gated.gates.single.completeError(StateError('read failed'));
      await _drain(tester);

      final value = container.read(_wi70NotesAsyncProvider);
      expect(value.hasError, isTrue);
      expect(value.hasValue, isFalse);
      expect(find.text(_emptyText), findsOneWidget);
      _expectNoSpinner();
    });
  }

  for (final (name, hosted) in [
    ('local reload error keeps the previous value rendered', false),
    ('hosted reload error keeps the previous value rendered', true),
  ]) {
    testWidgets(name, (tester) async {
      final (container, gated) = await _pump(tester, hosted: hosted);
      gated.gates.single.complete(_notes(['Alpha']));
      await _drain(tester);
      expect(find.text('Alpha'), findsOneWidget);

      container.read(vaultRevisionProvider.notifier).state++;
      await tester.pump();
      await tester.pump();
      expect(gated.gates, hasLength(2));

      gated.gates.last.completeError(StateError('reload failed'));
      await _drain(tester);

      final value = container.read(_wi70NotesAsyncProvider);
      expect(value.hasError, isTrue);
      expect(value.hasValue, isTrue, reason: 'the error carries the old value');
      expect(find.text('Alpha'), findsOneWidget);
      expect(find.text(_emptyText), findsNothing);
      _expectNoSpinner();
    });
  }

  testWidgets('a first load that completes empty renders the empty state', (
    tester,
  ) async {
    final (_, gated) = await _pump(tester, hosted: true);
    gated.gates.single.complete(const []);
    await _drain(tester);

    expect(find.text(_emptyText), findsOneWidget);
    _expectNoSpinner();
  });
}
