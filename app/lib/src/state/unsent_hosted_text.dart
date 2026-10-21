import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'pending_saves.dart';
import 'vault_state.dart';

/// One hosted note whose text couldn't reach the vault server (a row of the
/// A9 leave confirm).
class UnsentHostedNote {
  const UnsentHostedNote({required this.title, required this.since});

  /// The note's title as the row shows it.
  final String title;

  /// When the text first failed to reach the server. The row shows it as
  /// local 24-hour `HH:MM` ("unsaved since 14:32").
  final DateTime since;
}

/// What the A9 leave confirm renders (D20): the hosted vault's server and
/// name for the eyebrow and question, and one entry per unsent note.
class UnsentHostedText {
  const UnsentHostedText({
    required this.serverName,
    required this.vaultName,
    this.notes = const [],
  });

  /// Nothing unsent.
  static const none = UnsentHostedText(serverName: '', vaultName: '');

  final String serverName;
  final String vaultName;
  final List<UnsentHostedNote> notes;
}

/// True while hosted text couldn't reach the server (unreachable or `401`,
/// L16): #102's [pendingSavesProvider] holds a save for the open hosted
/// vault. Close, quit and switch vault ask before leaving only while it is
/// true.
final hasUnsentHostedTextProvider = Provider<bool>(
  (ref) => ref.watch(pendingSavesProvider).isNotEmpty,
);

/// The data the leave confirm renders: the open hosted vault's server name
/// ([hostedServerNameProvider]) and vault name, and one entry per save in
/// [pendingSavesProvider], in queue order. [UnsentHostedText.none] with no
/// hosted vault open.
final unsentHostedTextProvider = Provider<UnsentHostedText>((ref) {
  final vault = ref.watch(currentVaultProvider);
  if (vault is! HostedVaultRef) return UnsentHostedText.none;
  return UnsentHostedText(
    serverName: ref.watch(hostedServerNameProvider(vault.serverId)),
    vaultName: vault.vaultName,
    notes: [
      for (final save in ref.watch(pendingSavesProvider))
        UnsentHostedNote(title: save.title, since: save.since),
    ],
  );
});
