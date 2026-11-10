// WI #321 (A0, D19): the frozen Keys of the backup UI (architecture.md,
// "Frozen Keys"). Robot and widget tests find controls by these Keys; they
// change only by lead ruling. Design-added Keys stay local to the UI WI's own
// file. Each Key is a `ValueKey<String>` and wraps the named box, so a tap
// anywhere in the box lands on the Key's widget.
//
// SKELETON (red mode): every value is a placeholder; the implementer writes
// the string in each doc comment.
import 'package:flutter/widgets.dart';

import '../../state/backup_models.dart';

/// `backups-entry`: the sidebar entry's whole tappable box, padding included.
const backupsEntryKey = Key('');

/// `backups-entry-warning`: the warning badge only. The badge takes no press.
const backupsEntryWarningKey = Key('');

/// `backups-sheet`: the 620-wide panel (as `setup-sheet` in setup_sheet.dart),
/// not the barrier.
const backupsSheetKey = Key('');

/// `backups-toggle`: the on/off control widget.
const backupsToggleKey = Key('');

/// `backups-automatic`: the "Back up automatically" control widget.
const backupsAutomaticKey = Key('');

/// `backups-keep`: the keep-count control widget.
const backupsKeepKey = Key('');

/// `backups-destination-choose`: the "Choose folder…" row's full tap box.
const backupsDestinationChooseKey = Key('');

/// `backups-now`: the "Back up now" button.
const backupsNowKey = Key('');

/// `backups-retry`: the Retry button.
const backupsRetryKey = Key('');

/// `vault-picker-restore`: the vault picker's "Restore from backup…" button,
/// next to `vault-picker-create`.
const vaultPickerRestoreKey = Key('');

/// `restore-folder`: the Restore dialog's parent-folder button.
const restoreFolderKey = Key('');

/// `restore-submit`: a `KeyedSubtree` around the whole Restore button
/// (the `vault-picker-create` pattern, vault_picker.dart:243-254).
const restoreSubmitKey = Key('');

/// `backups-status`: the sheet's status text column.
const backupsStatusKey = Key('');

/// `restore-dialog`: the Restore dialog's AlertDialog.
const restoreDialogKey = Key('');

/// `restore-name`: the Restore dialog's vault-name TextField.
const restoreNameKey = Key('');

/// `restore-error`: the Restore dialog's error text.
const restoreErrorKey = Key('');

/// `backups-destination-<provider wire id>-<index>`, for example
/// `backups-destination-google_drive-1`: one destination row's full tap box.
/// [index] counts from zero among the listed options of the same [provider],
/// in list order (the second Google Drive account is `google_drive-1`).
Key backupDestinationKey(BackupProvider provider, int index) => const Key('');
