// WI #140 (Spec #123 W3, R16, R42): `memex attach` through [MemexCli] and
// its answer's mapping to an [AttachmentAddResult].
import 'dart:convert';

import '../memex_cli.dart';
import '../vault_access/attachments_access.dart';

/// R42's failure for a local `memex` without the `attach` command.
const memexTooOldForAttachmentsMessage =
    "This vault's memex is too old for attachments; update memex.";

/// The [AddedAttachment] of a store's `{markdown, path, name, size, type}`
/// answer (`memex attach`'s JSON line, `POST /attachments`' body), or null
/// when [json] is not one.
AddedAttachment? addedAttachmentFromJson(Object? json) {
  if (json is! Map<String, Object?>) return null;
  final markdown = json['markdown'];
  final path = json['path'];
  final name = json['name'];
  final size = json['size'];
  final type = json['type'];
  if (markdown is! String ||
      path is! String ||
      name is! String ||
      size is! int ||
      type is! String) {
    return null;
  }
  return AddedAttachment(
    markdown: markdown,
    path: path,
    name: name,
    size: size,
    type: type,
  );
}

/// The reason of a store's refusal whose text is [message] (R15): the
/// over-100 MB text is [AttachmentAddFailureReason.tooLarge], the folder text
/// [AttachmentAddFailureReason.folder], anything else
/// [AttachmentAddFailureReason.other].
AttachmentAddFailureReason attachRefusalReason(String message) {
  if (message.endsWith(" is larger than 100 MB and wasn't attached.")) {
    return AttachmentAddFailureReason.tooLarge;
  }
  if (message == "Folders can't be attached.") {
    return AttachmentAddFailureReason.folder;
  }
  return AttachmentAddFailureReason.other;
}

/// [e]'s message without the `'<operation> failed: '` prefix
/// `MemexException` puts before a C1 message.
String c1MessageOf(MemexException e, String operation) {
  final prefix = '$operation failed: ';
  final message = e.message;
  return message.startsWith(prefix)
      ? message.substring(prefix.length)
      : message;
}

extension AttachCli on MemexCli {
  /// `memex attach --vault <vaultPath> [--name=<name>] -- <filePath>`: stores
  /// the file (R16). Never throws for a `memex` answer:
  /// - exit 0 with the `{markdown, path, name, size, type}` line is
  ///   [AttachmentAdded]; any other exit-0 output is an
  ///   [AttachmentAddFailureReason.other] failure;
  /// - exit 2 with non-JSON stderr (a `memex` that predates the command) is
  ///   [AttachmentAddFailureReason.memexTooOld] with R42's text;
  /// - a C1 error is a failure whose message is the C1 message (R15's text
  ///   for a refusal), its reason from [attachRefusalReason].
  Future<AttachmentAddResult> attach({
    required String vaultPath,
    required String filePath,
    String? name,
  }) async {
    final r = await run([
      'attach',
      '--vault',
      vaultPath,
      if (name != null) '--name=$name',
      '--',
      filePath,
    ]);
    if (r.exitCode == 0) {
      final added = _parseLine(r.stdout);
      if (added != null) return AttachmentAdded(added);
      return const AttachmentAddFailed(
        AttachmentAddFailureReason.other,
        'memex attach printed output the app cannot read.',
      );
    }
    final failure = MemexException.fromCliFailure('attach', r);
    if (failure.code == null) {
      if (r.exitCode == 2) {
        return const AttachmentAddFailed(
          AttachmentAddFailureReason.memexTooOld,
          memexTooOldForAttachmentsMessage,
        );
      }
      final stderr = r.stderr.trim();
      return AttachmentAddFailed(
        AttachmentAddFailureReason.other,
        stderr.isEmpty ? 'memex attach failed (exit ${r.exitCode}).' : stderr,
      );
    }
    final message = c1MessageOf(failure, 'attach');
    return AttachmentAddFailed(attachRefusalReason(message), message);
  }
}

/// The first non-empty line of [stdout] as an [AddedAttachment], or null.
AddedAttachment? _parseLine(String stdout) {
  for (final line in const LineSplitter().convert(stdout)) {
    if (line.trim().isEmpty) continue;
    try {
      return addedAttachmentFromJson(jsonDecode(line));
    } on FormatException {
      return null;
    }
  }
  return null;
}
