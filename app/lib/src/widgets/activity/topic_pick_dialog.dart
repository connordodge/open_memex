import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../editor/fuzzy_score.dart';
import '../../editor/markdown_preview_text.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';

/// A `role: topic` note a block can be moved or filed into.
class TopicChoice {
  const TopicChoice({required this.id, required this.title});
  final String id;
  final String title;
}

/// What the topic dialog resolves: the chosen existing topic note
/// ([topicNoteId]) or the title of a topic note to create ([createTitle]);
/// exactly one of them is set. [why] is the trimmed `Why?` text, null when
/// blank.
class TopicPickResult {
  const TopicPickResult({this.topicNoteId, this.createTitle, this.why});
  final String? topicNoteId;
  final String? createTitle;
  final String? why;
}

/// The topic notes of [all] that match [query] (trimmed, case-insensitive,
/// `fuzzyScore` above zero), best match first; ties by title, then id.
/// [excludeId] is left out. An empty query keeps every topic.
List<TopicChoice> matchTopics(
  List<TopicChoice> all,
  String query, {
  String? excludeId,
}) {
  final needle = query.trim().toLowerCase();
  final scored = <(int, TopicChoice)>[];
  for (final t in all) {
    if (t.id == excludeId) continue;
    final score = fuzzyScore(t.title.toLowerCase(), needle);
    if (score > 0) scored.add((score, t));
  }
  scored.sort((a, b) {
    final byScore = b.$1.compareTo(a.$1);
    if (byScore != 0) return byScore;
    final byTitle = a.$2.title.toLowerCase().compareTo(
      b.$2.title.toLowerCase(),
    );
    return byTitle != 0 ? byTitle : a.$2.id.compareTo(b.$2.id);
  });
  return [for (final s in scored) s.$2];
}

/// The most grapheme clusters of a block's preview a dialog line shows.
const _previewLimit = 48;

/// The preview of the block whose markdown is [markdown], quoted as a dialog
/// line shows it: `markdownPreviewText` cut to its first 48 grapheme clusters,
/// trailing whitespace trimmed, then `…`; a preview of 48 or fewer is whole.
String _quotedPreview(String markdown) {
  final preview = markdownPreviewText(markdown);
  final clusters = preview.characters;
  if (clusters.length <= _previewLimit) return '“$preview”';
  final cut = clusters.take(_previewLimit).toString().trimRight();
  return '“$cut…”';
}

String? _whyOf(String text) {
  final why = text.trim();
  return why.isEmpty ? null : why;
}

/// `Move to…` / `File in…`: pick a topic note (Key `filed-topic-field` filters
/// the list with `fuzzyScore`; options have Keys `filed-topic-option-<id>`,
/// the `Create "<name>"` row `filed-topic-create`), an optional `Why?` (Key
/// `filed-why-field`) and confirm (Key `filed-confirm`) or cancel (Key
/// `filed-cancel`). [loadTopics] lists every topic note; [excludeId] (the
/// source topic note of a move) is not offered. Resolves null on Cancel and
/// Esc.
///
/// A line under the title quotes the block ([blockText], its markdown) and,
/// when [fromTopicTitle] is set (a move), the topic it is in.
///
/// Arrow keys move the highlight over the matches (clamped), Enter chooses the
/// highlighted match (the `Create` row when nothing matches) and, once a
/// target is chosen, confirms.
Future<TopicPickResult?> showTopicPickDialog(
  BuildContext context, {
  required String title,
  required String confirmLabel,
  required Future<List<TopicChoice>> Function() loadTopics,
  required String blockText,
  String? fromTopicTitle,
  String? excludeId,
}) => showDialog<TopicPickResult>(
  context: context,
  builder: (_) => _PickDialog(
    title: title,
    line: fromTopicTitle == null
        ? _quotedPreview(blockText)
        : '${_quotedPreview(blockText)} from $fromTopicTitle',
    confirmLabel: confirmLabel,
    loadTopics: loadTopics,
    excludeId: excludeId,
    withTopic: true,
  ),
);

/// `Remove from <topicTitle>`: says the block ([blockText], its markdown)
/// stays in the day, and asks for an optional `Why?` (Key `filed-why-field`).
/// Resolves the trimmed text (null when blank) wrapped in a record, or null on
/// Cancel and Esc.
Future<({String? why})?> showRemoveBlockDialog(
  BuildContext context, {
  required String topicTitle,
  required String blockText,
}) async {
  final result = await showDialog<TopicPickResult>(
    context: context,
    builder: (_) => _PickDialog(
      title: 'Remove from $topicTitle',
      line:
          '${_quotedPreview(blockText)} stays in the day; only this block is '
          'taken out of $topicTitle.',
      confirmLabel: 'Remove',
      loadTopics: () async => const [],
      withTopic: false,
    ),
  );
  return result == null ? null : (why: result.why);
}

class _PickDialog extends StatefulWidget {
  const _PickDialog({
    required this.title,
    required this.line,
    required this.confirmLabel,
    required this.loadTopics,
    required this.withTopic,
    this.excludeId,
  });

  final String title;

  /// The line under the title.
  final String line;
  final String confirmLabel;
  final Future<List<TopicChoice>> Function() loadTopics;
  final String? excludeId;
  final bool withTopic;

  @override
  State<_PickDialog> createState() => _PickDialogState();
}

class _PickDialogState extends State<_PickDialog> {
  final _topic = TextEditingController();
  final _why = TextEditingController();
  final _topicFocus = FocusNode();
  final _whyFocus = FocusNode();

  List<TopicChoice> _all = const [];
  int _highlight = 0;
  String? _chosenId;
  String? _chosenCreate;
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    _topic.addListener(_onQueryChanged);
    if (widget.withTopic) _load();
  }

  Future<void> _load() async {
    List<TopicChoice> loaded;
    try {
      loaded = await widget.loadTopics();
    } catch (_) {
      loaded = const [];
    }
    if (mounted) setState(() => _all = loaded);
  }

  String _lastQuery = '';

  void _onQueryChanged() {
    if (_topic.text == _lastQuery) return;
    _lastQuery = _topic.text;
    setState(() {
      _highlight = 0;
      _chosenId = null;
      _chosenCreate = null;
    });
  }

  @override
  void dispose() {
    _topic.dispose();
    _why.dispose();
    _topicFocus.dispose();
    _whyFocus.dispose();
    super.dispose();
  }

  List<TopicChoice> get _matches =>
      matchTopics(_all, _topic.text, excludeId: widget.excludeId);

  /// The name `Create "<name>"` would create, or null when none is offered.
  String? get _createName {
    final name = _topic.text.trim();
    if (name.isEmpty) return null;
    for (final t in _all) {
      if (t.title == name) return null;
    }
    return name;
  }

  void _close(TopicPickResult? result) {
    if (_closed) return;
    _closed = true;
    Navigator.of(context).pop(result);
  }

  void _confirm() {
    if (_closed) return;
    final why = _whyOf(_why.text);
    if (!widget.withTopic) return _close(TopicPickResult(why: why));
    final id = _chosenId;
    if (id != null) return _close(TopicPickResult(topicNoteId: id, why: why));
    final create = _chosenCreate;
    if (create != null) {
      return _close(TopicPickResult(createTitle: create, why: why));
    }
  }

  void _chooseHighlighted() {
    final matches = _matches;
    setState(() {
      if (matches.isNotEmpty) {
        _chosenId = matches[min(_highlight, matches.length - 1)].id;
        _chosenCreate = null;
      } else if (_createName != null) {
        _chosenCreate = _createName;
        _chosenId = null;
      }
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      _close(null);
      return KeyEventResult.handled;
    }
    if (widget.withTopic && _topicFocus.hasFocus) {
      if (key == LogicalKeyboardKey.arrowDown) {
        final last = max(_matches.length - 1, 0);
        setState(() => _highlight = min(_highlight + 1, last));
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowUp) {
        setState(() => _highlight = max(_highlight - 1, 0));
        return KeyEventResult.handled;
      }
    }
    if (key == LogicalKeyboardKey.enter &&
        (_topicFocus.hasFocus || _whyFocus.hasFocus)) {
      if (widget.withTopic && _chosenId == null && _chosenCreate == null) {
        _chooseHighlighted();
      } else {
        _confirm();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final matches = _matches;
    final create = _createName;
    final highlighted = matches.isEmpty
        ? null
        : matches[min(_highlight, matches.length - 1)].id;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onKey,
      child: AlertDialog(
        // A long topic title wraps at the content width instead of widening
        // the dialog.
        title: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Text(widget.title),
        ),
        // 6 px under the title (the default is 16), 16 px above the fields.
        contentPadding: const EdgeInsets.fromLTRB(24, 6, 24, 24),
        content: SizedBox(
          width: 360,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  widget.line,
                  key: const Key('filed-dialog-line'),
                  style: OmType.sans(
                    size: 12,
                    color: OmColors.fg2,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 16),
                if (widget.withTopic) ...[
                  TextField(
                    key: const Key('filed-topic-field'),
                    controller: _topic,
                    focusNode: _topicFocus,
                    autofocus: true,
                    decoration: const InputDecoration(labelText: 'Topic note'),
                  ),
                  const SizedBox(height: 8),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 200),
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        for (final t in matches)
                          _OptionRow(
                            key: Key('filed-topic-option-${t.id}'),
                            label: t.title,
                            highlighted: t.id == highlighted,
                            chosen: t.id == _chosenId,
                            onTap: () => setState(() {
                              _chosenId = t.id;
                              _chosenCreate = null;
                            }),
                          ),
                        if (create != null)
                          _OptionRow(
                            key: const Key('filed-topic-create'),
                            label: 'Create "$create"',
                            highlighted: matches.isEmpty,
                            chosen: _chosenCreate != null,
                            onTap: () => setState(() {
                              _chosenCreate = create;
                              _chosenId = null;
                            }),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
                TextField(
                  key: const Key('filed-why-field'),
                  controller: _why,
                  focusNode: _whyFocus,
                  autofocus: !widget.withTopic,
                  decoration: const InputDecoration(
                    labelText: 'Why? (optional)',
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            key: const Key('filed-cancel'),
            onPressed: () => _close(null),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('filed-confirm'),
            onPressed: _confirm,
            child: Text(widget.confirmLabel),
          ),
        ],
      ),
    );
  }
}

class _OptionRow extends StatelessWidget {
  const _OptionRow({
    super.key,
    required this.label,
    required this.highlighted,
    required this.chosen,
    required this.onTap,
  });

  final String label;
  final bool highlighted;
  final bool chosen;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      canRequestFocus: false,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        color: highlighted ? OmColors.surface4 : null,
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: OmType.sans(
                  size: 13,
                  color: chosen ? OmColors.accent : OmColors.fg0,
                ),
              ),
            ),
            if (chosen)
              const Icon(LucideIcons.check, size: 14, color: OmColors.accent),
          ],
        ),
      ),
    );
  }
}
