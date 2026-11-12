import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Where an opened echo should land (Spec #391 req 27): the echoed note and
/// the passage's byte offset in its body (null: open at the top). Not part
/// of `NoteTab`, so tab equality and history are unchanged. Value equality.
class EchoScrollTarget {
  const EchoScrollTarget(this.noteId, this.startByte);

  final String noteId;
  final int? startByte;

  @override
  bool operator ==(Object other) =>
      other is EchoScrollTarget &&
      other.noteId == noteId &&
      other.startByte == startByte;

  @override
  int get hashCode => Object.hash(noteId, startByte);

  @override
  String toString() => 'EchoScrollTarget($noteId, $startByte)';
}

/// The one-shot scroll target holder: the echoes tab [set]s it, the editor
/// [take]s it on arrival.
class EchoScrollTargetNotifier extends Notifier<EchoScrollTarget?> {
  @override
  EchoScrollTarget? build() => null;

  /// Holds [target], replacing any earlier one.
  void set(EchoScrollTarget target) => state = target;

  /// The held target when its note id is [noteId], else null. Either way
  /// the holder is empty afterwards.
  EchoScrollTarget? take(String noteId) {
    final held = state;
    state = null;
    return held != null && held.noteId == noteId ? held : null;
  }
}

final echoScrollTargetProvider =
    NotifierProvider<EchoScrollTargetNotifier, EchoScrollTarget?>(
      EchoScrollTargetNotifier.new,
    );
