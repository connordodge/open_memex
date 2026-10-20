// WI #70 (W0a) AC8–AC10: guardVaultWrite and the two L17 snackbars (Req 50,
// Req 33; design pack 70: A11 state 4 snackbar).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/theme/app_theme.dart';
import 'package:open_memex_app/src/vault_access/errors.dart';

const _reachNas = "couldn't reach nas. try again.";
const _confirmNas = "couldn't confirm with nas — check before trying again";

/// Pumps a scaffold and returns a context under its ScaffoldMessenger.
Future<BuildContext> _pumpHost(WidgetTester tester) async {
  late BuildContext captured;
  await tester.pumpWidget(
    MaterialApp(
      theme: buildOmTheme(),
      home: Scaffold(
        body: Builder(
          builder: (context) {
            captured = context;
            return const SizedBox.expand();
          },
        ),
      ),
    ),
  );
  return captured;
}

void main() {
  testWidgets(
    'guardVaultWrite on an unreachable server shows couldnt reach and calls the write once',
    (tester) async {
      final context = await _pumpHost(tester);
      var calls = 0;

      final result = await guardVaultWrite<int>(context, () async {
        calls++;
        throw const VaultUnreachableException(
          serverName: 'nas',
          mayHaveCommitted: false,
        );
      });
      await tester.pump();

      expect(result, isNull);
      expect(calls, 1, reason: 'writes are never retried');
      expect(find.text(_reachNas), findsOneWidget);
      expect(find.text(_confirmNas), findsNothing);
      final bar = tester.widget<SnackBar>(find.byType(SnackBar));
      expect(bar.action, isNull, reason: 'the board snackbar has no action');
      expect(
        bar.padding,
        const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        reason: 'design pack 70: snackbar padding 10 vertical, 14 horizontal',
      );
    },
  );

  testWidgets('guardVaultWrite names the server from the exception', (
    tester,
  ) async {
    final context = await _pumpHost(tester);

    await guardVaultWrite<void>(context, () async {
      throw const VaultUnreachableException(
        serverName: 'studio-mac',
        mayHaveCommitted: false,
      );
    });
    await tester.pump();

    expect(find.text("couldn't reach studio-mac. try again."), findsOneWidget);
  });

  testWidgets(
    'guardVaultWrite when the write may have committed shows couldnt confirm',
    (tester) async {
      final context = await _pumpHost(tester);
      var calls = 0;

      final result = await guardVaultWrite<String>(context, () async {
        calls++;
        throw const VaultUnreachableException(
          serverName: 'nas',
          mayHaveCommitted: true,
        );
      });
      await tester.pump();

      expect(result, isNull);
      expect(calls, 1);
      expect(find.text(_confirmNas), findsOneWidget);
      expect(find.text(_reachNas), findsNothing);
    },
  );

  testWidgets(
    'guardVaultWrite shows couldnt confirm after the write unmounts the calling context',
    (tester) async {
      final showEditor = ValueNotifier(true);
      addTearDown(showEditor.dispose);
      late BuildContext editorContext;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildOmTheme(),
          home: Scaffold(
            body: ValueListenableBuilder<bool>(
              valueListenable: showEditor,
              builder: (context, show, _) => show
                  ? Builder(
                      builder: (context) {
                        editorContext = context;
                        return const Text('editor');
                      },
                    )
                  : const Text('list'),
            ),
          ),
        ),
      );
      var calls = 0;

      final result = await guardVaultWrite<String>(editorContext, () async {
        calls++;
        // The write replaces the Scaffold body (e.g. the editor closes),
        // unmounting the context guardVaultWrite was given.
        showEditor.value = false;
        await tester.pump();
        expect(editorContext.mounted, isFalse);
        throw const VaultUnreachableException(
          serverName: 'nas',
          mayHaveCommitted: true,
        );
      });
      await tester.pump();

      expect(result, isNull);
      expect(calls, 1);
      expect(find.text('list'), findsOneWidget);
      expect(find.text(_confirmNas), findsOneWidget);
    },
  );

  testWidgets(
    'guardVaultWrite returns a successful write result with no snackbar',
    (tester) async {
      final context = await _pumpHost(tester);
      var calls = 0;

      final result = await guardVaultWrite<int>(context, () async {
        calls++;
        return 42;
      });
      await tester.pump();

      expect(result, 42);
      expect(calls, 1);
      expect(find.byType(SnackBar), findsNothing);
    },
  );

  testWidgets(
    'guardVaultWrite rethrows a MemexException unchanged with no snackbar',
    (tester) async {
      final context = await _pumpHost(tester);
      final error = MemexException(
        'update failed: version conflict',
        kind: MemexErrorKind.versionConflict,
        code: 'version_conflict',
        fields: const {'expected': 3, 'current': 4},
      );
      var calls = 0;

      Object? caught;
      try {
        await guardVaultWrite<int>(context, () async {
          calls++;
          throw error;
        });
      } catch (e) {
        caught = e;
      }
      await tester.pump();

      expect(caught, same(error));
      expect(calls, 1);
      expect(find.byType(SnackBar), findsNothing);
    },
  );

  testWidgets('guardVaultWrite rethrows other errors unchanged', (
    tester,
  ) async {
    final context = await _pumpHost(tester);
    final error = StateError('no CLI');

    Object? caught;
    try {
      await guardVaultWrite<int>(context, () async => throw error);
    } catch (e) {
      caught = e;
    }
    await tester.pump();

    expect(caught, same(error));
    expect(find.byType(SnackBar), findsNothing);
  });

  test(
    'VaultUnreachableException carries the server name and mayHaveCommitted',
    () {
      // Built from run-time values so the constructor itself runs.
      final name = ['n', 'a', 's'].join();
      final committed = name.length > 2;
      final e = VaultUnreachableException(
        serverName: name,
        mayHaveCommitted: committed,
      );

      expect(e, isA<Exception>());
      expect(e.serverName, 'nas');
      expect(e.mayHaveCommitted, isTrue);
      expect(e.toString(), isNot(contains('token')));
    },
  );
}
