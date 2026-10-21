import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db.dart';
import '../vault_access/vault_scoped.dart';
import 'vault_state.dart';

/// Outgoing links for a note through `VaultAccess`, stamped with the vault
/// they were loaded for (D14a). Skeleton: the WI #90 implementation fills it.
final linksOutAsyncProvider =
    FutureProvider.family<VaultScoped<List<LinkRow>>, String>(
      (ref, noteId) => throw UnimplementedError(),
    );

/// Outgoing links for a note. Provider.family keyed on note id.
final linksOutProvider = Provider.family<List<LinkRow>, String>((ref, noteId) {
  ref.watch(vaultRevisionProvider);
  final db = ref.watch(vaultDbProvider);
  if (db == null) return const [];
  return db.linksOutFor(noteId);
});

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
/// with the vault they were loaded for (D14a). Skeleton: WI #90 fills it.
final backlinksAsyncProvider =
    FutureProvider.family<
      VaultScoped<Map<String, List<BacklinkEntry>>>,
      String
    >((ref, noteId) => throw UnimplementedError());

/// Incoming links for a note, grouped by kind. Source titles are pre-joined
/// so the UI can render in one pass.
final backlinksProvider =
    Provider.family<Map<String, List<BacklinkEntry>>, String>((ref, noteId) {
      ref.watch(vaultRevisionProvider);
      final db = ref.watch(vaultDbProvider);
      if (db == null) return const {};
      final rows = db.linksInFor(noteId);
      if (rows.isEmpty) return const {};
      final fromIds = rows.map((r) => r.fromNoteId).toSet().toList();
      final titles = db.titlesForIds(fromIds);
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
      return out;
    });

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
