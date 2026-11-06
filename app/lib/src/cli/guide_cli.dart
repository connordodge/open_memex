import 'dart:convert';

import '../db/feedback_reads.dart';
import '../memex_cli.dart';

/// The parsed `memex guide get` result: the Vault Guide note.
class VaultGuide {
  const VaultGuide({
    required this.vaultId,
    required this.noteId,
    required this.version,
    required this.contentMd,
  });
  final String vaultId;
  final String noteId;
  final int version;
  final String contentMd;
}

/// The parsed `memex guide restore` result.
class GuideRestoreResult {
  const GuideRestoreResult({
    required this.vaultId,
    required this.noteId,
    required this.version,
  });
  final String vaultId;
  final String noteId;

  /// The guide note's new `notes.version`.
  final int version;
}

/// The [VaultGuide] of `{vault_id, note_id, version, content_md}`, or null.
/// Shared by the CLI and the hosted route.
VaultGuide? parseVaultGuide(Map<String, Object?> json) {
  if (json case {
    'vault_id': final String vaultId,
    'note_id': final String noteId,
    'version': final int version,
    'content_md': final String contentMd,
  }) {
    return VaultGuide(
      vaultId: vaultId,
      noteId: noteId,
      version: version,
      contentMd: contentMd,
    );
  }
  return null;
}

/// The revisions of `{vault_id, revisions: [{id, agent_change_id,
/// created_at}]}` in order, or null.
List<GuideRevisionRow>? parseGuideRevisions(Map<String, Object?> json) {
  if (json case {
    'vault_id': final String _,
    'revisions': final List<Object?> revisions,
  }) {
    final parsed = <GuideRevisionRow>[];
    for (final r in revisions) {
      if (r case {'id': final String id, 'created_at': final int createdAt}) {
        final change = (r as Map)['agent_change_id'];
        if (change != null && change is! String) return null;
        parsed.add(
          GuideRevisionRow(
            id: id,
            agentChangeId: change as String?,
            createdAt: createdAt,
          ),
        );
      } else {
        return null;
      }
    }
    return parsed;
  }
  return null;
}

/// The [GuideRestoreResult] of `{vault_id, note_id, version}`, or null.
GuideRestoreResult? parseGuideRestoreResult(Map<String, Object?> json) {
  if (json case {
    'vault_id': final String vaultId,
    'note_id': final String noteId,
    'version': final int version,
  }) {
    return GuideRestoreResult(
      vaultId: vaultId,
      noteId: noteId,
      version: version,
    );
  }
  return null;
}

/// `memex guide get|revisions|restore` wrappers (#256).
///
/// A CLI failure throws [MemexException] with the C1 `code` (`not_found`,
/// `guide_rule`); stdout that is not the Contract shape throws a
/// [MemexException] with a null code.
extension GuideCli on MemexCli {
  /// `memex guide get --vault V`: creates the guide on first call.
  Future<VaultGuide> getGuide({required String vaultPath}) => _call(
    this,
    'guide get',
    ['guide', 'get', '--vault', vaultPath],
    parseVaultGuide,
  );

  /// `memex guide revisions --vault V`.
  Future<List<GuideRevisionRow>> guideRevisions({required String vaultPath}) =>
      _call(this, 'guide revisions', [
        'guide',
        'revisions',
        '--vault',
        vaultPath,
      ], parseGuideRevisions);

  /// `memex guide restore --vault V --revision-id R`.
  Future<GuideRestoreResult> restoreGuide({
    required String vaultPath,
    required String revisionId,
  }) => _call(this, 'guide restore', [
    'guide',
    'restore',
    '--vault',
    vaultPath,
    '--revision-id',
    revisionId,
  ], parseGuideRestoreResult);
}

/// Runs [args], throws the C1 error of a failure, and returns what [parse]
/// makes of the JSON object on stdout; [parse] returning null (or stdout that
/// is not a JSON object) throws a null-code [MemexException].
Future<T> _call<T extends Object>(
  MemexCli cli,
  String operation,
  List<String> args,
  T? Function(Map<String, Object?> json) parse,
) async {
  final r = await cli.run(args);
  if (r.exitCode != 0) throw MemexException.fromCliFailure(operation, r);
  Object? json;
  try {
    json = jsonDecode(r.stdout.trim());
  } on FormatException {
    json = null;
  }
  final result = json is Map<String, Object?> ? parse(json) : null;
  if (result == null) {
    throw MemexException('$operation: could not parse output: ${r.stdout}');
  }
  return result;
}
