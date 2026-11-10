import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/settings.dart';
import '../state/vault_open_controller.dart';
import '../state/vault_state.dart';
import '../theme/colors.dart';
import '../widgets/picker/vault_picker_body.dart';

/// The full-screen vault picker (`_Router` in main.dart, no vault open): the
/// shared [VaultPickerBody] in a 560 px column, plus the launch reopen.
class VaultPickerScreen extends ConsumerStatefulWidget {
  const VaultPickerScreen({super.key});

  @override
  ConsumerState<VaultPickerScreen> createState() => _VaultPickerScreenState();
}

class _VaultPickerScreenState extends ConsumerState<VaultPickerScreen> {
  final _body = GlobalKey<VaultPickerBodyState>();

  /// The last vault while the launch reopen runs on it; its recent row
  /// shows as opening.
  VaultRef? _launchRef;

  @override
  void initState() {
    super.initState();
    // Launch reopen (#92, #96): with a last vault and no vault open, reopen
    // it once, after the first frame.
    final last = ref.read(settingsProvider).lastVaultRef;
    if (last != null && ref.read(currentVaultProvider) == null) {
      _launchRef = last;
      WidgetsBinding.instance.addPostFrameCallback((_) => _launch());
    }
  }

  Future<void> _launch() async {
    if (!mounted) return;
    final outcome = await ref.read(vaultOpenControllerProvider).launchReopen();
    if (!mounted) return;
    setState(() => _launchRef = null);
    await _body.currentState?.present(outcome, eyebrow: vaultPickerOpenEyebrow);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: OmColors.surface1,
      body: Center(
        child: ConstrainedBox(
          // Pack 97: a 560 px content column inside 40 px padding.
          constraints: const BoxConstraints(maxWidth: 640),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(40),
            child: VaultPickerBody(key: _body, opening: _launchRef),
          ),
        ),
      ),
    );
  }
}
