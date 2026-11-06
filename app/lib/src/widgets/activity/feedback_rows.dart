import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../db.dart';
import '../../db/activity_reads.dart';
import '../../db/feedback_reads.dart';
import '../../memex_cli.dart';
import '../../state/feedback_state.dart';
import '../../state/vault_state.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../../vault_access/errors.dart';
import '../atoms.dart';
import '../inline_error.dart';

/// The longest comment the vault accepts, in characters after trimming.
const maxCommentLength = 2000;

const _handledCode = 'feedback_handled';

/// Where the Feedback of one Activity tab goes (Spec #233 R23): [byEntry]
/// holds what hangs on an agent entry, [above] everything else, which shows
/// above the entries. Rows are newest first in every home.
class FeedbackHomes {
  const FeedbackHomes({required this.byEntry, required this.above});

  /// Feedback by `agent_change_id` of an entry on the tab.
  final Map<String, List<FeedbackRow>> byEntry;

  /// Feedback with no entry on the tab (no `agent_change_id`, or one whose
  /// entry no longer exists), plus the Vault Guide's no-note Feedback.
  final List<FeedbackRow> above;

  bool get isEmpty => byEntry.isEmpty && above.isEmpty;
}

/// The Feedback a note's Activity tab can show: the note's own rows, plus on
/// the Vault Guide's tab the rows that name no note.
class ActivityFeedback {
  const ActivityFeedback._(this._own, this._loose);

  /// Watches the Feedback reads for [note]. Both reads are empty below V6.
  factory ActivityFeedback.watch(WidgetRef ref, Note note) {
    final own = watchVaultValue(
      ref,
      feedbackForNoteProvider(note.id),
      const <FeedbackRow>[],
    );
    final loose = note.role == 'guide'
        ? watchVaultValue(
            ref,
            feedbackWithoutNoteProvider,
            const <FeedbackRow>[],
          )
        : const <FeedbackRow>[];
    return ActivityFeedback._(own, loose);
  }

  final List<FeedbackRow> _own;
  final List<FeedbackRow> _loose;

  /// Sorts the rows into their homes given the tab's [entries].
  FeedbackHomes homes(List<AgentChangeRow> entries) {
    final ids = {for (final e in entries) e.id};
    final byEntry = <String, List<FeedbackRow>>{};
    final unplaced = <FeedbackRow>[];
    for (final row in _own) {
      if (_isUndecodable(row)) continue;
      final change = row.agentChangeId;
      if (change != null && ids.contains(change)) {
        (byEntry[change] ??= []).add(row);
      } else {
        unplaced.add(row);
      }
    }
    return FeedbackHomes(
      byEntry: byEntry,
      above: _mergeNewestFirst(unplaced, [
        for (final row in _loose)
          if (!_isUndecodable(row)) row,
      ]),
    );
  }
}

/// A Correction whose stored change cannot be decoded renders nothing at all:
/// no row, no text, no status.
bool _isUndecodable(FeedbackRow row) =>
    row.kind == FeedbackKind.correction && row.correction == null;

/// Two newest-first lists merged newest first; on a tie [a] goes first.
List<FeedbackRow> _mergeNewestFirst(List<FeedbackRow> a, List<FeedbackRow> b) {
  final out = <FeedbackRow>[];
  var i = 0;
  var j = 0;
  while (i < a.length && j < b.length) {
    out.add(a[i].createdAt >= b[j].createdAt ? a[i++] : b[j++]);
  }
  out
    ..addAll(a.skip(i))
    ..addAll(b.skip(j));
  return out;
}

/// The Feedback rows above an Activity tab's entries.
class FeedbackAboveEntries extends StatelessWidget {
  const FeedbackAboveEntries({super.key, required this.rows});
  final List<FeedbackRow> rows;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final row in rows)
          Padding(
            key: ValueKey('feedback-home-${row.id}'),
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: FeedbackRowTile(row: row),
          ),
        const OmHairline(),
      ],
    );
  }
}

/// What hangs under one agent entry: its Feedback rows, then the Comment
/// action (or its open input). Below V6 there is neither.
class EntryFeedback extends ConsumerStatefulWidget {
  const EntryFeedback({super.key, required this.entry, required this.rows});
  final AgentChangeRow entry;
  final List<FeedbackRow> rows;

  @override
  ConsumerState<EntryFeedback> createState() => _EntryFeedbackState();
}

class _EntryFeedbackState extends ConsumerState<EntryFeedback> {
  bool _composing = false;

  Future<CommentSaveResult> _save(String text) async {
    final entry = widget.entry;
    try {
      final added = await guardVaultWrite(
        context,
        () => ref
            .read(feedbackActionsProvider)
            .addComment(
              noteId: entry.noteId,
              date: entry.day,
              changeId: entry.id,
              text: text,
            ),
      );
      if (added == null) return const CommentSaveResult.unreachable();
      if (mounted) setState(() => _composing = false);
      return const CommentSaveResult.saved();
    } on MemexException catch (e) {
      return CommentSaveResult.failed(e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canComment = ref.watch(vaultV6ReadyProvider);
    if (widget.rows.isEmpty && !canComment) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final row in widget.rows)
          Padding(
            key: ValueKey('feedback-home-${row.id}'),
            padding: const EdgeInsets.only(top: 8),
            child: FeedbackRowTile(row: row),
          ),
        if (canComment)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: _composing
                ? CommentComposer(
                    onSave: _save,
                    onCancel: () => setState(() => _composing = false),
                  )
                : Align(
                    alignment: Alignment.centerLeft,
                    child: OmButton(
                      key: Key('activity-comment-${widget.entry.id}'),
                      kind: OmButtonKind.ghost,
                      size: 24,
                      dense: true,
                      label: 'Comment',
                      onPressed: () => setState(() => _composing = true),
                    ),
                  ),
          ),
      ],
    );
  }
}

/// How a [CommentComposer] save ended.
class CommentSaveResult {
  const CommentSaveResult._(this.done, this.error);

  /// The vault took the text: the composer closes.
  const CommentSaveResult.saved() : this._(true, null);

  /// The write failed with [message]: the composer stays with its text.
  const CommentSaveResult.failed(String message) : this._(false, message);

  /// The vault server could not be reached (the snackbar said so): the
  /// composer stays with its text.
  const CommentSaveResult.unreachable() : this._(false, null);

  final bool done;
  final String? error;
}

/// A multi-line comment input with Cancel and Save (keys `comment-field`,
/// `comment-cancel`, `comment-save`). Save sends the trimmed text and refuses
/// it, with no call to [onSave], when it is empty after trimming or when the
/// raw text is over [maxCommentLength] Unicode code points.
class CommentComposer extends StatefulWidget {
  const CommentComposer({
    super.key,
    this.initialText = '',
    required this.onSave,
    required this.onCancel,
  });
  final String initialText;
  final Future<CommentSaveResult> Function(String text) onSave;
  final VoidCallback onCancel;

  @override
  State<CommentComposer> createState() => _CommentComposerState();
}

class _CommentComposerState extends State<CommentComposer> {
  late final TextEditingController _ctrl = TextEditingController(
    text: widget.initialText,
  );
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy) return;
    final raw = _ctrl.text;
    final text = raw.trim();
    if (text.isEmpty) {
      setState(() => _error = 'write a comment first.');
      return;
    }
    // The limit counts the raw text in Unicode code points (core's chars()).
    if (raw.runes.length > maxCommentLength) {
      setState(
        () => _error = 'comments are at most $maxCommentLength characters.',
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await widget.onSave(text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (!result.done) _error = result.error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (error != null)
          InlineError(
            message: error,
            onDismiss: () => setState(() => _error = null),
          ),
        TextField(
          key: const Key('comment-field'),
          controller: _ctrl,
          autofocus: true,
          minLines: 2,
          maxLines: 6,
          style: OmType.sans(size: 12, color: OmColors.fg0, height: 1.5),
          cursorColor: OmColors.accent,
          decoration: InputDecoration(
            isDense: true,
            hintText: 'Comment on this entry',
            hintStyle: OmType.sans(size: 12, color: OmColors.fg3),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            OmButton(
              key: const Key('comment-cancel'),
              kind: OmButtonKind.ghost,
              size: 24,
              dense: true,
              label: 'Cancel',
              onPressed: widget.onCancel,
            ),
            const SizedBox(width: 8),
            OmButton(
              key: const Key('comment-save'),
              kind: OmButtonKind.primary,
              size: 24,
              dense: true,
              label: 'Save',
              onPressed: _save,
            ),
          ],
        ),
      ],
    );
  }
}

/// One Feedback row: its words, its status (`Open` or `Handled: <reply>`),
/// and for an Open comment from the person, Edit and Delete.
class FeedbackRowTile extends ConsumerStatefulWidget {
  const FeedbackRowTile({super.key, required this.row});
  final FeedbackRow row;

  @override
  ConsumerState<FeedbackRowTile> createState() => _FeedbackRowTileState();
}

class _FeedbackRowTileState extends ConsumerState<FeedbackRowTile> {
  bool _editing = false;
  String? _error;

  FeedbackRow get _row => widget.row;

  /// Only an Open comment the person wrote can change.
  bool get _editable =>
      _row.kind == FeedbackKind.comment &&
      _row.source == FeedbackSource.person &&
      _row.status == FeedbackStatus.open;

  Future<CommentSaveResult> _saveEdit(String text) async {
    try {
      final edited = await guardVaultWrite(
        context,
        () => ref
            .read(feedbackActionsProvider)
            .editComment(id: _row.id, text: text),
      );
      if (edited == null) return const CommentSaveResult.unreachable();
      if (mounted) setState(() => _editing = false);
      return const CommentSaveResult.saved();
    } on MemexException catch (e) {
      if (e.code == _handledCode && mounted) {
        // The agent got there first: the refresh turns the row Handled.
        setState(() {
          _editing = false;
          _error = e.message;
        });
      }
      return CommentSaveResult.failed(e.message);
    }
  }

  Future<void> _delete() async {
    try {
      await guardVaultWrite(
        context,
        () => ref.read(feedbackActionsProvider).deleteComment(id: _row.id),
      );
    } on MemexException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final row = _row;
    if (_isUndecodable(row)) return const SizedBox.shrink();
    final error = _error;
    final editable = _editable;
    final handled = row.status == FeedbackStatus.handled;
    final words = _words(row);
    final why = row.kind == FeedbackKind.correction ? row.text : null;
    return Container(
      key: Key('feedback-${row.id}'),
      padding: const EdgeInsets.only(left: 10),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: OmColors.line2, width: 2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (row.source == FeedbackSource.chat)
            Text(
              'From chat',
              style: OmType.mono(size: 10.5, color: OmColors.agent),
            ),
          Text(
            words,
            style: OmType.sans(size: 12, color: OmColors.fg0, height: 1.5),
          ),
          if (why != null && why.isNotEmpty)
            Text(
              'Why? $why',
              style: OmType.sans(size: 12, color: OmColors.fg2, height: 1.5),
            ),
          const SizedBox(height: 2),
          if (error != null)
            InlineError(
              message: error,
              onDismiss: () => setState(() => _error = null),
            ),
          Row(
            children: [
              Text(
                handled ? _handledLine(row) : 'Open',
                key: Key('feedback-status-${row.id}'),
                style: OmType.mono(
                  size: 10.5,
                  color: handled ? OmColors.accentSoft : OmColors.fg2,
                ),
              ),
              if (editable && !_editing) ...[
                const SizedBox(width: 8),
                OmButton(
                  key: Key('feedback-edit-${row.id}'),
                  kind: OmButtonKind.ghost,
                  size: 22,
                  dense: true,
                  label: 'Edit',
                  onPressed: () => setState(() {
                    _editing = true;
                    _error = null;
                  }),
                ),
                OmButton(
                  key: Key('feedback-delete-${row.id}'),
                  kind: OmButtonKind.ghost,
                  size: 22,
                  dense: true,
                  label: 'Delete',
                  onPressed: _delete,
                ),
              ],
            ],
          ),
          if (editable && _editing)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: CommentComposer(
                initialText: row.text ?? '',
                onSave: _saveEdit,
                onCancel: () => setState(() => _editing = false),
              ),
            ),
        ],
      ),
    );
  }
}

String _handledLine(FeedbackRow row) {
  final reply = row.reply;
  return reply == null || reply.isEmpty ? 'Handled' : 'Handled: $reply';
}

/// What the row says, without its `Why?` note: `You: <text>`, the chat words
/// verbatim, or the Correction's wording.
String _words(FeedbackRow row) {
  final correction = row.correction;
  if (row.kind == FeedbackKind.comment) {
    final text = row.text ?? '';
    return row.source == FeedbackSource.chat ? text : 'You: $text';
  }
  if (correction == null) return '';
  return switch (correction) {
    ExcerptMovedCorrection(:final preview, :final toTitle) =>
      'You moved "$preview" to $toTitle',
    ExcerptRemovedCorrection(:final preview, :final title) =>
      'You removed "$preview" from $title',
    ExcerptAddedCorrection(:final preview, :final title) =>
      'You filed "$preview" in $title',
    MembershipRemovedCorrection(:final noteTitle, :final folderName) =>
      'You removed $noteTitle from $folderName',
    FolderRenamedCorrection(:final oldName, :final newName) =>
      'You renamed $oldName to $newName',
    FolderMovedCorrection(:final name) => 'You moved $name',
    FolderDeletedCorrection(:final name) => 'You deleted $name',
    TagRemovedCorrection(:final tag, :final noteId, :final noteTitle) =>
      noteId == null
          ? 'You removed #$tag from a deleted note ($noteTitle)'
          : 'You removed #$tag',
  };
}
