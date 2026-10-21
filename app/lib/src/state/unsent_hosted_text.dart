import 'package:flutter_riverpod/flutter_riverpod.dart';

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
/// L16). Default false; #102 binds it to its save queue. Close, quit and
/// switch vault ask before leaving only while it is true.
final hasUnsentHostedTextProvider = Provider<bool>((_) => false);

/// The data the leave confirm renders. Default [UnsentHostedText.none];
/// #102 binds it to its save queue.
final unsentHostedTextProvider = Provider<UnsentHostedText>(
  (_) => UnsentHostedText.none,
);
