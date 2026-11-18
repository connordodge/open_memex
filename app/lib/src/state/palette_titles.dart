// WI #77 (56-A3, Spec #59 reqs 13-16, 42, TD5; D19): the Command palette's
// Notes and Recent source.
import 'dart:math' show max;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db.dart' show NoteTitle;
import '../editor/fuzzy_score.dart';
import '../vault_access/vault_scoped.dart';
import 'canvas_state.dart';
import 'clock.dart';
import 'command_palette_state.dart';
import 'daily_state.dart';
import 'vault_access_state.dart';
import 'vault_state.dart';

/// The palette's title read limit (D19): one named large positive
/// constant, never 0, -1 or null, so every note title is read.
const kPaletteTitleLimit = 1 << 30;

/// How many Recent or Notes rows the palette lists.
const _rowLimit = 8;

/// The palette's own `allTitles(limit: kPaletteTitleLimit)` read. Auto
/// disposed with the source, so it runs once per open, and again on a
/// `vaultRevisionProvider` change.
final _paletteTitlesReadProvider =
    FutureProvider.autoDispose<VaultScoped<List<NoteTitle>>>((ref) async {
      ref.watch(vaultRevisionProvider);
      final vault = ref.watch(currentVaultProvider);
      final access = ref.watch(vaultAccessProvider);
      if (access == null) return VaultScoped(vault, const []);
      return VaultScoped(
        vault,
        await access.notes.allTitles(limit: kPaletteTitleLimit),
      );
    });

/// Fills #76's `paletteTitlesSourceProvider`: Recent (the 8 newest notes)
/// for the empty input, Notes (notes and canvases by fuzzy title, top 8)
/// for a typed one, from one `allTitles(limit: kPaletteTitleLimit)` read per
/// open, re-read on a `vaultRevisionProvider` change. Until that read
/// answers the rows come from `noteTitlesAsyncProvider`'s current value; a
/// failed read lists no rows. Daily notes are the notes
/// `dailyNotesAsyncProvider` lists, canvases come from
/// `canvasesAsyncProvider`.
final Override paletteTitlesOverride = paletteTitlesSourceProvider.overrideWith(
  (ref) {
    final vault = ref.watch(currentVaultProvider);
    final read = ref.watch(_paletteTitlesReadProvider);
    if (read.hasError) return (_) => const [];
    final titles = read.hasValue
        ? currentVaultData(read, vault)?.value ?? const <NoteTitle>[]
        : vaultFacadeValue(
            ref,
            ref.watch(noteTitlesAsyncProvider),
            const <NoteTitle>[],
          );

    final dailies = {
      for (final row in vaultFacadeValue(
        ref,
        ref.watch(dailyNotesAsyncProvider),
        const [],
      ))
        row.noteId: row.date,
    };
    final canvases = vaultFacadeValue(
      ref,
      ref.watch(canvasesAsyncProvider),
      const [],
    );
    final today = ref.watch(todayDateProvider);
    final now = ref.watch(clockProvider).now().millisecondsSinceEpoch;

    final notes = [
      for (final t in titles)
        _Entry(
          id: t.id,
          title: t.title,
          updatedAt: t.updatedAt,
          kind: dailies.containsKey(t.id)
              ? PaletteNoteKind.daily
              : PaletteNoteKind.note,
          today: dailies[t.id] == today,
        ),
    ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final all = [
      ...notes,
      for (final c in canvases)
        _Entry(
          id: c.canvasId,
          title: c.title,
          updatedAt: c.updatedAt,
          kind: PaletteNoteKind.canvas,
          today: false,
        ),
    ];

    return (query) {
      if (query.isEmpty) {
        return [for (final e in notes.take(_rowLimit)) e.item(now)];
      }
      final needle = query.toLowerCase();
      final scored = <(int, _Entry)>[
        for (final e in all)
          if (fuzzyScore(e.title.toLowerCase(), needle) case final score
              when score > 0)
            (score, e),
      ];
      scored.sort((a, b) {
        final byScore = b.$1.compareTo(a.$1);
        return byScore != 0
            ? byScore
            : b.$2.updatedAt.compareTo(a.$2.updatedAt);
      });
      return [
        for (final (_, e) in scored.take(_rowLimit))
          e.item(
            now,
            matched: fuzzyMatchPositions(e.title.toLowerCase(), needle),
          ),
      ];
    };
  },
);

/// One note, daily note or canvas the source can list.
class _Entry {
  const _Entry({
    required this.id,
    required this.title,
    required this.updatedAt,
    required this.kind,
    required this.today,
  });

  final String id;
  final String title;
  final int updatedAt;
  final PaletteNoteKind kind;

  /// A daily note for today's date: its meta reads `daily · today`.
  final bool today;

  NoteItem item(int now, {List<int> matched = const []}) => NoteItem(
    noteId: id,
    kind: kind,
    title: title,
    meta: today
        ? 'daily · today'
        : '${kind.name} · ${_age(max(0, now - updatedAt))} ago',
    matched: matched,
  );
}

/// [ms] as whole hours under a day, whole days under a week, else whole
/// weeks (`2 h`, `4 d`, `3 w`), floored.
String _age(int ms) {
  final hours = ms ~/ Duration.millisecondsPerHour;
  if (hours < 24) return '$hours h';
  if (hours < 24 * 7) return '${hours ~/ 24} d';
  return '${hours ~/ (24 * 7)} w';
}
