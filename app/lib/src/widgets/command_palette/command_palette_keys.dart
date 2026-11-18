// WI #77 (56-A3, Spec #59 reqs 4-5, 43; D12, D13): the ⌘K handler.
// Skeleton: handles nothing yet.
import 'package:flutter/widgets.dart';

/// Registers Cmd+K on `HardwareKeyboard` while mounted (the Workspace
/// mounts it just after `AgentsWindowMenuAttach`): a key-down opens the
/// Command palette, or closes it while it shows. Builds nothing.
class CommandPaletteKeys extends StatelessWidget {
  const CommandPaletteKeys({super.key});

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
