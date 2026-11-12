// WI #434 (Spec #392 req 12, 19; D24): `spellingMenuSyncProvider`. It sends
// `setMenuState` once at launch with the stored settings and once per
// change, applies native `menuToggle`s (grammar only while spelling is on),
// and calls `closeDocumentTags` whenever a vault is closed or switched away
// from, never when an editor is disposed. The app attaches it with one line.
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/settings.dart';
import 'package:open_memex_app/src/state/spelling_menu_sync.dart';
import 'package:open_memex_app/src/state/spelling_service.dart';
import 'package:open_memex_app/src/state/tabs_state.dart';
import 'package:open_memex_app/src/state/vault_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../robots/segmented_editor_robot.dart';
import '../support/app_harness.dart';
import '../support/fake_spelling_service.dart';
import '../support/font_fetch_hold.dart';
import '../support/spelling_editor_pump.dart';
import '../support/token_store_fakes.dart';

const _vaultA = LocalVaultRef('/Users/test/vaults/alpha');
const _vaultB = LocalVaultRef('/Users/test/vaults/bravo');
const _hosted = HostedVaultRef('srv-1', 'charlie');

/// The menu sync attached to a container with [prefs] stored and [vault]
/// open, over a fresh [FakeSpellingService].
typedef _Wi434Sync = ({
  ProviderContainer container,
  FakeSpellingService spelling,
  SettingsController settings,
});

Future<_Wi434Sync> _attach({
  Map<String, Object> prefs = const {},
  VaultRef? vault,
}) async {
  SharedPreferences.setMockInitialValues(prefs);
  final settings = await loadSettingsKeepingPickedBinary();
  final fake = FakeSpellingService();
  final c = ProviderContainer(
    overrides: [
      settingsProvider.overrideWith((_) => settings),
      spellingServiceProvider.overrideWithValue(fake),
    ],
  );
  addTearDown(c.dispose);
  if (vault != null) c.read(currentVaultProvider.notifier).state = vault;
  c.read(spellingMenuSyncProvider);
  await pumpEventQueue();
  return (container: c, spelling: fake, settings: settings);
}

void _setVault(ProviderContainer c, VaultRef? v) =>
    c.read(currentVaultProvider.notifier).state = v;

void main() {
  holdFontFetches();

  group('setMenuState (AC3)', () {
    test(
      'setMenuState goes to the channel once at launch with the stored values',
      () async {
        final s = await _attach(prefs: {'memex.check_spelling': false});
        expect(s.spelling.count('setMenuState'), 1);
        expect(s.spelling.lastMenuState, (
          checkSpelling: false,
          checkGrammar: true,
        ));
      },
    );

    test(
      'setMenuState goes to the channel once after each spelling setting change',
      () async {
        final s = await _attach();
        expect(s.spelling.count('setMenuState'), 1);
        expect(s.spelling.lastMenuState, (
          checkSpelling: true,
          checkGrammar: true,
        ));

        await s.settings.setCheckGrammar(false);
        await pumpEventQueue();
        expect(s.spelling.count('setMenuState'), 2);
        expect(s.spelling.lastMenuState, (
          checkSpelling: true,
          checkGrammar: false,
        ));

        await s.settings.setCheckSpelling(false);
        await pumpEventQueue();
        expect(s.spelling.count('setMenuState'), 3);
        expect(s.spelling.lastMenuState, (
          checkSpelling: false,
          checkGrammar: false,
        ));

        await s.settings.setCheckSpelling(true);
        await pumpEventQueue();
        expect(s.spelling.count('setMenuState'), 4);
        expect(s.spelling.lastMenuState, (
          checkSpelling: true,
          checkGrammar: false,
        ));
      },
    );

    test(
      'with spelling off setMenuState sends the stored grammar value',
      () async {
        final s = await _attach();
        await s.settings.setCheckSpelling(false);
        await pumpEventQueue();
        expect(s.spelling.lastMenuState, (
          checkSpelling: false,
          checkGrammar: true,
        ));
      },
    );

    test('an unrelated settings change sends no setMenuState', () async {
      final s = await _attach();
      expect(s.spelling.count('setMenuState'), 1);
      await s.settings.rememberVault('/Users/test/vaults/alpha');
      await s.settings.setMemexBinary('/usr/local/bin/memex');
      await pumpEventQueue();
      expect(s.spelling.count('setMenuState'), 1);
    });

    test('reading the menu sync again sends no second setMenuState', () async {
      final s = await _attach();
      s.container.read(spellingMenuSyncProvider);
      await pumpEventQueue();
      expect(s.spelling.count('setMenuState'), 1);
    });
  });

  group('native menuToggle (AC4)', () {
    test(
      'a native menuToggle with checkSpelling flips and persists checkSpelling and resends setMenuState',
      () async {
        final s = await _attach();
        s.spelling.emitMenuToggle(SpellingMenuItem.checkSpelling);
        await pumpEventQueue();
        expect(s.settings.state.checkSpelling, isFalse);
        expect(s.settings.state.checkGrammar, isTrue);
        expect(s.spelling.count('setMenuState'), 2);
        expect(s.spelling.lastMenuState, (
          checkSpelling: false,
          checkGrammar: true,
        ));
        expect((await relaunchSettings()).state.checkSpelling, isFalse);

        s.spelling.emitMenuToggle(SpellingMenuItem.checkSpelling);
        await pumpEventQueue();
        expect(s.settings.state.checkSpelling, isTrue);
        expect(s.spelling.count('setMenuState'), 3);
        expect(s.spelling.lastMenuState, (
          checkSpelling: true,
          checkGrammar: true,
        ));
      },
    );

    test(
      'menuToggle with checkGrammar while spelling is off changes nothing',
      () async {
        final s = await _attach(prefs: {'memex.check_spelling': false});
        expect(s.spelling.count('setMenuState'), 1);
        s.spelling.emitMenuToggle(SpellingMenuItem.checkGrammar);
        await pumpEventQueue();
        expect(s.settings.state.checkSpelling, isFalse);
        expect(s.settings.state.checkGrammar, isTrue);
        expect(s.spelling.count('setMenuState'), 1);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getBool('memex.check_grammar') ?? true, isTrue);
        expect((await relaunchSettings()).state.checkGrammar, isTrue);
      },
    );

    test(
      'menuToggle with checkGrammar while spelling is on flips and persists checkGrammar',
      () async {
        final s = await _attach();
        s.spelling.emitMenuToggle(SpellingMenuItem.checkGrammar);
        await pumpEventQueue();
        expect(s.settings.state.checkGrammar, isFalse);
        expect(s.settings.state.checkSpelling, isTrue);
        expect(s.spelling.count('setMenuState'), 2);
        expect(s.spelling.lastMenuState, (
          checkSpelling: true,
          checkGrammar: false,
        ));
        expect((await relaunchSettings()).state.checkGrammar, isFalse);

        s.spelling.emitMenuToggle(SpellingMenuItem.checkGrammar);
        await pumpEventQueue();
        expect(s.settings.state.checkGrammar, isTrue);
        expect(s.spelling.count('setMenuState'), 3);
      },
    );

    test('the grammar toggle works again once spelling is back on', () async {
      final s = await _attach(prefs: {'memex.check_spelling': false});
      s.spelling.emitMenuToggle(SpellingMenuItem.checkGrammar);
      await pumpEventQueue();
      expect(s.settings.state.checkGrammar, isTrue);
      s.spelling.emitMenuToggle(SpellingMenuItem.checkSpelling);
      await pumpEventQueue();
      s.spelling.emitMenuToggle(SpellingMenuItem.checkGrammar);
      await pumpEventQueue();
      expect(s.settings.state.checkSpelling, isTrue);
      expect(s.settings.state.checkGrammar, isFalse);
    });

    test(
      'the menu sync stops listening when its container is disposed',
      () async {
        final s = await _attach();
        expect(s.spelling.count('setMenuState'), 1);
        s.container.dispose();
        // A live subscription would reach the disposed container and throw
        // in the test zone, or write the flipped flag.
        s.spelling.emitMenuToggle(SpellingMenuItem.checkSpelling);
        await pumpEventQueue();
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getBool('memex.check_spelling'), isNull);
        expect(s.spelling.count('setMenuState'), 1);
      },
    );
  });

  group('vault hooks (AC10)', () {
    test(
      'closing the vault calls closeDocumentTags once and opening one calls it zero times',
      () async {
        final s = await _attach(vault: _vaultA);
        expect(s.spelling.count('closeDocumentTags'), 0);
        _setVault(s.container, null);
        await pumpEventQueue();
        expect(s.spelling.count('closeDocumentTags'), 1);
        _setVault(s.container, _vaultB);
        await pumpEventQueue();
        expect(s.spelling.count('closeDocumentTags'), 1);
      },
    );

    test(
      'switching from vault A to vault B calls closeDocumentTags once',
      () async {
        final s = await _attach(vault: _vaultA);
        _setVault(s.container, _vaultB);
        await pumpEventQueue();
        expect(s.spelling.count('closeDocumentTags'), 1);
        _setVault(s.container, _hosted);
        await pumpEventQueue();
        expect(s.spelling.count('closeDocumentTags'), 2);
      },
    );

    test(
      'a vault opened after launch with none open calls no closeDocumentTags until it closes',
      () async {
        final s = await _attach();
        _setVault(s.container, _vaultA);
        await pumpEventQueue();
        expect(s.spelling.count('closeDocumentTags'), 0);
        _setVault(s.container, null);
        await pumpEventQueue();
        expect(s.spelling.count('closeDocumentTags'), 1);
      },
    );

    test('the vault hooks send no setMenuState', () async {
      final s = await _attach(vault: _vaultA);
      _setVault(s.container, _vaultB);
      _setVault(s.container, null);
      await pumpEventQueue();
      expect(s.spelling.count('closeDocumentTags'), 2);
      expect(s.spelling.count('setMenuState'), 1);
    });
  });

  group('app attach (AC3, AC10)', () {
    testWidgets(
      'the app attaches the menu sync so launch sends setMenuState once and a native toggle reaches the settings',
      (tester) async {
        final fake = FakeSpellingService();
        final h = await pumpWorkspace(
          tester,
          overrides: [spellingServiceProvider.overrideWithValue(fake)],
        );
        expect(fake.count('setMenuState'), 1);
        expect(fake.lastMenuState, (checkSpelling: true, checkGrammar: true));

        fake.emitMenuToggle(SpellingMenuItem.checkSpelling);
        await pumpFrames(tester);
        expect(h.read(settingsProvider).checkSpelling, isFalse);
        expect(fake.count('setMenuState'), 2);
        expect(fake.count('closeDocumentTags'), 0);
      },
    );

    testWidgets(
      'disposing an editor by a Source mode toggle or a tab switch calls closeDocumentTags zero times and closing the vault calls it once',
      (tester) async {
        final e = await pumpSpellingEditor(tester, body: 'Intro line\n');
        expect(e.textSegment(0), findsOneWidget);

        await e.toggleSource();
        expect(e.sourceSurface, findsOneWidget);
        await e.toggleSource();
        expect(e.sourceSurface, findsNothing);

        await e.robot.open(fixtureZetaId);
        e.robot.expectActiveNote(fixtureZetaId);
        e.container.read(tabsProvider.notifier).close(NoteTab(fixtureZetaId));
        await pumpFrames(tester);
        await e.robot.open(spellingNoteId);
        e.robot.expectActiveNote(spellingNoteId);

        expect(e.spelling.count('closeDocumentTags'), 0);
        expect(e.spelling.count('setMenuState'), 1);

        e.container.read(currentVaultProvider.notifier).state = null;
        await pumpFrames(tester);
        expect(e.spelling.count('closeDocumentTags'), 1);
      },
    );
  });

  group('native error reply (review r1)', () {
    test(
      'native errors on setMenuState and closeDocumentTags raise no uncaught error',
      () async {
        // The real service over a channel that answers every call with a
        // native FlutterError (a PlatformException in Dart). The sync fires
        // both calls without awaiting, so an escaping error would reach the
        // test zone and fail this test.
        const channel = MethodChannel(spellingChannelName);
        final calls = <String>[];
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          throw PlatformException(code: 'bad_arguments', message: 'nope');
        });
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

        SharedPreferences.setMockInitialValues({});
        final settings = await loadSettingsKeepingPickedBinary();
        final c = ProviderContainer(
          overrides: [settingsProvider.overrideWith((_) => settings)],
        );
        addTearDown(c.dispose);
        c.read(currentVaultProvider.notifier).state = _vaultA;
        c.read(spellingMenuSyncProvider);
        await pumpEventQueue();
        await settings.setCheckSpelling(false);
        await pumpEventQueue();
        c.read(currentVaultProvider.notifier).state = null;
        await pumpEventQueue();

        expect(calls, ['setMenuState', 'setMenuState', 'closeDocumentTags']);
        expect(c.read(spellingServiceProvider).available, isTrue);
      },
    );
  });
}
