import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db.dart';
import '../vault_access/vault_scoped.dart';
import 'vault_access_state.dart';
import 'vault_state.dart';

/// Outgoing links for a note through `VaultAccess`, stamped with the vault
/// they were loaded for (D14a). Re-reads on every `vaultRevisionProvider`
/// bump; empty (stamped) with no vault access.
final linksOutAsyncProvider =
    FutureProvider.family<VaultScoped<List<LinkRow>>, String>((
      ref,
      noteId,
    ) async {
      ref.watch(vaultRevisionProvider);
      final vault = ref.watch(currentVaultProvider);
      final access = ref.watch(vaultAccessProvider);
      if (access == null) return VaultScoped(vault, const <LinkRow>[]);
      return VaultScoped(vault, await access.notes.linksOutFor(noteId));
    });

/// Outgoing links for a note. Synchronous facade over
/// [linksOutAsyncProvider]: empty before the first load and for another
/// vault's data.
final linksOutProvider = Provider.family<List<LinkRow>, String>(
  (ref, noteId) => vaultFacadeValue(
    ref,
    ref.watch(linksOutAsyncProvider(noteId)),
    const <LinkRow>[],
  ),
);

/// A backlink — incoming link enriched with the source note's title so the
/// UI can render "Source.title" without a second query per row.
class BacklinkEntry {
  BacklinkEntry({
    required this.linkId,
    required this.fromNoteId,
    required this.fromTitle,
    required this.kind,
    required this.label,
    required this.source,
  });
  final String linkId;
  final String fromNoteId;
  final String fromTitle;
  final String kind;
  final String? label;
  final String source;
}

/// Incoming links for a note, grouped by kind, through `VaultAccess`, stamped
/// with the vault they were loaded for (D14a). Source titles are pre-joined
/// (one `titlesForIds` read) so the UI can render in one pass.
final backlinksAsyncProvider =
    FutureProvider.family<
      VaultScoped<Map<String, List<BacklinkEntry>>>,
      String
    >((ref, noteId) async {
      ref.watch(vaultRevisionProvider);
      final vault = ref.watch(currentVaultProvider);
      final access = ref.watch(vaultAccessProvider);
      if (access == null) {
        return VaultScoped(vault, const <String, List<BacklinkEntry>>{});
      }
      final rows = await access.notes.linksInFor(noteId);
      if (rows.isEmpty) {
        return VaultScoped(vault, const <String, List<BacklinkEntry>>{});
      }
      final fromIds = rows.map((r) => r.fromNoteId).toSet().toList();
      final titles = await access.notes.titlesForIds(fromIds);
      final out = <String, List<BacklinkEntry>>{};
      for (final r in rows) {
        final entry = BacklinkEntry(
          linkId: r.id,
          fromNoteId: r.fromNoteId,
          fromTitle: titles[r.fromNoteId] ?? r.fromNoteId,
          kind: r.kind,
          label: r.label,
          source: r.source,
        );
        (out[r.kind] ??= <BacklinkEntry>[]).add(entry);
      }
      // Sort source titles alphabetically inside each kind for stable rendering.
      for (final list in out.values) {
        list.sort((a, b) => a.fromTitle.compareTo(b.fromTitle));
      }
      return VaultScoped(vault, out);
    });

/// Incoming links for a note, grouped by kind. Synchronous facade over
/// [backlinksAsyncProvider]: empty before the first load and for another
/// vault's data.
final backlinksProvider =
    Provider.family<Map<String, List<BacklinkEntry>>, String>(
      (ref, noteId) => vaultFacadeValue(
        ref,
        ref.watch(backlinksAsyncProvider(noteId)),
        const <String, List<BacklinkEntry>>{},
      ),
    );

/// Order kinds: built-ins first in canonical order, user-defined alphabetic.
List<String> orderedLinkKinds(Iterable<String> kinds) {
  const builtIn = ['references', 'extends', 'contradicts', 'example-of'];
  final present = kinds.toSet();
  final out = <String>[];
  for (final b in builtIn) {
    if (present.contains(b)) out.add(b);
  }
  final userDefined = present.where((k) => !builtIn.contains(k)).toList()
    ..sort();
  out.addAll(userDefined);
  return out;
}

/// Friendly label for a kind in the UI ("Contradicted by", "Extended by",
/// etc. for backlinks; defaults to the kind verbatim for user-defined).
String backlinkLabelForKind(String kind) {
  switch (kind) {
    case 'references':
      return 'References';
    case 'extends':
      return 'Extended by';
    case 'contradicts':
      return 'Contradicted by';
    case 'example-of':
      return 'Examples';
    default:
      return kind;
  }
}
