import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/agent_activity.dart';
import '../../state/agents_sheet/agents_sheet_state.dart';
import '../../state/clock.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../vault_access/agents_access.dart';
import '../agents/agent_age.dart';
import '../atoms.dart';
import 'agents_tab_loading.dart';

/// Below this window width the Live tab drops the meta line and the Recent
/// writes client column (Spec #394 req 47). The window, not the sheet.
const _narrowBelow = 672.0;

/// Recent writes shows at most this many rows (Spec #394 req 17).
const _recentCap = 20;

/// The Agents sheet's `Live` tab body (Spec #394 req 17-21, 47): connected
/// agents and the newest agent writes, from [agentActivityAsyncProvider].
///
/// It adds no timer and never reads the server: the provider's own presence
/// tick re-derives the view, so ages and `working` move with it (L410-2).
/// While the provider loads, including a stale value kept across a vault
/// switch, it shows [AgentsTabLoading] (D31). An `AsyncError` (the provider
/// never emits one) reads as the empty view (L410-1).
class LiveTab extends ConsumerWidget {
  const LiveTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activity = ref.watch(agentActivityAsyncProvider);
    if (activity.isLoading) return const AgentsTabLoading();
    final view = activity.hasError
        ? AgentActivityView.empty
        : activity.requireValue;
    final now = ref.watch(clockProvider).now();
    final narrow = MediaQuery.sizeOf(context).width < _narrowBelow;

    if (!view.available) return const _OlderServer();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (view.connected.isEmpty)
          _NoAgents(view: view, now: now)
        else
          _Connected(view: view, now: now, narrow: narrow),
        if (view.recent.isNotEmpty || view.connected.isNotEmpty)
          _RecentWrites(
            view: view,
            now: now,
            narrow: narrow,
            topGap: view.connected.isEmpty ? 22 : 18,
          ),
      ],
    );
  }
}

TextStyle get _labelStyle => OmType.mono(
  size: 10.5,
  weight: FontWeight.w500,
  color: OmColors.fg2,
  letterSpacing: 0.8,
);

/// A small round marker: the agent dot and the panel heading dot.
class _Dot extends StatelessWidget {
  const _Dot({super.key, required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: 7,
    height: 7,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}

/// `CONNECTED · n` and the agent cards.
class _Connected extends StatelessWidget {
  const _Connected({
    required this.view,
    required this.now,
    required this.narrow,
  });

  final AgentActivityView view;
  final DateTime now;
  final bool narrow;

  @override
  Widget build(BuildContext context) {
    final agents = view.connected;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('CONNECTED · ${agents.length}', style: _labelStyle),
        const SizedBox(height: 8),
        for (var i = 0; i < agents.length; i++) ...[
          if (i > 0) SizedBox(height: narrow ? 6 : 8),
          narrow
              ? _AgentRow(index: i, agent: agents[i], view: view, now: now)
              : _AgentCard(index: i, agent: agents[i], view: view, now: now),
        ],
      ],
    );
  }
}

Text _status(ConnectedAgent agent, AgentActivityView view, DateTime now) {
  final age = formatAgentAge(
    view.localMs(agent.presence.lastRequestAt),
    now: now,
  );
  return Text(
    agent.working ? 'working' : 'idle · $age',
    maxLines: 1,
    softWrap: false,
    style: OmType.mono(
      size: 11,
      color: agent.working ? OmColors.agent : OmColors.fg2,
    ),
  );
}

Text _name(AgentPresence presence) => Text(
  presence.clientName,
  maxLines: 1,
  overflow: TextOverflow.ellipsis,
  style: OmType.sans(size: 13, weight: FontWeight.w500, color: OmColors.fg0),
);

Color _dotColor(ConnectedAgent agent) =>
    agent.working ? OmColors.agent : OmColors.fg2;

/// `v0.14.2 · stdio · connected 14m · semantic recall on`; no version omits
/// the first part.
String _metaText(AgentPresence p, AgentActivityView view, DateTime now) {
  final connected = formatAgentAge(view.localMs(p.startedAt), now: now);
  return [
    if (p.clientVersion != null && p.clientVersion!.isNotEmpty)
      'v${p.clientVersion}',
    p.transport,
    'connected $connected',
    if (p.embeddings) 'semantic recall on' else 'keyword search only',
  ].join(' · ');
}

/// The wide card: dot, name over meta line, status at the right.
class _AgentCard extends StatelessWidget {
  const _AgentCard({
    required this.index,
    required this.agent,
    required this.view,
    required this.now,
  });

  final int index;
  final ConnectedAgent agent;
  final AgentActivityView view;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: Key('live-agent-card-$index'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: OmColors.surface3,
        border: Border.all(color: OmColors.line2),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: _Dot(
              key: Key('live-agent-dot-$index'),
              color: _dotColor(agent),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _name(agent.presence),
                Text(
                  _metaText(agent.presence, view, now),
                  style: OmType.mono(
                    size: 10.5,
                    color: OmColors.fg2,
                    height: 1.6,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          _status(agent, view, now),
        ],
      ),
    );
  }
}

/// The narrow one-line row: dot, name, status; no meta line.
class _AgentRow extends StatelessWidget {
  const _AgentRow({
    required this.index,
    required this.agent,
    required this.view,
    required this.now,
  });

  final int index;
  final ConnectedAgent agent;
  final AgentActivityView view;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    return Row(
      key: Key('live-agent-card-$index'),
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _Dot(key: Key('live-agent-dot-$index'), color: _dotColor(agent)),
        const SizedBox(width: 8),
        Expanded(child: _name(agent.presence)),
        const SizedBox(width: 8),
        _status(agent, view, now),
      ],
    );
  }
}

/// `RECENT WRITES`, the explainer and up to 20 rows.
class _RecentWrites extends StatelessWidget {
  const _RecentWrites({
    required this.view,
    required this.now,
    required this.narrow,
    required this.topGap,
  });

  final AgentActivityView view;
  final DateTime now;
  final bool narrow;
  final double topGap;

  @override
  Widget build(BuildContext context) {
    final rows = view.recent.take(_recentCap).toList();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(height: topGap),
        Text('RECENT WRITES', style: _labelStyle),
        const SizedBox(height: 8),
        Text(
          'The newest writes by any agent. Summaries name notes and folders, '
          'never your text.',
          style: OmType.sans(size: 12.5, color: OmColors.fg2, height: 1.55),
        ),
        const SizedBox(height: 6),
        for (var i = 0; i < rows.length; i++)
          _RecentRow(
            index: i,
            entry: rows[i],
            age: formatAgentAge(view.localMs(rows[i].createdAt), now: now),
            narrow: narrow,
          ),
      ],
    );
  }
}

/// One write: `client | summary | time` (wide), or `client · summary | time`
/// (narrow), with a line1 bottom border.
class _RecentRow extends StatelessWidget {
  const _RecentRow({
    required this.index,
    required this.entry,
    required this.age,
    required this.narrow,
  });

  final int index;
  final AgentActivityEntry entry;
  final String age;
  final bool narrow;

  @override
  Widget build(BuildContext context) {
    final summary = Text(
      narrow ? '${entry.clientName} · ${entry.summary}' : entry.summary,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: OmType.sans(size: 12.5, color: OmColors.fg1),
    );
    return Container(
      key: Key('live-recent-row-$index'),
      padding: const EdgeInsets.symmetric(vertical: 5),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: OmColors.line1)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          if (!narrow) ...[
            SizedBox(
              width: 84,
              child: Text(
                entry.clientName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: OmType.mono(size: 10.5, color: OmColors.fg2),
              ),
            ),
            const SizedBox(width: 10),
          ],
          Expanded(child: summary),
          const SizedBox(width: 10),
          // 34 wide, growing only when a long age needs more room.
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 34),
            child: Text(
              age,
              maxLines: 1,
              softWrap: false,
              textAlign: TextAlign.right,
              style: OmType.mono(size: 10.5, color: OmColors.fg2),
            ),
          ),
        ],
      ),
    );
  }
}

/// A heading with a 7 px fg2 dot.
class _PanelHeading extends StatelessWidget {
  const _PanelHeading({required this.text, required this.size});

  final String text;
  final double size;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      _Dot(color: OmColors.fg2),
      const SizedBox(width: 10),
      Expanded(
        child: Text(
          text,
          style: OmType.sans(
            size: size,
            weight: FontWeight.w600,
            color: OmColors.fg0,
          ),
        ),
      ),
    ],
  );
}

TextStyle get _bodyStyle =>
    OmType.sans(size: 12.5, color: OmColors.fg2, height: 1.55);

/// No agent is connected: the last write (or none), and `Set up an agent`.
class _NoAgents extends ConsumerWidget {
  const _NoAgents({required this.view, required this.now});

  final AgentActivityView view;
  final DateTime now;

  static const _hint =
      'Connect Claude Desktop or Claude Code to this vault to see it work '
      'here.';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final String line;
    if (view.recent.isEmpty) {
      line = 'No agent writes recorded for this vault yet.';
    } else {
      final last = view.recent.first;
      final age = formatAgentAge(view.localMs(last.createdAt), now: now);
      final when = age == 'now' ? 'just now' : '$age ago';
      line = 'Last agent write $when, by ${last.clientName}. $_hint';
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _PanelHeading(text: 'No agents connected', size: 15),
        const SizedBox(height: 6),
        Text(line, style: _bodyStyle),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: OmButton(
            key: const Key('live-set-up-agent'),
            kind: OmButtonKind.primary,
            focusable: true,
            size: 30,
            label: 'Set up an agent',
            onPressed: () => ref
                .read(agentsSheetTabProvider.notifier)
                .select(AgentsTab.connect),
          ),
        ),
      ],
    );
  }
}

/// The vault server predates agent activity (`available == false`); no
/// error colour (Spec #394 req 20).
class _OlderServer extends StatelessWidget {
  const _OlderServer();

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const _PanelHeading(
        text: 'Agent activity unavailable on this vault server',
        size: 14,
      ),
      const SizedBox(height: 6),
      Text(
        'The server is older than this app. Update memex on it to see '
        'connected agents and their writes here. Connect and Tools still '
        'work.',
        style: _bodyStyle,
      ),
    ],
  );
}
