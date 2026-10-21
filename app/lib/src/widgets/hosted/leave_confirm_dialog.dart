import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../state/unsent_hosted_text.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../atoms.dart';

/// How the person is leaving: the verb in the A9 leave confirm's question
/// and danger button ("close anyway", "quit anyway", "switch anyway").
enum LeaveAction {
  close('close'),
  quit('quit'),
  switchVault('switch');

  const LeaveAction(this.verb);

  final String verb;
}

/// Reads a provider: `ref.read` of a `Ref` or a `WidgetRef`.
typedef ProviderReader = T Function<T>(ProviderListenable<T> provider);

/// Whether a leave confirm is up in this app (one per provider container).
class _OpenConfirm {
  bool open = false;
}

final _openConfirmProvider = Provider<_OpenConfirm>((_) => _OpenConfirm());

/// Asks before leaving with unsent hosted text (Req 51, board A9).
///
/// Reads `hasUnsentHostedTextProvider` through [read] when called: false
/// completes true at once with no dialog. True shows the leave confirm for
/// [action] over [context] (which must sit under a Navigator) and completes
/// true for the danger button, false for cancel or a dismiss without a
/// choice. While a leave confirm is already up, another request completes
/// false without opening a second one.
Future<bool> confirmLeave(
  BuildContext context,
  LeaveAction action,
  ProviderReader read,
) async {
  if (!read(hasUnsentHostedTextProvider)) return true;
  final state = read(_openConfirmProvider);
  if (state.open) return false;
  state.open = true;
  try {
    final chosen = await showDialog<bool>(
      context: context,
      builder: (_) => LeaveConfirmDialog(
        text: read(unsentHostedTextProvider),
        action: action,
      ),
    );
    return chosen ?? false;
  } finally {
    state.open = false;
  }
}

/// The A9 leave confirm (Key `leave-confirm`, pack 103): the eyebrow
/// `<VAULT> · <SERVER>` with the can't-reach status dot, the question, one
/// row per unsent note (Key `leave-confirm-note-<n>`) and the actions
/// "cancel" (`leave-confirm-cancel`, pops false) and `<verb> anyway`
/// (`leave-confirm-proceed`, pops true).
class LeaveConfirmDialog extends StatelessWidget {
  const LeaveConfirmDialog({
    super.key,
    required this.text,
    required this.action,
  });

  final UnsentHostedText text;
  final LeaveAction action;

  /// Rows beyond this many scroll inside the dialog.
  static const maxVisibleRows = 4;

  static const _rowHeight = 34.5;
  static const _rowGap = 6.0;

  @override
  Widget build(BuildContext context) {
    final notes = text.notes;
    final rows = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < notes.length; i++) ...[
          if (i > 0) const SizedBox(height: _rowGap),
          _NoteRow(key: Key('leave-confirm-note-$i'), note: notes[i]),
        ],
      ],
    );
    return Center(
      child: Material(
        type: MaterialType.transparency,
        child: Container(
          key: const Key('leave-confirm'),
          width: 472,
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: OmColors.surface2,
            border: Border.all(color: OmColors.line2),
            borderRadius: BorderRadius.circular(10),
            boxShadow: [
              BoxShadow(
                color: OmColors.dialogShadow,
                offset: const Offset(0, 24),
                blurRadius: 64,
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Text(
                    '${text.vaultName} · ${text.serverName}'.toUpperCase(),
                    style: OmType.eyebrow(),
                  ),
                  const SizedBox(width: 7),
                  const StatusDot(state: StatusDotState.cantReach),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                "unsaved changes couldn't reach ${text.serverName}. "
                '${action.verb} anyway?',
                style: OmType.sans(
                  size: 15,
                  weight: FontWeight.w600,
                  height: 21 / 15,
                ),
              ),
              if (notes.isNotEmpty) ...[
                const SizedBox(height: 16),
                if (notes.length > maxVisibleRows)
                  SizedBox(
                    height:
                        maxVisibleRows * _rowHeight +
                        (maxVisibleRows - 1) * _rowGap,
                    child: SingleChildScrollView(child: rows),
                  )
                else
                  rows,
              ],
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OmButton(
                    key: const Key('leave-confirm-cancel'),
                    kind: OmButtonKind.ghost,
                    label: 'cancel',
                    onPressed: () => Navigator.of(context).pop(false),
                  ),
                  const SizedBox(width: 8),
                  OmButton(
                    key: const Key('leave-confirm-proceed'),
                    kind: OmButtonKind.danger,
                    label: '${action.verb} anyway',
                    onPressed: () => Navigator.of(context).pop(true),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One unsent note: file icon, title (one line), "unsaved since HH:MM".
class _NoteRow extends StatelessWidget {
  const _NoteRow({super.key, required this.note});

  final UnsentHostedNote note;

  @override
  Widget build(BuildContext context) {
    final since = note.since.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
      decoration: BoxDecoration(
        color: OmColors.surface3,
        border: Border.all(color: OmColors.line2),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          const Icon(LucideIcons.fileText, size: 12, color: OmColors.fg2),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              note.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: OmType.sans(
                size: 13,
                height: 16 / 13,
                color: OmColors.fg1,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            'unsaved since ${two(since.hour)}:${two(since.minute)}',
            style: OmType.mono(size: 11, color: OmColors.fg2),
          ),
        ],
      ),
    );
  }
}
