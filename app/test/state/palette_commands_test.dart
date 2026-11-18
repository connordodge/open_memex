// WI #77 (56-A3, Spec #59 reqs 19-22; AC 10-14): the Command palette's
// Commands source, read through #76's `paletteCommandsSourceProvider` with
// #77's `paletteCommandsOverride` installed in a plain ProviderContainer.
//
// Seams: a `LocalVaultAccess` over a FakeVaultDb (a CLI makes it writable,
// none makes `canWrite` false), a FakeClock for today's date, and no UI
// state store so the sidebar mode lives in memory.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/command_palette_state.dart';
import 'package:open_memex_app/src/state/palette_commands.dart';
import 'package:open_memex_app/src/state/sidebar_mode_state.dart';
import 'package:open_memex_app/src/state/ui_state_store.dart';
import 'package:open_memex_app/src/state/vault_access_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/vault_access/local/local_vault_access.dart';

import '../support/fake_clock.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';

const _wi77Vault = '/vaults/My Vault';

/// Requirement 19's fixed order.
const _order = [
  PaletteCommand.newNote,
  PaletteCommand.newCanvas,
  PaletteCommand.openToday,
  PaletteCommand.openVaultGraph,
  PaletteCommand.switchVault,
  PaletteCommand.vaultSettings,
  PaletteCommand.backups,
  PaletteCommand.agents,
  PaletteCommand.rightPanel,
  PaletteCommand.showDays,
  PaletteCommand.showTopics,
  PaletteCommand.showTags,
];

class _Wi77Commands {
  _Wi77Commands({
    bool canWrite = true,
    DateTime? now,
    bool rightPanelOpen = true,
  }) {
    final db = FakeVaultDb.v5();
    addTearDown(db.close);
    final cli = canWrite ? FakeMemexCli() : null;
    container = ProviderContainer(
      overrides: [
        currentVaultProvider.overrideWith(
          (_) => const LocalVaultRef(_wi77Vault),
        ),
        vaultDbProvider.overrideWithValue(db),
        memexCliProvider.overrideWithValue(null),
        clockProvider.overrideWithValue(
          FakeClock(now ?? DateTime(2026, 11, 18, 9)),
        ),
        uiStateStoreProvider.overrideWithValue(null),
        rightPanelOpenProvider.overrideWith((_) => rightPanelOpen),
        vaultAccessProvider.overrideWith(
          (_) => LocalVaultAccess(vaultPath: _wi77Vault, db: db, cli: cli),
        ),
        paletteCommandsOverride,
      ],
    );
    addTearDown(container.dispose);
    // Keep the autoDispose source alive, as the open palette does.
    container.listen(paletteCommandsSourceProvider, (_, _) {});
  }

  late final ProviderContainer container;

  List<CommandItem> rows(String query) =>
      container.read(paletteCommandsSourceProvider)(query);

  List<PaletteCommand> commands(String query) => [
    for (final r in rows(query)) r.command,
  ];

  CommandItem row(String query, PaletteCommand command) {
    final found = [
      for (final r in rows(query))
        if (r.command == command) r,
    ];
    expect(found, hasLength(1), reason: '${command.name} listed once');
    return found.single;
  }
}

void main() {
  test('the empty input lists the 12 commands in requirement 19 order', () {
    final rig = _Wi77Commands();

    expect(rig.commands(''), _order);
    expect(
      [for (final r in rig.rows('')) r.label],
      [
        'New note',
        'New canvas',
        'Open today',
        'Open vault graph',
        'Switch vault…',
        'Vault settings',
        'Backups',
        'Agents',
        'Hide right panel',
        'Show Days',
        'Show Topics',
        'Show Tags',
      ],
    );
    for (final r in rig.rows('')) {
      expect(r.matched, isEmpty, reason: '${r.label}: nothing typed');
      expect(r.id, PaletteItemId(PaletteItemKind.command, r.command.name));
    }
  });

  test('a vault that cannot be written leaves out New note and New canvas', () {
    final rig = _Wi77Commands(canWrite: false);

    expect(rig.commands(''), _order.skip(2).toList());
    expect(rig.rows(''), hasLength(10));
    expect(rig.rows('').first.label, 'Open today');
    expect(
      rig.commands('new'),
      isEmpty,
      reason: 'typing does not bring them back',
    );
  });

  test('a writable vault lists New note and New canvas when typing new', () {
    final rig = _Wi77Commands();

    expect(rig.commands('new'), [
      PaletteCommand.newNote,
      PaletteCommand.newCanvas,
    ]);
  });

  test(
    'the right panel command reads Show right panel while the panel is hidden and Hide right panel while it shows',
    () {
      final rig = _Wi77Commands(rightPanelOpen: false);
      expect(rig.row('', PaletteCommand.rightPanel).label, 'Show right panel');

      rig.container.read(rightPanelOpenProvider.notifier).state = true;
      expect(
        rig.row('', PaletteCommand.rightPanel).label,
        'Hide right panel',
        reason: 'the source follows the panel while the palette is open',
      );

      rig.container.read(rightPanelOpenProvider.notifier).state = false;
      expect(rig.row('', PaletteCommand.rightPanel).label, 'Show right panel');
    },
  );

  test('Open today meta is the injected clock date', () {
    expect(
      _Wi77Commands().row('', PaletteCommand.openToday).meta,
      '2026-11-18',
    );
    expect(
      _Wi77Commands(
        now: DateTime(2027, 2, 3, 23, 30),
      ).row('', PaletteCommand.openToday).meta,
      '2027-02-03',
    );
  });

  for (final (name, mode, shown) in [
    (
      'with the sidebar in Days the Show Days row has meta shown and no other row has a meta',
      SidebarMode.days,
      PaletteCommand.showDays,
    ),
    (
      'with the sidebar in Topics the Show Topics row has meta shown and no other row has a meta',
      SidebarMode.topics,
      PaletteCommand.showTopics,
    ),
    (
      'with the sidebar in Tags the Show Tags row has meta shown and no other row has a meta',
      SidebarMode.tags,
      PaletteCommand.showTags,
    ),
  ]) {
    test(name, () async {
      final rig = _Wi77Commands();
      await rig.container.read(sidebarModeProvider.notifier).select(mode);

      final rows = rig.rows('');
      expect(rows, hasLength(12));
      for (final r in rows) {
        final expected = switch (r.command) {
          PaletteCommand.openToday => '2026-11-18',
          final c when c == shown => 'shown',
          _ => null,
        };
        expect(r.meta, expected, reason: '${r.label}: no shortcut meta');
      }
    });
  }

  test(
    'a sidebar mode change while the palette is open moves the shown meta',
    () async {
      final rig = _Wi77Commands();
      expect(rig.row('', PaletteCommand.showDays).meta, 'shown');

      await rig.container
          .read(sidebarModeProvider.notifier)
          .select(SidebarMode.tags);

      expect(rig.row('', PaletteCommand.showDays).meta, isNull);
      expect(rig.row('', PaletteCommand.showTags).meta, 'shown');
    },
  );

  test('typed commands fuzzy match best first with ties in fixed order', () {
    final rig = _Wi77Commands(rightPanelOpen: false);

    // `show days` and `show tags` tie (prefix, same length) and keep the
    // fixed order; `show topics` and `show right panel` are longer.
    expect(rig.commands('show'), [
      PaletteCommand.showDays,
      PaletteCommand.showTags,
      PaletteCommand.showTopics,
      PaletteCommand.rightPanel,
    ]);
    expect(rig.row('show', PaletteCommand.showDays).matched, [0, 1, 2, 3]);
    expect(
      rig.row('show', PaletteCommand.rightPanel).label,
      'Show right panel',
    );
  });

  test(
    'typing back lists only Backups and an unmatched input lists no commands',
    () {
      final rig = _Wi77Commands();

      expect(rig.commands('back'), [PaletteCommand.backups]);
      expect(rig.row('back', PaletteCommand.backups).matched, [0, 1, 2, 3]);
      expect(rig.commands('qzxv'), isEmpty);
    },
  );

  test('an upper case input matches like the lower case one', () {
    final rig = _Wi77Commands();

    expect(rig.commands('BACK'), [PaletteCommand.backups]);
    expect(rig.row('BACK', PaletteCommand.backups).matched, [0, 1, 2, 3]);
  });

  test('matched characters of a substring match are its indices', () {
    final rig = _Wi77Commands(rightPanelOpen: false);

    // `panel` is a substring of `show right panel` (C5: drawn in accent).
    final row = rig.row('panel', PaletteCommand.rightPanel);
    expect(row.matched, [11, 12, 13, 14, 15]);
  });

  test('a typed command keeps the dynamic metas of the empty input', () async {
    final rig = _Wi77Commands();
    await rig.container
        .read(sidebarModeProvider.notifier)
        .select(SidebarMode.topics);

    expect(rig.row('today', PaletteCommand.openToday).meta, '2026-11-18');
    expect(rig.row('topics', PaletteCommand.showTopics).meta, 'shown');
  });
}
