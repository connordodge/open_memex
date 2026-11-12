// WI #434 (Spec #392 req 19): the app-wide spelling settings. `checkSpelling`
// and `checkGrammar` default on, persist under `memex.check_spelling` and
// `memex.check_grammar`, and grammar takes effect only while spelling is on
// (`spellCheckFlagsProvider`), while `checkGrammar` keeps its stored value.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_memex_app/src/state/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/token_store_fakes.dart';

/// A container whose settings are [settings].
ProviderContainer _container(SettingsController settings) {
  final c = ProviderContainer(
    overrides: [settingsProvider.overrideWith((_) => settings)],
  );
  addTearDown(c.dispose);
  return c;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('stored flags (AC1)', () {
    test(
      'fresh preferences turn spelling and grammar on and each setter persists across a reload',
      () async {
        final settings = await loadSettingsKeepingPickedBinary();
        expect(settings.state.checkSpelling, isTrue);
        expect(settings.state.checkGrammar, isTrue);

        await settings.setCheckSpelling(false);
        expect(settings.state.checkSpelling, isFalse);
        expect(settings.state.checkGrammar, isTrue);
        await settings.setCheckGrammar(false);
        expect(settings.state.checkGrammar, isFalse);

        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getBool('memex.check_spelling'), isFalse);
        expect(prefs.getBool('memex.check_grammar'), isFalse);

        final reloaded = await relaunchSettings();
        expect(reloaded.state.checkSpelling, isFalse);
        expect(reloaded.state.checkGrammar, isFalse);

        await reloaded.setCheckSpelling(true);
        await reloaded.setCheckGrammar(true);
        final again = await relaunchSettings();
        expect(again.state.checkSpelling, isTrue);
        expect(again.state.checkGrammar, isTrue);
      },
    );

    test('a stored false check_spelling loads as spelling off', () async {
      SharedPreferences.setMockInitialValues({'memex.check_spelling': false});
      final settings = await loadSettingsKeepingPickedBinary();
      expect(settings.state.checkSpelling, isFalse);
      expect(settings.state.checkGrammar, isTrue);
    });

    test('a stored false check_grammar loads as grammar off', () async {
      SharedPreferences.setMockInitialValues({'memex.check_grammar': false});
      final settings = await loadSettingsKeepingPickedBinary();
      expect(settings.state.checkSpelling, isTrue);
      expect(settings.state.checkGrammar, isFalse);
    });

    test(
      'a stored value of the wrong type loads as on without throwing',
      () async {
        SharedPreferences.setMockInitialValues({
          'memex.check_spelling': 'no',
          'memex.check_grammar': 0,
        });
        final settings = await loadSettingsKeepingPickedBinary();
        expect(settings.state.checkSpelling, isTrue);
        expect(settings.state.checkGrammar, isTrue);
      },
    );

    test(
      'the spelling setters keep every other setting and an unrelated setter keeps the spelling flags',
      () async {
        SharedPreferences.setMockInitialValues({
          'memex.binary_path': 'fake-memex',
        });
        final settings = await loadSettingsKeepingPickedBinary();
        await settings.rememberVault('/Users/test/vaults/alpha');
        await settings.setCheckSpelling(false);
        await settings.setCheckGrammar(false);
        expect(settings.state.memexBinaryPath, 'fake-memex');
        expect(settings.state.recentVaults, ['/Users/test/vaults/alpha']);
        expect(settings.state.lastVault, '/Users/test/vaults/alpha');

        await settings.rememberVault('/Users/test/vaults/bravo');
        expect(settings.state.checkSpelling, isFalse);
        expect(settings.state.checkGrammar, isFalse);
      },
    );

    test(
      'AppSettings built from run-time values carries both flags through copyWith',
      () {
        final values = [for (final s in 'tf'.split('')) s == 't'];
        for (final spelling in values) {
          for (final grammar in values) {
            final s = AppSettings(
              memexBinaryPath: null,
              checkSpelling: spelling,
              checkGrammar: grammar,
            );
            expect(s.checkSpelling, spelling);
            expect(s.checkGrammar, grammar);
            final kept = s.copyWith(memexBinaryPath: 'x');
            expect(kept.checkSpelling, spelling);
            expect(kept.checkGrammar, grammar);
            final flipped = s.copyWith(
              checkSpelling: !spelling,
              checkGrammar: !grammar,
            );
            expect(flipped.checkSpelling, !spelling);
            expect(flipped.checkGrammar, !grammar);
          }
        }
        final defaults = AppSettings(memexBinaryPath: null);
        expect(defaults.checkSpelling, isTrue);
        expect(defaults.checkGrammar, isTrue);
      },
    );
  });

  group('effective flags (AC2)', () {
    test(
      'with spelling off the effective grammar flag is false while the stored grammar stays true and turning spelling on restores it',
      () async {
        final settings = await loadSettingsKeepingPickedBinary();
        final c = _container(settings);
        expect(c.read(spellCheckFlagsProvider), (
          spelling: true,
          grammar: true,
        ));

        await settings.setCheckSpelling(false);
        expect(c.read(spellCheckFlagsProvider), (
          spelling: false,
          grammar: false,
        ));
        expect(settings.state.checkGrammar, isTrue);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getBool('memex.check_grammar') ?? true, isTrue);

        final reloaded = await relaunchSettings();
        expect(reloaded.state.checkSpelling, isFalse);
        expect(reloaded.state.checkGrammar, isTrue);

        await settings.setCheckSpelling(true);
        expect(c.read(spellCheckFlagsProvider), (
          spelling: true,
          grammar: true,
        ));
      },
    );

    test('grammar off with spelling on checks spelling only', () async {
      final settings = await loadSettingsKeepingPickedBinary();
      final c = _container(settings);
      await settings.setCheckGrammar(false);
      expect(c.read(spellCheckFlagsProvider), (spelling: true, grammar: false));
      await settings.setCheckSpelling(false);
      expect(c.read(spellCheckFlagsProvider), (
        spelling: false,
        grammar: false,
      ));
    });

    test(
      'spellCheckFlagsProvider notifies its listeners when a flag changes',
      () async {
        final settings = await loadSettingsKeepingPickedBinary();
        final c = _container(settings);
        final seen = <({bool spelling, bool grammar})>[];
        c.listen(spellCheckFlagsProvider, (_, next) => seen.add(next));
        await settings.setCheckGrammar(false);
        await pumpEventQueue();
        await settings.setCheckSpelling(false);
        await pumpEventQueue();
        await settings.setCheckGrammar(true);
        await pumpEventQueue();
        await settings.setCheckSpelling(true);
        await pumpEventQueue();
        expect(seen.last, (spelling: true, grammar: true));
        expect(seen, contains((spelling: true, grammar: false)));
        expect(seen, contains((spelling: false, grammar: false)));
      },
    );
  });
}
