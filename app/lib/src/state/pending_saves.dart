import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'vault_state.dart';

// The server name a `401`'s queued save shows (#101 owns the seam).
export 'hosted_identity.dart' show hostedServerNameProvider;

/// One hosted note whose editor save couldn't reach the vault server
/// (unreachable, timed out or `401`; Req 50, L16). It stays queued, with
/// its latest text, until a retry saves it.
class PendingSave {
  const PendingSave({
    required this.noteId,
    required this.title,
    required this.text,
    required this.baseVersion,
    required this.since,
    required this.serverName,
  });

  /// The note's id; a virtual Today note's tab id (`virtual-today:<date>`)
  /// while its first-edit create is queued.
  final String noteId;

  /// The note's title, as the leave confirms list it (#103).
  final String title;

  /// The queued text: the latest text typed. Further edits replace it.
  final String text;

  /// The `expected_version` the retry sends; null for a virtual Today
  /// create.
  final int? baseVersion;

  /// When the text first failed to reach the server, from `clockProvider`.
  final DateTime since;

  /// The vault server's name, as the editor label shows it.
  final String serverName;

  PendingSave _copyWith({String? title, String? text, int? baseVersion}) =>
      PendingSave(
        noteId: noteId,
        title: title ?? this.title,
        text: text ?? this.text,
        baseVersion: baseVersion ?? this.baseVersion,
        since: since,
        serverName: serverName,
      );
}

/// A [PendingSave] with the hosted vault it belongs to. A queued save only
/// ever retries into [vault].
class QueuedSave {
  const QueuedSave({
    required this.vault,
    required this.save,
    this.sendTitle,
    this.heldStatus,
    this.heldMessage,
  });

  final HostedVaultRef vault;
  final PendingSave save;

  /// The title the retry sends (null: unchanged).
  final String? sendTitle;

  /// Set when a retry reached the server but failed for another reason
  /// (a `version_conflict` that did not self-heal, or another error): the
  /// save no longer retries on its own, and the editor shows this status
  /// and [heldMessage] for the note. Null while it waits for the server.
  final SaveStatus? heldStatus;
  final String? heldMessage;

  QueuedSave _copyWith({
    PendingSave? save,
    String? sendTitle,
    bool clearHeld = false,
    SaveStatus? heldStatus,
    String? heldMessage,
  }) => QueuedSave(
    vault: vault,
    save: save ?? this.save,
    sendTitle: sendTitle ?? this.sendTitle,
    heldStatus: clearHeld ? null : (heldStatus ?? this.heldStatus),
    heldMessage: clearHeld ? null : (heldMessage ?? this.heldMessage),
  );
}

/// Every hosted vault's queued saves, oldest first. Kept across vault
/// switches; each entry names its vault.
class PendingSaveQueue extends StateNotifier<List<QueuedSave>> {
  PendingSaveQueue() : super(const []);

  /// The queued save of [noteId] in [vault], or null.
  QueuedSave? entryFor(VaultRef vault, String noteId) {
    for (final q in state) {
      if (q.vault == vault && q.save.noteId == noteId) return q;
    }
    return null;
  }

  /// The queued saves of [vault], oldest first.
  List<QueuedSave> entriesOf(VaultRef vault) => [
    for (final q in state)
      if (q.vault == vault) q,
  ];

  /// Queues [text] for [noteId] in [vault], or, when it is already queued,
  /// replaces its text, title and base version and keeps its place and
  /// since-time (the first failure's). A held entry waits for the server
  /// again.
  void put({
    required HostedVaultRef vault,
    required String noteId,
    required String title,
    required String text,
    required int? baseVersion,
    required DateTime now,
    required String serverName,
    String? sendTitle,
  }) {
    final existing = entryFor(vault, noteId);
    if (existing != null) {
      _replace(
        existing,
        existing._copyWith(
          save: existing.save._copyWith(
            title: title,
            text: text,
            baseVersion: baseVersion,
          ),
          sendTitle: sendTitle,
          clearHeld: true,
        ),
      );
      return;
    }
    state = [
      ...state,
      QueuedSave(
        vault: vault,
        sendTitle: sendTitle,
        save: PendingSave(
          noteId: noteId,
          title: title,
          text: text,
          baseVersion: baseVersion,
          since: now,
          serverName: serverName,
        ),
      ),
    ];
  }

  /// Replaces the queued text (and title) of [noteId] in [vault]; nothing
  /// when it is not queued.
  void updateText(
    VaultRef vault,
    String noteId,
    String text, {
    String? title,
    String? sendTitle,
  }) {
    final q = entryFor(vault, noteId);
    if (q == null) return;
    if (q.save.text == text &&
        (title == null || q.save.title == title) &&
        (sendTitle == null || q.sendTitle == sendTitle)) {
      return;
    }
    _replace(
      q,
      q._copyWith(
        save: q.save._copyWith(text: text, title: title),
        sendTitle: sendTitle,
      ),
    );
  }

  /// A retry of [noteId] saved its text at [version], but the text changed
  /// while it was in flight: the newer text stays queued on [version].
  void rebase(VaultRef vault, String noteId, int version) {
    final q = entryFor(vault, noteId);
    if (q == null) return;
    _replace(q, q._copyWith(save: q.save._copyWith(baseVersion: version)));
  }

  /// A retry of [noteId] reached the server and failed with [status] and
  /// [message]: it stops retrying on its own (see [QueuedSave.heldStatus]).
  void hold(VaultRef vault, String noteId, SaveStatus status, String message) {
    final q = entryFor(vault, noteId);
    if (q == null) return;
    _replace(q, q._copyWith(heldStatus: status, heldMessage: message));
  }

  /// A held save of [noteId] in [vault] waits for the server again (its next
  /// send couldn't reach it): the label shows and the next recovery retries
  /// it. Nothing when it is not queued or not held.
  void release(VaultRef vault, String noteId) {
    final q = entryFor(vault, noteId);
    if (q == null || q.heldStatus == null) return;
    _replace(q, q._copyWith(clearHeld: true));
  }

  /// Removes [noteId] from [vault]'s queue.
  void remove(VaultRef vault, String noteId) {
    final q = entryFor(vault, noteId);
    if (q == null) return;
    state = [
      for (final e in state)
        if (!identical(e, q)) e,
    ];
  }

  void _replace(QueuedSave old, QueuedSave next) {
    state = [for (final e in state) identical(e, old) ? next : e];
  }
}

/// Every hosted vault's queued saves (see [PendingSaveQueue]).
final pendingSaveQueueProvider =
    StateNotifierProvider<PendingSaveQueue, List<QueuedSave>>(
      (ref) => PendingSaveQueue(),
    );

/// The hosted editor's pending-save queue (#102): every queued note of the
/// open vault, oldest first. Empty on a local vault.
final pendingSavesProvider = Provider<List<PendingSave>>((ref) {
  final vault = ref.watch(currentVaultProvider);
  if (vault is! HostedVaultRef) return const [];
  return [
    for (final q in ref.watch(pendingSaveQueueProvider))
      if (q.vault == vault) q.save,
  ];
});

/// True while note [noteId] (a virtual Today tab's id for its queued create)
/// of the open vault has a queued save: its tab shows "not saved yet".
final notePendingSaveProvider = Provider.family<bool, String>(
  (ref, noteId) =>
      ref.watch(pendingSavesProvider).any((p) => p.noteId == noteId),
);

/// The editor label for a save queued until [serverName] answers (Req 50,
/// L16; also after a `401`).
String pendingSaveLabel(String serverName) =>
    'not saved yet · will save when $serverName is back';

/// The editor label of note [noteId] in the open vault: [pendingSaveLabel]
/// while its save waits for the server, null otherwise (also while the
/// queued save is held, see [QueuedSave.heldStatus]).
final pendingSaveLabelProvider = Provider.family<String?, String>((
  ref,
  noteId,
) {
  final vault = ref.watch(currentVaultProvider);
  if (vault is! HostedVaultRef) return null;
  for (final q in ref.watch(pendingSaveQueueProvider)) {
    if (q.vault == vault && q.save.noteId == noteId) {
      return q.heldStatus == null ? pendingSaveLabel(q.save.serverName) : null;
    }
  }
  return null;
});
