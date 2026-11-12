// WI #411 (Spec #394 req 26-27, Testing Strategy "sentinel-token test"): a
// hosted vault's access token never leaves the Connect tab's State. Across
// open, reveal, hide, copy and close, a sentinel token appears in no
// provider's state (or its family argument), no Semantics label, value or
// hint, no State's toString, no log line (print or debugPrint), no error
// and no SharedPreferences entry. Only the copies themselves (through
// `copySensitive`) and the revealed row and snippets on screen carry it.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/agents_sheet/connect/snippets.dart';
import 'package:open_memex_app/src/agents_sheet/connect/token_text.dart';
import 'package:open_memex_app/src/widgets/agents_sheet/connect_tab.dart';

import '../../support/connect_tab_rig.dart';
import '../../support/font_fetch_hold.dart';
import '../../support/token_store_fakes.dart';

const _sentinel = 'SENTINEL411-k3Xq-Vb7Lw2Np9Rt-c0de';

/// The part of the sentinel the mask never shows (all but its last 4).
const _secretPart = 'SENTINEL411-k3Xq-Vb7Lw2Np9Rt';

bool _leaks(Object? value, [int depth = 0]) {
  if (value == null || depth > 6) return false;
  if (value is String) return value.contains(_secretPart);
  if (value is Iterable) return value.any((v) => _leaks(v, depth + 1));
  if (value is Map) {
    return value.entries.any(
      (e) => _leaks(e.key, depth + 1) || _leaks(e.value, depth + 1),
    );
  }
  if (value is AsyncValue) {
    return _leaks(value.valueOrNull, depth + 1) ||
        _leaks(value.error, depth + 1) ||
        '$value'.contains(_secretPart);
  }
  return '$value'.contains(_secretPart);
}

/// Every place the sentinel must never be, as `where: what` lines.
List<String> _leaksNow(WidgetTester tester, ProviderContainer container) {
  final out = <String>[];
  for (final element in container.getAllProviderElements()) {
    final provider = element.origin;
    if (_leaks('$provider') || _leaks(provider.argument)) {
      out.add('provider id: $provider');
    }
    Object? state;
    try {
      state = element.readSelf();
    } catch (e) {
      state = e;
    }
    if (_leaks(state)) out.add('provider state: $provider');
  }

  for (final node in find.semantics.byPredicate((_) => true).evaluate()) {
    final d = node.getSemanticsData();
    for (final (field, text) in [
      ('label', d.label),
      ('value', d.value),
      ('hint', d.hint),
      ('tooltip', d.tooltip),
      ('increasedValue', d.increasedValue),
      ('decreasedValue', d.decreasedValue),
    ]) {
      if (text.contains(_secretPart)) out.add('semantics $field: ${node.id}');
    }
  }

  for (final e
      in find.byWidgetPredicate((w) => w is StatefulWidget).evaluate()) {
    if (e is StatefulElement && '${e.state}'.contains(_secretPart)) {
      out.add('State.toString: ${e.state.runtimeType}');
    }
  }
  return out;
}

void main() {
  holdFontFetches();

  testWidgets(
    'the sentinel token appears in no provider state Semantics label log or error across open reveal hide copy and close',
    (tester) async {
      final logs = <String>[];
      final errors = <String>[];
      final oldDebugPrint = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        logs.add(message ?? '');
      };
      final oldOnError = FlutterError.onError;
      FlutterError.onError = (details) {
        errors.add('${details.exception}\n${details.stack}');
        oldOnError?.call(details);
      };
      final steps = <String, List<String>>{};
      try {
        await runZoned(
          () async {
            final rig = await pumpConnect(
              tester,
              vault: agentsSheetHostedVault,
              tokens: {agentsSheetServer.id: _sentinel},
            );
            void check(String step) =>
                steps[step] = _leaksNow(tester, rig.container);

            // Open: the mask only.
            expect(
              inSheet(textShowing(maskToken(_sentinel))),
              findsOneWidget,
              reason: 'the token row is masked',
            );
            expect(find.byType(ConnectTab), findsOneWidget);
            check('open');

            // Reveal: the real token on screen, in this tab's State only.
            await rig.tap(inSheet(find.text('Reveal')));
            expect(inSheet(textShowing(_sentinel)), findsOneWidget);
            expect(
              codeBlockText(tester, copyDesktopConfigLabel),
              hostedClaudeDesktopEntry(
                memexPath: connectMemexPath,
                vaultName: 'studio',
                mcpAddress: connectMcpAddress,
                token: RealTokenText(_sentinel),
              ),
            );
            check('revealed');

            await rig.chooseClient('Claude Code');
            expect(textContaining(_secretPart), findsWidgets);
            check('revealed Claude Code');

            // Hide.
            await rig.tap(inSheet(find.text('Hide')));
            expect(textContaining(_secretPart), findsNothing);
            check('hidden');

            // Copy each token-bearing value.
            await rig.copy(copyAccessTokenLabel);
            await rig.copy(copyCodeCommandLabel);
            await rig.chooseClient('Claude Desktop');
            await rig.copy(copyDesktopConfigLabel);
            expect(rig.sensitive, hasLength(3));
            expect(rig.sensitive.every((s) => s.contains(_sentinel)), isTrue);
            expect(textContaining(_secretPart), findsNothing);
            check('copied');
            rig.harness.clock.advance(const Duration(seconds: 3));
            await rig.settle();
            check('copied state over');

            // Reveal, then close with it revealed.
            await rig.tap(inSheet(find.text('Reveal')));
            expect(inSheet(textShowing(_sentinel)), findsOneWidget);
            await rig.closeSheet();
            expect(textContaining(_secretPart), findsNothing);
            check('closed');

            await rig.reopen();
            expect(inSheet(textShowing(maskToken(_sentinel))), findsOneWidget);
            check('reopened');

            expect(await prefsEntriesContaining(_secretPart), isEmpty);
            expect(
              rig.harness.tokens.calls.where((c) => c.contains(_secretPart)),
              isEmpty,
            );
            expect(tester.takeException(), isNull);
          },
          zoneSpecification: ZoneSpecification(
            print: (self, parent, zone, line) => logs.add(line),
          ),
        );
      } finally {
        debugPrint = oldDebugPrint;
        FlutterError.onError = oldOnError;
      }

      expect(steps.keys, [
        'open',
        'revealed',
        'revealed Claude Code',
        'hidden',
        'copied',
        'copied state over',
        'closed',
        'reopened',
      ]);
      for (final MapEntry(key: step, value: found) in steps.entries) {
        expect(found, isEmpty, reason: 'after $step');
      }
      expect(logs.where((l) => l.contains(_secretPart)), isEmpty);
      expect(errors.where((l) => l.contains(_secretPart)), isEmpty);
      expect(errors, isEmpty);
    },
  );
}
