import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/vault_state.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';
import 'atoms.dart';

/// Inline kind chip shown briefly after a wikilink is inserted. Lets the
/// user re-type the wikilink (`[[Title]]` → `[[Title~kind]]`) without
/// leaving the keyboard flow. Auto-dismisses after 10s, on Esc, or when
/// the caret leaves the inserted range.
class KindChipController extends ChangeNotifier {
  bool _visible = false;
  String _selectedKind = 'references';
  int _wikilinkStart = -1;
  int _wikilinkEnd = -1;

  bool get visible => _visible;
  String get selectedKind => _selectedKind;
  int get wikilinkStart => _wikilinkStart;
  int get wikilinkEnd => _wikilinkEnd;

  /// Show the chip. `start..end` is the byte range of the just-inserted
  /// wikilink (`[[Title]]` or `[[Title|alias]]`) within `controller.text`.
  void show({
    required int start,
    required int end,
    String kind = 'references',
  }) {
    _wikilinkStart = start;
    _wikilinkEnd = end;
    _selectedKind = kind;
    _visible = true;
    notifyListeners();
  }

  void hide() {
    if (!_visible) return;
    _visible = false;
    _wikilinkStart = -1;
    _wikilinkEnd = -1;
    notifyListeners();
  }

  /// Update the chip's kind and rewrite the wikilink in `controller`.
  /// Returns the new caret offset so the caller can place it.
  int rewrite({
    required TextEditingController controller,
    required String newKind,
    String? newLabel,
  }) {
    if (!_visible) return -1;
    final text = controller.text;
    if (_wikilinkStart < 0 || _wikilinkEnd > text.length) {
      hide();
      return -1;
    }
    // Parse the existing wikilink: [[Title]], [[Title~kind]],
    // [[Title|alias]], or [[Title~kind|alias]].
    final existing = text.substring(_wikilinkStart, _wikilinkEnd);
    if (!existing.startsWith('[[') || !existing.endsWith(']]')) {
      hide();
      return -1;
    }
    final inner = existing.substring(2, existing.length - 2);
    var title = inner;
    var aliasPart = '';
    final pipeAt = inner.indexOf('|');
    if (pipeAt >= 0) {
      title = inner.substring(0, pipeAt);
      aliasPart = inner.substring(pipeAt); // includes leading '|'
    }
    final tildeAt = title.indexOf('~');
    if (tildeAt >= 0) {
      title = title.substring(0, tildeAt);
    }
    if (newLabel != null && newLabel.isNotEmpty) {
      aliasPart = '|$newLabel';
    }
    String kindPart;
    if (newKind == 'references') {
      kindPart = '';
    } else {
      kindPart = '~$newKind';
    }
    final replacement = '[[$title$kindPart$aliasPart]]';
    final newText =
        text.substring(0, _wikilinkStart) +
        replacement +
        text.substring(_wikilinkEnd);
    final delta = replacement.length - existing.length;
    final newEnd = _wikilinkEnd + delta;
    final newCaret = controller.selection.baseOffset.clamp(0, newText.length);
    controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: newCaret),
    );
    _wikilinkEnd = newEnd;
    _selectedKind = newKind;
    notifyListeners();
    return newCaret;
  }

  /// Inspect the current selection. If the caret is outside the inserted
  /// wikilink range, hide the chip.
  void onSelectionChanged(int caret) {
    if (!_visible) return;
    if (caret < _wikilinkStart || caret > _wikilinkEnd) {
      hide();
    }
  }
}

/// The chip widget itself. Three quick built-in buttons + a "More…" picker
/// over kinds present in the vault.
class KindChip extends ConsumerStatefulWidget {
  const KindChip({
    super.key,
    required this.controller,
    required this.editorController,
    required this.anchor,
  });
  final KindChipController controller;
  final TextEditingController editorController;
  final Offset anchor;

  @override
  ConsumerState<KindChip> createState() => _KindChipState();
}

class _KindChipState extends ConsumerState<KindChip> {
  Timer? _autoDismiss;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onCtrl);
    _scheduleDismiss();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onCtrl);
    _autoDismiss?.cancel();
    super.dispose();
  }

  void _onCtrl() {
    if (mounted) setState(() {});
    _scheduleDismiss();
  }

  void _scheduleDismiss() {
    _autoDismiss?.cancel();
    if (!widget.controller.visible) return;
    _autoDismiss = Timer(const Duration(seconds: 10), () {
      widget.controller.hide();
    });
  }

  void _pick(String kind) {
    widget.controller.rewrite(
      controller: widget.editorController,
      newKind: kind,
    );
  }

  /// The first read of the vault's link kinds; empty when it fails or the
  /// vault changed meanwhile.
  Future<List<String>> _firstKinds() async {
    final vault = ref.read(currentVaultProvider);
    try {
      final loaded = await ref.read(linkKindsAsyncProvider.future);
      return loaded.vault == vault ? loaded.value : const [];
    } on Exception {
      return const [];
    }
  }

  Future<void> _pickMore() async {
    // The kinds loaded so far (a same-vault reload keeps the previous ones);
    // on the first open, the first read.
    final existing =
        readVaultValue<List<String>?>(ref, linkKindsAsyncProvider, null) ??
        await _firstKinds();
    if (!mounted) return;
    final selected = await showDialog<String>(
      context: context,
      builder: (_) => _KindPickerDialog(existing: existing),
    );
    if (selected != null && selected.isNotEmpty) {
      _pick(selected);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Loads the link kinds with the chip (D14a: async) so "More…" has them.
    ref.listen(linkKindsAsyncProvider, (_, _) {});
    if (!widget.controller.visible) return const SizedBox.shrink();
    return Positioned(
      left: widget.anchor.dx,
      top: widget.anchor.dy,
      child: Material(
        elevation: 6,
        color: OmColors.surface3,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
          side: BorderSide(color: OmColors.line3),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Row(
            key: const Key('kind-chip'),
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final k in const [
                'references',
                'extends',
                'contradicts',
                'example-of',
              ])
                _ChipButton(
                  key: Key('kind-chip-button-$k'),
                  label: k,
                  active: widget.controller.selectedKind == k,
                  onTap: () => _pick(k),
                ),
              _ChipButton(
                key: const Key('kind-chip-more'),
                label: 'more…',
                active: false,
                onTap: _pickMore,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChipButton extends StatelessWidget {
  const _ChipButton({
    super.key,
    required this.label,
    required this.active,
    required this.onTap,
  });
  final String label;
  final bool active;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 2),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: active ? OmColors.accent : Colors.transparent,
            border: Border.all(
              color: active ? OmColors.accent : OmColors.line2,
              width: 1,
            ),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            label.toUpperCase(),
            style: OmType.mono(
              size: 10,
              color: active ? OmColors.accentFg : OmColors.fg2,
              letterSpacing: 0.6,
              weight: FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

class _KindPickerDialog extends StatefulWidget {
  const _KindPickerDialog({required this.existing});
  final List<String> existing;

  @override
  State<_KindPickerDialog> createState() => _KindPickerDialogState();
}

class _KindPickerDialogState extends State<_KindPickerDialog> {
  final _ctrl = TextEditingController();
  String? _error;

  bool _isValidKind(String s) {
    final n = s.trim().toLowerCase();
    if (n.isEmpty || n.length > 64) return false;
    return RegExp(r'^[a-z][a-z0-9-]*$').hasMatch(n);
  }

  void _submit() {
    final s = _ctrl.text.trim().toLowerCase();
    if (!_isValidKind(s)) {
      setState(
        () => _error =
            'kind must be lowercase kebab-case (a-z, 0-9, dashes) and start with a letter',
      );
      return;
    }
    Navigator.of(context).pop(s);
  }

  @override
  Widget build(BuildContext context) {
    final user = widget.existing
        .where(
          (k) => !const [
            'references',
            'extends',
            'contradicts',
            'example-of',
          ].contains(k),
        )
        .toList();
    return AlertDialog(
      title: Text('PICK A KIND', style: OmType.eyebrow()),
      content: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 360, maxWidth: 440),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (user.isNotEmpty) ...[
              Text(
                'kinds you\'ve already used',
                style: OmType.mono(size: 11, color: OmColors.fg2),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final k in user)
                    GestureDetector(
                      onTap: () => Navigator.of(context).pop(k),
                      child: const OmChip(
                        label: 'placeholder',
                        tone: ChipTone.neutral,
                      ),
                    ).withLabel(k),
                ],
              ),
              const SizedBox(height: 16),
            ],
            Text(
              'or create a new kind',
              style: OmType.mono(size: 11, color: OmColors.fg2),
            ),
            const SizedBox(height: 6),
            Container(
              decoration: BoxDecoration(
                color: OmColors.surface3,
                border: Border.all(color: OmColors.line2, width: 1),
                borderRadius: BorderRadius.circular(6),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: TextField(
                controller: _ctrl,
                autofocus: true,
                style: OmType.sans(size: 13, color: OmColors.fg0),
                decoration: const InputDecoration(hintText: 'inspired-by'),
                onChanged: (_) => setState(() => _error = null),
                onSubmitted: (_) => _submit(),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: OmType.mono(size: 11, color: OmColors.danger),
              ),
            ],
          ],
        ),
      ),
      actions: [
        OmButton(
          kind: OmButtonKind.ghost,
          label: 'cancel',
          onPressed: () => Navigator.of(context).pop(),
        ),
        OmButton(kind: OmButtonKind.primary, label: 'use', onPressed: _submit),
      ],
    );
  }
}

/// Tiny extension to bolt a label onto a wrapped [GestureDetector] so the
/// existing-user-defined-kinds chips display the kind text instead of the
/// `placeholder` we passed.
extension _ChipLabel on GestureDetector {
  Widget withLabel(String text) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: OmColors.surface3,
          border: Border.all(color: OmColors.line2, width: 1),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          text.toUpperCase(),
          style: OmType.mono(size: 11, color: OmColors.fg1, letterSpacing: 0.8),
        ),
      ),
    );
  }
}
