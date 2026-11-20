//! WI #134 (Spec #123 R1, R3, R4, R31, R33; ruling D16, D18): the attachment
//! stored-name rule, the reference markdown and its grammar, the type tables
//! and the GLOSSARY entry.
//!
//! The grammar, encoder and executable-table rows come from the shared
//! fixture `app/test/fixtures/attachments/refs.json`, which the app's Dart
//! mirror reads too, so the two implementations can't drift. Every row is
//! checked.

use std::collections::BTreeSet;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

use memex_core::attachments::{
    self, ReferenceKind, EXECUTABLE_EXTENSIONS, INLINE_IMAGE_EXTENSIONS,
};
use serde_json::Value;

/// R33's table, exactly as the Spec lists it.
const R33_EXECUTABLES: [&str; 26] = [
    "command",
    "tool",
    "terminal",
    "sh",
    "zsh",
    "bash",
    "py",
    "rb",
    "pl",
    "pkg",
    "mpkg",
    "dmg",
    "app",
    "workflow",
    "scpt",
    "applescript",
    "jar",
    "exe",
    "fileloc",
    "inetloc",
    "webloc",
    "afploc",
    "ftploc",
    "mailloc",
    "newsloc",
    "atloc",
];

/// R31's inline image types.
const R31_IMAGES: [&str; 5] = ["png", "jpg", "jpeg", "gif", "webp"];

fn fixture() -> Value {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../app/test/fixtures/attachments/refs.json");
    let text = fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()));
    serde_json::from_str(&text).expect("refs.json is JSON")
}

fn rows<'a>(fx: &'a Value, key: &str) -> &'a [Value] {
    fx[key]
        .as_array()
        .unwrap_or_else(|| panic!("refs.json has a {key} array"))
}

fn text<'a>(row: &'a Value, key: &str) -> &'a str {
    row[key]
        .as_str()
        .unwrap_or_else(|| panic!("row {row} has a string {key}"))
}

fn kind_text(kind: ReferenceKind) -> &'static str {
    match kind {
        ReferenceKind::Image => "image",
        ReferenceKind::Link => "link",
    }
}

/// The destination of a one-reference markdown string: what is between the
/// last `](` and the closing `)`.
fn destination_of(markdown: &str) -> &str {
    let start = markdown.rfind("](").expect("a destination") + 2;
    markdown[start..].strip_suffix(')').expect("closing )")
}

// ---------------------------------------------------------------------------
// AC: refs.json — the parser (R4), the encoder (R3) and the executable table
// (R33) agree with every row.
// ---------------------------------------------------------------------------

#[test]
fn every_refs_json_reference_row_parses_as_the_row_says() {
    let fx = fixture();
    let refs = rows(&fx, "references");
    let valid = refs.iter().filter(|r| r["valid"] == true).count();
    assert!(valid >= 5, "refs.json has valid rows ({valid})");
    assert!(refs.len() - valid >= 10, "refs.json has invalid rows");
    for row in refs {
        let markdown = text(row, "markdown");
        let why = text(row, "why");
        let parsed = attachments::parse_reference(markdown);
        if row["valid"] == true {
            let r = parsed.unwrap_or_else(|| panic!("{why}: {markdown:?} is a reference"));
            assert_eq!(kind_text(r.kind), text(row, "kind"), "{why}: kind");
            assert_eq!(r.target.path, text(row, "path"), "{why}: decoded path");
            assert_eq!(r.target.name, text(row, "name"), "{why}: decoded name");
            let hash = text(row, "path").split('/').nth(2).unwrap();
            assert_eq!(r.target.hash, hash, "{why}: hash");
        } else {
            assert_eq!(parsed, None, "{why}: {markdown:?} is not a reference");
        }
    }
}

#[test]
fn parse_destination_accepts_every_valid_rows_destination_and_refuses_bare_non_paths() {
    let fx = fixture();
    for row in rows(&fx, "references")
        .iter()
        .filter(|r| r["valid"] == true)
    {
        let why = text(row, "why");
        let dest = destination_of(text(row, "markdown"));
        let target = attachments::parse_destination(dest)
            .unwrap_or_else(|| panic!("{why}: {dest:?} is an attachment path"));
        assert_eq!(target.path, text(row, "path"), "{why}: decoded path");
        assert_eq!(target.name, text(row, "name"), "{why}: decoded name");
    }
    let h = fx["hash"].as_str().unwrap();
    for bad in [
        format!("objects/66/{}/x.txt", h.to_uppercase()),
        format!("objects/77/{h}/x.txt"),
        format!("objects/66/{}/x.txt", &h[..63]),
        format!("objects/66/{h}/.."),
        format!("objects/66/{h}/."),
        format!("objects/66/{h}/a%2Fb.txt"),
        format!("objects/66/{h}/"),
        format!("https://example.com/objects/66/{h}/x.png"),
        "notes/x.txt".to_string(),
        String::new(),
    ] {
        assert_eq!(
            attachments::parse_destination(&bad),
            None,
            "{bad:?} is not an attachment path"
        );
    }
}

#[test]
fn parse_path_takes_an_already_decoded_path_and_does_not_decode_it_again() {
    let fx = fixture();
    for row in rows(&fx, "references")
        .iter()
        .filter(|r| r["valid"] == true)
    {
        let why = text(row, "why");
        let path = text(row, "path");
        let target = attachments::parse_path(path)
            .unwrap_or_else(|| panic!("{why}: {path:?} is an attachment path"));
        assert_eq!(target.path, path, "{why}: path");
        assert_eq!(target.name, text(row, "name"), "{why}: name");
        assert_eq!(target.hash, path.split('/').nth(2).unwrap(), "{why}: hash");
    }
    let h = fx["hash"].as_str().unwrap();
    // A decoded name may hold a `%`: it stays as it is, not decoded again.
    let target = attachments::parse_path(&format!("objects/66/{h}/a%41.txt")).unwrap();
    assert_eq!(target.name, "a%41.txt");
    // A decoded `%` that isn't followed by hex digits is just a character.
    assert!(attachments::parse_path(&format!("objects/66/{h}/100%.txt")).is_some());
    for bad in [
        format!("objects/66/{}/x.txt", h.to_uppercase()),
        format!("objects/77/{h}/x.txt"),
        format!("objects/66/{}/x.txt", &h[..63]),
        format!("objects/66/{h}/.."),
        format!("objects/66/{h}/."),
        format!("objects/66/{h}/a/b.txt"),
        format!("objects/66/{h}/"),
        format!("/objects/66/{h}/x.txt"),
        format!("Objects/66/{h}/x.txt"),
        format!("objects66/{h}/x.txt"),
        format!("objects/66/{h}"),
        "objects".to_string(),
        String::new(),
    ] {
        assert_eq!(attachments::parse_path(&bad), None, "{bad:?}");
    }
}

#[test]
fn a_stored_attachments_path_is_a_parse_path_path_and_its_markdown_a_reference() {
    let h = H;
    let name = "Q3 report [final].pdf";
    let md = attachments::markdown_for(name, h);
    let r = attachments::parse_reference(&md).expect("reference");
    assert_eq!(r.target.name, name);
    assert_eq!(r.target.hash, h);
    assert_eq!(
        attachments::parse_path(&r.target.path).as_ref(),
        Some(&r.target)
    );
}

#[test]
fn every_refs_json_encode_row_is_what_markdown_for_and_encode_name_return() {
    let fx = fixture();
    let encode = rows(&fx, "encode");
    assert!(encode.len() >= 10, "refs.json has encode rows");
    for row in encode {
        let name = text(row, "name");
        assert_eq!(
            attachments::markdown_for(name, text(row, "hash")),
            text(row, "markdown"),
            "markdown for {name:?}"
        );
        assert_eq!(
            attachments::encode_name(name),
            text(row, "encoded_name"),
            "encoded name of {name:?}"
        );
        assert_eq!(
            attachments::is_inline_image(name),
            text(row, "kind") == "image",
            "inline image type of {name:?}"
        );
    }
}

#[test]
fn every_refs_json_encode_row_parses_back_to_its_name_and_kind() {
    let fx = fixture();
    for row in rows(&fx, "encode") {
        let name = text(row, "name");
        let hash = text(row, "hash");
        let markdown = text(row, "markdown");
        let r = attachments::parse_reference(markdown)
            .unwrap_or_else(|| panic!("{markdown:?} parses as a reference"));
        assert_eq!(r.target.name, name, "round trip of {name:?}");
        assert_eq!(r.target.hash, hash);
        assert_eq!(
            r.target.path,
            format!("objects/{}/{hash}/{name}", &hash[..2]),
            "decoded path of {name:?}"
        );
        assert_eq!(kind_text(r.kind), text(row, "kind"), "kind of {name:?}");
    }
}

#[test]
fn every_refs_json_executable_row_matches_the_executable_table() {
    let fx = fixture();
    let ex = rows(&fx, "executable");
    let covered: BTreeSet<String> = ex
        .iter()
        .filter(|r| r["executable"] == true)
        .filter_map(|r| text(r, "name").rsplit('.').next().map(str::to_lowercase))
        .collect();
    for e in R33_EXECUTABLES {
        assert!(
            covered.contains(e),
            "refs.json has an executable row for .{e}"
        );
    }
    assert!(
        ex.iter().any(|r| r["executable"] == false),
        "refs.json has a non-executable control"
    );
    for row in ex {
        let name = text(row, "name");
        assert_eq!(
            attachments::is_executable_name(name),
            row["executable"] == true,
            "{}: {name:?}",
            text(row, "why")
        );
    }
}

// ---------------------------------------------------------------------------
// AC: markdown (R3) — image form for the inline types in any case, escapes,
// uppercase percent hex.
// ---------------------------------------------------------------------------

const H: &str = "66bc7611813b7443f25c4af21004864b3975eb83fb7c74be572b9d6aa74bd462";

#[test]
fn markdown_is_image_form_for_png_jpg_jpeg_gif_webp_in_any_case_and_link_form_otherwise() {
    for ext in [
        "png", "PNG", "Jpg", "jpeg", "JPEG", "gif", "GIF", "webp", "WebP",
    ] {
        let name = format!("pic.{ext}");
        let md = attachments::markdown_for(&name, H);
        assert_eq!(md, format!("![{name}](objects/66/{H}/{name})"), "{name}");
    }
    for name in [
        "pic.heic", "pic.svg", "pic.tiff", "pic.bmp", "pic.pdf", "png", "pic",
    ] {
        let md = attachments::markdown_for(name, H);
        assert_eq!(md, format!("[{name}](objects/66/{H}/{name})"), "{name}");
    }
}

#[test]
fn encode_name_keeps_only_unreserved_bytes_and_writes_uppercase_hex() {
    let unreserved = "ABCXYZabcxyz0189-._~";
    assert_eq!(attachments::encode_name(unreserved), unreserved);
    assert_eq!(attachments::encode_name(" "), "%20");
    assert_eq!(attachments::encode_name("é"), "%C3%A9");
    assert_eq!(attachments::encode_name("%"), "%25");
    assert_eq!(attachments::encode_name("/"), "%2F");
    assert_eq!(attachments::encode_name("\\"), "%5C");
    assert_eq!(attachments::encode_name("[]()"), "%5B%5D%28%29");
    assert_eq!(attachments::encode_name("\u{7f}"), "%7F");
    assert_eq!(attachments::encode_name("@!*'"), "%40%21%2A%27");
    // Every byte outside the unreserved set, ASCII and not.
    for b in 0u8..=127 {
        let c = b as char;
        let s = c.to_string();
        let keep = c.is_ascii_alphanumeric() || "-._~".contains(c);
        let want = if keep { s.clone() } else { format!("%{b:02X}") };
        assert_eq!(attachments::encode_name(&s), want, "byte {b:#04x}");
    }
}

#[test]
fn bracketed_text_escapes_open_bracket_close_bracket_and_backslash() {
    assert_eq!(
        attachments::markdown_for("a[b]c\\d.txt", H),
        format!("[a\\[b\\]c\\\\d.txt](objects/66/{H}/a%5Bb%5Dc%5Cd.txt)")
    );
    // Other markdown punctuation is left alone in the text.
    assert_eq!(
        attachments::markdown_for("*a_b* (c).txt", H),
        format!("[*a_b* (c).txt](objects/66/{H}/%2Aa_b%2A%20%28c%29.txt)")
    );
}

// ---------------------------------------------------------------------------
// AC: stored-name rule (R1).
// ---------------------------------------------------------------------------

#[test]
fn stored_name_replaces_slash_backslash_nul_and_control_characters_with_underscore() {
    assert_eq!(attachments::stored_name("a/b\\c.txt"), "a_b_c.txt");
    assert_eq!(attachments::stored_name("a\0b.txt"), "a_b.txt");
    assert_eq!(attachments::stored_name("a\u{1}b.txt"), "a_b.txt");
    assert_eq!(attachments::stored_name("a\u{1f}b.txt"), "a_b.txt");
    assert_eq!(attachments::stored_name("a\u{7f}b.txt"), "a_b.txt");
    assert_eq!(attachments::stored_name("a\tb\nc\rd.txt"), "a_b_c_d.txt");
    assert_eq!(attachments::stored_name("//"), "__");
    // Each control character U+0001-U+001F on its own, inside a name.
    for c in 1u32..=0x1f {
        let ch = char::from_u32(c).unwrap();
        assert_eq!(
            attachments::stored_name(&format!("a{ch}b")),
            "a_b",
            "U+{c:04X}"
        );
    }
}

#[test]
fn stored_name_keeps_characters_just_outside_the_replaced_ranges() {
    // U+0020 (inside), U+007E, U+0080 and U+00A0 are not replaced.
    assert_eq!(attachments::stored_name("a b~c.txt"), "a b~c.txt");
    assert_eq!(attachments::stored_name("a\u{80}b.txt"), "a\u{80}b.txt");
    assert_eq!(
        attachments::stored_name("Café [1] 100%.txt"),
        "Café [1] 100%.txt"
    );
    assert_eq!(attachments::stored_name("Q3 report.pdf"), "Q3 report.pdf");
}

#[test]
fn stored_name_trims_leading_and_trailing_whitespace() {
    assert_eq!(
        attachments::stored_name("  Q3 report.pdf  "),
        "Q3 report.pdf"
    );
    assert_eq!(attachments::stored_name(" a b "), "a b");
}

#[test]
fn stored_name_of_an_empty_or_blank_name_is_file() {
    assert_eq!(attachments::stored_name(""), "file");
    assert_eq!(attachments::stored_name("   "), "file");
}

#[test]
fn stored_name_of_dot_or_dot_dot_after_the_trim_is_file() {
    for given in [".", "..", " .. ", " . ", "\u{a0}..\u{a0}"] {
        assert_eq!(attachments::stored_name(given), "file", "{given:?}");
    }
    // Control characters become `_` before the trim, so they are not trimmed.
    assert_eq!(attachments::stored_name("\t..\n"), "_.._");
    assert_eq!(attachments::stored_name("/"), "_");
    // Only exactly `.` and `..` are special.
    for kept in ["...", ".hidden", "a.", "a..", ". .", ".a"] {
        assert_eq!(attachments::stored_name(kept), kept, "{kept:?}");
    }
    assert_eq!(attachments::stored_name(&".".repeat(300)), ".".repeat(255));
}

#[test]
fn stored_name_over_255_bytes_is_cut_on_a_character_boundary_keeping_the_extension() {
    // ASCII: exactly 255 bytes stays; 256 is cut to 255.
    let at = format!("{}.pdf", "a".repeat(251));
    assert_eq!(at.len(), 255);
    assert_eq!(attachments::stored_name(&at), at, "255 bytes is kept");
    let over = format!("{}.pdf", "a".repeat(252));
    let cut = attachments::stored_name(&over);
    assert_eq!(
        cut,
        format!("{}.pdf", "a".repeat(251)),
        "256 bytes is cut to 255"
    );

    let long = format!("{}.pdf", "a".repeat(300));
    let cut = attachments::stored_name(&long);
    assert_eq!(cut.len(), 255);
    assert_eq!(cut, format!("{}.pdf", "a".repeat(251)));

    // Two-byte characters: 125 x é (250 bytes) + .txt = 254; one more é is 256.
    let two = format!("{}.txt", "é".repeat(200));
    let cut = attachments::stored_name(&two);
    assert_eq!(cut, format!("{}.txt", "é".repeat(125)));
    assert_eq!(cut.len(), 254);

    // Four-byte characters: 62 (248 bytes) + .png = 252.
    let four = format!("{}.png", "\u{1F600}".repeat(70));
    let cut = attachments::stored_name(&four);
    assert_eq!(cut, format!("{}.png", "\u{1F600}".repeat(62)));

    // No extension: the cut keeps the first 255 bytes.
    let plain = "b".repeat(400);
    assert_eq!(attachments::stored_name(&plain), "b".repeat(255));
    let plain_two = "é".repeat(200);
    assert_eq!(attachments::stored_name(&plain_two), "é".repeat(127));

    // The cut is after the trim: trimmed, 255 bytes fits.
    let padded = format!("  {at}  ");
    assert_eq!(attachments::stored_name(&padded), at);
}

#[test]
fn stored_name_trims_whitespace_the_255_byte_cut_leaves_and_is_idempotent() {
    // The cut lands just after a space in the stem.
    let spaced = format!("{} {}.txt", "a".repeat(250), "b".repeat(10));
    let got = attachments::stored_name(&spaced);
    assert_eq!(got, format!("{}.txt", "a".repeat(250)));
    assert_eq!(attachments::stored_name(&got), got, "idempotent");

    // No extension: the cut lands just after a space at the end.
    let plain = format!("{} {}", "a".repeat(254), "b".repeat(10));
    let got = attachments::stored_name(&plain);
    assert_eq!(got, "a".repeat(254));
    assert_eq!(attachments::stored_name(&got), got, "idempotent");

    // Several spaces before the cut are all trimmed.
    let many = format!("{}   {}.pdf", "c".repeat(248), "d".repeat(20));
    let got = attachments::stored_name(&many);
    assert_eq!(got, format!("{}.pdf", "c".repeat(248)));
    assert_eq!(attachments::stored_name(&got), got, "idempotent");
}

#[test]
fn stored_name_keeps_an_extension_of_254_bytes_and_cuts_one_of_255() {
    // Extension of 254 bytes (the dot and 253 letters): one byte is left for
    // the stem.
    let ext254 = format!(".{}", "e".repeat(253));
    let got = attachments::stored_name(&format!("stem{ext254}"));
    assert_eq!(got, format!("s{ext254}"));
    assert_eq!(got.len(), 255);

    // Extension of 255 bytes: it leaves no room, so the name is cut whole.
    let ext255 = format!(".{}", "e".repeat(254));
    let got = attachments::stored_name(&format!("stem{ext255}"));
    assert_eq!(got.len(), 255);
    assert_eq!(got, format!("stem.{}", "e".repeat(250)));
}

// ---------------------------------------------------------------------------
// AC: MIME table, inline types and the executable table (R31, R33).
// ---------------------------------------------------------------------------

#[test]
fn mime_for_maps_known_extensions_in_any_case_and_unknown_ones_to_octet_stream() {
    for (name, mime) in [
        ("a.png", "image/png"),
        ("a.PNG", "image/png"),
        ("a.jpg", "image/jpeg"),
        ("a.jpeg", "image/jpeg"),
        ("a.JPG", "image/jpeg"),
        ("a.gif", "image/gif"),
        ("a.webp", "image/webp"),
        ("Q3 report.pdf", "application/pdf"),
        ("notes.txt", "text/plain"),
        ("notes.md", "text/markdown"),
        ("table.csv", "text/csv"),
        ("data.json", "application/json"),
        ("a.qqq", "application/octet-stream"),
        ("no extension", "application/octet-stream"),
        ("png", "application/octet-stream"),
        ("", "application/octet-stream"),
    ] {
        assert_eq!(attachments::mime_for(name), mime, "{name:?}");
    }
}

#[test]
fn mime_for_every_other_table_entry_and_the_types_a_browser_would_run_as_a_page() {
    for (name, mime) in [
        ("a.heic", "image/heic"),
        ("a.heif", "image/heif"),
        ("a.tif", "image/tiff"),
        ("a.TIFF", "image/tiff"),
        ("a.bmp", "image/bmp"),
        ("a.markdown", "text/markdown"),
        ("a.tsv", "text/tab-separated-values"),
        ("a.rtf", "application/rtf"),
        ("a.zip", "application/zip"),
        ("a.gz", "application/gzip"),
        ("a.tar", "application/x-tar"),
        ("a.mp3", "audio/mpeg"),
        ("a.m4a", "audio/mp4"),
        ("a.wav", "audio/wav"),
        ("a.mp4", "video/mp4"),
        ("a.mov", "video/quicktime"),
        ("a.doc", "application/msword"),
        (
            "a.docx",
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        ),
        ("a.xls", "application/vnd.ms-excel"),
        (
            "a.xlsx",
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        ),
        ("a.ppt", "application/vnd.ms-powerpoint"),
        (
            "a.pptx",
            "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        ),
        // Served as a download, never run as a page.
        ("a.html", "application/octet-stream"),
        ("a.HTM", "application/octet-stream"),
        ("a.xhtml", "application/octet-stream"),
        ("a.svg", "application/octet-stream"),
        ("a.js", "application/octet-stream"),
        // Only the last extension counts.
        ("a.png.txt", "text/plain"),
        ("a.txt.qqq", "application/octet-stream"),
    ] {
        assert_eq!(attachments::mime_for(name), mime, "{name:?}");
    }
}

#[test]
fn inline_image_types_are_exactly_png_jpg_jpeg_gif_webp_in_any_case() {
    let table: BTreeSet<&str> = INLINE_IMAGE_EXTENSIONS.iter().copied().collect();
    assert_eq!(table, R31_IMAGES.iter().copied().collect::<BTreeSet<_>>());
    assert_eq!(INLINE_IMAGE_EXTENSIONS.len(), R31_IMAGES.len());
    for ext in R31_IMAGES {
        assert!(attachments::is_inline_image(&format!("a.{ext}")), ".{ext}");
        let upper = ext.to_uppercase();
        assert!(
            attachments::is_inline_image(&format!("a.{upper}")),
            ".{upper}"
        );
    }
    for name in [
        "a.heic",
        "a.svg",
        "a.tiff",
        "a.bmp",
        "a.pdf",
        "png",
        "a.png.txt",
    ] {
        assert!(!attachments::is_inline_image(name), "{name}");
    }
}

#[test]
fn executable_table_matches_r33_exactly() {
    let table: BTreeSet<&str> = EXECUTABLE_EXTENSIONS.iter().copied().collect();
    assert_eq!(
        table,
        R33_EXECUTABLES.iter().copied().collect::<BTreeSet<_>>()
    );
    assert_eq!(EXECUTABLE_EXTENSIONS.len(), R33_EXECUTABLES.len());
    for ext in R33_EXECUTABLES {
        assert!(
            attachments::is_executable_name(&format!("x.{ext}")),
            ".{ext}"
        );
    }
    for name in ["x.txt", "x.pdf", "x.png", "sh", "x.sh.txt", "x.command.zip"] {
        assert!(!attachments::is_executable_name(name), "{name}");
    }
}

/// #171 (L17): opening a location file follows the location it holds (an
/// app or script on disk, or a URL), so it is revealed, never opened.
#[test]
fn location_files_are_executable_in_any_letter_case() {
    for name in [
        "Read me.webloc",
        "Read me.WEBLOC",
        "Read me.WebLoc",
        "Site.inetloc",
        "Site.INETLOC",
        "Site.InetLoc",
        "Disk.fileloc",
        "Disk.FILELOC",
        "Disk.FileLoc",
        ".webloc",
    ] {
        assert!(attachments::is_executable_name(name), "{name}");
    }
    for name in [
        "notes.webloc.txt",
        "Site.inetloc.zip",
        "webloc",
        "x.weblocs",
        "x.filelo",
        "x.inet",
    ] {
        assert!(!attachments::is_executable_name(name), "{name}");
    }
}

#[test]
fn a_location_file_on_disk_counts_as_executable_without_an_x_bit() {
    let tmp = tempfile::tempdir().unwrap();
    for name in ["Read me.WEBLOC", "Site.inetloc", "Disk.FileLoc"] {
        let p = file_with_mode(tmp.path(), name, 0o644);
        assert!(attachments::is_executable(&p), "{name} by its extension");
    }
    let p = file_with_mode(tmp.path(), "notes.webloc.txt", 0o644);
    assert!(!attachments::is_executable(&p), "notes.webloc.txt");
}

fn file_with_mode(dir: &Path, name: &str, mode: u32) -> PathBuf {
    let p = dir.join(name);
    fs::write(&p, b"#!/bin/sh\necho hi\n").unwrap();
    fs::set_permissions(&p, fs::Permissions::from_mode(mode)).unwrap();
    p
}

#[test]
fn a_file_with_any_executable_permission_bit_counts_as_executable() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path();
    for (name, mode, want) in [
        ("plain notes.txt", 0o644, false),
        ("owner x.txt", 0o744, true),
        ("group x.txt", 0o654, true),
        ("other x.txt", 0o645, true),
        ("all x", 0o755, true),
        ("read only.txt", 0o444, false),
    ] {
        let p = file_with_mode(dir, name, mode);
        assert_eq!(attachments::is_executable(&p), want, "{name} mode {mode:o}");
    }
    // The x-bit rule is for regular files: a folder is not executable, a
    // missing path is not, and a missing path with a table extension is.
    let folder = dir.join("some folder");
    fs::create_dir(&folder).unwrap();
    fs::set_permissions(&folder, fs::Permissions::from_mode(0o755)).unwrap();
    assert!(!attachments::is_executable(&folder), "a folder");
    assert!(!attachments::is_executable(&dir.join("missing.txt")));
    assert!(attachments::is_executable(&dir.join("missing.exe")));
    // The extension table applies to files on disk too, without any x bit.
    let p = file_with_mode(dir, "build.sh", 0o644);
    assert!(attachments::is_executable(&p), "build.sh by its extension");
    let p = file_with_mode(dir, "Setup.pkg", 0o600);
    assert!(attachments::is_executable(&p), "Setup.pkg by its extension");
}

// ---------------------------------------------------------------------------
// AC: GLOSSARY.md `## Attachments (#121)` right after `## Backups (#315)`
// (D16); the last five headings unchanged.
// ---------------------------------------------------------------------------

fn glossary() -> String {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../GLOSSARY.md");
    fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()))
}

#[test]
fn glossary_has_the_attachments_section_right_after_backups_with_the_exact_entry() {
    let g = glossary();
    let headings: Vec<&str> = g.lines().filter(|l| l.starts_with("## ")).collect();
    let backups = headings
        .iter()
        .position(|h| *h == "## Backups (#315)")
        .expect("## Backups (#315)");
    assert_eq!(
        headings.get(backups + 1).copied(),
        Some("## Attachments (#121)"),
        "the section right after Backups"
    );
    let entry = "## Attachments (#121)\n\n\
        **Attachment**:\n\
        A file copied into a vault's `objects/` folder, stored once per content, and referenced from a note body by a markdown image or link whose target is its vault-relative path.\n\
        _Avoid_: asset, media, embed (images are not transclusions), upload\n";
    assert!(g.contains(entry), "the exact Attachments entry");
    assert_eq!(
        g.matches("## Attachments (#121)").count(),
        1,
        "one Attachments section"
    );
    // The section ends before the next heading (one blank line).
    let after = &g[g.find(entry).unwrap() + entry.len()..];
    assert!(
        after.starts_with("\n## "),
        "only the one entry in the section"
    );
}

#[test]
fn glossary_last_five_headings_are_unchanged() {
    let g = glossary();
    let headings: Vec<&str> = g.lines().filter(|l| l.starts_with("## ")).collect();
    assert_eq!(
        &headings[headings.len() - 5..],
        [
            "## Navigation (#230)",
            "## Outline (#54)",
            "## Command palette (#56)",
            "## Find in note (#55)",
            "## Releases (#356)",
        ]
    );
}
