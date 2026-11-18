// WI #77 (56-A3, Spec #59 reqs 4-5, 42-43; D12, D13): the ⌘K handler.
import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'command_palette.dart';

/// Registers Cmd+K on `HardwareKeyboard` while mounted (the Workspace
/// mounts it just after `AgentsWindowMenuAttach`): a key-down opens the
/// Command palette over this widget's context, or closes it while it shows.
/// Only the exact chord (Cmd, no Shift, Control or Option) is handled, so
/// Cmd+F, Cmd+G and Cmd+E reach the native menu. A key repeat is claimed and
/// does nothing; a key up is not handled. While another modal route covers
/// the workspace, or covers the showing palette, the chord is not handled.
/// Unmounting closes the palette.
/// Builds nothing.
class CommandPaletteKeys extends StatefulWidget {
  const CommandPaletteKeys({super.key});

  @override
  State<CommandPaletteKeys> createState() => _CommandPaletteKeysState();
}

class _CommandPaletteKeysState extends State<CommandPaletteKeys> {
  /// The container the palette opens in: kept while mounted, so [dispose]
  /// can close the palette without an ancestor lookup.
  late ProviderContainer _container;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _container = ProviderScope.containerOf(context, listen: false);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    // The Workspace unmounted (req 42): close the palette once the tree is
    // unlocked, unless the app went with it.
    final container = _container;
    void close() {
      try {
        closeCommandPalette(container);
      } on StateError {
        // The container was disposed: nothing shows any more.
      }
    }

    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => close());
    } else {
      scheduleMicrotask(close);
    }
    super.dispose();
  }

  bool _onKey(KeyEvent event) {
    if (event is KeyUpEvent) return false;
    if (event.logicalKey != LogicalKeyboardKey.keyK) return false;
    final keys = HardwareKeyboard.instance;
    if (!keys.isMetaPressed ||
        keys.isShiftPressed ||
        keys.isControlPressed ||
        keys.isAltPressed) {
      return false;
    }
    final showing = isCommandPaletteShowing(_container);
    // A modal other than the palette owns the keyboard: one over the
    // workspace, or one pushed over the palette itself.
    if (showing) {
      if (!isCommandPaletteCurrent(_container)) return false;
    } else if (ModalRoute.of(context)?.isCurrent == false) {
      return false;
    }
    // A held chord is claimed (so macOS does not beep) but toggles once.
    if (event is! KeyDownEvent) return true;
    if (showing) {
      closeCommandPalette(_container);
    } else {
      unawaited(showCommandPalette(context));
    }
    return true;
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
