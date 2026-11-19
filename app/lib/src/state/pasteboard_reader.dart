import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'vault_trash.dart';

/// What the system clipboard holds that an attachment can use (Spec #123 R8).
///
/// The native side reports files, and [hasText] on its own, so the caller can
/// apply R8's order: files, then text, then image. It reads image bytes only
/// when the clipboard holds neither files nor text, so [png] is null whenever
/// [hasText] is true.
class PasteboardContents {
  const PasteboardContents({
    this.files = const [],
    this.png,
    this.hasText = false,
  });

  /// Absolute paths of the files on the clipboard; empty when none.
  final List<String> files;

  /// A PNG image on the clipboard (a TIFF is converted natively); null when
  /// none, and not read at all when the clipboard holds files or text.
  final Uint8List? png;

  /// Whether the clipboard also holds plain text.
  final bool hasText;
}

/// The clipboard seam. Tests replace it with a fake.
abstract interface class PasteboardReader {
  /// Reads the clipboard. Never throws: any failure reads as empty.
  Future<PasteboardContents> read();
}

/// The default [PasteboardReader]: sends `readPasteboard` on the
/// `open_memex/files` channel and maps the reply.
class PlatformPasteboardReader implements PasteboardReader {
  const PlatformPasteboardReader();

  @override
  Future<PasteboardContents> read() async {
    try {
      final reply = await vaultFilesChannel.invokeMethod<Object?>(
        'readPasteboard',
      );
      if (reply is! Map) return const PasteboardContents();
      final files = reply['files'];
      final png = reply['png'];
      return PasteboardContents(
        files: files is List ? files.whereType<String>().toList() : const [],
        png: png is Uint8List ? png : null,
        hasText: reply['hasText'] == true,
      );
    } on PlatformException {
      return const PasteboardContents();
    } on MissingPluginException {
      return const PasteboardContents();
    }
  }
}

/// The app's [PasteboardReader]. Tests override it with a fake.
final pasteboardReaderProvider = Provider<PasteboardReader>(
  (ref) => const PlatformPasteboardReader(),
);
