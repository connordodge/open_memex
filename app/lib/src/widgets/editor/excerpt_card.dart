import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../editor/excerpt_render.dart';
import '../../editor/segments.dart';
import '../../state/tabs_state.dart';
import '../../state/vault_access_state.dart';
import '../../state/vault_state.dart';
import '../../vault_access/vault_scoped.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../atoms.dart';

/// The rendered text of one transclusion token through the open vault's
/// daily domain ([renderExcerpt]), re-read on every vault revision, with the
/// vault it was rendered for (D14a). Null with no vault open.
final excerptRenderProvider = FutureProvider.autoDispose
    .family<
      VaultScoped<RenderedExcerpt?>,
      ({String date, String from, String? to})
    >((ref, token) async {
      ref.watch(vaultRevisionProvider);
      final vault = ref.watch(currentVaultProvider);
      final access = ref.watch(vaultAccessProvider);
      if (access == null) return VaultScoped(vault, null);
      return VaultScoped(
        vault,
        await renderExcerpt(
          access.daily,
          date: token.date,
          from: token.from,
          to: token.to,
        ),
      );
    });

/// A read-only excerpt card (Key `excerpt-card-<index>`) for one
/// transclusion [segment]: the live text of the referenced daily-note blocks
/// (C4, re-read on every vault revision), a `YYYY-MM-DD` caption
/// (Key `excerpt-card-caption-<index>`) that opens that daily note, and an
/// `×` (Key `excerpt-card-remove-<index>`) that calls [onRemove].
///
/// [index] is the segment's position in `split()`'s list. [onRemove] is
/// null while a removal is in flight.
class ExcerptCard extends ConsumerWidget {
  const ExcerptCard({
    super.key,
    required this.index,
    required this.segment,
    required this.onRemove,
  });

  final int index;
  final TransclusionSegment segment;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // No vault open: no note (and no card) to show.
    if (ref.watch(vaultAccessProvider) == null) return const SizedBox.shrink();
    final date = segment.date;
    // Until the first render lands the card shows no text.
    final rendered = watchVaultValue<RenderedExcerpt?>(
      ref,
      excerptRenderProvider((date: date, from: segment.from, to: segment.to)),
      null,
    );
    return Container(
      key: Key('excerpt-card-$index'),
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.fromLTRB(14, 8, 8, 12),
      decoration: BoxDecoration(
        color: OmColors.surface3,
        border: Border.all(color: OmColors.line2, width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  key: Key('excerpt-card-caption-$index'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _openDay(ref),
                  child: Text(
                    date,
                    style: OmType.mono(size: 11, color: OmColors.accentSoft),
                  ),
                ),
              ),
              const Spacer(),
              OmButton(
                key: Key('excerpt-card-remove-$index'),
                kind: OmButtonKind.ghost,
                size: 22,
                icon: LucideIcons.x,
                tooltip: 'remove excerpt',
                onPressed: onRemove,
              ),
            ],
          ),
          const SizedBox(height: 4),
          // One text run: the blocks joined with `\n` (C4).
          Text(
            rendered?.text ?? '',
            style: OmType.mono(
              size: 13.5,
              color: rendered?.removed ?? false ? OmColors.fg3 : OmColors.fg1,
              height: 1.7,
            ),
          ),
        ],
      ),
    );
  }

  /// Opens the daily note of the card's date as the active tab, looked up
  /// through the daily domain.
  Future<void> _openDay(WidgetRef ref) async {
    final access = ref.read(vaultAccessProvider);
    if (access == null) return;
    final tabs = ref.read(tabsProvider.notifier);
    final row = await access.daily.dailyNoteForDate(segment.date);
    if (row == null || !tabs.mounted) return;
    tabs.openOrFocus(NoteTab(row.noteId));
  }
}
