// WI #103 (orchestrator ruling): the switch confirm is wired into the app
// root through `appRootOverrides` in lib/main.dart, so state/ imports no
// widget and `leaveVaultGuardProvider` keeps its default-allow body. No test
// pumps through `main()` itself, so a source scan pins that main()'s root
// ProviderScope spreads the list, and widget tests pin what the list wires.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/main.dart';
import 'package:open_memex_app/src/state/unsent_hosted_text.dart';
import 'package:open_memex_app/src/state/vault_open_controller.dart';
import 'package:path/path.dart' as p;

/// [source] with `//` line comments and `/* */` block comments removed, so
/// a commented-out spread does not count.
String _wi103StripComments(String source) => source
    .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '')
    .replaceAll(RegExp(r'//[^\n]*'), '');

/// The text between the bracket at [open] and its matching close bracket.
String? _wi103Enclosed(String s, int open) {
  final opener = s[open];
  final closer = switch (opener) {
    '(' => ')',
    '[' => ']',
    '{' => '}',
    _ => null,
  };
  if (closer == null) return null;
  var depth = 0;
  for (var i = open; i < s.length; i++) {
    if (s[i] == opener) depth++;
    if (s[i] == closer && --depth == 0) return s.substring(open + 1, i);
  }
  return null;
}

/// The `overrides:` list of the ProviderScope that `main()` passes straight
/// to `runApp`, or null when main() runs no such scope.
String? _wi103RootScopeOverrides(String source) {
  final code = _wi103StripComments(source);
  final mainHead = RegExp(
    r'(?:^|\n)\s*(?:Future<void>|void)\s+main\s*\(\s*\)\s*(?:async\s*)?\{',
  ).firstMatch(code);
  if (mainHead == null) return null;
  final body = _wi103Enclosed(code, mainHead.end - 1);
  if (body == null) return null;
  final run = RegExp(r'\brunApp\s*\(\s*ProviderScope\s*\(').firstMatch(body);
  if (run == null) return null;
  final scopeArgs = _wi103Enclosed(body, run.end - 1);
  if (scopeArgs == null) return null;
  final overrides = RegExp(r'\boverrides\s*:\s*\[').firstMatch(scopeArgs);
  if (overrides == null) return null;
  return _wi103Enclosed(scopeArgs, overrides.end - 1);
}

bool _wi103SpreadsAppRootOverrides(String source) {
  final list = _wi103RootScopeOverrides(source);
  return list != null && RegExp(r'\.\.\.\s*appRootOverrides\b').hasMatch(list);
}

/// A screen with one button that asks [leaveVaultGuardProvider] and records
/// its answer in [answers].
Widget _wi103GuardProbe(List<Override> overrides, List<bool> answers) =>
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        home: Consumer(
          builder: (context, ref, _) => Scaffold(
            body: TextButton(
              key: const Key('wi103-ask-guard'),
              onPressed: () async =>
                  answers.add(await ref.read(leaveVaultGuardProvider)(context)),
              child: const Text('ask'),
            ),
          ),
        ),
      ),
    );

final _wi103Unsent = [
  hasUnsentHostedTextProvider.overrideWithValue(true),
  unsentHostedTextProvider.overrideWithValue(
    UnsentHostedText(
      serverName: 'studio',
      vaultName: 'notes',
      notes: [UnsentHostedNote(title: 'Draft', since: DateTime(2026, 10, 20))],
    ),
  ),
];

void main() {
  group('main root scope source scan', () {
    test('the root scope scan finds the appRootOverrides spread', () {
      const wired = '''
Future<void> main() async {
  final settings = await load();
  runApp(
    ProviderScope(
      overrides: [
        settingsProvider.overrideWith((_) => settings),
        ...appRootOverrides,
      ],
      child: const OpenMemexApp(),
    ),
  );
}
''';
      expect(_wi103SpreadsAppRootOverrides(wired), isTrue);
      expect(
        _wi103SpreadsAppRootOverrides(
          wired.replaceFirst('...appRootOverrides,', ''),
        ),
        isFalse,
        reason: 'the spread line dropped',
      );
      expect(
        _wi103SpreadsAppRootOverrides(
          wired.replaceFirst('...appRootOverrides,', '// ...appRootOverrides,'),
        ),
        isFalse,
        reason: 'the spread commented out',
      );
      expect(
        _wi103SpreadsAppRootOverrides('''
void main() {
  runApp(const ProviderScope(child: OpenMemexApp()));
}
final x = ProviderScope(overrides: [...appRootOverrides], child: y);
'''),
        isFalse,
        reason: 'a spread outside main() does not count',
      );
    });

    test('main runs the root ProviderScope with appRootOverrides', () {
      final source = File(p.join('lib', 'main.dart')).readAsStringSync();
      expect(
        _wi103RootScopeOverrides(source),
        isNotNull,
        reason: 'main() passes a ProviderScope with overrides to runApp',
      );
      expect(_wi103SpreadsAppRootOverrides(source), isTrue);
    });
  });

  group('appRootOverrides', () {
    testWidgets(
      'appRootOverrides makes the leave guard the switch confirm and switch anyway allows',
      (tester) async {
        final answers = <bool>[];
        await tester.pumpWidget(
          _wi103GuardProbe([...appRootOverrides, ..._wi103Unsent], answers),
        );

        await tester.tap(find.byKey(const Key('wi103-ask-guard')));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('leave-confirm')), findsOneWidget);
        expect(find.text('switch anyway'), findsOneWidget);
        expect(answers, isEmpty, reason: 'the guard waits for the person');

        await tester.tap(find.byKey(const Key('leave-confirm-proceed')));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('leave-confirm')), findsNothing);
        expect(answers, [true]);
      },
    );

    testWidgets(
      'appRootOverrides leave guard answers false on cancel of the switch confirm',
      (tester) async {
        final answers = <bool>[];
        await tester.pumpWidget(
          _wi103GuardProbe([...appRootOverrides, ..._wi103Unsent], answers),
        );

        await tester.tap(find.byKey(const Key('wi103-ask-guard')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('leave-confirm-cancel')));
        await tester.pumpAndSettle();

        expect(answers, [false]);
      },
    );

    testWidgets(
      'appRootOverrides leave guard allows at once with no unsent hosted text',
      (tester) async {
        final answers = <bool>[];
        await tester.pumpWidget(
          _wi103GuardProbe([...appRootOverrides], answers),
        );

        await tester.tap(find.byKey(const Key('wi103-ask-guard')));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('leave-confirm')), findsNothing);
        expect(answers, [true]);
      },
    );

    testWidgets(
      'with no override the leave guard allows at once even with unsent hosted text',
      (tester) async {
        final answers = <bool>[];
        await tester.pumpWidget(_wi103GuardProbe([..._wi103Unsent], answers));

        await tester.tap(find.byKey(const Key('wi103-ask-guard')));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('leave-confirm')), findsNothing);
        expect(answers, [true]);
      },
    );
  });
}
