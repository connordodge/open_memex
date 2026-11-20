#!/usr/bin/env python3
"""Writes the attachment extraction fixtures (WI #136, Spec #123 R43, R44).

Every file here is made by this script, from nothing: no PDF is copied from
anywhere. Run it from any folder; it writes next to itself.

- text-layer.pdf: one page, a text layer in the base-14 Helvetica font.
- image-only.pdf: one page holding only an 8x8 grey image (no text).
- corrupt.pdf: a PDF header and the start of a catalog, then junk: no pages,
  no cross-reference table, no trailer.
- invalid-utf8.txt: UTF-8 text with three invalid byte sequences in it.
"""

import os

HERE = os.path.dirname(os.path.abspath(__file__))

# The words the tests search for. Keep in step with
# crates/memex-core/tests/attachments_extract.rs.
TITLE = "Quarterly zebra migration report"
LINE = "Striped kelp forests drift north"


def pdf(objects):
    """A PDF from `objects` (bytes, numbered from 1) with a correct xref."""
    out = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
    offsets = []
    for i, body in enumerate(objects, start=1):
        offsets.append(len(out))
        out += b"%d 0 obj\n" % i + body + b"\nendobj\n"
    xref = len(out)
    out += b"xref\n0 %d\n" % (len(objects) + 1)
    out += b"0000000000 65535 f \n"
    for off in offsets:
        out += b"%010d 00000 n \n" % off
    out += b"trailer\n<< /Size %d /Root 1 0 R >>\n" % (len(objects) + 1)
    out += b"startxref\n%d\n%%%%EOF\n" % xref
    return bytes(out)


def stream(dictionary, data):
    return b"<< " + dictionary + b" /Length %d >>\nstream\n" % len(data) + data + b"\nendstream"


def text_layer():
    content = (
        b"BT /F1 24 Tf 72 720 Td (" + TITLE.encode() + b") Tj ET\n"
        b"BT /F1 12 Tf 72 690 Td (" + LINE.encode() + b") Tj ET"
    )
    return pdf(
        [
            b"<< /Type /Catalog /Pages 2 0 R >>",
            b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R"
            b" /Resources << /Font << /F1 5 0 R >> >> >>",
            stream(b"", content),
            b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica"
            b" /Encoding /WinAnsiEncoding >>",
        ]
    )


def image_only():
    pixels = bytes((x * 32) % 256 for x in range(64))
    content = b"q 200 0 0 200 72 500 cm /Im1 Do Q"
    return pdf(
        [
            b"<< /Type /Catalog /Pages 2 0 R >>",
            b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R"
            b" /Resources << /XObject << /Im1 5 0 R >> >> >>",
            stream(b"", content),
            stream(
                b"/Type /XObject /Subtype /Image /Width 8 /Height 8"
                b" /ColorSpace /DeviceGray /BitsPerComponent 8",
                pixels,
            ),
        ]
    )


def corrupt():
    return (
        b"%PDF-1.4\n1 0 obj\n<< /Type /Catalog /Pages 2 0 R\n"
        + b"\x00\xff\xfe garbage that is not a PDF object \x13\x37" * 4
        + b"\n"
    )


def invalid_utf8():
    # "caf\xc3\xa9" is valid UTF-8 (cafe with an acute e). \xff, \xc3\x28 and
    # a lone \x80 are not.
    return (
        b"Invoice for the walrus caf\xc3\xa9\n\n"
        b"Total \xff due on receipt \xc3\x28 tundra \x80 ledger\n"
    )


def main():
    files = {
        "text-layer.pdf": text_layer(),
        "image-only.pdf": image_only(),
        "corrupt.pdf": corrupt(),
        "invalid-utf8.txt": invalid_utf8(),
    }
    for name, data in files.items():
        with open(os.path.join(HERE, name), "wb") as f:
            f.write(data)


if __name__ == "__main__":
    main()
