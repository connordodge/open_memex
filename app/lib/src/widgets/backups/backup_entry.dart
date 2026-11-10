// WI #326 (A5, D24): the sidebar "backups" row under the vault pills and the
// automatic-failure warning (Spec #315 reqs 24, 31a, 37; design pack
// design/315-vault-backups/packs/326.md, board B1).
//
// Skeleton (red mode): the public widget only. It renders nothing yet.
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The open vault's backups row: its state as text (off, never, the last
/// backup's age, backing up…, or the amber failure), and a press opens
/// `showBackupsSheet`. Reads the state from `backupControllerProvider` only.
class BackupEntry extends ConsumerWidget {
  const BackupEntry({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => const SizedBox.shrink();
}
