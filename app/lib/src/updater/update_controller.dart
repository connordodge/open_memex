import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'update_state.dart';

// Stub (A0 #32): the signatures are frozen (D2). A3 #37 fills the bodies.

/// How a [UpdateController.relaunch] ended.
enum RelaunchOutcome {
  /// The install helper started and the app is exiting.
  exiting,

  /// The person cancelled the quit guard; the update stays Ready.
  cancelled,

  /// The install-location check or the helper failed; the state is Error.
  failed,

  /// Nothing ran: the update isn't Ready, or a relaunch is already running.
  ignored,
}

/// The only sequencer of Self-update and the single source of truth the
/// modal and version labels render from (TD3, D2). It survives the modal
/// closing.
class UpdateController extends Notifier<UpdateState> {
  @override
  UpdateState build() => const UpdateIdle();

  /// Runs the launch sequence (D8); true when the app root should open the
  /// modal.
  Future<bool> launch() async => false;

  /// Checks the Appcast. A [manual] check is never throttled.
  Future<void> check({required bool manual}) async {}

  /// Downloads and verifies the offered update.
  Future<void> install() async {}

  /// **try again**: goes where the error cause's target says (req 15).
  Future<void> tryAgain() async {}

  /// **later** (req 16, 16a).
  void later() {}

  /// **relaunch** (req 23, D2): location check, then [confirmQuit], then
  /// the install helper, then the confirmed process exit.
  Future<RelaunchOutcome> relaunch({
    required Future<bool> Function() confirmQuit,
  }) async => RelaunchOutcome.ignored;
}

/// The app's [UpdateController].
final updateControllerProvider =
    NotifierProvider<UpdateController, UpdateState>(UpdateController.new);
