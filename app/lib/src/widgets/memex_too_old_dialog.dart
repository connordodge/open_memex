import 'package:flutter/widgets.dart';

/// What the person chose in the too-old-memex refusal (L20).
enum MemexTooOldChoice { cancel, locateBinary }

/// Shows the too-old-memex refusal (the A9 state-1 layout) for the folder at
/// [path] under [eyebrow] and completes with the choice that closed it.
Future<MemexTooOldChoice?> showMemexTooOldDialog(
  BuildContext context, {
  required String path,
  required String eyebrow,
}) async {
  throw UnimplementedError('#92: too-old memex refusal');
}
