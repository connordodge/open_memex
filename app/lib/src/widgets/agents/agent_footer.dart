import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/agent_activity.dart';
import '../../state/clock.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../agents_sheet/agents_sheet.dart' show openAgentsSheet;
import '../atoms.dart';
import '../editor/note_header.dart' show formatUpdatedAgo;
import 'agent_age.dart';

/// The sidebar's live agents footer (#390 req 18-29, D13): the header (the
/// `agents · live` eyebrow, a dot that pulses while an agent is connected, and
/// the `OPEN ↗` link, #408), then one of the connected agents with the newest
/// activity, the disconnected hint, or the unavailable line. Apart from that
/// link it has no pointer, hover, focus or keyboard handling.
///
/// Height (req 27a): at most 3 agent rows and 3 activity rows at text scale
/// 1.0 and 2 of each from 1.3, never above [maxFooterHeight], and never so
/// tall that the pane above the footer in the sidebar's column drops below
/// [minPaneHeight]: activity rows drop first, then agent rows, and `+<n> more`
/// stays.
class AgentFooter extends ConsumerWidget {
  const AgentFooter({super.key});

  /// The tallest the footer grows.
  static const maxFooterHeight = 180.0;

  /// The room the pane above keeps in the sidebar's column.
  static const minPaneHeight = 120.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(agentActivityAsyncProvider);
    final scaler = MediaQuery.textScalerOf(context);
    final metrics = _Metrics(scaler);
    // D31: after a vault switch the old view stays in `value`, so only
    // `isLoading` says the view is not for this vault. The provider never
    // emits an error; if it did, the header alone is the safe fallback.
    final view = async.isLoading || async.hasError ? null : async.value;
    final now = ref.read(clockProvider).now();
    return _FooterBudget(
      minHeight: metrics.headerOnly,
      child: LayoutBuilder(
        builder: (context, constraints) => _Body(
          view: view,
          now: now,
          metrics: metrics,
          cap: min(constraints.maxHeight, maxFooterHeight),
          width: constraints.maxWidth,
        ),
      ),
    );
  }
}

/// Text sizes at one text scale (rows are one line, so heights are exact).
class _Metrics {
  _Metrics(this.scaler)
    : bigScale = scaler.scale(1.0) >= 1.3,
      row = scaler.scale(_size) * 1.5,
      line = scaler.scale(_size) * 1.6,
      header = max(scaler.scale(11) * 1.5, scaler.scale(_size) * 1.5);

  static const _size = 10.5;
  static const padding = 22.0;
  static const sidePadding = 24.0;
  static const headerGap = 8.0;
  static const groupGap = 6.0;
  static const lineGap = 2.0;

  final TextScaler scaler;

  /// The row limit applies from text scale 1.3.
  final bool bigScale;
  final double row;
  final double line;
  final double header;

  int get rowLimit => bigScale ? 2 : 3;
  double get headerOnly => padding + header;
}

/// How many agent and activity rows fit.
class _Plan {
  _Plan(this.agents, this.feed, {required this.more});
  final int agents;
  final int feed;

  /// Whether the `+n more` line fits (it only drops under the header floor).
  final bool more;
}

_Plan _planRows({
  required int connected,
  required int recent,
  required _Metrics m,
  required double cap,
}) {
  var agents = min(connected, m.rowLimit);
  var feed = min(recent, m.rowLimit);
  double height() {
    final lines = agents + (agents < connected ? 1 : 0);
    if (lines == 0) return m.headerOnly;
    var h = m.headerOnly + _Metrics.headerGap + lines * m.row;
    if (feed > 0) h += (lines > 0 ? _Metrics.groupGap : 0) + feed * m.row;
    return h;
  }

  // Activity rows drop first, then agent rows (the `+n more` line stays).
  while (height() > cap + 0.01) {
    if (feed > 0) {
      feed--;
    } else if (agents > 0) {
      agents--;
    } else {
      break;
    }
  }
  // Below the header floor not even the `+n more` line fits: the header
  // alone is what is left (it never drops).
  return _Plan(agents, feed, more: height() <= cap + 0.01);
}

const _hint1 = 'wire memex serve into Claude Desktop';
const _hint2 = 'to see live activity here';

TextStyle _mono({Color color = OmColors.fg2, double height = 1.5}) =>
    OmType.mono(size: _Metrics._size, color: color, height: height);

class _Body extends StatelessWidget {
  const _Body({
    required this.view,
    required this.now,
    required this.metrics,
    required this.cap,
    required this.width,
  });

  final AgentActivityView? view;
  final DateTime now;
  final _Metrics metrics;
  final double cap;

  /// The footer's width, to measure how many lines the hint wraps to.
  final double width;

  /// Lines (1 or 2) [text] takes at the footer's content width.
  int _lines(String text) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: _mono(height: 1.6)),
      textDirection: TextDirection.ltr,
      textScaler: metrics.scaler,
      maxLines: 2,
    )..layout(maxWidth: max(1.0, width - _Metrics.sidePadding));
    final lines = painter.computeLineMetrics().length;
    painter.dispose();
    return lines.clamp(1, 2);
  }

  @override
  Widget build(BuildContext context) {
    final v = view;
    final connected = v?.connected ?? const <ConnectedAgent>[];
    final band = _LinkBand();
    final children = <Widget>[_header(pulse: connected.isNotEmpty, band: band)];
    var label = 'Agents.';
    if (v != null && !v.available) {
      label = 'Agent activity unavailable on this vault server.';
      // The copy is wider than the sidebar, so it takes two lines. Under the
      // room for both, the header alone stays.
      if (cap - metrics.headerOnly - _Metrics.headerGap >=
          2 * metrics.line - 0.01) {
        children
          ..add(const SizedBox(height: _Metrics.headerGap))
          ..add(
            Text(
              'agent activity unavailable on this vault server',
              key: const Key('agent-footer-unavailable'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: _mono(height: 1.6),
            ),
          );
      }
    } else if (v != null && connected.isEmpty) {
      label = 'No agents connected.';
      final latest = v.recent.isEmpty ? null : v.recent.first;
      final room = cap - metrics.headerOnly - _Metrics.headerGap - metrics.line;
      // Short of room, the hint goes before the last-write line.
      final lastWrite =
          latest != null && room >= _Metrics.lineGap + metrics.line - 0.01;
      // The hint is measured at the real width: a line that does not fit
      // wraps (up to two lines each) instead of losing words.
      final hintLines = _lines(_hint1) + _lines(_hint2);
      final hint =
          room - (lastWrite ? _Metrics.lineGap + metrics.line : 0) >=
          _Metrics.lineGap + hintLines * metrics.line - 0.01;
      if (latest != null) {
        label +=
            ' Last agent write '
            '${formatUpdatedAgo(v.localMs(latest.createdAt), now: now)}.';
      }
      // Under the header floor the header alone stays.
      if (room >= -0.01) {
        children
          ..add(const SizedBox(height: _Metrics.headerGap))
          ..add(
            Text(
              'no agents connected',
              key: const Key('agent-footer-empty'),
              style: _mono(height: 1.6),
            ),
          );
      }
      if (hint) {
        // Two Texts, each wrapping on its own at most twice; the budget above
        // reserved the lines they measured to.
        children
          ..add(const SizedBox(height: _Metrics.lineGap))
          ..add(
            Text(
              _hint1,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: _mono(height: 1.6),
            ),
          )
          ..add(
            Text(
              _hint2,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: _mono(height: 1.6),
            ),
          );
      }
      if (lastWrite) {
        children
          ..add(const SizedBox(height: _Metrics.lineGap))
          ..add(
            Text(
              'last agent write '
              '${_lastWriteAge(v.localMs(latest.createdAt))}',
              key: const Key('agent-footer-last-write'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: _mono(height: 1.6),
            ),
          );
      }
    } else if (v != null) {
      final plan = _planRows(
        connected: connected.length,
        recent: v.recent.length,
        m: metrics,
        cap: cap,
      );
      final shown = connected.take(plan.agents).toList();
      final feed = v.recent.take(plan.feed).toList();
      final single = connected.length == 1 ? connected.first : null;
      // Prefix every row unless exactly one agent is connected and every
      // shown entry is from its session (req 21).
      final prefixed =
          single == null ||
          feed.any((e) => e.sessionId != single.presence.sessionId);

      final sentence = StringBuffer(
        connected.length == 1
            ? '1 agent connected.'
            : '${connected.length} agents connected.',
      );
      if (shown.isNotEmpty || (shown.length < connected.length && plan.more)) {
        children.add(const SizedBox(height: _Metrics.headerGap));
      }
      for (final (i, a) in shown.indexed) {
        final age = formatAgentAge(
          v.localMs(a.presence.lastRequestAt),
          now: now,
        );
        sentence.write(
          a.working
              ? ' ${a.presence.clientName} working.'
              : ' ${a.presence.clientName} idle, '
                    '${formatUpdatedAgo(v.localMs(a.presence.lastRequestAt), now: now)}.',
        );
        children.add(_agentRow(i, a, age));
      }
      if (shown.length < connected.length && plan.more) {
        children.add(
          Text(
            '+${connected.length - shown.length} more',
            key: const Key('agent-footer-more'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: _mono(),
          ),
        );
      }
      if (feed.isNotEmpty) {
        children.add(const SizedBox(height: _Metrics.groupGap));
        for (final (i, e) in feed.indexed) {
          children.add(
            _activityRow(
              i,
              e.summary,
              prefixed ? e.clientName : null,
              formatAgentAge(v.localMs(e.createdAt), now: now),
            ),
          );
        }
        sentence.write(
          ' Latest: ${feed.first.summary.replaceAll(RegExp(r'\s*→\s*'), ' to ')}, '
          '${formatUpdatedAgo(v.localMs(feed.first.createdAt), now: now)}',
        );
      }
      label = sentence.toString();
    }

    // One VoiceOver stop (#390): the summary sentence, and (D52) a tap
    // action with the hint `Opens Agents` that opens the sheet. Not a
    // button: the node carries the status sentence.
    return Semantics(
      container: true,
      label: label,
      hint: 'Opens Agents',
      onTap: () => openAgentsSheet(context),
      excludeSemantics: true,
      child: _LinkBandHost(
        band: band,
        child: Container(
          key: const Key('agent-footer'),
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        ),
      ),
    );
  }

  String _lastWriteAge(int unixMs) {
    final age = formatAgentAge(unixMs, now: now);
    return age == 'now' ? 'just now' : '$age ago';
  }

  Widget _header({required bool pulse, required _LinkBand band}) => Row(
    children: [
      const Eyebrow('agents · live'),
      const SizedBox(width: 8),
      OmDot(
        key: const Key('agent-footer-dot'),
        color: pulse ? OmColors.agent : OmColors.fg3,
        size: 5,
        pulse: pulse,
      ),
      const Spacer(),
      _OpenLink(band: band),
    ],
  );

  Widget _agentRow(int i, ConnectedAgent a, String age) => Row(
    key: Key('agent-footer-agent-$i'),
    children: [
      Flexible(
        child: Text(
          a.presence.clientName,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.ellipsis,
          style: _mono(color: OmColors.fg1),
        ),
      ),
      const SizedBox(width: 8),
      Text(
        a.working ? 'working' : 'idle · $age',
        maxLines: 1,
        softWrap: false,
        style: _mono(color: a.working ? OmColors.agent : OmColors.fg2),
      ),
    ],
  );

  Widget _activityRow(int i, String summary, String? client, String age) {
    final base = _mono();
    return Row(
      key: Key('agent-footer-activity-$i'),
      children: [
        Expanded(
          child: client == null
              ? Text(
                  summary,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: base,
                )
              : Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: '$client ',
                        style: base.copyWith(color: OmColors.fg1),
                      ),
                      TextSpan(text: summary),
                    ],
                  ),
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: base,
                ),
        ),
        const SizedBox(width: 8),
        Text(age, maxLines: 1, softWrap: false, style: base),
      ],
    );
  }
}

/// Gives the footer's content the room it may fill: at most
/// [AgentFooter.maxFooterHeight], and when its parent is the sidebar's
/// vertical `Column`, what is left once every earlier non-flex sibling has its
/// height and the (flex) pane keeps [AgentFooter.minPaneHeight]. A `Column`
/// hands a non-flex child unbounded height, so the footer reads its
/// siblings; `minHeight` (the header alone) is the floor, since the header
/// never drops.
class _FooterBudget extends SingleChildRenderObjectWidget {
  const _FooterBudget({required this.minHeight, required super.child});

  final double minHeight;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderFooterBudget(minHeight);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderFooterBudget renderObject,
  ) {
    renderObject.minHeight = minHeight;
  }
}

class _RenderFooterBudget extends RenderProxyBox {
  _RenderFooterBudget(this._minHeight);

  double _minHeight;

  set minHeight(double value) {
    if (value == _minHeight) return;
    _minHeight = value;
    markNeedsLayout();
  }

  double _budget(BoxConstraints incoming) {
    var room = AgentFooter.maxFooterHeight;
    final p = parent;
    if (p is RenderFlex &&
        p.direction == Axis.vertical &&
        p.constraints.hasBoundedHeight) {
      var used = 0.0;
      RenderBox? c = p.firstChild;
      while (c != null && c != this) {
        final data = c.parentData! as FlexParentData;
        if ((data.flex ?? 0) == 0) used += c.size.height;
        c = data.nextSibling;
      }
      room = min(
        room,
        p.constraints.maxHeight - used - AgentFooter.minPaneHeight,
      );
    } else if (incoming.hasBoundedHeight) {
      room = min(room, incoming.maxHeight);
    }
    return max(room, _minHeight);
  }

  /// The budget travels in the constraints, so the column's own relayout
  /// (a window resize, a longer vault list) lays the footer out again: the
  /// column calls this on every one of its layouts, and the budget is read
  /// here, where reading the siblings' sizes is permitted (the column is
  /// the active layout, and it laid them out with `parentUsesSize`).
  @override
  void layout(Constraints constraints, {bool parentUsesSize = false}) {
    final incoming = constraints as BoxConstraints;
    super.layout(
      incoming.copyWith(
        maxHeight: max(
          incoming.minHeight,
          min(incoming.maxHeight, _budget(incoming)),
        ),
      ),
      parentUsesSize: parentUsesSize,
    );
  }
}

/// The header's `OPEN ↗` link (#408, Spec #394 req 2, D13): fg2 at rest, fg0
/// with an underline (the default offset) while the pointer is over it, the
/// click cursor, the tooltip `Agents ⇧⌘A`, and a tap opens the Agents sheet.
/// It is a mouse affordance with no focus treatment (⇧⌘A is the keyboard
/// path, and the footer's one semantics leaf has the tap action, D52), and
/// adds no semantics outside that leaf. The Key names the label's own text
/// box.
///
/// Its hit box (D52) is the label's width and at least [_linkHitHeight] tall,
/// centred on the label: the tap, the click cursor, the tooltip and the hover
/// colour all follow it. It reaches past the header row without growing it,
/// so no footer element moves: [_LinkBandHost] hit-tests the band before the
/// footer's own children.
class _OpenLink extends StatefulWidget {
  const _OpenLink({required this.band});

  final _LinkBand band;

  @override
  State<_OpenLink> createState() => _OpenLinkState();
}

class _OpenLinkState extends State<_OpenLink> {
  bool _hover = false;

  void _setHover(bool hover) {
    if (_hover != hover) setState(() => _hover = hover);
  }

  @override
  Widget build(BuildContext context) => _LinkBandTarget(
    band: widget.band,
    child: Tooltip(
      message: 'Agents ⇧⌘A',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => _setHover(true),
        onExit: (_) => _setHover(false),
        child: GestureDetector(
          onTap: () => openAgentsSheet(context),
          child: Text(
            'OPEN ↗',
            key: const Key('agent-footer-open'),
            style:
                OmType.mono(
                  size: 10.5,
                  color: _hover ? OmColors.fg0 : OmColors.fg2,
                  letterSpacing: 0.8,
                ).copyWith(
                  decoration: _hover
                      ? TextDecoration.underline
                      : TextDecoration.none,
                  decorationColor: OmColors.fg0,
                ),
          ),
        ),
      ),
    ),
  );
}

/// The minimum height of the `OPEN ↗` link's hit box (D52).
const _linkHitHeight = 24.0;

/// Joins the footer's [_LinkBandHost] to the link's [_LinkBandTarget] for one
/// build of the footer.
class _LinkBand {
  _RenderLinkBandTarget? target;
}

/// Hit-tests the link's band before its child. The band reaches past the
/// header row (and the column that holds it), which would reject a point
/// outside their boxes, but it stays inside the footer's padding.
class _LinkBandHost extends SingleChildRenderObjectWidget {
  const _LinkBandHost({required this.band, required super.child});

  final _LinkBand band;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderLinkBandHost(band);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderLinkBandHost renderObject,
  ) {
    renderObject.band = band;
  }
}

class _RenderLinkBandHost extends RenderProxyBox {
  _RenderLinkBandHost(this.band);

  _LinkBand band;

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    final target = band.target;
    if (size.contains(position) &&
        target != null &&
        target.hasSize &&
        _holds(target)) {
      final hit = result.addWithPaintTransform(
        transform: target.getTransformTo(this),
        position: position,
        hitTest: (result, local) => target.hitTestBand(result, local),
      );
      if (hit) {
        result.add(BoxHitTestEntry(this, position));
        return true;
      }
    }
    return super.hitTest(result, position: position);
  }

  bool _holds(RenderObject node) {
    for (RenderObject? p = node.parent; p != null; p = p.parent) {
      if (identical(p, this)) return true;
    }
    return false;
  }
}

/// Marks the link's box for [_LinkBandHost]; laid out and painted as its
/// child alone.
class _LinkBandTarget extends SingleChildRenderObjectWidget {
  const _LinkBandTarget({required this.band, required super.child});

  final _LinkBand band;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderLinkBandTarget(band);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderLinkBandTarget renderObject,
  ) {
    renderObject.band = band;
  }
}

class _RenderLinkBandTarget extends RenderProxyBox {
  _RenderLinkBandTarget(this._band);

  _LinkBand _band;

  set band(_LinkBand value) {
    if (identical(value, _band)) return;
    if (identical(_band.target, this)) _band.target = null;
    _band = value;
    if (attached) value.target = this;
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _band.target = this;
  }

  @override
  void detach() {
    if (identical(_band.target, this)) _band.target = null;
    super.detach();
  }

  /// The hit box in local coordinates: the label's width, at least
  /// [_linkHitHeight] tall, centred on the label.
  Rect get _bandRect {
    final h = max(size.height, _linkHitHeight);
    return Rect.fromLTWH(0, (size.height - h) / 2, size.width, h);
  }

  /// Hits the link for any [local] point in its band: a point off the label
  /// reaches the link's tooltip, cursor, hover and tap on the label's centre
  /// line.
  bool hitTestBand(BoxHitTestResult result, Offset local) {
    if (!_bandRect.contains(local)) return false;
    final inner = size.contains(local)
        ? local
        : Offset(local.dx, size.height / 2);
    return hitTest(result, position: inner);
  }
}
