# HWP distribution permissions

The WebView uses this read-only helper on HWP5 compound files. It reads the `FileHeader` and the start of each distribution `ViewText/SectionN` stream from the bytes already passed to rhwp. It does not decrypt the section body or rewrite the document. The two result bits independently disable text selection/copy and PDF printing. An unreadable compound header or option record disables both capabilities.

The helper uses [`cfb` 0.16.0](https://crates.io/crates/cfb/0.16.0), the same CFB crate used by the bundled rhwp 0.9.0 source at `c9095c5f67632e6721e800ccc7fb43ea49d26682`, which pins 0.15.0. The HWP5 header and distribution options follow the [Hancom HWP format specifications](https://www2.hancom.com/support/downloadCenter/hwpOwpml). Dependency versions and checksums are pinned in `Cargo.lock`. See `THIRD_PARTY_NOTICES.txt` for license notices.

From the repository root, use Rust 1.93.1 with the `wasm32-unknown-unknown` target and `wasm-bindgen-cli` 0.2.127.

```sh
CARGO_TARGET_DIR=build/hwp-policy cargo +1.93.1 build --manifest-path tools/hwp-policy/Cargo.toml --target wasm32-unknown-unknown --release --locked
wasm-bindgen --target web --no-typescript --out-dir assets/js --out-name hwp_policy build/hwp-policy/wasm32-unknown-unknown/release/hwp_distribution_policy.wasm
CARGO_TARGET_DIR=build/hwp-policy cargo +1.93.1 test --manifest-path tools/hwp-policy/Cargo.toml --locked
```
