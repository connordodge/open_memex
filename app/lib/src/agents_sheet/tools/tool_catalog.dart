// WI #412 (Spec #394 req 13, 15-16, 32-35): the tool and prompt list the
// Tools tab shows, and how it is read. The list is the binary's (`memex
// tools`, `GET .../tools`): never copied into Dart. Skeleton: the types and
// signatures are frozen; the bodies are the implementer's.

/// One MCP tool as `memex tools` reports it.
class ToolInfo {
  const ToolInfo({
    required this.name,
    required this.summary,
    required this.group,
    required this.writes,
  });

  final String name;
  final String summary;

  /// The group id (`notes`, `daily`, ...); a newer binary may send one the
  /// app does not know.
  final String group;

  /// True for a tool that changes the vault (it carries the `WRITES` tag).
  final bool writes;
}

/// One MCP prompt as `memex tools` reports it.
class PromptInfo {
  const PromptInfo({required this.name, required this.summary});

  final String name;
  final String summary;
}

/// `{tools: [{name, summary, group, writes}], prompts: [{name, summary}]}`.
class ToolCatalog {
  const ToolCatalog({required this.tools, required this.prompts});

  /// Reads the wire shape. Order is kept. Throws [FormatException] when the
  /// shape is wrong: not an object, `tools` or `prompts` missing or not a
  /// list, an entry that is not an object, a missing or non-string `name`,
  /// `summary` or `group`, or a non-bool `writes`.
  factory ToolCatalog.fromJson(Object? json) {
    if (json is! Map) throw const FormatException('expected a JSON object');
    final tools = _list(json, 'tools');
    final prompts = _list(json, 'prompts');
    return ToolCatalog(
      tools: [
        for (final t in tools)
          ToolInfo(
            name: _string(t, 'name'),
            summary: _string(t, 'summary'),
            group: _string(t, 'group'),
            writes: _bool(t, 'writes'),
          ),
      ],
      prompts: [
        for (final p in prompts)
          PromptInfo(name: _string(p, 'name'), summary: _string(p, 'summary')),
      ],
    );
  }

  /// In the order the binary returned them.
  final List<ToolInfo> tools;
  final List<PromptInfo> prompts;

  /// The tools whose name or summary contains [query], ignoring case, in
  /// their original order. A blank [query] keeps every tool.
  List<ToolInfo> matchingTools(String query) {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return tools;
    return [
      for (final t in tools)
        if (t.name.toLowerCase().contains(needle) ||
            t.summary.toLowerCase().contains(needle))
          t,
    ];
  }
}

List<Map<Object?, Object?>> _list(Map<Object?, Object?> json, String key) {
  final value = json[key];
  if (value is! List) throw FormatException('`$key` is not a list');
  return [
    for (final e in value)
      if (e is Map)
        e
      else
        throw FormatException('an entry of `$key` is not an object'),
  ];
}

String _string(Map<Object?, Object?> json, String key) {
  final value = json[key];
  if (value is! String) throw FormatException('`$key` is not a string');
  return value;
}

bool _bool(Map<Object?, Object?> json, String key) {
  final value = json[key];
  if (value is! bool) throw FormatException('`$key` is not a bool');
  return value;
}

/// A known tool group: its wire [id] and section [label] (req 34).
class ToolGroup {
  const ToolGroup(this.id, this.label);

  final String id;
  final String label;
}

/// The known groups in display order (req 34).
const toolGroups = <ToolGroup>[
  ToolGroup('notes', 'Notes and search'),
  ToolGroup('daily', 'Daily review'),
  ToolGroup('folders', 'Smart Folders'),
  ToolGroup('tags', 'Tags and Note footer'),
  ToolGroup('feedback', 'Feedback and Vault Guide'),
  ToolGroup('canvas', 'Canvases'),
];

/// The id [groupTools] gives the trailing group of unknown ids.
const otherToolGroupId = 'other';

/// One section of the list: a [label] and its [tools], in returned order.
class ToolSection {
  const ToolSection({
    required this.id,
    required this.label,
    required this.tools,
  });

  final String id;
  final String label;
  final List<ToolInfo> tools;
}

/// [tools] in sections: the known groups in [toolGroups] order (a group with
/// no tools is left out), then `Other` ([otherToolGroupId]) holding every
/// tool whose group is not a known id, if any. Tools keep the order they
/// came in within a section.
List<ToolSection> groupTools(List<ToolInfo> tools) {
  final known = {for (final g in toolGroups) g.id};
  return [
    for (final g in toolGroups)
      if (tools.any((t) => t.group == g.id))
        ToolSection(
          id: g.id,
          label: g.label,
          tools: [
            for (final t in tools)
              if (t.group == g.id) t,
          ],
        ),
    if (tools.any((t) => !known.contains(t.group)))
      ToolSection(
        id: otherToolGroupId,
        label: 'Other',
        tools: [
          for (final t in tools)
            if (!known.contains(t.group)) t,
        ],
      ),
  ];
}

/// What reading the tool list gave. Reads never throw for an expected
/// failure: those are results.
sealed class ToolCatalogResult {
  const ToolCatalogResult();
}

/// The list.
final class ToolCatalogOk extends ToolCatalogResult {
  const ToolCatalogOk(this.catalog);

  final ToolCatalog catalog;
}

/// Local vault and no `memex` binary (none configured, or it cannot start).
final class ToolCatalogBinaryNotFound extends ToolCatalogResult {
  const ToolCatalogBinaryNotFound();
}

/// `memex tools` exited with a usage error (clap exit 2): the memex is older
/// than the app.
final class ToolCatalogTooOld extends ToolCatalogResult {
  const ToolCatalogTooOld();
}

/// Hosted vault: the server answered `404 not_found` (no such route), so it
/// is older than the app.
final class ToolCatalogServerTooOld extends ToolCatalogResult {
  const ToolCatalogServerTooOld();
}

/// Any other failure. [message] is the CLI's or the server's own message,
/// without the `<operation> failed: ` prefix.
final class ToolCatalogError extends ToolCatalogResult {
  const ToolCatalogError(this.message);

  final String message;
}
