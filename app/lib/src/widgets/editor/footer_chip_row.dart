import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../db/daily_reads.dart';
import '../../state/daily_state.dart';
import '../../state/tabs_state.dart';
import '../../state/vault_state.dart';
import '../../theme/colors.dart';
import '../atoms.dart';

/// A daily note's Topics footer (Req 18): one clickable chip per footer
/// topic of [dailyNoteId], in footer (rowid) order, each opening its topic
/// note (Key `footer-chip-<topicNoteId>`). Never a text field.
class FooterChipBar extends ConsumerWidget {
  const FooterChipBar({super.key, required this.dailyNoteId});
  final String dailyNoteId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chips = watchVaultValue(
      ref,
      footerChipsAsyncProvider(dailyNoteId),
      const <FooterChipRow>[],
    );
    return Container(
      key: const Key('footer-chip-row'),
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.only(top: 10),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: OmColors.line1, width: 1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Eyebrow('Topics', color: OmColors.fg3),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final chip in chips)
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    key: Key('footer-chip-${chip.topicNoteId}'),
                    behavior: HitTestBehavior.opaque,
                    onTap: () => ref
                        .read(tabsProvider.notifier)
                        .follow(NoteTab(chip.topicNoteId)),
                    child: OmChip(label: chip.topicTitle),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
