// WI #434 (Spec #392 req 12, 19; D24): keeps the native Spelling submenu and
// the spelling settings in step, and closes document tags on vault close.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'settings.dart';
import 'spelling_service.dart';
import 'vault_state.dart';

/// Attached once for the app's life (one appended line in main.dart or
/// workspace.dart): sends `setMenuState` at launch and on every change,
/// applies native `menuToggle`s, and calls `closeDocumentTags` whenever a
/// vault is closed or switched away from.
///
/// `setMenuState` carries the STORED flags: with spelling off it still
/// sends the stored `checkGrammar` (the native side greys the item). A
/// native grammar toggle while spelling is off changes nothing. Editor
/// dispose never closes document tags (req 12).
final spellingMenuSyncProvider = Provider<void>((ref) {
  final spelling = ref.watch(spellingServiceProvider);

  ref.listen<({bool checkSpelling, bool checkGrammar})>(
    settingsProvider.select(
      (s) => (checkSpelling: s.checkSpelling, checkGrammar: s.checkGrammar),
    ),
    (_, flags) => unawaited(
      spelling.setMenuState(
        checkSpelling: flags.checkSpelling,
        checkGrammar: flags.checkGrammar,
      ),
    ),
    fireImmediately: true,
  );

  final toggles = spelling.menuToggles.listen((item) {
    final settings = ref.read(settingsProvider.notifier);
    final now = ref.read(settingsProvider);
    switch (item) {
      case SpellingMenuItem.checkSpelling:
        unawaited(settings.setCheckSpelling(!now.checkSpelling));
      case SpellingMenuItem.checkGrammar:
        if (now.checkSpelling) {
          unawaited(settings.setCheckGrammar(!now.checkGrammar));
        }
    }
  });
  ref.onDispose(toggles.cancel);

  ref.listen<VaultRef?>(currentVaultProvider, (previous, _) {
    if (previous != null) unawaited(spelling.closeDocumentTags());
  });
});
