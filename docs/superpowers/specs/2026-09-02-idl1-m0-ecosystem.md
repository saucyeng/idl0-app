# idl1 M0 — Ecosystem Verification Report

Compiled 2026-09-02. "Latest stable" = newest non-prerelease release on crates.io / npm,
verified directly against the crates.io API (`https://crates.io/api/v1/crates/<name>`) and
the npm registry API (`https://registry.npmjs.org/<name>`) — the same source `cargo add` /
`npm install` resolve against — plus targeted web research for the five findings below.

## 1. Versions

| name | registry | latest stable | released | license | pin | source URL |
| --- | --- | --- | --- | --- | --- | --- |
| tauri | crates.io | 2.11.5 | 2026-07-01 | Apache-2.0 OR MIT | `2.11.5` | https://crates.io/crates/tauri/2.11.5 |
| tauri-build | crates.io | 2.6.3 | 2026-06-17 | Apache-2.0 OR MIT | `2.6.3` | https://crates.io/crates/tauri-build/2.6.3 |
| tauri-plugin-shell | crates.io | 2.3.6 | 2026-08-31 | Apache-2.0 OR MIT | `2.3.6` | https://crates.io/crates/tauri-plugin-shell/2.3.6 |
| @tauri-apps/cli | npm | 2.11.4 | 2026-06-28 | Apache-2.0 OR MIT | `^2.11.4` | https://www.npmjs.com/package/@tauri-apps/cli/v/2.11.4 |
| @tauri-apps/api | npm | 2.11.1 | 2026-06-17 | Apache-2.0 OR MIT | `^2.11.1` | https://www.npmjs.com/package/@tauri-apps/api/v/2.11.1 |
| create-tauri-app | npm | 4.6.2 | 2025-08-05 | Apache-2.0 OR MIT | `^4.6.2` | https://www.npmjs.com/package/create-tauri-app/v/4.6.2 |
| btleplug | crates.io | 0.13.0 | 2026-08-31 | MIT/Apache-2.0/BSD-3-Clause | `0.13.0` | https://crates.io/crates/btleplug/0.13.0 |
| mdns-sd | crates.io | 0.21.1 | 2026-08-31 | Apache-2.0 OR MIT | `0.21.1` | https://crates.io/crates/mdns-sd/0.21.1 |
| axum | crates.io | 0.8.9 | 2026-04-14 | MIT | `0.8.9` | https://crates.io/crates/axum/0.8.9 |
| tokio | crates.io | 1.53.1 | 2026-07-20 | MIT | `1.53.1` | https://crates.io/crates/tokio/1.53.1 |
| arrow | crates.io | 59.3.0 | 2026-09-01 | Apache-2.0 | `59.3.0` | https://crates.io/crates/arrow/59.3.0 |
| parquet | crates.io | 59.3.0 | 2026-09-01 | Apache-2.0 | `59.3.0` | https://crates.io/crates/parquet/59.3.0 |
| rusqlite | crates.io | 0.40.2 | 2026-08-08 | MIT | `0.40.2` | https://crates.io/crates/rusqlite/0.40.2 |
| fitparser | crates.io | 0.11.0 | 2026-05-01 | MIT | `0.11.0` | https://crates.io/crates/fitparser/0.11.0 |
| pulldown-cmark | crates.io | 0.13.4 | 2026-05-20 | MIT | `0.13.4` | https://crates.io/crates/pulldown-cmark/0.13.4 |
| notify | crates.io | 8.2.0 | 2025-08-03 | CC0-1.0 | `8.2.0` | https://crates.io/crates/notify/8.2.0 |
| serde | crates.io | 1.0.229 | 2026-07-18 | MIT OR Apache-2.0 | `1.0.229` | https://crates.io/crates/serde/1.0.229 |
| serde_json | crates.io | 1.0.151 | 2026-07-20 | MIT OR Apache-2.0 | `1.0.151` | https://crates.io/crates/serde_json/1.0.151 |
| thiserror | crates.io | 2.0.20 | 2026-08-08 | MIT OR Apache-2.0 | `2.0.20` | https://crates.io/crates/thiserror/2.0.20 |
| @observablehq/runtime | npm | 6.0.0 | 2024-11-06 | ISC | `^6.0.0` | https://www.npmjs.com/package/@observablehq/runtime/v/6.0.0 |
| @observablehq/plot | npm | 0.6.17 | 2025-02-14 | ISC | `^0.6.17` | https://www.npmjs.com/package/@observablehq/plot/v/0.6.17 |
| @observablehq/inputs | npm | 0.12.0 | 2024-08-27 | ISC | `^0.12.0` | https://www.npmjs.com/package/@observablehq/inputs/v/0.12.0 |
| d3 | npm | 7.9.0 | 2024-03-12 | ISC | `^7.9.0` | https://www.npmjs.com/package/d3/v/7.9.0 |
| codemirror | npm | 6.0.2 | 2025-06-19 | MIT | `^6.0.2` | https://www.npmjs.com/package/codemirror/v/6.0.2 |
| @codemirror/lang-javascript | npm | 6.2.5 | 2026-03-02 | MIT | `^6.2.5` | https://www.npmjs.com/package/@codemirror/lang-javascript/v/6.2.5 |
| @codemirror/lang-markdown | npm | 6.5.2 | 2026-08-04 | MIT | `^6.5.2` | https://www.npmjs.com/package/@codemirror/lang-markdown/v/6.5.2 |
| react | npm | 19.2.8 | 2026-07-21 | MIT | `^19.2.8` | https://www.npmjs.com/package/react/v/19.2.8 |
| react-dom | npm | 19.2.8 | 2026-07-21 | MIT | `^19.2.8` | https://www.npmjs.com/package/react-dom/v/19.2.8 |
| vite | npm | 8.2.2 | 2026-08-20 | MIT | `^8.2.2` | https://www.npmjs.com/package/vite/v/8.2.2 |
| @vitejs/plugin-react | npm | 6.1.1 | 2026-08-28 | MIT | `^6.1.1` | https://www.npmjs.com/package/@vitejs/plugin-react/v/6.1.1 |
| vitest | npm | 4.1.11 | 2026-08-18 | MIT | `^4.1.11` | https://www.npmjs.com/package/vitest/v/4.1.11 |
| typescript | npm | 7.0.2 | 2026-07-08 | Apache-2.0 | `^7.0.2` | https://www.npmjs.com/package/typescript/v/7.0.2 |

Note: `typescript` 7.0.x is the native (Go-ported "tsgo") rewrite line, now `dist-tags.latest`
on the npm registry as of this check — a major-version jump from the 5.x line current at the
controller's January-2026 knowledge cutoff. Verified directly against the registry, not
assumed; flagged here since it is the row most likely to surprise a reader.

## 2. Findings

1. **Tauri v2 mobile IPC (`tauri::ipc::Response`) as ArrayBuffer, no base64/JSON — Partial (yes by architecture, not explicitly documented for mobile).**
   Tauri's docs confirm `tauri::ipc::Response::new(Vec<u8>)` exists precisely to bypass JSON
   serialization for large payloads, decoded frontend-side as raw bytes
   (https://v2.tauri.app/develop/calling-rust/). Since the v2 IPC refactor (tauri-apps/tauri
   discussion around issue #7662, "the new ipc:// fetch-based approach"), all platforms —
   desktop and mobile — route IPC through the same `ipc://` custom-protocol fetch, which wry
   implements per-platform (`WKURLSchemeHandler` on iOS/macOS, `shouldInterceptRequest`/
   `WebResourceResponse` on Android: https://github.com/tauri-apps/wry/issues/1710,
   https://deepwiki.com/tauri-apps/tauri/4.4-custom-protocol-handlers) and which is also used
   to stream arbitrary binary media with HTTP Range support on mobile — evidence the channel
   carries raw bytes untouched on Android/iOS, not just desktop. No official doc or GitHub
   issue was found stating raw-byte responses are downgraded to base64/JSON on mobile, and no
   bug report describes `ipc::Response` behaving differently there; the mobile IPC bugs found
   (#7656, #7662, #6105) are about the URI-scheme refactor breaking IPC generally in the
   2.0.0-alpha era, not about byte-encoding fidelity. I could not find an explicit
   official statement of "identical to desktop" for this exact API on mobile — verdict is
   inferred from shared architecture plus absence of contrary evidence, not a direct citation
   confirming it.

2. **Sandboxed `<iframe sandbox="allow-scripts">` (no allow-same-origin) + `postMessage` with a transferable `ArrayBuffer`, in WKWebView (iOS) and Android System WebView — Yes.**
   Per the WHATWG HTML spec, a sandboxed iframe without `allow-same-origin` gets an opaque
   origin; `postMessage` is spec-designed for exactly this case and works provided the caller
   uses `targetOrigin: "*"` (an opaque origin can never match a literal origin string). A
   worked example confirms this pattern in production:
   https://joshua.hu/rendering-sandboxing-arbitrary-html-content-iframe-interacting ("Since
   postMessage is literally intended for cross-origin communication, we are able to create a
   communication channel from the parent to the iframe, while the iframe is sandboxed
   cross-origin," with the caveat "you have to use postMessage with receiver set to `*`").
   `postMessage`'s structured-clone algorithm has supported `Transferable` objects including
   `ArrayBuffer` since early WebKit and Chromium implementations
   (https://developer.mozilla.org/en-US/docs/Web/API/Window/postMessage) — both WKWebView
   (WebKit) and Android System WebView (Chromium) are evergreen, spec-compliant engines with
   no special carve-out for sandboxed frames on this API. No WKWebView- or Android
   WebView-specific bug blocking transferable-`ArrayBuffer` `postMessage` from a
   `sandbox="allow-scripts"` frame was found; the only failures surfaced in search results are
   developer misconfiguration (a literal `targetOrigin` instead of `"*"`, or direct
   `contentWindow` property access, which is a same-origin-policy issue unrelated to
   `postMessage`). Caveat: no dedicated mobile-WebView test report or Apple/Google doc names
   this exact combination explicitly; verdict rests on general spec compliance plus absence of
   contrary evidence, not a mobile-specific test citation.

3. **btleplug platform support matrix — Yes, documented and current.**
   Source: https://github.com/deviceplug/btleplug (README) and
   https://crates.io/crates/btleplug/0.13.0. Device discovery, GATT operations,
   characteristic read/write, and notifications are all supported on Windows 10+, macOS,
   Linux (BlueZ), iOS, and Android. iOS "should 'just work'... and seems to be stable" — it
   shares its CoreBluetooth-based implementation with macOS and needs only
   `NSBluetoothAlwaysUsageDescription` in `Info.plist`. Android needs a "somewhat complicated"
   hybrid Rust/Java (JNI) build, minimum API level 24 (Android 7.0), and Proguard/R8 keep
   rules when minifying. The crate is actively maintained: 0.13.0 was published 2026-08-31,
   one day before this report.

4. **Tauri v2 mobile BLE plugins — Yes, one actively-maintained option covers scan/connect/GATT read/write/notify on both Android and iOS.**
   `tauri-plugin-blec` (https://github.com/MnlPhlp/tauri-plugin-blec,
   https://crates.io/crates/tauri-plugin-blec) wraps `btleplug` directly for Windows, macOS,
   Linux, and iOS (no dedicated `ios/` folder in the repo — iOS goes through the same
   btleplug/CoreBluetooth path as desktop, confirmed via its `Cargo.toml` iOS build target and
   README's iOS `Info.plist`/CoreBluetooth setup steps); Android gets a dedicated Tauri
   plugin (`android/` directory, JNI shim) to avoid hand-rolling JNI bindings. Its JS API
   (`guest-js/index.ts`, read directly from the repo) exports `startScan`, `stopScan`,
   `checkPermissions`, `getAdapterState`, `getScanningUpdates`, `connect`, `disconnect`,
   `getConnectionUpdates`, `read`, `readString`, `send`, `sendString`, `subscribe`,
   `subscribeString`, `unsubscribe`, `listServices`, `getMtu`, `setAndroidMtu` — covering
   scan, connect, and GATT read/write/notify. Dual MIT/Apache-2.0. Actively maintained:
   crates.io shows 0.12.0 last published 2026-06-08. An alternative,
   `tauri-plugin-bluetooth` (26F-Studio,
   https://crates.io/crates/tauri-plugin-bluetooth), exists but looks abandoned: crates.io
   shows 0.1.1 last published 2025-02-19 (over a year stale as of this report), and its
   GitHub repo (github.com/26F-Studio/tauri-plugin-bluetooth) now 404s. Recommendation:
   `tauri-plugin-blec`.

5. **`parquet` crate: column projection, row-group statistics pushdown, `DELTA_BINARY_PACKED` for INT64 — Yes, all three confirmed.**
   Column projection: `ArrowReaderBuilder::with_projection` — "Only read data from the
   provided column indexes"
   (https://docs.rs/parquet/59.3.0/parquet/arrow/arrow_reader/struct.ArrowReaderBuilder.html).
   Row-group statistics filtering / predicate pushdown on min/max: confirmed by the official
   Apache Arrow blog — "the parquet crate ... supports predicate pushdown in the form of row
   group pruning, that is using statistics to skip reading entire row groups... The Parquet
   reader can look at the row group statistics, compare the predicate against min/max values"
   (https://arrow.apache.org/blog/2022/12/26/querying-parquet-with-millisecond-latency/), with
   `ColumnChunkMetaData::statistics() -> Option<&Statistics>` exposing the per-column min/max
   and `with_row_groups`/`with_row_selection`/`with_row_filter` to act on it (the crate also
   supports finer page-index-level pruning, beyond what was asked).
   `DELTA_BINARY_PACKED`: `parquet::basic::Encoding::DELTA_BINARY_PACKED` is documented as
   "Delta encoding for integers, either INT32 or INT64. Works best on sorted data."
   (https://arrow.apache.org/rust/parquet/basic/enum.Encoding.html), and it is not just
   declared but implemented — a vectorized decoder ships for it
   (https://github.com/apache/arrow-rs/pull/1284, "Vectorize DeltaBitPackDecoder, up to 5x
   faster decoding," benchmarked against both `Int32Type` and `Int64Type`).
