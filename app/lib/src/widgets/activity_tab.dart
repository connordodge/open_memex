import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../dates.dart';
import '../db/activity_reads.dart';
import '../state/activity_state.dart';
import '../state/vault_state.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';
import '../vault_access/vault_async_view.dart';
import 'activity/filed_section.dart';
import 'atoms.dart';
import 'panel_placeholder_tab.dart';

const _activityEyebrow = 'agent activity · this note';
const _activitySubtitle =
    'every read and write by every connected agent. attaches to the audit log when a vault is shared with claude desktop.';
const _activityEmpty =
    'no activity yet.\nconnect an agent via the MCP server to see what they touch.';

/// The selected note's `agent_changes` log, newest first.
class ActivityTab extends ConsumerWidget {
  const ActivityTab({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = watchVaultValue(ref, selectedNoteAsyncProvider, null);
    const emptyTab = PanelPlaceholderTab(
      eyebrow: _activityEyebrow,
      subtitle: _activitySubtitle,
      empty: _activityEmpty,
      emptyKey: Key('activity-empty'),
    );
    if (selected == null) return emptyTab;
    return VaultAsyncView<List<AgentChangeRow>>(
      value: ref.watch(agentChangesAsyncProvider(selected.id)),
      empty: const <AgentChangeRow>[],
      builder: (context, entries) {
        final filed = watchFilingToShow(ref, selected);
        if (entries.isEmpty && filed == null) return emptyTab;
        return ListView(
          children: [
            if (filed != null) FiledSection(note: selected),
            if (entries.isNotEmpty) ...[
              const PanelHeader(eyebrow: _activityEyebrow),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Text(_activitySubtitle, style: _activitySubtitleStyle),
              ),
              const OmHairline(),
              for (final entry in entries) _ActivityEntry(entry: entry),
            ],
          ],
        );
      },
    );
  }
}

final _activitySubtitleStyle = OmType.mono(
  size: 10.5,
  color: OmColors.fg3,
  height: 1.6,
);

class _ActivityEntry extends StatelessWidget {
  const _ActivityEntry({required this.entry});
  final AgentChangeRow entry;
  @override
  Widget build(BuildContext context) {
    final at = DateTime.fromMillisecondsSinceEpoch(entry.createdAt);
    return Container(
      key: Key('activity-entry-${entry.id}'),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: OmColors.line1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            formatDateTime(at),
            style: OmType.mono(size: 11, color: OmColors.agent),
          ),
          const SizedBox(height: 2),
          Text(entry.day, style: OmType.mono(size: 10.5, color: OmColors.fg3)),
          const SizedBox(height: 6),
          for (final bullet in entry.bullets)
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Text(
                '· $bullet',
                style: OmType.sans(size: 12, color: OmColors.fg1, height: 1.5),
              ),
            ),
        ],
      ),
    );
  }
}
