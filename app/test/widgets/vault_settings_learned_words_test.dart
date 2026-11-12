// WI #432 (Spec #392 req 17, 15b): the Learned words section of the vault
// settings dialog, below Smart Folder depth.
//
// - heading `Learned words`; the words in alphabetical order by `word_key`,
//   each with a remove button (Key `learned-word-remove-<word_key>`);
// - no words: `no learned words yet.`;
// - remove acts at once (not on Save) through
//   `learnedWordsActionsProvider.unlearn`: success removes the row, a failure
//   shows the dialog's InlineError with the error message and keeps the row;
// - two presses of one remove button in the same frame run one unlearn;
// - a hosted vault on an older server shows the empty state.
//
// Seams: FakeWordsAccess (scripted words, held and failing unlearns),
// FakeMemexCli (`settings get` for the depth field), FakeSpellingService,
// FakeVaultServer (hosted). Never a real `memex`.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/memex_cli.dart';
import 'package:open_memex_app/src/state/clock.dart';
import 'package:open_memex_app/src/state/hosted_connection_state.dart';
import 'package:open_memex_app/src/state/learned_words_seam.dart';
import 'package:open_memex_app/src/state/spelling_service.dart';
import 'package:open_memex_app/src/state/vault_access_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:open_memex_app/src/vault_access/errors.dart';
import 'package:open_memex_app/src/vault_access/hosted/hosted_client.dart';
import 'package:open_memex_app/src/vault_access/hosted/hosted_vault_access.dart';
import 'package:open_memex_app/src/theme/colors.dart';
import 'package:open_memex_app/src/theme/typography.dart';
import 'package:open_memex_app/src/vault_access/local/local_vault_access.dart';
import 'package:open_memex_app/src/widgets/inline_error.dart';
import 'package:open_memex_app/src/widgets/vault_settings_dialog.dart';

import '../support/fake_clock.dart';
import '../support/fake_memex_cli.dart';
import '../support/fake_spelling_service.dart';
import '../support/fake_vault_server.dart';
import '../support/fake_words_access.dart';
import '../support/font_fetch_hold.dart';

const _vault = LocalVaultRef('/tmp/om-432-dialog');
const _hosted = HostedVaultRef(fakeServerId, 'seed');
const _openKey = Key('wi432-open-vault-settings');

Finder get _dialog => find.byKey(const Key('vault-settings-dialog'));

Finder _inDialog(Finder f) => find.descendant(of: _dialog, matching: f);

Finder _remove(String wordKey) =>
    find.byKey(Key('learned-word-remove-$wordKey'));

Finder get _anyRemove => find.byWidgetPredicate(
  (w) =>
      w.key is ValueKey<String> &&
      (w.key! as ValueKey<String>).value.startsWith('learned-word-remove-'),
);

class _Wi432Dialog {
  _Wi432Dialog(this.words, this.cli, this.spelling);

  final FakeWordsAccess? words;
  final FakeMemexCli? cli;
  final FakeSpellingService spelling;
}

FakeMemexCli _settingsCli() => FakeMemexCli()
  ..on(
    'settings get',
    (_) => FakeMemexCli.ok(
      '{"vault_id":"v","key":"smart_folder_max_depth","value":2}\n',
    ),
  );

Widget _app(List<Override> overrides) => ProviderScope(
  overrides: overrides,
  child: MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          key: _openKey,
          onPressed: () => showVaultSettingsDialog(context),
          child: const Text('open'),
        ),
      ),
    ),
  ),
);

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.byKey(_openKey));
  await tester.pumpAndSettle();
  expect(_dialog, findsOneWidget);
}

/// The dialog on a local vault whose learned words are [words].
Future<_Wi432Dialog> _pumpLocal(
  WidgetTester tester, {
  required List<String> words,
  bool withCli = true,
  List<Override> extra = const [],
}) async {
  final fake = FakeWordsAccess(vaultPath: _vault.path)..script(words);
  final cli = withCli ? _settingsCli() : null;
  final spelling = FakeSpellingService();
  await tester.binding.setSurfaceSize(const Size(1000, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    _app([
      currentVaultProvider.overrideWith((_) => _vault),
      vaultDbProvider.overrideWithValue(null),
      memexCliProvider.overrideWithValue(cli),
      spellingServiceProvider.overrideWithValue(spelling),
      vaultAccessProvider.overrideWith(
        (ref) =>
            LocalVaultAccess(vaultPath: _vault.path, cli: cli, words: fake),
      ),
      ...extra,
    ]),
  );
  await tester.pumpAndSettle();
  await _open(tester);
  return _Wi432Dialog(fake, cli, spelling);
}

double _top(WidgetTester tester, Finder f) => tester.getTopLeft(f).dy;

void main() {
  holdFontFetches();

  testWidgets(
    'the vault settings dialog lists learned words alphabetically with a remove button each',
    (tester) async {
      await _pumpLocal(tester, words: ['memex', 'Zeta', 'apple', 'Émile']);

      expect(_inDialog(find.text('Learned words')), findsOneWidget);
      expect(
        _top(tester, _inDialog(find.text('Learned words'))),
        greaterThan(_top(tester, _inDialog(find.text('Smart Folder depth')))),
        reason: 'the section is below Smart Folder depth',
      );

      // word_key order: apple < memex < zeta < émile.
      const shown = ['apple', 'memex', 'Zeta', 'Émile'];
      const keys = ['apple', 'memex', 'zeta', 'émile'];
      for (var i = 0; i < shown.length; i++) {
        expect(
          _inDialog(find.text(shown[i])),
          findsOneWidget,
          reason: shown[i],
        );
        expect(_inDialog(_remove(keys[i])), findsOneWidget, reason: keys[i]);
      }
      expect(_anyRemove, findsNWidgets(4));
      for (var i = 1; i < shown.length; i++) {
        expect(
          _top(tester, find.text(shown[i])),
          greaterThan(_top(tester, find.text(shown[i - 1]))),
          reason: '${shown[i - 1]} is listed before ${shown[i]}',
        );
        expect(
          _top(tester, _remove(keys[i])),
          greaterThan(_top(tester, _remove(keys[i - 1]))),
          reason: 'remove ${keys[i - 1]} is above remove ${keys[i]}',
        );
      }
      expect(find.text('no learned words yet.'), findsNothing);
    },
  );

  testWidgets('with no learned words the dialog shows no learned words yet.', (
    tester,
  ) async {
    await _pumpLocal(tester, words: []);

    expect(_inDialog(find.text('Learned words')), findsOneWidget);
    expect(_inDialog(find.text('no learned words yet.')), findsOneWidget);
    expect(_anyRemove, findsNothing);
  });

  testWidgets(
    'removing a word in the dialog unlearns it at once and removes its row',
    (tester) async {
      final env = await _pumpLocal(tester, words: ['memex', 'teh']);

      await tester.tap(_remove('teh'));
      await tester.pumpAndSettle();

      expect(env.words!.unlearnCalls, ['teh']);
      expect(env.spelling.callsFor('unlearn').map((c) => c.args['word']), [
        'teh',
      ]);
      expect(_inDialog(find.text('teh')), findsNothing);
      expect(_remove('teh'), findsNothing);
      expect(_inDialog(find.text('memex')), findsOneWidget);
      expect(_remove('memex'), findsOneWidget);
      expect(_dialog, findsOneWidget, reason: 'remove does not close it');
      expect(
        env.cli!.callsFor('settings set'),
        isEmpty,
        reason: 'remove acts at once, not on Save',
      );
      expect(find.byType(InlineError), findsNothing);
    },
  );

  testWidgets('removing the last word shows no learned words yet.', (
    tester,
  ) async {
    await _pumpLocal(tester, words: ['teh']);

    await tester.tap(_remove('teh'));
    await tester.pumpAndSettle();

    expect(_anyRemove, findsNothing);
    expect(_inDialog(find.text('no learned words yet.')), findsOneWidget);
  });

  testWidgets(
    'a failed remove shows the InlineError with the error message and keeps the row',
    (tester) async {
      final env = await _pumpLocal(tester, words: ['memex', 'teh']);
      env.words!.unlearnError = MemexException(
        'words rm failed: the disk is full',
        code: 'internal',
      );

      await tester.tap(_remove('teh'));
      await tester.pumpAndSettle();

      expect(env.words!.unlearnCalls, ['teh']);
      expect(_inDialog(find.byType(InlineError)), findsOneWidget);
      expect(
        _inDialog(find.textContaining('the disk is full')),
        findsOneWidget,
      );
      expect(_inDialog(find.text('teh')), findsOneWidget);
      expect(_remove('teh'), findsOneWidget);
      expect(_remove('memex'), findsOneWidget);
      expect(env.spelling.count('unlearn'), 0);
      expect(_dialog, findsOneWidget);
    },
  );

  testWidgets(
    'two presses of one remove button in the same frame run one unlearn',
    (tester) async {
      final env = await _pumpLocal(tester, words: ['memex', 'teh']);
      env.words!.holdUnlearns = true;

      await tester.tap(_remove('teh'));
      await tester.tap(_remove('teh'));
      await tester.pump();

      env.words!.releaseUnlearns();
      await tester.pumpAndSettle();

      expect(env.words!.unlearnCalls, ['teh']);
      expect(env.spelling.count('unlearn'), 1);
      expect(_remove('teh'), findsNothing);
    },
  );

  testWidgets(
    'a hosted vault on an older server shows the empty learned words state',
    (tester) async {
      final server = FakeVaultServer()..serveDomain('compat');
      await tester.binding.setSurfaceSize(const Size(1000, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        _app([
          clockProvider.overrideWithValue(FakeClock()),
          utcOffsetProvider.overrideWithValue(() => Duration.zero),
          currentVaultProvider.overrideWith((_) => _hosted),
          vaultDbProvider.overrideWithValue(null),
          memexCliProvider.overrideWithValue(null),
          spellingServiceProvider.overrideWithValue(FakeSpellingService()),
          vaultAccessProvider.overrideWith(
            (ref) => HostedVaultAccess(
              client: HostedClient(
                ref,
                serverId: fakeServerId,
                serverName: fakeServerName,
                serverUrl: fakeServerUrl,
                accessToken: fakeServerToken,
                httpClient: server.client,
              ),
              vaultName: 'seed',
            ),
          ),
        ]),
      );
      await tester.pumpAndSettle();
      await _open(tester);

      expect(
        server.requests.where(
          (r) => r.method == 'GET' && r.url.path == '/vaults/seed/api/v1/words',
        ),
        isNotEmpty,
      );
      expect(_inDialog(find.text('Learned words')), findsOneWidget);
      expect(_inDialog(find.text('no learned words yet.')), findsOneWidget);
      expect(_anyRemove, findsNothing);
    },
  );

  group('contracts (verify)', () {
    testWidgets(
      'a remove the actions refuse without a message shows the fallback Could not remove text',
      (tester) async {
        final refuse = _RefusingActions();
        await _pumpLocal(
          tester,
          words: ['memex', 'teh'],
          extra: [learnedWordsActionsProvider.overrideWithValue(refuse)],
        );

        await tester.tap(_remove('teh'));
        await tester.pumpAndSettle();

        expect(refuse.unlearned, ['teh']);
        expect(_inDialog(find.byType(InlineError)), findsOneWidget);
        expect(_inDialog(find.text('Could not remove "teh".')), findsOneWidget);
        expect(_remove('teh'), findsOneWidget);
      },
    );

    testWidgets(
      'a remove with no memex CLI shows that the CLI is not available and keeps the row',
      (tester) async {
        final env = await _pumpLocal(tester, words: ['teh'], withCli: false);
        // The depth load already says it; dismiss it so the remove's own
        // error is the one on screen.
        await tester.tap(find.byKey(const Key('inline-error-dismiss')));
        await tester.pumpAndSettle();
        expect(find.byType(InlineError), findsNothing);

        await tester.tap(_remove('teh'));
        await tester.pumpAndSettle();

        expect(env.words!.unlearnCalls, isEmpty);
        expect(
          _inDialog(find.text('The memex CLI is not available.')),
          findsOneWidget,
        );
        expect(_remove('teh'), findsOneWidget);
        expect(env.spelling.count('unlearn'), 0);
      },
    );

    testWidgets(
      'a new remove clears the earlier error and a failed remove can be retried',
      (tester) async {
        final env = await _pumpLocal(tester, words: ['memex', 'teh']);
        env.words!.unlearnError = MemexException(
          'words rm failed: the disk is full',
        );
        await tester.tap(_remove('teh'));
        await tester.pumpAndSettle();
        expect(_inDialog(find.byType(InlineError)), findsOneWidget);

        env.words!
          ..unlearnError = null
          ..holdUnlearns = true;
        await tester.tap(_remove('teh'));
        await tester.pump();

        expect(
          find.byType(InlineError),
          findsNothing,
          reason: 'starting a remove clears the old error',
        );
        env.words!.releaseUnlearns();
        await tester.pumpAndSettle();

        expect(env.words!.unlearnCalls, ['teh', 'teh']);
        expect(_remove('teh'), findsNothing);
        expect(find.byType(InlineError), findsNothing);
      },
    );

    testWidgets('removing two different words at once runs both unlearns', (
      tester,
    ) async {
      final env = await _pumpLocal(tester, words: ['memex', 'teh']);
      env.words!.holdUnlearns = true;

      await tester.tap(_remove('teh'));
      await tester.tap(_remove('memex'));
      await tester.pump();
      env.words!.releaseUnlearns();
      await tester.pumpAndSettle();

      expect(env.words!.unlearnCalls, ['teh', 'memex']);
      expect(_inDialog(find.text('no learned words yet.')), findsOneWidget);
    });

    testWidgets('closing the dialog while a remove runs ends cleanly', (
      tester,
    ) async {
      final env = await _pumpLocal(tester, words: ['teh']);
      env.words!.holdUnlearns = true;

      await tester.tap(_remove('teh'));
      await tester.pump();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(_dialog, findsNothing);

      env.words!.releaseUnlearns();
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(env.words!.unlearnCalls, ['teh']);
      expect(env.spelling.count('unlearn'), 1);
    });

    testWidgets(
      'a word row is a mono fg0 word with an fg2 remove button named for the word',
      (tester) async {
        await _pumpLocal(tester, words: ['Émile']);

        final word = tester.widget<Text>(_inDialog(find.text('Émile')));
        expect(word.style?.color, OmColors.fg0);
        expect(word.style?.fontSize, 13);
        expect(word.style?.fontFamily, OmType.mono(size: 13).fontFamily);
        expect(word.overflow, TextOverflow.ellipsis);

        final remove = tester.widget<IconButton>(_remove('émile'));
        expect(remove.tooltip, 'Remove "Émile"');
        expect(remove.color, OmColors.fg2);
        expect(remove.iconSize, 16);
        expect(remove.onPressed, isNotNull);

        final heading = tester.widget<Text>(
          _inDialog(find.text('Learned words')),
        );
        expect(heading.style?.color, OmColors.fg0);
        expect(heading.style?.fontSize, 13);
      },
    );

    testWidgets('the empty state text is a 12px fg2 line', (tester) async {
      await _pumpLocal(tester, words: []);

      final empty = tester.widget<Text>(
        _inDialog(find.text('no learned words yet.')),
      );
      expect(empty.style?.color, OmColors.fg2);
      expect(empty.style?.fontSize, 12);
    });

    for (final (name, committed, copy) in [
      (
        'a remove that hits a hosted outage shows couldn\'t reach nas in the InlineError and keeps the row',
        false,
        "couldn't reach nas. try again.",
      ),
      (
        'a remove that may have committed shows couldn\'t confirm with nas in the InlineError and keeps the row',
        true,
        "couldn't confirm with nas — check before trying again",
      ),
    ]) {
      testWidgets(name, (tester) async {
        final env = await _pumpLocal(tester, words: ['memex', 'teh']);
        env.words!.unlearnError = VaultUnreachableException(
          serverName: 'nas',
          mayHaveCommitted: committed,
        );

        await tester.tap(_remove('teh'));
        await tester.pumpAndSettle();

        expect(_inDialog(find.byType(InlineError)), findsOneWidget);
        expect(_inDialog(find.text(copy)), findsOneWidget);
        expect(
          find.textContaining('VaultUnreachableException'),
          findsNothing,
          reason: 'never the exception debug string',
        );
        expect(_remove('teh'), findsOneWidget);
        expect(env.spelling.count('unlearn'), 0);
      });
    }

    testWidgets(
      'a hosted remove with the server refusing shows couldn\'t reach nas in the InlineError',
      (tester) async {
        final server = FakeVaultServer()
          ..route(
            'GET',
            '/vaults/seed/api/v1/words',
            json: {
              'vault_id': 'v',
              'words': [
                {'word': 'teh', 'created_at': 1},
              ],
            },
          );
        final spelling = FakeSpellingService();
        await tester.binding.setSurfaceSize(const Size(1000, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          _app([
            clockProvider.overrideWithValue(FakeClock()),
            utcOffsetProvider.overrideWithValue(() => Duration.zero),
            currentVaultProvider.overrideWith((_) => _hosted),
            vaultDbProvider.overrideWithValue(null),
            memexCliProvider.overrideWithValue(null),
            spellingServiceProvider.overrideWithValue(spelling),
            vaultAccessProvider.overrideWith(
              (ref) => HostedVaultAccess(
                client: HostedClient(
                  ref,
                  serverId: fakeServerId,
                  serverName: fakeServerName,
                  serverUrl: fakeServerUrl,
                  accessToken: fakeServerToken,
                  httpClient: server.client,
                ),
                vaultName: 'seed',
              ),
            ),
          ]),
        );
        await tester.pumpAndSettle();
        await _open(tester);
        expect(_remove('teh'), findsOneWidget);
        server.failure = FakeServerFailure.refused;

        await tester.tap(_remove('teh'));
        await tester.pumpAndSettle();

        expect(
          _inDialog(find.text("couldn't reach nas. try again.")),
          findsOneWidget,
        );
        expect(_remove('teh'), findsOneWidget);
        expect(spelling.count('unlearn'), 0);
      },
    );

    testWidgets(
      'on a short viewport the dialog scrolls instead of overflowing and Save stays reachable',
      (tester) async {
        final words = [for (var i = 0; i < 30; i++) 'w${'$i'.padLeft(2, '0')}'];
        final env = await _pumpLocal(tester, words: words);
        await tester.binding.setSurfaceSize(const Size(400, 300));
        await tester.pumpAndSettle();

        expect(
          tester.takeException(),
          isNull,
          reason: 'no RenderFlex overflow',
        );
        expect(_dialog, findsOneWidget);
        final scrollable = find
            .descendant(
              of: _dialog,
              matching: find.byType(SingleChildScrollView),
            )
            .first;
        final position = tester
            .state<ScrollableState>(
              find
                  .descendant(of: scrollable, matching: find.byType(Scrollable))
                  .first,
            )
            .position;
        expect(
          position.maxScrollExtent,
          greaterThan(0),
          reason: 'the content is taller than the viewport and scrolls',
        );
        expect(
          tester.getRect(find.byKey(const Key('vault-settings-save'))).bottom,
          lessThanOrEqualTo(300),
          reason: 'Save is on screen',
        );

        await tester.ensureVisible(_remove('w00'));
        await tester.pumpAndSettle();
        await tester.tap(_remove('w00'));
        await tester.pumpAndSettle();
        expect(env.words!.unlearnCalls, ['w00']);
      },
    );

    testWidgets(
      'a long list scrolls within 240px and every remove button is reachable',
      (tester) async {
        final words = [for (var i = 0; i < 30; i++) 'w${'$i'.padLeft(2, '0')}'];
        final env = await _pumpLocal(tester, words: words);

        final scroll = find
            .ancestor(
              of: _remove('w00'),
              matching: find.byType(SingleChildScrollView),
            )
            .first;
        expect(tester.getSize(scroll).height, 240);
        expect(
          tester.getRect(_remove('w29')).bottom,
          greaterThan(tester.getRect(scroll).bottom),
          reason: 'the last row starts below the 240px viewport',
        );

        await tester.scrollUntilVisible(
          _remove('w29'),
          100,
          scrollable: find
              .descendant(of: scroll, matching: find.byType(Scrollable))
              .first,
        );
        await tester.tap(_remove('w29'));
        await tester.pumpAndSettle();

        expect(env.words!.unlearnCalls, ['w29']);
        expect(_remove('w29'), findsNothing);
      },
    );
  });
}

/// Learned-words actions whose unlearn refuses, with no message.
class _RefusingActions implements LearnedWordsActions {
  final List<String> unlearned = [];

  @override
  Future<bool> learn(String word) async => false;

  @override
  Future<bool> unlearn(String word) async {
    unlearned.add(word);
    return false;
  }
}
