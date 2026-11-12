// WI #411 (Spec #394 req 13, 29; design pack
// design/394-agents-sheet/packs/411.md "Not on the board", RULINGS #17): the
// Claude Desktop detection line on the Connect tab's Claude Desktop pane.
// Each matcher result's status copy, when the config is read (shown, shown
// again, app refocus while shown, each `Check again`) and that reads never
// stack. Every read goes through `claudeConfigReaderProvider`, overridden
// with a fake: no test reads the real Claude Desktop config.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/agents_sheet/connect/claude_config_reader.dart';
import 'package:open_memex_app/src/state/agents_sheet/connect_tab_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/theme/colors.dart';

import '../../support/connect_tab_rig.dart';
import '../../support/font_fetch_hold.dart';
import '../../support/journey_harness.dart';

const _notSetUp = 'Claude Desktop isn’t set up for this vault yet.';
const _missing = 'Claude Desktop’s config file wasn’t found.';
const _unreadable = 'Couldn’t read Claude Desktop’s config file.';
const _secret = 'cfg-secret-411-zzQ9';

String _config(Map<String, Object?> servers) =>
    jsonEncode({'mcpServers': servers});

Map<String, Object?> _serve(List<String> args, {Map<String, String>? env}) => {
  'command': connectMemexPath,
  'args': ['serve', ...args],
  'env': ?env,
};

/// One detection case: what the reader answers, on which vault, and the
/// exact status line Spec #394 req 29 gives it.
typedef _Wi411Case = ({
  String name,
  FakeClaudeConfigReader reader,
  VaultRef vault,
  String status,
});

Color? _colorOf(WidgetTester tester, Finder f) {
  final rich = tester.widget<RichText>(
    find
        .descendant(of: f, matching: find.byType(RichText), matchRoot: true)
        .first,
  );
  return styledRuns(rich.text).first.style.color;
}

void main() {
  holdFontFetches();

  final home = Platform.environment['HOME']!;

  group('status lines', () {
    testWidgets(
      'each detection result shows its exact status line above step 1 in fg1',
      (tester) async {
        final tildeVault = LocalVaultRef('$home/om411-tilde-vault');
        final cases = <_Wi411Case>[
          (
            name: 'local match with recall',
            reader: FakeClaudeConfigReader.contents(
              _config({
                'memex': _serve([
                  '--vault',
                  connectVaultPath,
                  '--with-embeddings',
                ]),
              }),
            ),
            vault: agentsSheetLocalVault,
            status:
                'Claude Desktop is set up for this vault as "memex" · '
                'semantic recall on',
          ),
          (
            name: 'local match without recall',
            reader: FakeClaudeConfigReader.contents(
              _config({
                'studio': _serve(['--vault=$connectVaultPath']),
              }),
            ),
            vault: agentsSheetLocalVault,
            status:
                'Claude Desktop is set up for this vault as "studio" · '
                'without semantic recall',
          ),
          (
            name: 'hosted match',
            reader: FakeClaudeConfigReader.contents(
              _config({
                'memex-studio': _serve(
                  ['--remote', '$connectMcpAddress/'],
                  env: {'MEMEX_ACCESS_TOKEN': _secret},
                ),
              }),
            ),
            vault: agentsSheetHostedVault,
            status: 'Claude Desktop is set up for this vault as "memex-studio"',
          ),
          (
            name: 'tilde path',
            reader: FakeClaudeConfigReader.contents(
              _config({
                'memex': _serve(['--vault', '~/om411-tilde-vault']),
              }),
            ),
            vault: tildeVault,
            status:
                'Set up as "memex", but its path uses ~, which Claude '
                'Desktop doesn’t expand.',
          ),
          (
            name: 'not set up',
            reader: FakeClaudeConfigReader.contents(
              _config({
                'memex': _serve(['--vault', '/Users/tester/vaults/Other']),
              }),
            ),
            vault: agentsSheetLocalVault,
            status: _notSetUp,
          ),
          (
            name: 'not set up hosted',
            reader: FakeClaudeConfigReader.contents(
              _config({
                'memex': _serve(['--vault', connectVaultPath]),
              }),
            ),
            vault: agentsSheetHostedVault,
            status: _notSetUp,
          ),
          (
            name: 'missing',
            reader: FakeClaudeConfigReader.missing(),
            vault: agentsSheetLocalVault,
            status: _missing,
          ),
          (
            name: 'unreadable',
            reader: FakeClaudeConfigReader.unreadable(),
            vault: agentsSheetLocalVault,
            status: _unreadable,
          ),
          (
            name: 'oversized',
            reader: FakeClaudeConfigReader.oversized(),
            vault: agentsSheetLocalVault,
            status: _unreadable,
          ),
          (
            name: 'invalid json',
            reader: FakeClaudeConfigReader.contents('{"mcpServers": {'),
            vault: agentsSheetLocalVault,
            status: _unreadable,
          ),
        ];
        for (final c in cases) {
          await pumpConnect(tester, vault: c.vault, reader: c.reader);
          final line = inSheet(textShowing(c.status));
          expect(line, findsOneWidget, reason: c.name);
          expect(_colorOf(tester, line), OmColors.fg1, reason: c.name);
          final step1 = c.vault is HostedVaultRef
              ? connectStepHostedMerge
              : connectStepOpenConfig;
          expect(
            tester.getTopLeft(line).dy,
            lessThan(tester.getTopLeft(textShowing(step1)).dy),
            reason: '${c.name}: above step 1',
          );
          expect(inSheet(find.text('Check again')), findsOneWidget);
          expect(c.reader.reads, 1, reason: c.name);
        }
      },
    );

    testWidgets('the detection line shows only on the Claude Desktop pane', (
      tester,
    ) async {
      final rig = await pumpConnect(tester);
      expect(inSheet(textShowing(_missing)), findsOneWidget);
      expect(inSheet(find.text('Check again')), findsOneWidget);

      await rig.chooseClient('Claude Code');
      expect(textShowing(_missing), findsNothing);
      expect(find.text('Check again'), findsNothing);

      await rig.chooseClient('Claude Desktop');
      expect(inSheet(textShowing(_missing)), findsOneWidget);
    });

    testWidgets('detection never shows an entry env value or a parse error', (
      tester,
    ) async {
      final logs = <String>[];
      final oldDebugPrint = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        logs.add(message ?? '');
      };
      try {
        await runZoned(
          () async {
            final reader = FakeClaudeConfigReader.contents(
              _config({
                'other': {
                  'command': '/usr/bin/other',
                  'env': {'OTHER_KEY': _secret},
                },
                'memex': _serve(
                  ['--vault', connectVaultPath],
                  env: {'MEMEX_ACCESS_TOKEN': _secret},
                ),
              }),
            );
            final rig = await pumpConnect(tester, reader: reader);
            expect(
              inSheet(
                textShowing(
                  'Claude Desktop is set up for this vault as "memex" · '
                  'without semantic recall',
                ),
              ),
              findsOneWidget,
            );
            expect(textContaining(_secret), findsNothing);

            // A broken file whose text holds a secret: fixed copy only.
            reader.result = ClaudeConfigContents(
              '{"mcpServers": {"x": {"env": {"K": "$_secret"}}',
            );
            await rig.tap(inSheet(find.text('Check again')));
            expect(inSheet(textShowing(_unreadable)), findsOneWidget);
            expect(textContaining(_secret), findsNothing);
            expect(textContaining('FormatException'), findsNothing);
            expect(tester.takeException(), isNull);
          },
          zoneSpecification: ZoneSpecification(
            print: (self, parent, zone, line) => logs.add(line),
          ),
        );
      } finally {
        debugPrint = oldDebugPrint;
      }
      expect(logs.where((l) => l.contains(_secret)), isEmpty);
      expect(logs.where((l) => l.contains('FormatException')), isEmpty);
    });
  });

  group('when it reads', () {
    test('the default config reader reads under the real home directory', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final reader = container.read(claudeConfigReaderProvider);
      expect(
        reader,
        isA<FileClaudeConfigReader>()
            .having((r) => r.homeDirectory, 'homeDirectory', home)
            .having(
              (r) => r.path,
              'path',
              '$home/Library/Application Support/Claude/'
                  'claude_desktop_config.json',
            ),
      );
    });

    testWidgets(
      'the journey harness never reads the real Claude Desktop config',
      (tester) async {
        final app = await pumpJourneyApp(tester);
        final reader = app.read(claudeConfigReaderProvider);
        expect(reader, isA<FakeClaudeConfigReader>());
        expect(reader, isNot(isA<FileClaudeConfigReader>()));
        expect(await reader.read(), isA<ClaudeConfigMissing>());
      },
    );

    testWidgets(
      'detection reads once when Connect is shown and again when it is shown again',
      (tester) async {
        final rig = await pumpConnect(tester);
        final reader = rig.reader!;
        expect(reader.reads, 1);
        expect(inSheet(textShowing(_missing)), findsOneWidget);

        await rig.showTab('tools');
        expect(reader.reads, 1, reason: 'not while another tab is shown');

        reader.result = ClaudeConfigContents(
          _config({
            'memex': _serve(['--vault', connectVaultPath, '--with-embeddings']),
          }),
        );
        await rig.showTab('connect');
        expect(reader.reads, 2);
        expect(
          inSheet(
            textShowing(
              'Claude Desktop is set up for this vault as "memex" · '
              'semantic recall on',
            ),
          ),
          findsOneWidget,
          reason: 'the line shows the new read',
        );

        await rig.closeSheet();
        await rig.reopen();
        expect(reader.reads, 3, reason: 'a new sheet shows Connect again');
      },
    );

    testWidgets('app refocus re-reads only while Connect is shown', (
      tester,
    ) async {
      final rig = await pumpConnect(tester);
      final reader = rig.reader!;
      expect(reader.reads, 1);

      reader.result = const ClaudeConfigUnreadable();
      await rig.refocusApp();
      expect(reader.reads, 2, reason: 'one read per regained focus');
      expect(inSheet(textShowing(_unreadable)), findsOneWidget);

      await rig.showTab('tools');
      await rig.refocusApp();
      expect(reader.reads, 2, reason: 'not while Tools is shown');

      await rig.showTab('connect');
      expect(reader.reads, 3);
      await rig.closeSheet();
      await rig.refocusApp();
      expect(reader.reads, 3, reason: 'not once the sheet is closed');
    });

    testWidgets(
      'Check again reads once per press and never runs two reads at once',
      (tester) async {
        final reader = HeldClaudeConfigReader(const ClaudeConfigMissing());
        final rig = await pumpConnect(
          tester,
          overrides: [claudeConfigReaderProvider.overrideWithValue(reader)],
        );
        expect(reader.reads, 1);
        reader.release();
        await rig.settle();
        expect(inSheet(textShowing(_missing)), findsOneWidget);

        // A read in flight: more presses and a refocus start no second one.
        reader.result = const ClaudeConfigUnreadable();
        await tester.tap(inSheet(find.text('Check again')));
        await tester.pump();
        expect(reader.reads, 2);
        if (find.text('Check again').evaluate().isNotEmpty) {
          await tester.tap(find.text('Check again'));
          await tester.pump();
        }
        await rig.refocusApp();
        expect(reader.reads, 2, reason: 'never two reads at once');
        expect(reader.maxInFlight, 1);

        reader.holding = false;
        reader.release();
        await rig.settle();
        expect(inSheet(textShowing(_unreadable)), findsOneWidget);
        expect(reader.maxInFlight, 1);

        // Settled: each press is one more read.
        final settled = reader.reads;
        await rig.tap(inSheet(find.text('Check again')));
        expect(reader.reads, settled + 1);
        await rig.tap(inSheet(find.text('Check again')));
        expect(reader.reads, settled + 2);
        expect(reader.maxInFlight, 1);
      },
    );

    testWidgets(
      'switching tabs and back while a read is in flight starts no second read',
      (tester) async {
        final reader = HeldClaudeConfigReader(const ClaudeConfigMissing());
        final rig = await pumpConnect(
          tester,
          overrides: [claudeConfigReaderProvider.overrideWithValue(reader)],
        );
        expect(reader.reads, 1);

        await rig.showTab('tools');
        await rig.showTab('connect');
        expect(reader.reads, 1, reason: 'the new tab joins the pending read');
        expect(reader.maxInFlight, 1);
        expect(inSheet(textShowing(_missing)), findsNothing);

        reader.holding = false;
        reader.release();
        await rig.settle();
        expect(reader.reads, 1);
        expect(reader.maxInFlight, 1);
        expect(
          inSheet(textShowing(_missing)),
          findsOneWidget,
          reason: 'the remounted tab still gets the result',
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'closing and reopening the sheet while a read is in flight starts no second read',
      (tester) async {
        final reader = HeldClaudeConfigReader(const ClaudeConfigMissing());
        final rig = await pumpConnect(
          tester,
          overrides: [claudeConfigReaderProvider.overrideWithValue(reader)],
        );
        expect(reader.reads, 1);

        await rig.closeSheet();
        await rig.reopen();
        expect(reader.reads, 1, reason: 'the new sheet joins the pending read');
        expect(reader.maxInFlight, 1);

        reader.holding = false;
        reader.release();
        await rig.settle();
        expect(reader.maxInFlight, 1);
        expect(inSheet(textShowing(_missing)), findsOneWidget);
        expect(tester.takeException(), isNull);

        // The read is over: the next Connect shown reads again.
        await rig.showTab('tools');
        await rig.showTab('connect');
        expect(reader.reads, 2);
      },
    );

    testWidgets(
      'a read that throws shows the fixed line and the next press reads again',
      (tester) async {
        final reader = _Wi411FlakyReader(const ClaudeConfigMissing());
        final rig = await pumpConnect(
          tester,
          overrides: [claudeConfigReaderProvider.overrideWithValue(reader)],
        );
        expect(reader.reads, 1);
        expect(inSheet(textShowing(_unreadable)), findsOneWidget);
        expect(tester.takeException(), isNull);

        await rig.tap(inSheet(find.text('Check again')));
        expect(reader.reads, 2, reason: 'a failed read does not stick');
        expect(inSheet(textShowing(_missing)), findsOneWidget);
      },
    );
  });

  group('shared config reads', () {
    test(
      'a read asked for while one is in flight joins it and the next one starts fresh',
      () async {
        final reader = HeldClaudeConfigReader(const ClaudeConfigMissing());
        final reads = ClaudeConfigReads(reader);

        final first = reads.read();
        final second = reads.read();
        expect(reader.reads, 1);
        expect(identical(first, second), isTrue);

        reader.holding = false;
        reader.release();
        expect(await first, isA<ClaudeConfigMissing>());
        expect(await second, isA<ClaudeConfigMissing>());

        reader.result = const ClaudeConfigUnreadable();
        final third = await reads.read();
        expect(reader.reads, 2, reason: 'a finished read is not reused');
        expect(third, isA<ClaudeConfigUnreadable>());
        expect(reader.maxInFlight, 1);
      },
    );

    test('a failed read is passed on and the next one starts fresh', () async {
      final reader = _Wi411FlakyReader(const ClaudeConfigMissing());
      final reads = ClaudeConfigReads(reader);

      await expectLater(reads.read(), throwsA(isA<StateError>()));
      expect(await reads.read(), isA<ClaudeConfigMissing>());
      expect(reader.reads, 2);
    });
  });
}

/// A reader whose first read throws and whose later reads answer [result].
class _Wi411FlakyReader implements ClaudeConfigReader {
  _Wi411FlakyReader(this.result);

  final ClaudeConfigRead result;
  int reads = 0;

  @override
  Future<ClaudeConfigRead> read() async {
    reads++;
    if (reads == 1) throw StateError('boom');
    return result;
  }
}
