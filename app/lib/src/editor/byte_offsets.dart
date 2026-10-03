// UTF-8 byte offsets (server `blocks.start_byte` / `end_byte`, D12) <-> Dart
// UTF-16 code-unit indexes. All such conversion in the app goes through here.
//
// An offset that isn't on a character boundary throws [ArgumentError].

/// Converts a UTF-16 code-unit index in [text] to a UTF-8 byte offset.
int utf16ToUtf8(String text, int utf16Index) => throw UnimplementedError();

/// Converts a UTF-8 byte offset in [text] to a UTF-16 code-unit index.
int utf8ToUtf16(String text, int utf8Offset) => throw UnimplementedError();
