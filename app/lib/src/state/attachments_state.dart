import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../vault_access/attachments_access.dart';
import 'vault_access_state.dart';

/// The open vault's [AttachmentsAccess] (Spec #123 V1): null with no open
/// vault, else `vaultAccessProvider`'s attachments domain. Tests override it
/// with a fake (`FakeAttachmentsAccess`).
final attachmentsProvider = Provider<AttachmentsAccess?>(
  (ref) => ref.watch(vaultAccessProvider)?.attachments,
);
