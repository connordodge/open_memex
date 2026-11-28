// WI #76 (56-A2) stub, filled by #78 (56-A4, Spec #59 reqs 31-33; design
// pack 78 C4): the Passages state rows and footers. #77's shell places them
// in the Passages part of the list.
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../state/command_palette_state.dart';
import '../../state/palette_passages.dart' show passagesMinQuery;
import '../../state/search_model_download.dart';
import '../../state/vault_state.dart';
import '../../vault_access/search_access.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';
import '../atoms.dart';
import 'palette_group_header.dart';
import 'palette_row.dart';

/// The Passages state row (Spec #59 reqs 31-33) when `paletteProvider`'s
/// `passages` lists no rows: its own `PASSAGES` header and one unselectable
/// state line (`searching`, `memex-outdated`, `server-outdated`, `no-cli`,
/// `error`), each a polite live region. With every group empty once
/// Passages has answered (or under 2 characters) it is instead the single
/// `no matches for “<query>”` row (C4 state 8), with no header.
class PassagesStateRow extends ConsumerWidget {
  const PassagesStateRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = ref.watch(paletteProvider);
    final query = palette.query.trim();
    if (palette.noMatches) return _NoMatches(query);
    if (query.length < passagesMinQuery) return const SizedBox.shrink();
    final line = switch (palette.passages) {
      PassagesSearching() => const _StateLine(
        'searching',
        'searching note text…',
        spinner: true,
      ),
      PassagesUnavailable(reason: MemexOutdated()) => const _StateLine(
        'memex-outdated',
        'update memex to search note text.',
      ),
      PassagesUnavailable(reason: ServerOutdated()) => const _StateLine(
        'server-outdated',
        'update the vault server to search note text.',
      ),
      PassagesUnavailable(reason: SearchNoCli()) => const _StateLine(
        'no-cli',
        'note text search needs the memex CLI.',
      ),
      PassagesError() => const _StateLine(
        'error',
        "couldn't search note text.",
      ),
      _ => null,
    };
    if (line == null) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PaletteGroupHeader(kind: PaletteGroupKind.passages),
        line,
      ],
    );
  }
}

/// The Passages footer after the hit rows (req 31, C4 states 2-4): the
/// model-not-downloaded footer and download button (a local vault; also
/// after a failed download), downloading, embeddings off, and
/// `keyword matches only.` for any other keyword-only answer. Shown only
/// while the Passages group lists rows; none for `semantic: on`.
class PassagesFooter extends ConsumerWidget {
  const PassagesFooter({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = ref.watch(paletteProvider);
    final passages = palette.passages;
    if (palette.query.trim().length < passagesMinQuery ||
        passages.rows.isEmpty) {
      return const SizedBox.shrink();
    }
    final local = ref.watch(currentVaultProvider) is LocalVaultRef;
    const notDownloaded = _FooterSpec(
      'model-not-downloaded',
      'keyword matches only. meaning search needs the local model.',
      button: true,
    );
    const keywordOnly = _FooterSpec('unavailable', 'keyword matches only.');
    final spec = switch (passages) {
      PassagesDownloading() => const _FooterSpec(
        'downloading',
        "downloading the model… keyword matches until it's done.",
        spinner: true,
      ),
      PassagesDownloadFailed() => local ? notDownloaded : keywordOnly,
      PassagesShown(semantic: Semantic.on) => null,
      PassagesShown(semantic: Semantic.modelNotDownloaded) =>
        local ? notDownloaded : keywordOnly,
      PassagesShown(semantic: Semantic.embeddingsOff) => const _FooterSpec(
        'embeddings-off',
        'keyword matches only. semantic recall is off on this vault server.',
      ),
      PassagesShown() => keywordOnly,
      _ => null,
    };
    if (spec == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
      child: KeyedSubtree(
        key: PaletteKeys.passagesState(spec.state),
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: OmColors.line1)),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 11, 10, 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (spec.spinner) ...[
                  const _Spinner(),
                  const SizedBox(height: 12),
                ],
                Semantics(
                  container: true,
                  liveRegion: true,
                  child: Text(
                    spec.text,
                    style: OmType.mono(
                      size: 11,
                      color: OmColors.fg2,
                      height: 17.6 / 11,
                    ),
                  ),
                ),
                if (spec.button) ...[
                  const SizedBox(height: 12),
                  OmButton(
                    key: PaletteKeys.download,
                    kind: OmButtonKind.secondary,
                    size: 28,
                    dense: true,
                    focusable: true,
                    icon: LucideIcons.download,
                    iconSize: 13,
                    label: 'Download model (130 MB)',
                    semanticLabel:
                        'Download the embedding model, 130 megabytes',
                    onPressed: () => _download(ref),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Starts the open vault's download for the current input.
  static void _download(WidgetRef ref) {
    final vault = ref.read(currentVaultProvider);
    if (vault == null) return;
    ref
        .read(searchModelDownloadProvider(vault).notifier)
        .start(ref.read(paletteProvider).query.trim());
  }
}

class _FooterSpec {
  const _FooterSpec(
    this.state,
    this.text, {
    this.button = false,
    this.spinner = false,
  });

  final String state;
  final String text;
  final bool button;
  final bool spinner;
}

final _stateStyle = OmType.mono(size: 11, color: OmColors.fg2, height: 14 / 11);

/// One unselectable state line (C4): 32 high, padding H10, gap 10, mono 11
/// `fg2`, keyed `palette-passages-<state>`, a polite live region.
class _StateLine extends StatelessWidget {
  const _StateLine(this.state, this.text, {this.spinner = false});

  final String state;
  final String text;
  final bool spinner;

  @override
  Widget build(BuildContext context) {
    return KeyedSubtree(
      key: PaletteKeys.passagesState(state),
      child: Semantics(
        container: true,
        liveRegion: true,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 32),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            child: Row(
              children: [
                if (spinner) ...[const _Spinner(), const SizedBox(width: 10)],
                Expanded(child: Text(text, style: _stateStyle)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// `no matches for “<query>”` (C4 state 8): one 44 px row, text centred
/// vertically, a polite live region.
class _NoMatches extends StatelessWidget {
  const _NoMatches(this.query);

  final String query;

  @override
  Widget build(BuildContext context) {
    return KeyedSubtree(
      key: PaletteKeys.noMatches,
      child: Semantics(
        container: true,
        liveRegion: true,
        child: SizedBox(
          height: 44,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'no matches for “$query”',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: _stateStyle,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The `loader-circle` spinner, 14 px `fg2`, one turn a second.
class _Spinner extends StatefulWidget {
  const _Spinner();

  @override
  State<_Spinner> createState() => _SpinnerState();
}

class _SpinnerState extends State<_Spinner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _turn = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  )..repeat();

  @override
  void dispose() {
    _turn.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RotationTransition(
    turns: _turn,
    child: const Icon(LucideIcons.loaderCircle, size: 14, color: OmColors.fg2),
  );
}
