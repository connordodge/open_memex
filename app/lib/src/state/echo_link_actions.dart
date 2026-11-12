import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db.dart';
import '../editor/segments.dart' show FooterSegment, split;
import '../memex_cli.dart';
import '../vault_access/vault_access.dart';
import 'topic_actions.dart';
import 'vault_access_state.dart';
import 'vault_state.dart';

/// Which write an echo's `link` makes (Spec #391 req 29).
enum EchoLinkPlan {
  /// `NotesAccess.addLink(from: open, to: echo, kind: 'references')`, after
  /// the flush (req 31).
  fromOpen,

  /// `DailyAccess.addFooterChip(dailyNoteId: open, topicNoteId: echo)`.
  footerChip,

  /// `NotesAccess.addLink(from: echo, to: open, kind: 'references')`.
  fromEcho,

  /// No `link` button.
  none,
}

/// The [EchoLinkPlan] for an open note of [openRole] and an echo of
/// [echoRole] (`daily`, `topic`, or null for a plain note): any open note
/// other than a daily note links from the open note; an open daily note
/// files a topic echo as a footer chip, is linked from a plain echo, and
/// offers nothing for a daily echo.
EchoLinkPlan echoLinkPlan({
  required String? openRole,
  required String? echoRole,
}) {
  if (openRole != 'daily') return EchoLinkPlan.fromOpen;
  return switch (echoRole) {
    'topic' => EchoLinkPlan.footerChip,
    'daily' => EchoLinkPlan.none,
    _ => EchoLinkPlan.fromEcho,
  };
}

/// Runs an echo's `link` (A4, #429).
abstract interface class EchoLinkActions {
  /// Writes the link [plan] names between [openNoteId] and [echo].
  Future<void> link({
    required String openNoteId,
    required Echo echo,
    required EchoLinkPlan plan,
  });
}

/// The real [EchoLinkActions] (A4). Reads through [_container], not a
/// widget's ref: the echo row may be gone by the time the write returns.
class _VaultEchoLinkActions implements EchoLinkActions {
  const _VaultEchoLinkActions(this._container);

  final ProviderContainer _container;

  /// - [EchoLinkPlan.fromOpen]: through [flushThenWrite] (ruling D19), the
  ///   edit waiting on the save debounce is stored, then `addLink(from: open,
  ///   to: echo)`, then the editor is rebased on the stored note. Text typed
  ///   while the link is written is kept with the link carried into it
  ///   ([carryAutoAddedLinks], ruling D54), so neither is lost. A failed
  ///   flush writes nothing and throws an error whose text is
  ///   [saveFirstFailedMessage] (req 31); a save still in flight is waited
  ///   for, not a failure. From the flush until the rebase the editor holds
  ///   its debounced saves, so text typed during the link saves after it, on
  ///   the linked version, with no conflict. Once `addLink` has succeeded, a
  ///   failure to read the stored note back or rebase on it is not an error:
  ///   the link counts as made and the editor is left as it was.
  /// - [EchoLinkPlan.footerChip]: `addFooterChip(open, echo)`, no flush; the
  ///   open editor is rebased on the new version with its pending edit kept
  ///   ([rebaseEditorAfterWrite]).
  /// - [EchoLinkPlan.fromEcho]: `addLink(from: echo, to: open)`, no flush;
  ///   the open note and the editor are not touched.
  ///
  /// Once the write has succeeded, `vaultRevisionProvider` is bumped exactly
  /// once; for [EchoLinkPlan.fromOpen] that one bump also stands for the
  /// flushed edit's save ([flushThenWrite]'s `holdSaves`), so one link
  /// reaches the echoes tab as one revision change. A failed write bumps
  /// nothing of its own (a flushed edit that saved still bumps once) and
  /// propagates its error unchanged.
  @override
  Future<void> link({
    required String openNoteId,
    required Echo echo,
    required EchoLinkPlan plan,
  }) async {
    final access = _container.read(vaultAccessProvider);
    if (access == null) throw MemexException('No vault is open.');
    // Set once a write of footerChip or fromEcho succeeded; fromOpen's bump
    // is flushThenWrite's.
    var wrote = false;
    try {
      switch (plan) {
        case EchoLinkPlan.fromOpen:
          final open = await _openNote(access, openNoteId);
          var linked = false;
          try {
            await flushThenWrite(
              _container,
              note: open,
              carryOver: carryAutoAddedLinks,
              waitForSaves: true,
              holdSaves: true,
              write: () async {
                final result = await access.notes.addLink(
                  fromNoteId: openNoteId,
                  toNoteId: echo.noteId,
                  kind: 'references',
                );
                linked = true;
                return result.noteVersion;
              },
            );
          } on Exception {
            // The link is written: a failed read or rebase after it is not a
            // failed link (a retry would add the link again). The editor
            // stays on its old version, so a later save is a version
            // conflict rather than a silent overwrite of the link.
            if (!linked) rethrow;
          }
        case EchoLinkPlan.footerChip:
          final open = await _openNote(access, openNoteId);
          final result = await access.daily.addFooterChip(
            dailyNoteId: openNoteId,
            topicNoteId: echo.noteId,
          );
          wrote = true;
          await rebaseEditorAfterWrite(
            _container,
            access,
            note: open,
            version: result.version,
          );
        case EchoLinkPlan.fromEcho:
          await access.notes.addLink(
            fromNoteId: echo.noteId,
            toNoteId: openNoteId,
            kind: 'references',
          );
          wrote = true;
        case EchoLinkPlan.none:
          throw ArgumentError.value(plan, 'plan', 'This echo has no link.');
      }
    } finally {
      if (wrote) _container.read(vaultRevisionProvider.notifier).state++;
    }
  }

  /// The stored open note: the editor's stand-in when a later read fails.
  Future<Note> _openNote(VaultAccess access, String id) async {
    final note = await access.notes.getNote(id);
    if (note == null) {
      throw MemexException('This note no longer exists.', code: 'not_found');
    }
    return note;
  }
}

/// The heading of the section `add-link` (kind `references`) writes links
/// under (crates/memex-mcp/src/md_links.rs).
const _autoAddedHeading = '## Auto-added links';

/// The [flushThenWrite] carry-over of an echo link from the open note
/// (ruling D54): [typed] (the editor text, changed while the link was
/// written) with each line the write added to the `## Auto-added links`
/// section, that is each line of [stored]'s section that [flushed]'s section
/// lacks, put back when [typed] lacks it.
///
/// - [typed] without the section gets the added lines in a new section at the
///   bottom of its body, above any Note footer, where `add-link` puts one.
/// - [typed] with the section (edited while the link was written) keeps it as
///   written, with the lines it lacks added at its end: there is never a
///   second section.
/// - Nothing added, or nothing missing, gives [typed] unchanged.
///
/// Lines are compared without surrounding whitespace.
String carryAutoAddedLinks({
  required String typed,
  required String flushed,
  required String stored,
}) {
  final before = {
    for (final line in _autoAddedLines(_splitFooter(flushed).body)) line.trim(),
  };
  final added = [
    for (final line in _autoAddedLines(_splitFooter(stored).body))
      if (!before.contains(line.trim())) line.trimRight(),
  ];
  if (added.isEmpty) return typed;
  final (:body, :footer) = _splitFooter(typed);
  final lines = body.split('\n');
  final start = _autoAddedStart(lines);
  if (start < 0) {
    var person = body;
    while (person.endsWith('\n')) {
      person = person.substring(0, person.length - 1);
    }
    return '$person\n\n$_autoAddedHeading\n\n${added.join('\n')}\n$footer';
  }
  final end = _autoAddedEnd(lines, start);
  final have = {for (final line in lines.sublist(start + 1, end)) line.trim()};
  final missing = [
    for (final line in added)
      if (!have.contains(line.trim())) line,
  ];
  if (missing.isEmpty) return typed;
  // After the section's last non-blank line, so the list stays together.
  var at = end;
  while (at > start + 1 && lines[at - 1].trim().isEmpty) {
    at--;
  }
  if (at == start + 1) {
    // Only the heading: one blank line under it, as add-link writes.
    if (at < end) {
      at++;
    } else {
      missing.insert(0, '');
    }
  }
  if (at == lines.length) missing.add('');
  lines.insertAll(at, missing);
  return '${lines.join('\n')}$footer';
}

/// [text] split into its body and its Note footer (from the footer's marker
/// line to the end, or empty without one).
({String body, String footer}) _splitFooter(String text) {
  final last = split(text, isDaily: false).last;
  final raw = last is FooterSegment ? last.raw : null;
  if (raw == null) return (body: text, footer: '');
  return (body: text.substring(0, text.length - raw.length), footer: raw);
}

/// The index of the `## Auto-added links` heading in [lines], or -1.
int _autoAddedStart(List<String> lines) =>
    lines.indexWhere((line) => line.trim() == _autoAddedHeading);

/// Where the section headed at [start] ends: the next heading of depth 1 or
/// 2 (or any `###` line), as md_links.rs walks it, or the end of [lines].
int _autoAddedEnd(List<String> lines, int start) {
  for (var i = start + 1; i < lines.length; i++) {
    final line = lines[i];
    if (line.startsWith('# ') ||
        line.startsWith('## ') ||
        line.startsWith('###')) {
      return i;
    }
  }
  return lines.length;
}

/// The non-blank lines of [body]'s `## Auto-added links` section, if any.
List<String> _autoAddedLines(String body) {
  final lines = body.split('\n');
  final start = _autoAddedStart(lines);
  if (start < 0) return const [];
  return [
    for (final line in lines.sublist(start + 1, _autoAddedEnd(lines, start)))
      if (line.trim().isNotEmpty) line,
  ];
}

/// The app's [EchoLinkActions].
final echoLinkActionsProvider = Provider<EchoLinkActions>(
  (ref) => _VaultEchoLinkActions(ref.container),
);
