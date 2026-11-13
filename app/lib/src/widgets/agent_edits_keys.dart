// The frozen D19 Keys of agent note edits (Spec #7, WI #13 A1). A2 (#14,
// note menu + title icon) and A3 (#15, Activity tab Restore) import these;
// no other file spells these key strings.
import 'package:flutter/foundation.dart';

/// The ⋯ menu's checkable `Read-only for agents` MenuItemButton.
const noteMenuAgentReadOnlyKey = Key('note-menu-agent-read-only');

/// The title icon's SizedBox inside its Tooltip (not the title row).
const agentReadOnlyIconKey = Key('agent-read-only-icon');

/// The Restore button of the agent-edit Activity entry [agentChangeId]:
/// `note-restore-<agentChangeId>`.
Key noteRestoreKey(String agentChangeId) => const Key('');

/// The Restore confirm dialog's confirm button.
const noteRestoreConfirmKey = Key('note-restore-confirm');

/// The Restore confirm dialog's cancel button.
const noteRestoreCancelKey = Key('note-restore-cancel');
