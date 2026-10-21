// WI #105 (F1) AC6: local opens with hosted vaults on (Req 31, L20, D19).
// `memex vault check` runs before the vault opens (fake CLI call order); a
// `network_filesystem` refusal leads to the set-up sheet through its "set up
// a vault server…"; a too-old memex (exit 2) refusal's "locate memex
// binary…" stores the picked binary, and the next open checks again with
// it. The real app runs over the journey harness with the fake CLI and the
// fake file picker.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/screens/workspace.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:path/path.dart' as p;

import '../robots/picker_robot.dart';
import '../support/app_harness.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_vault_db.dart';
import '../support/file_picker_fakes.dart';
import '../support/hosted_harness.dart';
import '../support/journey_harness.dart';
import '../support/vault_folders.dart';
import '../support/vault_picker_harness.dart' show wi97HoldFontFetches;

/// clap's answer from a memex without `vault check` (exit 2).
const _clapUsageError =
    "error: unrecognized subcommand 'vault'\n\nUsage: memex <COMMAND>\n";

/// A fake CLI whose `vault check` answers [check].
FakeMemexCli _cli(FakeCliHandler check, {String binaryPath = 'fake-memex'}) =>
    FakeMemexCli(binaryPath: binaryPath)
      ..on('vault check', check)
      ..on('settings get', (_) => FakeMemexCli.ok(settingsGetMaxDepthStdout));

List<String> _subcommands(FakeMemexCli cli) => [
  for (final c in cli.calls) c.subcommand,
];

void main() {
  wi97HoldFontFetches();

  group('local open runs vault check first (AC6)', () {
    testWidgets(
      'open local vault runs memex vault check before the vault opens',
      (tester) async {
        final vault = createVaultFolder('om105_local_');
        installFakeFilePicker().directories.add(vault.path);
        final gate = Completer<MemexResult>();
        final cli = _cli((_) => gate.future);
        final app = await pumpJourneyApp(
          tester,
          cli: cli,
          db: FakeVaultDb.v5(),
          servers: [HostedServerFixture()],
        );
        final r = PickerRobot(app);

        await r.tap(r.openLocal);

        expect(_subcommands(cli), ['vault check']);
        expect(cli.calls.single.args, [
          'vault',
          'check',
          '--vault',
          vault.path,
        ]);
        expect(app.read(currentVaultProvider), isNull);
        expect(find.byType(Workspace), findsNothing);

        gate.complete(FakeMemexCli.ok());
        await app.settle();

        expect(app.read(currentVaultProvider), LocalVaultRef(vault.path));
        expect(find.byType(Workspace), findsOneWidget);
        expect(_subcommands(cli).first, 'vault check');
      },
    );

    testWidgets(
      'a network drive refusal leads through set up a vault server to the set up sheet and opens nothing',
      (tester) async {
        final vault = createVaultFolder('om105_nas_');
        installFakeFilePicker().directories.add(vault.path);
        final cli = _cli(
          (_) => FakeMemexCli.error(
            'network_filesystem',
            'the vault folder is on a network filesystem',
          ),
        );
        final app = await pumpJourneyApp(
          tester,
          cli: cli,
          db: FakeVaultDb.v5(),
        );
        final r = PickerRobot(app);

        await r.tap(r.openLocal);
        expect(r.networkRefusal, findsOneWidget);
        await r.tap(r.networkRefusalSetUp);

        expect(r.networkRefusal, findsNothing);
        expect(r.setUpSheet, findsOneWidget);
        await r.tap(r.setUpClose);
        expect(r.setUpSheet, findsNothing);
        expect(app.read(currentVaultProvider), isNull);
        expect(_subcommands(cli), ['vault check']);
      },
    );

    testWidgets(
      'a too old memex refusal locates a new binary and the next open checks again with it',
      (tester) async {
        final vault = createVaultFolder('om105_old_');
        final binDir = createPlainFolder('om105_bin_');
        final newBinary = p.join(binDir.path, 'memex');
        File(newBinary).writeAsStringSync('#!/bin/sh\n');
        final picker = installFakeFilePicker()
          ..directories.addAll([vault.path, vault.path])
          ..files.add(newBinary);
        final oldCli = _cli(
          (_) => FakeMemexCli.failure(_clapUsageError, exitCode: 2),
        );
        final newCli = _cli((_) => FakeMemexCli.ok(), binaryPath: newBinary);
        final app = await pumpJourneyApp(
          tester,
          clis: {'fake-memex': oldCli, newBinary: newCli},
          db: FakeVaultDb.v5(),
        );
        final r = PickerRobot(app);

        await r.tap(r.openLocal);
        expect(r.tooOldRefusal, findsOneWidget);
        await r.tap(r.tooOldLocate);

        expect(picker.calls.last.method, 'pickFiles');
        expect(app.settings.memexBinaryPath, newBinary);
        expect(r.tooOldRefusal, findsNothing);
        expect(app.read(currentVaultProvider), isNull);
        expect(newCli.calls, isEmpty);

        await r.tap(r.openLocal);

        expect(oldCli.callsFor('vault check'), hasLength(1));
        expect(newCli.calls.first.args, [
          'vault',
          'check',
          '--vault',
          vault.path,
        ]);
        expect(app.read(currentVaultProvider), LocalVaultRef(vault.path));
        expect(find.byType(Workspace), findsOneWidget);
      },
    );
  });
}
