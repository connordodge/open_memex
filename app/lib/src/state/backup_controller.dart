// WI #321 (A0, D19, D23): the backup controller's public API. The abstract
// class, the providers' types and the in-flight set are frozen; the live
// controller is the stub A3 (#324) replaces. A4 (#325), A5 (#326) and A6
// (#327) build on this API with `FakeBackupController`.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'backup_models.dart';
import 'vault_ref.dart';

/// The due rule (D12, Spec req 23), the Dart port of Rust `state::is_due`:
/// a check backs up when there is no [lastSuccessAt], when [lastSuccessAt] is
/// after [now] (the clock went backwards), or when 24 hours (86 400 000 ms)
/// or more have passed. Compares instants, never calendar fields.
/// Skeleton (WI #324 red step): A3 fills it.
bool isBackupDue(DateTime? lastSuccessAt, DateTime now) => false;

/// Backups for the open vault (D23): the automatic schedule, "Back up now",
/// the hosted status and its polling, and the per-vault view state the sheet
/// and the sidebar entry show. App-wide (not autoDispose), kept alive by
/// `Sidebar.build` watching [backupControllerProvider].
///
/// [state] holds the view state of each vault the controller has seen, so a
/// widget that watches the provider rebuilds when one changes.
abstract class BackupController
    extends StateNotifier<Map<VaultRef, BackupViewState>> {
  BackupController(super.state);

  /// [vault]'s current view state. A vault the controller hasn't seen reads
  /// as [BackupSheetMode.off] (`hosted` per the ref).
  BackupViewState viewStateOf(VaultRef vault);

  /// "Back up now" (without `--if-changed`) for a local vault, or the POST
  /// for a hosted one. Returns without any CLI or HTTP call while a backup of
  /// [vault] is in flight, however it started.
  Future<void> backUpNow(VaultRef vault);

  /// The Backups sheet opened on [vault]: re-reads the state, and for a
  /// hosted vault starts the 2 s poll while the server reports `in_progress`.
  void openSheet(VaultRef vault);

  /// The sheet closed: the hosted poll stops.
  void closeSheet(VaultRef vault);
}

/// The real controller. Stub: neutral returns, no behavior (A3 fills it).
class LiveBackupController extends BackupController {
  LiveBackupController(Ref ref) : super(const {});

  @override
  BackupViewState viewStateOf(VaultRef vault) =>
      const BackupViewState(mode: BackupSheetMode.off);

  @override
  Future<void> backUpNow(VaultRef vault) async {}

  @override
  void openSheet(VaultRef vault) {}

  @override
  void closeSheet(VaultRef vault) {}
}

final backupControllerProvider =
    StateNotifierProvider<BackupController, Map<VaultRef, BackupViewState>>(
      (ref) => LiveBackupController(ref),
    );

/// The local vault paths with a backup running right now (manual or
/// automatic), app-wide. The "Back up now" button is disabled while the open
/// vault's path is in it, and an automatic check never starts for a path in
/// it.
final backupInFlightProvider = StateProvider<Set<String>>(
  (ref) => const <String>{},
);
