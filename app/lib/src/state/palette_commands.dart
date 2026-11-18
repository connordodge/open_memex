// WI #77 (56-A3, Spec #59 reqs 19-22): the Command palette's Commands
// source.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../editor/fuzzy_score.dart';
import 'command_palette_state.dart';
import 'daily_state.dart';
import 'sidebar_mode_state.dart';
import 'vault_access_state.dart';
import 'vault_state.dart';

/// Fills #76's `paletteCommandsSourceProvider`: requirement 19's commands
/// available on the open vault (New note and New canvas only when
/// `VaultAccess.canWrite`), fuzzy-matched against the trimmed input, best
/// first, ties in fixed order. The right-panel label follows
/// `rightPanelOpenProvider`; Open today's meta is today's date; the current
/// sidebar mode's Show row has meta `shown`.
final Override paletteCommandsOverride = paletteCommandsSourceProvider
    .overrideWith((ref) {
      final canWrite = ref.watch(vaultAccessProvider)?.canWrite ?? false;
      final rightPanelOpen = ref.watch(rightPanelOpenProvider);
      final mode = ref.watch(sidebarModeProvider);
      final today = ref.watch(todayDateProvider);
      final all = [
        for (final command in PaletteCommand.values)
          if (canWrite || !_writes(command))
            CommandItem(
              command,
              label: command.label(rightPanelOpen: rightPanelOpen),
              meta: _meta(command, today: today, mode: mode),
            ),
      ];
      return (query) => _match(all, query);
    });

/// New note and New canvas write to the vault.
bool _writes(PaletteCommand command) =>
    command == PaletteCommand.newNote || command == PaletteCommand.newCanvas;

/// Open today's ISO date, `shown` on the Show row of [mode], else none.
String? _meta(
  PaletteCommand command, {
  required String today,
  required SidebarMode mode,
}) => switch (command) {
  PaletteCommand.openToday => today,
  PaletteCommand.showDays when mode == SidebarMode.days => 'shown',
  PaletteCommand.showTopics when mode == SidebarMode.topics => 'shown',
  PaletteCommand.showTags when mode == SidebarMode.tags => 'shown',
  _ => null,
};

/// [all] for the empty [query]; otherwise the rows whose label fuzzy-matches
/// it (score above 0), best first, ties in [all]'s order, with the matched
/// characters.
List<CommandItem> _match(List<CommandItem> all, String query) {
  if (query.isEmpty) return all;
  final needle = query.toLowerCase();
  final scored = <(int, int, CommandItem)>[];
  for (var i = 0; i < all.length; i++) {
    final score = fuzzyScore(all[i].label.toLowerCase(), needle);
    if (score > 0) scored.add((score, i, all[i]));
  }
  scored.sort((a, b) {
    final byScore = b.$1.compareTo(a.$1);
    return byScore != 0 ? byScore : a.$2.compareTo(b.$2);
  });
  return [
    for (final (_, _, item) in scored)
      CommandItem(
        item.command,
        label: item.label,
        meta: item.meta,
        matched: fuzzyMatchPositions(item.label.toLowerCase(), needle),
      ),
  ];
}
