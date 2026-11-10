# onnxruntime notices

memex links ONNX Runtime 1.24.2 statically. `ort` 2.0.0-rc.12 (through
`ort-sys` 2.0.0-rc.12, see `Cargo.lock`) downloads pyke's prebuilt
`libonnxruntime.a`, built from onnxruntime v1.24.2 (`ms@1.24.2` in ort-sys's
`build/download/dist.txt`). It is not a crate, so `cargo metadata` does not
list it, and `scripts/release/notices.sh` copies these files into
`THIRD_PARTY_NOTICES.txt`.

- `LICENSE`: https://github.com/microsoft/onnxruntime/blob/v1.24.2/LICENSE
- `ThirdPartyNotices.txt`: https://github.com/microsoft/onnxruntime/blob/v1.24.2/ThirdPartyNotices.txt

Both are copied verbatim from the `v1.24.2` tag. When `ort` moves to another
onnxruntime release, replace both files from that release's tag and update
the version here.
