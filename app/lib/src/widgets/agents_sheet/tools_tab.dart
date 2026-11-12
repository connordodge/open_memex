import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../agents_sheet/tools/tool_catalog.dart';
import '../../state/agents_sheet/tools_tab_state.dart';
import '../../state/settings.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../atoms.dart';
import '../inline_error.dart';
import '../memex_too_old_dialog.dart' show locateMemexBinary;
import 'agents_tab_loading.dart';

/// The Agents sheet's `Tools` tab body (Spec #394 req 13, 15, 16, 32-35,
/// 47): the prompts and the tools the memex binary (or the vault server)
/// reports, in the Spec's groups, with a filter. The list is read once per
/// sheet open by `toolsTabProvider`; this widget only shows it.
class ToolsTab extends ConsumerStatefulWidget {
  const ToolsTab({super.key});

  /// Below this window width a row stacks (Spec #394 req 47).
  static const stackBelow = 672.0;

  @override
  ConsumerState<ToolsTab> createState() => _ToolsTabState();
}

const _nameColumn = 186.0;
const _columnGap = 12.0;
const _tagColumn = 46.0;

const _intro = 'What an agent connected to this vault can call. ';
const _introTail = ' tools change the vault and show under Live.';
const _promptsLabel = 'PROMPTS · START A RUN FROM THE CLIENT’S PROMPT MENU';

class _ToolsTabState extends ConsumerState<ToolsTab> {
  final _filter = TextEditingController();
  final _filterNode = FocusNode(debugLabel: 'tools-filter');

  // The error result the person dismissed; it shows nothing until the next
  // read gives a new result.
  ToolCatalogError? _dismissed;
  bool _locating = false;

  @override
  void initState() {
    super.initState();
    _filter.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _filter.dispose();
    _filterNode.dispose();
    super.dispose();
  }

  Future<void> _locate() async {
    if (_locating) return;
    _locating = true;
    try {
      final before = ref.read(settingsProvider).memexBinaryPath;
      await locateMemexBinary(ref.read(settingsProvider.notifier));
      if (!mounted) return;
      // A different path rebuilds the read through the settings watch. The
      // same path (a reinstalled binary) changes nothing there, so read again.
      if (ref.read(settingsProvider).memexBinaryPath == before) {
        await ref.read(toolsTabProvider.notifier).retry();
      }
    } finally {
      _locating = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final read = ref.watch(toolsTabProvider);
    final result = read.isLoading ? null : read.valueOrNull;
    if (result == null) return const AgentsTabLoading();
    return switch (result) {
      ToolCatalogOk(:final catalog) => _list(context, catalog),
      ToolCatalogBinaryNotFound() => _unavailable(
        'memex not found',
        action: OmButton(
          key: const Key('tools-locate-memex'),
          label: 'Locate memex…',
          focusable: true,
          onPressed: _locate,
        ),
      ),
      ToolCatalogTooOld() => _unavailable(
        'Tool list unavailable: this memex is older than the app.',
      ),
      ToolCatalogServerTooOld() => _unavailable(
        'Tool list unavailable on this vault server.',
      ),
      ToolCatalogError() when identical(result, _dismissed) =>
        const SizedBox.shrink(),
      ToolCatalogError(:final message) => InlineError(
        message: message,
        onRetry: () => ref.read(toolsTabProvider.notifier).retry(),
        onDismiss: () => setState(() => _dismissed = result),
      ),
    };
  }

  /// A state with no list: a heading (7 px fg2 dot, sans 14 w600 fg0) and an
  /// optional action under it.
  Widget _unavailable(String heading, {Widget? action}) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: const BoxDecoration(
              color: OmColors.fg2,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              heading,
              style: OmType.sans(
                size: 14,
                weight: FontWeight.w600,
                color: OmColors.fg0,
              ),
            ),
          ),
        ],
      ),
      if (action != null) ...[const SizedBox(height: 10), action],
    ],
  );

  Widget _list(BuildContext context, ToolCatalog catalog) {
    final stacked = MediaQuery.sizeOf(context).width < ToolsTab.stackBelow;
    final query = _filter.text;
    final sections = groupTools(catalog.matchingTools(query));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _introText(),
        const SizedBox(height: 12),
        _filterField(),
        if (catalog.prompts.isNotEmpty)
          _Section(
            labelKey: const Key('tools-prompts-label'),
            label: _promptsLabel,
            rows: [
              for (final p in catalog.prompts)
                _ToolRow(
                  rowKey: Key('prompt-row-${p.name}'),
                  nameKey: Key('prompt-name-${p.name}'),
                  summaryKey: Key('prompt-summary-${p.name}'),
                  name: p.name,
                  summary: p.summary,
                  writes: false,
                  stacked: stacked,
                ),
            ],
          ),
        if (sections.isEmpty && query.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 18),
            child: Text(
              'No tools match this filter.',
              key: const Key('tools-filter-empty'),
              style: OmType.sans(size: 12.5, color: OmColors.fg2),
            ),
          ),
        for (final s in sections)
          _Section(
            labelKey: Key('tools-group-${s.id}'),
            label: s.label.toUpperCase(),
            rows: [
              for (final t in s.tools)
                _ToolRow(
                  rowKey: Key('tool-row-${t.name}'),
                  nameKey: Key('tool-name-${t.name}'),
                  summaryKey: Key('tool-summary-${t.name}'),
                  name: t.name,
                  summary: t.summary,
                  writes: t.writes,
                  stacked: stacked,
                ),
            ],
          ),
      ],
    );
  }

  Widget _introText() {
    final style = OmType.sans(size: 12.5, height: 1.55, color: OmColors.fg2);
    return Text.rich(
      key: const Key('tools-intro'),
      TextSpan(
        style: style,
        children: [
          const TextSpan(text: _intro),
          TextSpan(
            text: 'WRITES',
            style: style.copyWith(color: OmColors.agent),
          ),
          const TextSpan(text: _introTail),
        ],
      ),
    );
  }

  Widget _filterField() {
    return Container(
      key: const Key('tools-filter-box'),
      constraints: const BoxConstraints(minHeight: 30),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: OmColors.surface0,
        border: Border.all(color: OmColors.line2),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          const Icon(LucideIcons.search, size: 13, color: OmColors.fg2),
          const SizedBox(width: 8),
          Expanded(
            // Shift-cmd-A belongs to the native Agents menu item: the field
            // never handles it, so it reaches the menu.
            child: Focus(
              canRequestFocus: false,
              skipTraversal: true,
              onKeyEvent: (node, event) => KeyEventResult.ignored,
              child: TextField(
                key: const Key('tools-filter'),
                controller: _filter,
                focusNode: _filterNode,
                cursorColor: OmColors.accent,
                style: OmType.sans(size: 12.5, color: OmColors.fg0),
                decoration: InputDecoration.collapsed(
                  hintText: 'Filter tools',
                  hintStyle: OmType.sans(size: 12.5, color: OmColors.fg2),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A labelled block: 18 px above, the label (mono 10.5 w500, 0.8 spacing,
/// fg2) 8 px above its rows.
class _Section extends StatelessWidget {
  const _Section({
    required this.labelKey,
    required this.label,
    required this.rows,
  });

  final Key labelKey;
  final String label;
  final List<Widget> rows;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 18),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            label,
            key: labelKey,
            style: OmType.mono(
              size: 10.5,
              weight: FontWeight.w500,
              color: OmColors.fg2,
              letterSpacing: 0.8,
            ),
          ),
        ),
        ...rows,
      ],
    ),
  );
}

/// One tool or prompt row. Wide: name column 186, gap 12, the summary, gap
/// 12, then the `WRITES` tag right-aligned. Stacked: the name with its tag 8
/// px after it, the summary 2 px under. Every row has a 1 px line1 bottom
/// border.
class _ToolRow extends StatelessWidget {
  const _ToolRow({
    required this.rowKey,
    required this.nameKey,
    required this.summaryKey,
    required this.name,
    required this.summary,
    required this.writes,
    required this.stacked,
  });

  final Key rowKey;
  final Key nameKey;
  final Key summaryKey;
  final String name;
  final String summary;
  final bool writes;
  final bool stacked;

  @override
  Widget build(BuildContext context) {
    final nameText = Text(
      name,
      key: nameKey,
      style: OmType.mono(size: 12, color: OmColors.fg0),
    );
    final summaryText = Text(
      summary,
      key: summaryKey,
      style: OmType.sans(size: 12, color: OmColors.fg2),
    );
    return DecoratedBox(
      key: rowKey,
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: OmColors.line1)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: stacked
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Wrap(
                    spacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [nameText, if (writes) const _WritesTag()],
                  ),
                  const SizedBox(height: 2),
                  summaryText,
                ],
              )
            : Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  SizedBox(width: _nameColumn, child: nameText),
                  const SizedBox(width: _columnGap),
                  Expanded(child: summaryText),
                  const SizedBox(width: _columnGap),
                  if (writes)
                    ConstrainedBox(
                      constraints: const BoxConstraints(minWidth: _tagColumn),
                      child: const Align(
                        alignment: Alignment.centerRight,
                        child: _WritesTag(),
                      ),
                    )
                  else
                    const SizedBox(width: _tagColumn),
                ],
              ),
      ),
    );
  }
}

/// The `WRITES` tag of a tool that changes the vault.
class _WritesTag extends StatelessWidget {
  const _WritesTag();

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
    decoration: BoxDecoration(
      color: OmColors.writesTagBg,
      borderRadius: BorderRadius.circular(3),
    ),
    child: Text(
      'WRITES',
      style: OmType.mono(
        size: 9.5,
        weight: FontWeight.w500,
        color: OmColors.agent,
        height: 1.0,
        letterSpacing: 0.8,
      ),
    ),
  );
}
