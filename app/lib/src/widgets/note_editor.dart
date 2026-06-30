import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:path/path.dart' as p;

import '../db.dart';
import '../memex_cli.dart';
import '../state/vault_state.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';
import 'atoms.dart';
import 'kind_chip.dart';
import 'wikilink_autocomplete.dart';

/// Editor controller — owns the debounced save state. Unchanged in shape
/// from the previous version; the design redesign happens in the widget tree.
class EditorController extends StateNotifier<EditorStateValue> {
  EditorController(this._ref)
    : super(
        const EditorStateValue(
          title: '',
          contentMd: '',
          status: SaveStatus.idle,
        ),
      );

  final Ref _ref;
  Timer? _debounce;
  String? _activeNoteId;

  void loadNote(Note? note) {
    _debounce?.cancel();
    if (note == null) {
      _activeNoteId = null;
      state = const EditorStateValue(
        title: '',
        contentMd: '',
        status: SaveStatus.idle,
      );
      return;
    }
    _activeNoteId = note.id;
    state = EditorStateValue(
      title: note.title,
      contentMd: note.contentMd,
      status: SaveStatus.clean,
      lastSavedVersion: note.version,
    );
  }

  void onTitleChanged(String value) {
    if (_activeNoteId == null) return;
    if (value == state.title) return; // no-op (e.g. programmatic re-hydration)
    state = state.copyWith(
      title: value,
      status: SaveStatus.dirty,
      clearError: true,
    );
    _scheduleSave();
  }

  void onContentChanged(String value) {
    if (_activeNoteId == null) return;
    if (value == state.contentMd) return; // no-op (programmatic re-hydration)
    state = state.copyWith(
      contentMd: value,
      status: SaveStatus.dirty,
      clearError: true,
    );
    _scheduleSave();
  }

  void _scheduleSave() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), _save);
  }

  Future<void> _save() async {
    final id = _activeNoteId;
    if (id == null) return;
    final cli = _ref.read(memexCliProvider);
    final vaultPath = _ref.read(currentVaultProvider);
    final version = state.lastSavedVersion;
    if (cli == null || vaultPath == null || version == null) return;

    state = state.copyWith(status: SaveStatus.saving, clearError: true);
    try {
      final result = await cli.updateNote(
        vaultPath: vaultPath,
        noteId: id,
        expectedVersion: version,
        title: state.title.trim().isEmpty ? null : state.title.trim(),
        contentMd: state.contentMd,
      );
      if (_activeNoteId != id) return;
      state = state.copyWith(
        status: SaveStatus.clean,
        lastSavedVersion: result.version,
        clearError: true,
      );
      _ref.read(vaultRevisionProvider.notifier).state++;
    } on MemexException catch (e) {
      if (_activeNoteId != id) return;
      state = state.copyWith(
        status: e.kind == MemexErrorKind.versionConflict
            ? SaveStatus.conflict
            : SaveStatus.error,
        errorMessage: e.message,
      );
    } catch (e) {
      if (_activeNoteId != id) return;
      state = state.copyWith(
        status: SaveStatus.error,
        errorMessage: e.toString(),
      );
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }
}

final editorControllerProvider =
    StateNotifierProvider<EditorController, EditorStateValue>(
      EditorController.new,
    );

class NoteEditor extends ConsumerStatefulWidget {
  const NoteEditor({
    super.key,
    required this.rightPanelOpen,
    required this.onToggleRightPanel,
    this.onBackToCanvas,
  });
  final bool rightPanelOpen;
  final VoidCallback onToggleRightPanel;

  /// When non-null, the editor is shown zoomed-in from a canvas. The toolbar
  /// renders a "← back to canvas" affordance that invokes this.
  final VoidCallback? onBackToCanvas;

  @override
  ConsumerState<NoteEditor> createState() => _NoteEditorState();
}

class _NoteEditorState extends ConsumerState<NoteEditor> {
  late final TextEditingController _titleCtrl;
  late final TextEditingController _bodyCtrl;
  String? _hydratedFor;

  @override
  void initState() {
    super.initState();
    _titleCtrl = TextEditingController();
    _bodyCtrl = TextEditingController();
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _bodyCtrl.dispose();
    super.dispose();
  }

  void _hydrate(Note? note, EditorController controller) {
    if (note?.id == _hydratedFor) return;
    _hydratedFor = note?.id;
    controller.loadNote(note);
    _titleCtrl.text = note?.title ?? '';
    _bodyCtrl.text = note?.contentMd ?? '';
  }

  @override
  Widget build(BuildContext context) {
    final note = ref.watch(selectedNoteProvider);
    final editor = ref.watch(editorControllerProvider);
    final controller = ref.read(editorControllerProvider.notifier);
    final vaultPath = ref.watch(currentVaultProvider);

    ref.listen<Note?>(
      selectedNoteProvider,
      (_, curr) => _hydrate(curr, controller),
    );
    if (note != null && _hydratedFor != note.id) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _hydrate(note, controller);
      });
    }

    // Returns a plain Container (not Expanded): each call site places this in
    // its own flex/bounded parent (workspace `_TabBody` inside an Expanded,
    // `_ZoomedNoteView` inside a Positioned.fill). Rooting in Expanded here
    // caused two competing FlexParentData widgets on the same RenderObject.
    return Container(
      color: OmColors.surface2,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Toolbar(
            note: note,
            vaultPath: vaultPath,
            status: editor.status,
            rightOpen: widget.rightPanelOpen,
            onToggleRight: widget.onToggleRightPanel,
            onBackToCanvas: widget.onBackToCanvas,
          ),
          const OmHairline(),
          Expanded(
            child: note == null
                ? _EmptyEditor()
                : _DocumentSurface(
                    note: note,
                    titleCtrl: _titleCtrl,
                    bodyCtrl: _bodyCtrl,
                    onTitleChanged: controller.onTitleChanged,
                    onContentChanged: controller.onContentChanged,
                    errorMessage: editor.errorMessage,
                  ),
          ),
          const OmHairline(),
          _StatusBar(status: editor.status),
        ],
      ),
    );
  }
}

class _Toolbar extends ConsumerWidget {
  const _Toolbar({
    required this.note,
    required this.vaultPath,
    required this.status,
    required this.rightOpen,
    required this.onToggleRight,
    this.onBackToCanvas,
  });
  final Note? note;
  final String? vaultPath;
  final SaveStatus status;
  final bool rightOpen;
  final VoidCallback onToggleRight;
  final VoidCallback? onBackToCanvas;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      height: 44,
      color: OmColors.surface1,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        children: [
          if (onBackToCanvas != null) ...[
            _BackToCanvasButton(onTap: onBackToCanvas!),
            const SizedBox(width: 12),
          ],
          Expanded(
            child: _Breadcrumb(note: note, vaultPath: vaultPath),
          ),
          if (status == SaveStatus.conflict)
            const OmChip(label: 'conflict — reload', tone: ChipTone.danger),
          if (status == SaveStatus.error)
            const OmChip(label: 'save failed', tone: ChipTone.danger),
          const SizedBox(width: 8),
          OmButton(
            kind: OmButtonKind.ghost,
            size: 26,
            icon: LucideIcons.share,
            onPressed: null,
            tooltip: 'share',
          ),
          const SizedBox(width: 4),
          OmButton(
            kind: OmButtonKind.ghost,
            size: 26,
            icon: LucideIcons.ellipsis,
            onPressed: null,
            tooltip: 'more',
          ),
          const SizedBox(width: 4),
          // Right-panel (agents) toggle — relocated here from the old
          // second-level tab bar, which duplicated the workspace tab row.
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: onToggleRight,
              child: Container(
                width: 26,
                height: 26,
                alignment: Alignment.center,
                child: Icon(
                  LucideIcons.atom,
                  size: 14,
                  color: rightOpen ? OmColors.fg0 : OmColors.fg2,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// "← back to canvas" pill shown in the toolbar when a note is opened by
/// zooming in from a canvas.
class _BackToCanvasButton extends StatelessWidget {
  const _BackToCanvasButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: OmColors.surface2,
      borderRadius: BorderRadius.circular(4),
      child: InkWell(
        key: const Key('zoom-out-back-button'),
        borderRadius: BorderRadius.circular(4),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          child: Text(
            '← back to canvas',
            style: OmType.mono(size: 11, color: OmColors.fg1),
          ),
        ),
      ),
    );
  }
}

class _Breadcrumb extends StatelessWidget {
  const _Breadcrumb({required this.note, required this.vaultPath});
  final Note? note;
  final String? vaultPath;
  @override
  Widget build(BuildContext context) {
    if (note == null || vaultPath == null) {
      return const SizedBox.shrink();
    }
    final vaultName = p.basename(vaultPath!);
    final parts = [vaultName, '${note!.title}.md'];
    return Row(
      children: [
        for (var i = 0; i < parts.length; i++) ...[
          Text(
            parts[i],
            style: OmType.mono(
              size: 11.5,
              color: i == parts.length - 1 ? OmColors.fg1 : OmColors.fg3,
            ),
          ),
          if (i < parts.length - 1)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Text(
                '/',
                style: OmType.mono(size: 11.5, color: OmColors.fg4),
              ),
            ),
        ],
      ],
    );
  }
}

class _DocumentSurface extends ConsumerStatefulWidget {
  const _DocumentSurface({
    required this.note,
    required this.titleCtrl,
    required this.bodyCtrl,
    required this.onTitleChanged,
    required this.onContentChanged,
    required this.errorMessage,
  });
  final Note note;
  final TextEditingController titleCtrl;
  final TextEditingController bodyCtrl;
  final ValueChanged<String> onTitleChanged;
  final ValueChanged<String> onContentChanged;
  final String? errorMessage;

  @override
  ConsumerState<_DocumentSurface> createState() => _DocumentSurfaceState();
}

class _DocumentSurfaceState extends ConsumerState<_DocumentSurface> {
  final _bodyKey = GlobalKey();
  final _autocompleteKey = GlobalKey<WikilinkAutocompleteState>();
  final _bodyFocus = FocusNode(debugLabel: 'editor-body');
  final _kindChipCtrl = KindChipController();
  String _lastSeenBody = '';

  @override
  void initState() {
    super.initState();
    _lastSeenBody = widget.bodyCtrl.text;
    widget.bodyCtrl.addListener(_onBodyChanged);
    // Intercept ↑/↓/Enter/Tab/Esc when the autocomplete popover is open
    // so the body field doesn't process them.
    _bodyFocus.onKeyEvent = (node, event) {
      final autocomplete = _autocompleteKey.currentState;
      if (autocomplete == null || !autocomplete.isOpen) {
        return KeyEventResult.ignored;
      }
      return autocomplete.handleKeyEvent(event);
    };
  }

  @override
  void dispose() {
    widget.bodyCtrl.removeListener(_onBodyChanged);
    _bodyFocus.dispose();
    _kindChipCtrl.dispose();
    super.dispose();
  }

  void _onBodyChanged() {
    final text = widget.bodyCtrl.text;
    final caret = widget.bodyCtrl.selection.baseOffset;
    if (text != _lastSeenBody) {
      _lastSeenBody = text;
      // Route to the editor controller's save path. This catches BOTH
      // user typing AND programmatic splices (autocomplete inserts, kind
      // chip rewrites) — onChanged on a TextField only fires for user input.
      widget.onContentChanged(text);
    }
    if (caret >= 0) {
      _kindChipCtrl.onSelectionChanged(caret);
    }
  }

  /// Compute the global screen offset where the popover should anchor.
  /// Uses a TextPainter that mirrors the body field's style + width to
  /// figure out where the caret sits inside the editor's RenderBox.
  Offset _caretGlobal() {
    final ctx = _bodyKey.currentContext;
    if (ctx == null) return Offset.zero;
    final box = ctx.findRenderObject() as RenderBox?;
    if (box == null) return Offset.zero;

    final text = widget.bodyCtrl.text;
    final caret = widget.bodyCtrl.selection.baseOffset.clamp(0, text.length);
    // TextPainter measures the prefix, then we ask where its end sits.
    final prefix = text.substring(0, caret);
    final style = OmType.mono(size: 13.5, color: OmColors.fg0, height: 1.7);
    final painter = TextPainter(
      text: TextSpan(
        // Include a single trailing space so the painter has something to
        // measure even when the prefix ends with a newline.
        text: prefix.isEmpty ? ' ' : prefix,
        style: style,
      ),
      textDirection: TextDirection.ltr,
      maxLines: null,
    );
    painter.layout(maxWidth: box.size.width);
    final localCaret = painter.getOffsetForCaret(
      TextPosition(offset: prefix.length),
      Rect.zero,
    );
    painter.dispose();
    final lineHeight = 13.5 * 1.7;
    final origin = box.localToGlobal(Offset.zero);
    return origin + Offset(localCaret.dx, localCaret.dy + lineHeight);
  }

  @override
  Widget build(BuildContext context) {
    final note = widget.note;
    return Stack(
      children: [
        SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(28, 28, 28, 200),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _MetaRail(note: note),
                  const SizedBox(height: 18),
                  TextField(
                    key: const Key('editor-title'),
                    controller: widget.titleCtrl,
                    style: OmType.h1Serif(),
                    cursorColor: OmColors.accent,
                    decoration: InputDecoration(
                      hintText: 'Untitled',
                      hintStyle: OmType.serif(
                        size: 36,
                        color: OmColors.fg3,
                        weight: FontWeight.w500,
                      ),
                    ),
                    onChanged: widget.onTitleChanged,
                  ),
                  if (note.tags.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        for (final t in note.tags)
                          Text(
                            '#$t',
                            style: OmType.mono(
                              size: 12,
                              color: OmColors.accentSoft,
                            ),
                          ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 18),
                  if (widget.errorMessage != null) ...[
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        widget.errorMessage!,
                        style: OmType.mono(size: 11, color: OmColors.danger),
                      ),
                    ),
                  ],
                  TextField(
                    key: _bodyKey,
                    controller: widget.bodyCtrl,
                    focusNode: _bodyFocus,
                    maxLines: null,
                    minLines: 12,
                    cursorColor: OmColors.accent,
                    style: OmType.mono(
                      size: 13.5,
                      color: OmColors.fg0,
                      height: 1.7,
                    ),
                    decoration: InputDecoration(
                      hintText: 'type [[ to link a note · write markdown…',
                      hintStyle: OmType.mono(size: 13.5, color: OmColors.fg3),
                    ),
                    // No onChanged here — the controller listener above
                    // routes both typed AND programmatic splice updates
                    // through the save path.
                  ),
                ],
              ),
            ),
          ),
        ),
        // Wikilink autocomplete (zero-size widget; uses an Overlay).
        WikilinkAutocomplete(
          key: _autocompleteKey,
          controller: widget.bodyCtrl,
          caretLocator: _caretGlobal,
          onNoteCreatedSelect: (_) {},
          onInserted: (start, end) {
            _kindChipCtrl.show(start: start, end: end);
          },
        ),
        // Floating kind chip near the bottom of the editor pane.
        ListenableBuilder(
          listenable: _kindChipCtrl,
          builder: (context, _) {
            final box =
                _bodyKey.currentContext?.findRenderObject() as RenderBox?;
            // build() runs before layout, so on the first frame the box has no
            // size yet and `localToGlobal` would walk into an unlaid-out
            // ancestor (hasSize assertion). The chip is only shown after a
            // wikilink insert — well past first layout — so falling back to
            // Offset.zero until the box is laid out is safe.
            final origin = (box != null && box.hasSize && box.attached)
                ? box.localToGlobal(Offset.zero)
                : Offset.zero;
            // Anchor relative to the surrounding Stack; the OverlayEntry
            // approach the chip implements would be cleaner, but for v1 we
            // place it just above the bottom of the editor.
            final size = MediaQuery.of(context).size;
            return KindChip(
              controller: _kindChipCtrl,
              editorController: widget.bodyCtrl,
              anchor: Offset(origin.dx + 24, size.height - 110),
            );
          },
        ),
      ],
    );
  }
}

class _MetaRail extends StatelessWidget {
  const _MetaRail({required this.note});
  final Note note;
  @override
  Widget build(BuildContext context) {
    final updated = _formatRelative(note.updatedAt);
    final words = _wordCount(note.contentMd);
    return Container(
      padding: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: OmColors.line1, width: 1)),
      ),
      child: Wrap(
        spacing: 14,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(LucideIcons.clock, size: 11, color: OmColors.fg3),
              const SizedBox(width: 5),
              Text(
                'updated $updated',
                style: OmType.mono(size: 11, color: OmColors.fg3),
              ),
            ],
          ),
          Text('·', style: OmType.mono(size: 11, color: OmColors.fg4)),
          Text(
            '$words words',
            style: OmType.mono(size: 11, color: OmColors.fg3),
          ),
        ],
      ),
    );
  }

  static String _formatRelative(int unixMs) {
    final delta = DateTime.now().millisecondsSinceEpoch - unixMs;
    if (delta < 60 * 1000) return 'just now';
    final m = delta ~/ 60000;
    if (m < 60) return '$m minute${m == 1 ? '' : 's'} ago';
    final h = m ~/ 60;
    if (h < 24) return '$h hour${h == 1 ? '' : 's'} ago';
    final d = h ~/ 24;
    return '$d day${d == 1 ? '' : 's'} ago';
  }

  static int _wordCount(String s) {
    final words = s.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
    return words.length;
  }
}

class _StatusBar extends StatelessWidget {
  const _StatusBar({required this.status});
  final SaveStatus status;
  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (status) {
      SaveStatus.idle => ('idle', OmColors.fg3),
      SaveStatus.dirty => ('unsaved', OmColors.warn),
      SaveStatus.saving => ('saving…', OmColors.fg2),
      SaveStatus.clean => ('synced', OmColors.accent),
      SaveStatus.error => ('save failed', OmColors.danger),
      SaveStatus.conflict => ('conflict', OmColors.danger),
    };
    return Container(
      key: const Key('save-indicator'),
      height: 26,
      color: OmColors.surface1,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          OmDot(color: color, size: 5, pulse: status == SaveStatus.saving),
          const SizedBox(width: 5),
          Text(
            label,
            style: OmType.mono(size: 10.5, color: color, letterSpacing: 0.2),
          ),
          const SizedBox(width: 10),
          Text('·', style: OmType.mono(size: 11, color: OmColors.fg4)),
          const SizedBox(width: 10),
          Text('md', style: OmType.mono(size: 10.5, color: OmColors.fg3)),
          const Spacer(),
          Text(
            'agents API · ⌘;',
            style: OmType.mono(size: 10.5, color: OmColors.fg2),
          ),
        ],
      ),
    );
  }
}

class _EmptyEditor extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'select a note from the sidebar',
            style: OmType.mono(size: 12, color: OmColors.fg3),
          ),
          const SizedBox(height: 12),
          Text(
            'or press ⌘N to create a new one',
            style: OmType.mono(size: 11, color: OmColors.fg4),
          ),
        ],
      ),
    );
  }
}
