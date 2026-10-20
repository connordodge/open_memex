import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../state/settings.dart';
import 'network_drive_refusal_dialog.dart';

/// What the person chose in the too-old-memex refusal (L20).
enum MemexTooOldChoice { cancel, locateBinary }

/// The too-old-memex refusal copy (req 31).
const memexTooOldMessage =
    'this memex is too old to open vaults safely. update memex, then try again.';

/// Shows the too-old-memex refusal (the A9 state-1 layout) for the folder at
/// [path] under [eyebrow] and completes with the choice that closed it.
Future<MemexTooOldChoice?> showMemexTooOldDialog(
  BuildContext context, {
  required String path,
  required String eyebrow,
}) {
  return showDialog<MemexTooOldChoice>(
    context: context,
    builder: (ctx) => LocalOpenRefusalDialog(
      key: const Key('memex-too-old-refusal'),
      eyebrow: eyebrow,
      path: path,
      // A drive icon would claim a network drive (design pack 92).
      pathIcon: LucideIcons.folder,
      message: memexTooOldMessage,
      cancelKey: const Key('memex-too-old-cancel'),
      onCancel: () => Navigator.of(ctx).pop(MemexTooOldChoice.cancel),
      primaryKey: const Key('memex-too-old-locate'),
      primaryLabel: 'locate memex binary…',
      onPrimary: () => Navigator.of(ctx).pop(MemexTooOldChoice.locateBinary),
    ),
  );
}

/// "locate memex binary…": asks for the binary with the native file picker
/// and stores the picked path in [settings] when the file exists. A
/// cancelled picker or a missing file keeps the configured binary.
Future<void> locateMemexBinary(SettingsController settings) async {
  final r = await FilePicker.platform.pickFiles(
    dialogTitle: 'Locate the memex binary',
    type: FileType.any,
  );
  final path = r?.files.singleOrNull?.path;
  if (path != null && File(path).existsSync()) {
    await settings.setMemexBinary(path);
  }
}
