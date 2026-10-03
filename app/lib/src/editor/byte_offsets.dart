// UTF-8 byte offsets (server `blocks.start_byte` / `end_byte`, D12) <-> Dart
// UTF-16 code-unit indexes. All such conversion in the app goes through here.
//
// An offset that isn't on a character boundary throws [ArgumentError].

/// Converts a UTF-16 code-unit index in [text] to a UTF-8 byte offset.
///
/// Throws [RangeError] (an [ArgumentError]) when [utf16Index] is outside
/// `0..text.length`, and [ArgumentError] when it falls between the two halves
/// of a surrogate pair.
int utf16ToUtf8(String text, int utf16Index) {
  RangeError.checkValueInInterval(utf16Index, 0, text.length, 'utf16Index');
  if (utf16Index > 0 &&
      utf16Index < text.length &&
      _isHighSurrogate(text.codeUnitAt(utf16Index - 1)) &&
      _isLowSurrogate(text.codeUnitAt(utf16Index))) {
    throw ArgumentError.value(
      utf16Index,
      'utf16Index',
      'falls between the halves of a surrogate pair',
    );
  }
  var bytes = 0;
  var i = 0;
  while (i < utf16Index) {
    final width = _charAt(text, i);
    bytes += width.bytes;
    i += width.units;
  }
  return bytes;
}

/// Converts a UTF-8 byte offset in [text] to a UTF-16 code-unit index.
///
/// Throws [ArgumentError] when [utf8Offset] is not a character boundary of
/// the UTF-8 encoding of [text]: negative, past its end, or inside a
/// multi-byte character.
int utf8ToUtf16(String text, int utf8Offset) {
  var bytes = 0;
  var i = 0;
  while (bytes < utf8Offset && i < text.length) {
    final width = _charAt(text, i);
    bytes += width.bytes;
    i += width.units;
  }
  if (bytes != utf8Offset) {
    throw ArgumentError.value(
      utf8Offset,
      'utf8Offset',
      'is not a character boundary in the UTF-8 encoding of the text',
    );
  }
  return i;
}

/// The UTF-8 byte width and UTF-16 code-unit width of the character at [i].
///
/// A lone surrogate counts as U+FFFD (three bytes), as `utf8.encode` does.
({int bytes, int units}) _charAt(String text, int i) {
  final unit = text.codeUnitAt(i);
  if (unit < 0x80) return (bytes: 1, units: 1);
  if (unit < 0x800) return (bytes: 2, units: 1);
  if (_isHighSurrogate(unit) &&
      i + 1 < text.length &&
      _isLowSurrogate(text.codeUnitAt(i + 1))) {
    return (bytes: 4, units: 2);
  }
  return (bytes: 3, units: 1);
}

bool _isHighSurrogate(int unit) => unit >= 0xD800 && unit <= 0xDBFF;

bool _isLowSurrogate(int unit) => unit >= 0xDC00 && unit <= 0xDFFF;
