# IDL0 Design Rationale

Decisions made and why. Read this for context; read IDL0_SPEC.md to build.

---

## Hardware

**SPI over I2C for remote IMUs**
I2C with a PCA9548A multiplexer was the first prototype. Reliability over ~2-foot cable runs was poor. SPI with individual CS lines is unconditionally more reliable at those distances.

**LSM6DSO32 over BMI160**
BMI160 at ±16g saturated during aggressive riding (large drops, rough terrain). LSM6DSO32 at ±32g captures the full impact dynamics. Same SPI interface, straightforward swap.

**4-layer PCB over 2-layer**
Negligible cost difference at Seeed Fusion. Dedicated ground and power planes on inner layers improve signal integrity and simplify routing, particularly for the RF section.

**Deutsch DTM connector**
Automotive-grade, IP67, vibration-resistant. Appropriate for a device mounted to a bike in mud and rain. Suffix letters (A/B/C/D) indicate mechanical keying position only — not electrical differences.

**Integrated ceramic patch GPS antenna**
Cleaner system than external U.FL/SMA. Requires 50mm ground plane and 50Ω impedance RF trace. Trade-off: fixed orientation sensitivity vs. external antenna flexibility. Acceptable for a device mounted to the bike frame.

---

## Firmware

**Zero processing in firmware**
Every clock cycle spent computing in firmware is a clock cycle not writing data. The ESP32-C6 is fast enough for the write path but adding DSP would require careful timing management and could cause dropped samples. All computation deferred to the app where resources are abundant.

**Variable-stride binary records**
Fixed-width records with zero-fill was considered. Variable stride chosen because: at IDL0's data rates (~155 MB/hr peak) the I/O efficiency difference is small but non-zero, the flexibility for disabled channels is real, and the parser complexity is modest (channel mask read once from header, record size computed once per session load). GPS and wheel pulse records are inherently variable anyway — consistency across the format is worth something.

**GPS time anchor via NMEA body**
The filename rename approach (prototype) is fragile — files get renamed by users. The body-based approach (parse first valid RMC sentence, correlate boot-relative timestamp with UTC) is robust to renaming and copying. Note: the firmware's GPS packet `timestamp_ms` comment is wrong — it's milliseconds since boot, not UTC.

---

## App Architecture

**Flutter over React Native**
React Native's JavaScript bridge adds overhead for continuous sensor data display. Flutter compiles Dart to native ARM, renders its own pixels, no bridge. For a data analysis tool doing continuous chart updates from 800Hz data, this matters. Single codebase also serves the primary requirement: one developer, multiple platforms.

**Rust processing layer**
Goal: scipy-equivalent math functions available to users through the math channel editor, on every platform including mobile, with no separate runtime. Python fails on mobile. C++ has better libraries (Eigen, FFTW) but cross-compilation for Android + iOS + desktop simultaneously is a build system problem. Rust with sci-rs satisfies all requirements: native compilation everywhere Flutter targets, scipy-compatible function names so users can apply documentation they find online, `flutter_rust_bridge` handles FFI generation automatically.

**flutter_rust_bridge over manual FFI**
Manual dart:ffi requires writing C headers, managing memory manually, and maintaining bindings by hand. flutter_rust_bridge generates all of this from Rust function signatures. Official Flutter Favorite package, v2.12 at time of writing.

**sci-rs over implementing DSP from scratch**
The processing layer tests should verify correct usage of the library, not reimplementation of biquad coefficients. sci-rs is validated against scipy. The test burden becomes "did I call butter_dyn with the right parameters" not "does my filter converge to zero on DC input."

**Riverpod over Provider/Bloc**
Provider is older and gets messy at this complexity level. Bloc is verbose for a single-developer project. Riverpod's `FutureProvider.family` maps cleanly onto lazy math channel evaluation (compute per session/channel pair on demand), and `AsyncValue` handles the loading/error/data states that file parsing and WiFi transfer need.

**Two-file model (.idl0 + .idl0w)**
Log file is immutable — it's the raw data. All derived work (workspace layout, lap gates, annotations, math channels) lives in the workspace file. This means:
- Log file can never be corrupted through normal app use
- Workspace is shareable: send `.idl0w` to a coach, they load it against their copy of the `.idl0`
- Sync is clean: only the small workspace file changes frequently, not the large log file

**Variable stride chosen over fixed-width records**
See Firmware section above. The parser argument applies symmetrically — modest complexity for real flexibility.

---

## Analysis

**Distance X axis always available**
Even for single-rider analysis, a distance-based X axis is useful when looking at suspension behavior vs. track position rather than vs. time. Distance from wheel speed is high-resolution but corrupted by slip. Distance from GPS is accurate but 5 Hz resolution (~2.2m at race pace). Both have appropriate use cases. Time is still the default.

**Cross-rider comparison: time-from-gate as default, not distance**
i2pro defaults to distance, which makes sense for circuit racing where lines are consistent. Mountain bike has variable lines, frequent braking, loose surfaces. Time-from-gate with phase-shift reading is the preferred method for experienced MTB data engineers. Distance available when useful.

**GPS time anchor over filename for session timestamps**
See Firmware section. The in-body approach is authoritative and rename-resistant.

**Suspension travel requires double integration**
The IMUs measure acceleration. Velocity = ∫acceleration dt.
Position (travel) = ∬acceleration dt — two sequential
integration steps. Each stage accumulates drift, so two
separate high-pass filter passes are required: one before
the first integration (removes DC bias), one between the
two integrations (suppresses drift from first stage before
it compounds through the second). Conservative cutoffs
(0.15–0.3 Hz) perform better than aggressive (>0.5 Hz)
because suspension dynamics occur in the 1–20 Hz range.
The shipped template `integrate(integrate([IMU1_AccelZ]))`
is a starting point. For long sessions, wrap each stage
explicitly with `butter()` calls.

---

## Distribution

**iOS via PWA not native app**
Apple Developer account ($99/yr) + App Store review + notarization for every release. For a v1 product targeting a niche market, this overhead is not justified. PWA via Chrome or Safari gives iPhone users the full analysis experience (everything except BLE device connection). The primary field tool is Android.

**macOS notarization required**
Apple requires all apps distributed outside the Mac App Store to be scanned and signed by Apple's servers. One-time setup, ~5 minute automated process per release via `xcrun notarytool`. Not a legal document.

**MIT over Apache 2.0**
The system is not complex enough to warrant patent concerns. MIT is more widely understood and has fewer requirements. No meaningful benefit from Apache's patent grant for this project.

---

## Processing Layer (Rust)

**One-sided FFT spectrum**
Input is always real-valued. The two-sided spectrum is conjugate-symmetric and redundant. Returning `n/2 + 1` bins halves the output size, matches `numpy.fft.rfft` semantics, and is what the Analyze tab consumes. Full complex output would only be useful if Hilbert transform or cross-correlation were implemented in the same call — they aren't.

**FFT takes no `sample_rate_hz` parameter**
The `fft(ch, window)` math channel expression spec (§10) does not include sample rate. The Rust `fft(data, window)` function matches this — it returns bin indices 0..n/2, not frequencies in Hz. Caller computes `freq[k] = k × fs / n`. This keeps the Rust function pure (no sample-rate dependency) but means the Analyze tab must pass sample rate separately when building the frequency axis.

**`compute_bias` input: `Vec<Vec<f64>>` → Dart `List<Float64List>`**
A flat `Vec<f64>` + stride would be more FRB-efficient. Nested `Vec<Vec<f64>>` was chosen because each element is a semantically complete 6-channel sample `[ax, ay, az, gx, gy, gz]` — the structure matches the logical layout of the data. The Dart ergonomics cost (`Float64List.fromList([...])` per sample rather than `[...]`) is real but modest; calibration runs once at setup, not in a hot loop.

**One shared `stft()` primitive for `welch()` and `spectrogram()`**
A duplicate spectral path (or a third-party STFT crate) was the obvious alternative. One primitive was chosen for two reasons: (1) physical consistency — because both charts derive from the same frames, a peak at 12 Hz in the spectrogram reads identically to 12 Hz in the Welch spectrum, with no numerical drift; (2) DRY — windowing, detrending, and segmentation are non-trivial; one implementation means one bug surface, one set of tests. The `stft()` function returns complex frames so future work (transfer functions, coherence, Hilbert transform) is a thin consumer on top of the same primitive, not a new spectral stack.

**`realfft` over `rustfft` for real-valued input**
All IDL0 channels are real-valued. A full complex FFT wastes the always-zero imaginary input and computes the conjugate-symmetric negative-frequency half redundantly. `realfft` exploits real symmetry to compute only the `n/2 + 1` non-redundant bins — approximately 2× faster and half the memory. The only cost is a test-tolerance relaxation (from exact equality to 1e-9 numeric equivalence) because `realfft`'s internal butterfly ordering differs slightly from `rustfft`; the physical output is equivalent.

**Antiparallel degenerate case in `rotation_from_gravity`: 180° about vehicle X**
`Rotation3::rotation_between` returns `None` when the two vectors are exactly antiparallel (sensor Z pointing straight down — sensor mounted fully upside-down). nalgebra gives no canonical rotation in this case. The fallback is 180° about vehicle X (forward axis): this physically inverts the Z axis while preserving left/right symmetry, which is the natural correction for an upside-down sensor. Identity matrix would silently produce wrong results; returning an error would break calibration with no recovery path.

---

## Data Layer

**`Session.bikeProfileSnapshot` stored as a JSON string, not a `BikeProfile?` object**
Profile edits made after a session is downloaded must not silently mutate the historical record of what the bike was configured as at recording time. Storing the snapshot as an opaque JSON string freezes it at download time regardless of subsequent profile changes. The cost: callers must call `.bikeProfile` to deserialize it on every access. The alternative — a live `BikeProfile?` reference — would require care to avoid aliasing the mutable profile store.

**`Session.configChecksum` typed as `String`, not `int`**
The binary format (§5.1) encodes CRC32 as a `u32`. `String` was chosen to avoid committing to hex/decimal representation before the binary parser is integrated. Once the parser lands, if the checksum is only compared for equality (not displayed), `int` is cleaner and should be considered.

**Gate crossing: first crossing of a sector gate per lap wins**
If the GPS track crosses a sector gate multiple times within one lap (e.g., the rider reverses direction), only the first crossing is used. "Last crossing" would handle interrupted runs better but is harder to reason about. "All crossings" would require a new sector model. First-wins is deterministic and correct for all normal cases.

**Gate crossing: silently skip sector gates that are never crossed**
If a sector gate placed on the map is not crossed by the GPS track (gate off the racing line, GPS outage, different route), the sector is omitted from the lap rather than aborting detection or returning an error. This matches the "recover what's readable" principle. There is currently no user-facing warning when a placed sector gate produces no split — adding one is a future improvement.

**Gate crossing: half-open interval `u ∈ (0, 1]` for track parameter**
The track segment parameter `u` uses a half-open interval to avoid double-counting when the GPS track passes exactly through the gate point at a GPS fix. With a closed interval `[0, 1]`, both the arriving segment (u=1) and the departing segment (u=0) detect the same crossing. With `u ∈ (0, 1]`, only the arriving segment counts it. This matters for test determinism; in real GPS data (3–5 m resolution) exact endpoint coincidence is unlikely.

**`MathChannel.sampleRateHz = 0` means "inherit from source channel at eval time"**
Storing `0` as a sentinel avoids requiring the user to specify a rate before the expression is validated — rate is not known until the source channel is resolved. Any code evaluating a math channel must handle `sampleRateHz == 0` by looking up the primary source channel's rate. The alternative (mandatory explicit rate) would couple the metadata bar to expression validation order.

**`ComponentLayout` uses normalized 0.0–1.0 coordinates, not pixels or a fixed grid**
Normalized coordinates are device-independent — the same layout file renders correctly on a 1080p phone and a 4K desktop without any stored resolution dependency. The cost is that the drag-resize UI must convert between pixel and normalized coordinates on every interaction. The alternative (a discrete column/row grid) simplifies snap-to-grid but requires committing to a grid resolution before the drag-resize UI is designed.

**`ComponentLayout.type` stored as an open string, not a `ComponentType` enum**
An open string survives forward migrations: a workspace created by a future app version with new component types loads cleanly in older app versions (unknown types skipped or shown as placeholders). A closed enum gives compile-time exhaustiveness checking but breaks loading on schema extension. Given that the component set is explicitly noted as incomplete (§14.1, drag-resize deferred), open string is the lower-risk choice.

**Atomic workspace write via `.tmp` sibling + rename**
`Workspace.save()` writes to `path.tmp` then renames, rather than writing directly to the target path, to prevent a partially-written workspace from being read as valid on crash or power loss. On Android, `File.rename` requires source and destination to be on the same filesystem partition. The `.tmp` sibling is in the same directory as the workspace file, so this holds for all app-private storage. Verify if the workspace directory is ever on a removable SD card.

**`BinaryParser` returns `ParseResult`, not a bare `Session`**
A `ParseResult` wrapper was added to carry both the (possibly partial) `Session` and an optional `TruncatedRecordException`. The alternative — embedding partial data inside the thrown exception — would require callers to use exception handling as control flow for a routine success case (partial files are expected for interrupted sessions). The alternative — throwing and discarding parsed data — would lose valid data silently. `ParseResult` lets callers always receive a `Session` object regardless of truncation while preserving the exception details for surfacing to the UI.

**v1 NMEA: checksum not validated**
Each v1 GPS record contains a single NMEA sentence whose trailing `*XX` checksum is stripped but not XOR-verified. The firmware always writes correct checksums. Validating would require re-scanning the sentence bytes, adds a failure mode that would discard GPS records (breaking time reconstruction), and provides no benefit over verifying the file's completeness via `payload_len`. If corrupted-in-transit GPS records become a real problem (WiFi transfer without checksumming), add NMEA checksum validation at that point.

**`UnsupportedWorkspaceVersionException` placed under `ParseException`**
This exception is thrown during file loading, which made `ParseException` the closest semantic fit in the §16.1 hierarchy. An alternative is a direct `IdlException` subclass or a new `WorkspaceException` abstract class. If workspace version errors need to be caught separately from binary parse errors at call sites, promoting it to its own branch is worthwhile.

---

## Transport Layer

**Two download methods on `WifiTransfer`: `downloadFile` and `downloadFileTo`**
`downloadFile` buffers the entire file in memory (`Uint8List`). At ~155 MB/hr peak, a single session file can be tens to hundreds of megabytes — too large to hold in memory reliably on Android. `downloadFileTo` streams directly to disk in chunks, so peak RAM usage is one chunk regardless of file size. `downloadFile` exists as a convenience for tests and small reads where memory cost is acceptable. In production the UI should always call `downloadFileTo`.

**Progress callback: `(int received, int total)` with `total = -1` for unknown size**
`-1` is the sentinel for "device did not send `Content-Length`." The alternative — a `DownloadProgress` record type — was considered but rejected: it adds a type for a two-field value that is consumed in one place (the download panel). A nullable `int?` for total was also considered; `-1` was preferred because Dart UI code reads more clearly as `total > 0 ? received / total : null` than a double-null-check. If the spec ever standardises the firmware response headers, this sentinel can be dropped.

**`TransferTimeoutException` for non-200 HTTP status on `/download`**
The §16.1 hierarchy has no exception type that cleanly maps to "device responded but with an error code." `TransferTimeoutException` was the closest fit because the §16.2 behavior (retry with backoff) is what the caller should do in both cases. The mismatch is acknowledged: a 404 (file not found) is not a timeout, and if the firmware ever returns distinct error codes, a dedicated `FileNotFoundException` should be added and this mapping revisited.

**Device reports `session_id` in `/files`, rather than the app inferring identity**
To show NEW vs in-library and to sync only missing files, the Sync screen must know each device file's identity. The library is keyed by the 16-byte header UUID, but the device-side filename (`session_NNN.idl0`) has no relation to it. Three options: (1) the device reports `session_id` in the `/files` listing; (2) the app reads each file's header over an HTTP Range request; (3) the app keeps a local ledger of filenames it has downloaded. Option 1 was chosen because it is exact and — unlike the local ledger — correctly recognises sessions that entered the library via Drive sync on another phone. It is also cheap: the firmware already holds the UUID it wrote into each header. The header-peek (option 2) needs Range support and N extra round-trips; the ledger (option 3) is the only zero-firmware option but is blind to multi-device libraries. The firmware change is small and rides the `/files` JSON contract that already existed.

**The download queue is sequential by design, not by limitation**
The ESP32 serves one HTTP request at a time on its AP, and the app builds a fresh `http.Client` per download. Rather than work around this, the Sync queue embraces it: files download strictly one at a time. This keeps the device, the on-disk write path, and the progress UI simple and race-free, and a single-socket transfer saturates the link anyway. Parallelism would add concurrency hazards (interleaved writes, racing progress state) for no throughput gain. If a future firmware revision ever supports concurrent connections, the queue can be widened, but there is no reason to today.

**`BleConnection.statusStream` is a broadcast stream**
A single-subscription stream would be simpler but only one listener could receive status updates. The Device tab and potentially a persistent status bar both need to subscribe independently. `StreamController.broadcast()` allows this. The tradeoff: broadcast streams silently drop events when there are no listeners (before the first `listen` call). Callers should subscribe before calling `connect()` to avoid missing the initial status read emitted at connection time.

**`sessionIndexLoaderProvider` does not close the `SessionIndex` it opens**
The provider opens a `SessionIndex`, reads all sessions, then discards the reference without calling `close()`. The underlying sqflite database stays open in the connection pool. This follows the pattern of the pre-existing `sessionIndexProvider` in `runs_provider.dart`. In contrast, `RunsNotifier.importFiles()` calls `index.close()` explicitly. The inconsistency is known; the working assumption is that sqflite tolerates multiple open handles to the same file. If resource exhaustion or file-lock issues arise, `sessionIndexLoaderProvider` should reuse `sessionIndexProvider` or call `close()` after reading.

**`SessionIndex` has no `onUpgrade` migration handler**
`openDatabase` is called with `version: 1` and only `onCreate`. The first schema change will require adding an `onUpgrade` callback. The index is a cache — in the worst case, migration can drop and recreate the table and `rebuildFromSessions` repopulates it from the files. This is the intended fallback strategy: log a warning, wipe the index, let the next folder scan restore it. Worth noting this explicitly when `onUpgrade` is first needed.

---

## UI Layer — Providers

**`loadSessions()` replaces the full list, not merges**
`SessionNotifier.loadSessions()` replaces `state.sessions` entirely rather than merging by UUID. `sessionIndexLoaderProvider` is the authoritative source at startup. All post-load writes go through `addSession()` and never race with the loader on the same event loop turn — `RunsTab` must be built (triggering the load) before the user can trigger an import. A merge would require UUID-based deduplication that is only needed if `loadSessions()` could ever be called after `addSession()` has already run, which the architecture does not permit.

**`ref.read` rather than `ref.watch` in `channelDataProvider`**
`channelDataProvider` uses `ref.read(sessionProvider)` to look up the session file path, not `ref.watch`. Since `.idl0` files are immutable after download (§9.4), re-parsing on every session-list change would produce identical results and waste the parse. `ref.watch` would also mean adding any session to the library — even one unrelated to the chart being viewed — invalidates every channel cache in the app simultaneously.

---

## UI Layer — Analyze Tab

**X axis fallback does not revert `workspaceProvider` state**
When wheel or GPS data is absent and the chart falls back to time-axis display, `WorkspaceNotifier.setXAxisMode` is not called to write `time` back to the provider. Mutating state inside a widget build path would be a side effect that triggers a rebuild, potentially causing an infinite loop. More importantly, leaving the requested mode in the provider means the chart automatically switches to the correct mode when the required channel is loaded, with no user action. The cost is that `XAxisSelector` shows "Wheel" or "GPS" while the chart shows time — the warning banner is the signal that the two are temporarily out of step.

**Cursor readout uses nearest-spot, not interpolation**
`TimeSeriesChart._nearestSpotAtX` returns the plotted `FlSpot` whose x is closest to the cursor — no linear interpolation between samples. fl_chart's tooltip then formats that spot's y via `formatChannelValue` (3 significant figures, magnitude-aware decimals). Interpolation would add a tiny accuracy gain (at 800 Hz the worst-case error between nearest and interpolated y is one sample interval × local slope), but the formatter's sig-fig rounding masks the difference at every magnitude band the cursor is ever read at on screen. Revisit only if a use case surfaces where the user is reading values to higher precision than `formatChannelValue` exposes.

**`TabController` rebuilt synchronously in `WorkbookBar.build()`, with `TickerProviderStateMixin` (not `Single`)**
The `_tabController` is disposed and recreated inside `build()` when `worksheets.length` changes. `TickerProviderStateMixin` is required — not `SingleTickerProviderStateMixin`. The distinction: `Single` stores the first created ticker in a `_ticker` field and never clears it. After `TabController.dispose()` the ticker object is disposed but `_ticker` is still non-null, so any subsequent `createTicker` call throws `"multiple tickers were created"` — even with only one ticker alive at a time. `TickerProviderStateMixin` has no such constraint and is the correct choice whenever a ticker may be created, disposed, and recreated over a single State lifetime. Regression test: `test/ui/workbook_bar_test.dart` verifies that tapping "+" twice rebuilds the `TabController` cleanly.

**Empty state in `ChartWorkspace` hides `XAxisSelector`**
When no sessions are selected, the entire `ChartWorkspace` body is replaced by a centered message — including the `XAxisSelector`. The alternative is to show the selector above an empty chart area. The selector has no useful function without channel data: switching between time/wheel-speed/GPS axes is only meaningful when samples are present to rescale. Showing it without data would invite interaction with a control that has no effect.

**`cursorProvider` keyed by stable worksheet UUID — FIXED**
Originally keyed by integer index. The bug: `cursorProvider(0)` for workbook A and `cursorProvider(0)` for workbook B were the same provider instance — switching workbooks without clearing the cursor leaked position across workbooks. Fixed by adding `final String id` (UUID) to `Worksheet` and rekeying `cursorProvider` as `StateNotifierProvider.family<CursorNotifier, double?, String>`. All call sites (`TimeSeriesChart`, `ChartWorkspace`) now pass `worksheet.id`. `AnalyzeTab` uses `ValueKey(worksheet.id)` to key `ChartWorkspace`.

**Naming: Workbook / Worksheet, not Project / Page**
i2pro calls these "Project" and "Page." "Project" collides with the Dart project and the IDE project in every conversation about the codebase. "Workbook" is unambiguous and familiar from spreadsheet tooling; "Worksheet" follows naturally. Users who know i2pro terminology can be bridged with a note in help text if confusion is reported.

**Initial channel colour: fixed palette, each chart cycles independently**
Colours are not allocated from a shared global pool — each chart cycles its own fixed palette in order of channel addition. This avoids the coordination problem: if chart A removes a channel, chart B's palette does not shift. The tradeoff is that the same logical channel can appear in different colours in different charts, which complicates cross-chart comparison. The correct long-term fix (a channel-identity → colour map persisted in `.idl0w`) requires channel identity to be stable across math expression re-evaluation; deferred until math channel evaluation semantics are finalised.

---

## UI Layer — Device Tab

**`ConfigEditor` initialises from provider once at widget creation, not live-synced**
`initState` reads `deviceProvider.currentConfig` exactly once. If the provider value changes while the form is open (e.g., a future auto-load on connect), the form keeps its stale copy. The alternative — watching the provider and reinitialising on change — would silently discard any edits the user had already made. Since the only way config reaches the provider is via a user-initiated Push Config, the "stale copy" scenario cannot occur in v1; this should be revisited if auto-load from device is added.

**Calibration pre-flight checklist gates the "Calibrate IMUs" button**
All three checklist items must be checked before the button enables. §11 states the preconditions as prose; a blocking gate rather than advisory text was chosen because a bad calibration (bike still leaning, rider on the bike) silently corrupts the rotation matrix used for every subsequent session. The cost of one extra tap per calibration is negligible compared to the cost of silently bad data.

**`CalibrationPanel` uses a deterministic 5-second `AnimationController`, not an indeterminate spinner**
The device takes ~5 s to collect samples (§11). A determinate `LinearProgressIndicator` driven by a 5-second `AnimationController` sets an accurate expectation and reassures the user that something is happening. An indeterminate spinner conveys no timing information. This animation runs in parallel with the actual `calibrate()` Future; if the device ever takes longer than 5 s the bar will be full before the future completes — the button remains disabled until the future resolves regardless.

**`DeviceState` has no `isLoading` or `error` fields**
The task-specified state (`isConnected`, `deviceName`, `batteryPercent`, `isRecording`, `currentConfig`) does not include loading or error state. BLE operation errors are caught by widget-local `try/finally` blocks and surfaced via `ScaffoldMessenger`. This matches the existing pattern in `SessionNotifier` and `WorkspaceNotifier`. If a persistent error state is ever needed (e.g., "last connection failed — tap to retry"), add a `String? lastError` field to `DeviceState` at that point rather than pre-emptively.

**`stopRecording()` has no `isConnected` guard; `startRecording()` does**
`startRecording()` guards with `if (!state.isConnected) return` because there is a plausible path where the user taps Start before the connect completes. `stopRecording()` does not guard because the Stop button is only rendered when `isRecording == true`, which can only be true if a prior `startRecording()` succeeded — which required `isConnected`. The asymmetry is deliberate, not an oversight. See CLAUDE.md: "do not add error handling for scenarios that can't happen."

**`_buildConfig()` always emits all scaling fields regardless of pressure sensor enable flags**
When `pressure_front_enabled = false`, the `scaling.pressure_front` block is still included in the pushed JSON. The §8 example config includes all fields unconditionally, and the compatibility note states firmware ignores unknown fields. Conditionally omitting sub-trees would create divergence between what the editor shows and what is stored, complicating round-trip parsing. The firmware reads `enabled` before using `scaling`, so the extra fields are harmless.

---

## UI Layer — Maths Tab

**Channel parse errors are silently skipped in `availableChannelNamesProvider`**
When `channelDataProvider(id)` resolves to `AsyncError` (file missing, parse failure), `availableChannelNamesProvider` skips that session's channels via `whenData()` with no user-facing indication. The Maths tab expression editor shows only a validation result — it does not indicate that a session failed to load. This is intentional at the scaffold stage: channel availability is an editing convenience, not a data integrity gate. When the Analyze tab loads real channel data per §16, that path will need explicit error surfacing.

**Expression editor defers validation display until first edit**
The validation status row is hidden until the user has made at least one edit (or the channel already has a non-empty expression on open). The alternative — showing "Expression cannot be empty" immediately when a blank channel is selected — is technically correct but noisy: the user has not yet had a chance to type anything. The `_hasValidated` flag in `ExpressionEditorState` tracks this; it is set on first validation timer fire and on `initState` if the loaded expression is non-empty. This affects display only — validation still runs on every change regardless of whether the status row is visible.

---

## UI Layer — Runs Tab

**`AlertDialog` for the metadata editor**
A bottom sheet or a pushed route were both considered. `AlertDialog` was chosen because it works on both mobile and desktop without a layout change, and the metadata form (8 short fields) is small enough to fit without scrolling on most screens. If the form grows substantially (e.g., adding per-session gear settings), reconsider a dedicated route to give each field more breathing room.

**Filter dropdowns are non-cascading (populated from all sessions, not the current filtered set)**
When a rider filter is active, the venue dropdown still shows all venues present anywhere in the library, not only venues where that rider has sessions. Cascading filters are more precise but harder to use: options disappear mid-selection and the user cannot explore combinations that exist. Non-cascading avoids the disappearing-option problem at the cost of occasionally showing venues that produce zero results when combined with the current rider filter.

**Two-panel layout breakpoint at 800 dp, not 600 dp**
The shell navigation breakpoint (600 dp) controls whether a side rail is present. The Runs tab two-panel split (download panel + session library) needs more room: below about 800 dp the download panel is too narrow to show filename, file size, and a Download button on one line. Using 600 dp would trigger the split at a width where content immediately wraps. The 800 dp value is a starting point; adjust after device testing.

**`SyncStatus` defined in `runs_provider.dart`**
Drive sync is not yet implemented, so there is no Drive-specific provider file to own this enum. It lives adjacent to `RunsState` because that is where sync status is currently stored and consumed. When Drive sync is implemented, move `SyncStatus` to whichever file owns the Drive sync logic (expected: `drive_sync_provider.dart`) and update all import sites.

---

## Decisions Still Open

Active project work-to-do is tracked in `TASKS.md` (per `CLAUDE.md §10`). Inline `**TODO:**` markers in `docs/IDL0_SPEC.md` flag places where the spec itself is incomplete.

---

## Venue: derived grouping vs first-class entity

As of 2026-05-05 the Data tab redesign chose Option A: venue stays a string field on `Track.venueName` and `SessionMetadata.venueName`, rather than a first-class entity with its own Drive-as-DB file and SQLite cache.

**Why.** A venue's identity-relevant data today is its name. Tracks already carry the GPS reference polyline that anchors location. A `Venue` entity with one string field is not worth a Drive folder, a new provider, conflict resolution, or a schema migration on Track and SessionMetadata.

**Upgrade path A → B.** When venues need fields beyond a name (description, photo, default map center, region grouping), introduce a `Venue` class mirroring `Track`. The data migration is mechanical: one Venue row per `distinct Track.venueName`, replace `venueName: String` with `venueId: String?` on Track and SessionMetadata, populate the FK from the deduped table. Drive folder layout: `IDL0/venues/<uuid>.idl0v`.

Because the upgrade can be done in an afternoon when there's a real demand signal, the cost of starting at A is bounded.

---

## Sector Timing & Ghost Lap — Implementation Approach

(Relocated from IDL0_SPEC.md §14.5 during the 2026-05-04 spec overhaul. Belongs here because it describes WHY the implementation choices were made, not WHAT the system does.)

The lap detector, sector timing, and GPS-position-based time deltas ("ghost lap" comparison showing where time is gained/lost vs a reference run) are all implemented in-house. The motorsport-telemetry open-source landscape is sparse and hobbyist-grade; mature options (MoTeC, AiM, RaceChrono) are proprietary. The underlying algorithms are well-known:

- **Gate crossing:** 2D segment intersection with flat-earth approximation (already in `LapDetector`).
- **Track simplification:** Ramer–Douglas–Peucker when displaying long sessions.
- **Ghost timing (point-by-point delta):** for each sample in the comparison run, find the closest spatial point on the reference run's polyline, compute time delta. Linear interpolation between samples gives sub-sample precision.
- **Theoretical best lap:** per-sector minimum across all laps in the session.

These are textbook computational geometry. UI work (gate placement on map, sector tables, ghost-overlay charts) is the bulk of the effort. UX inspiration may be drawn from MoTeC i2pro conventions — patterns are conventions, not IP.

---

## Lap timing as tagged union vs. list of gates

As of 2026-05-07, `Track.lapGates: List<LapGate>` was replaced by `Track.lapTiming: LapTiming?` — a sealed union of `Circuit` (one shared start/finish gate) and `PointToPoint` (separate start and finish).

**Why.** The list model was loose: a 0-element list meant "no timing", a 1-element list meant Circuit, a 2-element list meant Point-to-Point, and 3+-element lists silently truncated. The intent was implicit in the length; serialisation, validation, and UI all duplicated the same length-checks. Tagging the union explicitly hands the discriminator to the type system — `switch(timing)` is exhaustive, `null` cleanly means "no timing", and the lap detector's branching collapses to one `switch`.

**Migration.** Legacy on-disk Tracks load via `Track.fromJson` mapping `lap_gates: []` → `lapTiming: null`, `lap_gates: [g1]` → `Circuit(g1)`, `lap_gates: [g1, g2]` → `PointToPoint(g1, g2)`, and `lap_gates: [g1, g2, ...]` truncating extras. `toJson` always writes the new `lap_timing` shape.

## Per-session gate override removed

As of 2026-05-07, the §17 workspace-over-track fall-through is removed. `LapDetector` and `visitLapsProvider` read only `Track.lapTiming` / `Track.sectorGates` / `Track.neutralZones`. `Workspace.lapGates` and `Workspace.sectorGates` remain in the model dormant.

**Why.** The dual write surface meant existing Tracks always had 0 gates (no UI ever wrote to them) and lap detection only worked for sessions whose workspace happened to carry gates. New sessions visiting the same Track inherited the empty Track and produced 0 laps. Track-first ownership is the simpler mental model: a Track has gates, sessions visit it, the gates apply.

**Why keep workspace fields.** Future Session Gates territory: pure overlay analysis (mark a section to measure inside a single session) without polluting the Track. The fields cost nothing dormant; deletion is deferred until Session Gates is brainstormed.

---

## Why tile-based on-demand decimation, not eager pyramid (2026-05-27)

We considered three approaches for keeping the Analyze chart smooth at session lengths up to 2 hr × 800 Hz:

1. **Single-pass min/max per frame** — simple, but at 5.76 M samples × 6 channels per frame, even Rust hits ~30 ms — drops frames during pinch.
2. **Eager full pyramid at session load** — pre-compute every tier. Per-frame cost is constant, but session-open burns ~500 ms and the pyramid eats ~80 MB per active session before the user does anything.
3. **Tile-based lazy decimation (chosen)** — like Google Maps tiles, but 1D. Compute only the visible tiles at the picked tier; cache them with LRU eviction. The plan originally called for an eager tier-4 pre-warm of the active worksheet, but that was dropped during Task 7 because the worksheet model doesn't carry (sessionId, channelId) pairs — first paint relies on the chart widget's lazy `_ensureIngested` path, which produces ~30 ms of first-paint Rust work and is acceptable.

Tile-based wins because cost is amortised across user interaction rather than burnt upfront, memory is bounded by the cache cap rather than session length, and at the actual workload (per-tile ~10k–500k samples, ~1–3 ms FRB hop) the user can't tell the difference between a cache hit and a cache miss within one frame.

The trade-off accepted: tile-based code is more complex than a single decimation pass. We chose the complexity because the 2 hr session target is non-negotiable for race-day use.

### FFT: compose Welch on rustfft rather than adopt welch-sde

sci-rs 0.4 provides no spectral-density API. `welch-sde` is a thin wrapper over the
same `rustfft` we already use, but offers only segment/overlap/mean/PSD — no detrend
(it requires zero-mean input), no median averaging, no magnitude output, no Hamming
window — and is a single 0.1.0 release from January 2022. We would have hand-written
the flexible majority anyway, so `welch()` is composed directly on `rustfft`, reusing
the `window_weights` helper. No new dependency. The FFT chart calls `welch()`; the
legacy `fft()` is retained because it backs the math-channel `fft(ch, window)`
function, and `welch(segments=1, rect, no detrend)` reproduces it bit-for-bit.

---

## Engine as a standalone `/rust` workspace, not a Flutter-bound layer (2026-05-30)

The Rust code began as a DSP *layer* of the Flutter app (`app/rust`, with
`#[flutter_rust_bridge::frb]` annotations directly on the math functions). That
made the processing logic impossible to reuse outside the app — no headless
batch processing, no CLI, no Python/WASM path — and risked the parsing/processing
logic drifting between the app and any future tool. Phase 0 of the engine
migration restructures it into a repo-root `/rust` cargo workspace so the engine
is a first-class artifact and the app is just one consumer.

**Three crates, not one, and the split is compiler-enforced.**
- `idl-rs` (core) is **pure** — no `flutter_rust_bridge`, no `clap`, no I/O
  beyond `std::fs`. This is what Python (pyo3) and WASM (wasm-bindgen) will bind
  to, and it must compile to `wasm32`.
- `idl-rs-bridge` holds the thin `#[frb]` wrappers and `#[frb(mirror(...))]`
  declarations; it is the only crate Flutter sees. Keeping FRB here (rather than
  a `cli`/`frb` feature flag on the core) means the *compiler*, not developer
  discipline, guarantees the core stays binding-free.
- `idl-rs-cli` is a separate crate for the same reason — its `clap`/filesystem
  deps never reach the WASM/pyo3-facing core.

**Product rebrand IDL0 → idl-rs is product-only.** `idl-rs` was free on
crates.io/npm/PyPI (`idl` was taken and collides with Interface/Interactive Data
Language). The `.idl0`/`.idl0w` file extensions and the `IDL0` magic header are
frozen — the tool is renamed, the format it reads is not (the ffmpeg/`.mp4`
split). The Android `applicationId` is likewise unchanged, since changing it
would orphan every installed app's local session library.

**FFI boundary carries output-shaped data, not raw samples.** Once `idl-rs`
owns parsing (later phases), raw samples never cross to Dart just to be handed
onward; Rust produces the render/output-ready form (chart min/max tiles,
summaries, lap tables, export buffers) and Dart pulls it at the latest efficient
point. This shrinks the bridge each phase and favours an opaque-handle FFI model
over bulk-copying a mirrored data model. See the migration roadmap for the
phased plan.

## Parser cut-over: opaque handle, right-sized to the keystone (2026-05-31)

The app parses `.idl0` through the engine via a `RustOpaque<SessionHandle>`, not
an eagerly-copied mirrored DTO. Rust owns the parsed session; Dart pulls a small
`session_metadata` summary, the channel list, and per-channel samples on demand.
This is the D8 model made concrete for the parser phase. The handle is
**transient** this phase — `channelDataProvider` drains it into the existing
`List<ChannelData>` and drops it — so nothing downstream of the provider changed;
the cached, decimate-off-the-handle lifetime arrives in Phase 3.

**Right-sized to the keystone.** The goal was one parser (delete the Dart one),
not the full bridge-shrink. Dart-computed math-channel results render through the
same `ingest_channel → decimate_tile` path as raw channels, and the math
evaluator stays Dart until Phase 3. Retiring `ingest_channel` now would mean a
handle-scoped re-injector plus a chart-widget refactor that Phase 3 redoes once
math results are Rust-owned — throwaway work. So the chart decimation path is
left untouched and its shrink is a clean Phase-3 co-delivery.

**Synthesis moved into the engine.** `Time` and `Distance` are derived channels;
`Distance` is trapezoidal integration of GPS speed. Both are DSP and belong in
`idl-rs` (one implementation for the app and the CLI), not duplicated in a Dart
provider.

**Parse errors cross as a unit-enum `kind` + `message`, not a data enum.** FRB
renders Rust data-carrying enums as `freezed` Dart classes, which would pull
`freezed` + `build_runner` into the app. A flat `ParseErrorKind` (unit enum) plus
a `message` string is freezed-free and maps cleanly onto the existing Dart
exception hierarchy.

**`duration_ms` canonicalised to the longest channel span**, uniformly for
`.idl0` and `.gpx`, replacing the per-source split (`channels.first` vs a
`GPS_EpochMs` span). One rule, correct when the first channel is short or
event-driven; it is a display-only library field.

## CLI export lives in the engine core, not the CLI crate (2026-06-01)

Phase 2 added CSV/JSON export. The serialization lives in the `idl-rs` **core**
(`export` module), not in `idl-rs-cli`. Export is pure, data-in/data-out
formatting over the parsed session — exactly the kind of capability that should
belong to the engine, not one front end. Putting it in core means the CLI today,
the Flutter app, and future Python/WASM bindings all inherit one implementation
(roadmap D8 / §11: an export buffer is a first-class engine output, like the
chart tiles and summary). The writers stream to a caller-provided `io::Write`, so
the core never opens a sink — it stays within the "no I/O beyond `std::fs`" rule
while the CLI owns the file/stdout handle.

**CSV is long/tidy (`channel,time_s,value`), not column-per-channel.** Channels
have different sample rates (IMU fast, GPS slow, event-driven irregular), so a
wide table forces a shared time grid — resampling or NaN-padding, i.e. inventing
data. Long format puts every sample on its own row with its own time, handling
any rate mix losslessly in one file; JSON is the parallel nested form for tools
that prefer structure. CSV is hand-rolled (three controlled columns) to keep the
core dependency-light and wasm-friendly; JSON uses serde_json.

**Parquet deferred.** It would pull a heavy `arrow`/`polars` dependency with no
current columnar consumer; `--format parquet` is additive later (natural
alongside the Phase 6 bindings). The exporter dumps the parsed + synthesized
channels the handle holds; math results live in a separate store (see the next
section) and joining them into the export set is a small additive follow-up.

## Math evaluator lives in the engine core (2026-06-01)

Phase 3a moved the math-channel expression engine — tokenizer, recursive-descent
parser, evaluator, value types, and the full function set — out of the
1,840-line Dart `MathChannelEvaluator` into the pure `idl-rs` core `math` module,
consumed via `eval_math`. One implementation of the expression language now
serves the app, the CLI, and future Python/WASM bindings, mirroring the
parser/DSP-in-the-engine decisions above.

**Grammar ported verbatim, not swapped for a crate.** The hand-written grammar
(scipy-mirroring function names, `[Channel Name]` references that may contain
spaces and digit-leading segments) is a user-facing contract. A third-party Rust
expression crate would have changed semantics and error messages; a faithful
port keeps every existing expression and the Maths-tab help text valid. The
highest-risk surface in the migration, so deletion of the Dart evaluator is gated
on parity tests ported from its own test suite.

**Retained handle + interior-mutable math store.** The evaluator reads channels
Rust-side through a `ChannelLookup` rather than receiving a marshalled sample map
(honoring roadmap D8 — output-shaped data crosses FFI, not raw samples). That
required the `SessionHandle` to become *retained* (it was drained-and-dropped in
Phase 1) and to gain a math-channel store. The store is a separate
`RwLock<Vec<Channel>>`, **not** a wrapping of the parsed `session.channels`: the
parsed channels stay immutable so Phase 2's exporter `channel_data() -> &[Channel]`
borrow is unaffected, and `add_channel(&self, …)` writes only the math store.
`ChannelLookup` reads base/synthesized first, then the math store.

**Resolver stays Dart, behind clean seams.** The cross-channel dependency
resolver is multi-session, Riverpod-cache-aware orchestration — app concern, not
physics — so it stays Dart for now. It writes resolved dependencies back into the
handle via `add_channel`, so the next `eval_math` reads them natively. Moving the
resolver into Rust later is therefore additive: it becomes another `ChannelLookup`
implementation that evaluates an unresolved `[Name]` on demand. The
`ChannelLookup` trait + `add_channel` are the seams that keep that move cheap.

**Overlay as a second handle, not marshalled samples.** Cross-session
`variance_*` needs the reference session's GPS + channel data. Rather than copy
the overlay session's samples to Dart and back, the overlay crosses as a second
`RustOpaque<SessionHandle>`; the variance geometry reads its channels Rust-side.
The lap windows (small scalars) and the epoch→uniform-time conversion stay
Dart-side — the conversion needs lap timestamps the Dart lap detector owns (laps
are a Phase 4 entity), and only the converted bounds cross.

**Math dependency resolver lives in the engine (Phase 3b).** The cross-channel
dependency resolver (walk `[Name]` refs, evaluate deps-first, write results back
into the session handle) moved from Dart into `idl-rs` (`math::resolve`). It had
to: the CLI's `math --workbook` path resolves dependencies with no Flutter
present. Per the migration's "no two live implementations" rule, the app cut
over to the `resolve_math_dependencies` bridge fn and the Dart resolver was
deleted; lap-context *building* (which reads `.idl0w`, laps, the overlay
session) stays Dart.

**The CLI clones derived channels for export.** Derived channels live in the
session handle's `RwLock<Vec<Channel>>` math store, and a read guard cannot lend
a `&Channel` past its own scope — so the exporter (which borrows base channels
straight from the handle) cannot reach them the same way. The CLI's `math`
command therefore takes the owned derived channels straight from
`apply_workbook`'s report and exports them via `export::write_channels`, an
explicit-slice entry point. One O(samples) copy in a one-shot batch tool is
cheaper than coupling the exporter to the lock's lifetime; D8's no-copy
discipline governs the FFI bridge (where copies would recur), not the CLI.

## Lap detection in the engine (Phase 4a, 2026-06-01)

`LapDetector` moved into `idl_rs::laps`: `detect_laps` reads GPS from the
retained handle and takes the Track's gate/timing config as input, returning the
lap table. GPS never crosses to Dart for detection. The `window` parameter does
visit-windowed detection in Rust (the app's only detection caller,
`visitLapsProvider`, always passes a `TrackVisit` window) — no Dart-side GPS
slicing. The Track config models (`LapGate`/`SectorGate`/`LapTiming`/
`NeutralZone`) and `buildGpsTrack` stay Dart: they're persisted in `.idl0w`/Track
JSON and still used by track matching, which moves in 4b (a temporary
GPS-assembly duplication retired then). Gate coordinates stay at the raw
degrees × 1e7 channel scale — the crossing geometry (2D cross-products and
parameter ratios) is scale-invariant, so no conversion happens.

## WiFi link lifecycle: radio handoff + reconciler (2026-06-10)

The architectural turns and why:

**BLE off in WiFi mode (radio handoff), not interval-stretching.** Espressif's
coexistence matrix marks SoftAP (station connected) + any BLE activity as
"C1 — supported but the performance is unstable", and the time-slicing scheme
cedes up to ~50% of radio time to a connected BLE link. Keeping the phone GATT
link up during transfers — the previous design — was the documented unstable
regime, the likely root cause of intermittent transfer flakiness, and halved
throughput. Stretching the BLE connection interval was rejected: smaller win,
still C1. Dropping BLE entirely requires an HTTP control plane (`/ping`,
`/handoff`, `/wifi_off`) plus two safety rails — BLE stays up until the app
acknowledges the HTTP link, and a 5-minute no-activity failsafe exits WiFi
mode autonomously — so neither side can be stranded without a control channel.

**Link reconciler, not event-handler bind logic.** The previous
bind-on-mode-change handlers raced each other (unserialized async syncs,
stale completions clobbering state, releases tearing down in-flight binds).
A single-flight desired-vs-actual reconciler removes the interleavings
structurally instead of guarding them with epochs and queues. The platform
boundary became commands + an event stream because an Android network is an
event-driven resource; forcing it into one pending `MethodChannel.Result`
created the timeout/settle races and the dialog-dismissing 10 s timer.

**Loopback proxy, not `bindProcessToNetwork`.** Process-wide binding routed
all app traffic to the AP, breaking Drive sync during transfers and giving
every network disturbance app-wide blast radius. A ~100-line Kotlin TCP
forwarder over `Network.socketFactory` scopes AP routing to device sockets
only. Moving HTTP itself into Kotlin was rejected (platform layer stays thin;
the app also runs on Windows where no binding exists at all).

**`/ping` verifies identity, not just reachability.** Every IDL0 AP shares
`192.168.4.1`, so a reachability probe can "succeed" against the wrong
device. The probe returns the device name and protocol version; `linked`
means identity-verified. It doubles as the WiFi-mode status feed once BLE is
off, and as the liveness heartbeat.

## Suspension-kinematics estimator: geometry-constrained state estimation (2026-06-23)

The architectural turns and why:

**A state estimator, not a filtered channel.** The naive
`integrate(integrate([IMU1_AccelZ]))` double-integrates noisy specific force and
drifts without bound, ignoring the bike. The geometry *is* the information that
makes inferring travel/velocity/steering from IMUs solvable — so this is a
geometry-constrained state-estimation problem. Every output is a coupled
estimate sharing one state and its cross-covariance, not an independent
mini-filter per quantity.

**One shared model surface; the IEKF is scaffold, the batch smoother (M5) is the
payoff — on the *same* residuals.** The process and measurement factors are
defined once (`ErrorState`/`ProcessModel`/`MeasurementModel`) and consumed
verbatim by the forward IEKF now and the batch Gauss-Newton/IEKS later. This is
the Bell-1994 equivalence: nonlinearly, the iterated Kalman smoother *is*
Gauss-Newton on the MAP cost, so the forward filter is initialization and the
backward batch pass is where offline accuracy lands — no duplicated residual
math. The IEKF update is written in information/GN form precisely so the batch
solver stacks the identical factors.

**Right-perturbation error-state, analytic Jacobians, never autodiff.** The SO(3)
convention is pinned (`x = x̂ ⊞ δ`, `R̂·exp([δθ]×)`) so every factor's `∂r/∂δ`
is one unambiguous derivation, FD-checked at 1e-6. Autodiff was rejected: it
breaks the filter↔batch reuse, hides convention bugs, and is a divergence
footgun in a hand-tuned estimator.

**A pure-core engine separate from the math evaluator; outputs are virtual
sensors.** A recursive, stateful, joint IEKF cannot be a `call_function` arm
(those are stateless, element-wise, name→samples). It lives in its own
`estimate/` module and is *invoked* by named virtual-sensor functions
(`wheel_velocity()`, …) — quantities, not a `kalman()`/`estimate()` meta-verb —
so the maths UI gets one discoverable, unit-typed chip per output while the
joint coupling stays in the shared `StateEstimate` underneath. The state schema
is first-class and inspectable (you can see exactly what a run estimates) but
lazily materialized (means → channels; covariance on demand), and geometry is
**per-session** (a workbook can compare two bikes) rather than per-workbook.

**Which quantities are states vs measurements vs omitted is earned, not
default.** Chassis velocity is a carried state because GPS-aided inertial fusion
observes it (and it enables acceleration-compensated leveling); chassis
*position*, IMU1/2 accel bias, tires, and rider force are deliberately omitted
because nothing pins them (they would random-walk and absorb real signal). The
rear gyro-rate factor is standard-but-geometry-weighted: strong for a
swingarm/linkage mount, ~zero for this bike's seatstay — chosen by
`dθ_link/dw_r`, never special-cased.

**Travel DC anchors on topout, not sag.** Sag is where the suspension sits *with
rider weight on*; an unweighted/parked bike rests at **topout (d=0)**, the hard
physical floor. So travel is seeded at topout and the sag prior is a loose,
**coasting-only** DC nudge — never applied to a parked (stationary) window, where
assuming sag would simply be wrong. The authoritative travel DC comes from events
— the diff-accel integrating a weighting/compression transition, and the
**topout reference** — every airborne moment (free fall, IMU0 specific force ≈ 0)
is a known full-extension d=0, re-zeroing the double-integrator — and until one
occurs the ledger reports travel DC as RelativeOnly rather than asserting a sag
value the IMUs never measured. (Surfaced by the real static-flat log: once sag was
demoted to coasting-only, the engine correctly held travel at ~0, not sag.
Confirmed on a real jump session: open-loop travel drifts ~170 mm across the ride,
but the airborne topout zeroing collapses the between-jumps divergence to ~0.3 mm
— the events, not a sag assumption, are the load-bearing DC anchor. The bottomout
reference + a more robust event detector are the remaining growth.)

## Firmware distribution: GitHub Releases as host, git tag as version of record (2026-06-29)

The turns and why:

**GitHub Releases over a self-hosted manifest.** The repo is already public, so
the Releases REST API gives a channel system (the **prerelease flag** = stable vs
beta), CDN-backed downloads, release notes, and version history for free — no
server to run, no token to embed, well under the 60 req/hr unauthenticated limit
for update checks. A self-hosted `latest.json` was the alternative; it buys
branding control at the cost of hosting, uptime, and hand-rolled manifests. The
app talks to the host through a one-method `FirmwareCatalog` interface
(`GitHubReleasesCatalog` the sole impl), so a future move to a static host is a
single new class, not an app rewrite.

**The git tag is the single version of record.** CI sets the build version from
the tag (leading `v` stripped) → embedded `esp_app_desc_t.version` → `/ping fw`
and the §7.3 `Firmware:` status line. No version constant is maintained by hand,
and the device-reported version is by construction the release tag the app
compares against.

**Dedicated repo per target, plain `v*` tags — the "one sword."** Rather than
namespacing tags in the shared monorepo, firmware moves to its own repo (under
the planned `saucyeng` org), so it uses plain `v*` tags and `/releases/latest`
works directly. The reusable spine — semver tag → GitHub Actions build → GitHub
Release → self-update client — then applies per repo to firmware now and the
Windows/app-store builds later (the CI half reuses everywhere; the self-update
client reuses for firmware, Windows, and sideloaded Android, but store apps let
the store own delivery).

**Reuse the OTA push, don't rebuild it.** The download layer ends by handing
bytes to the existing `pushFirmware` / pending-verify path (P9). The new surface
is just fetch + compare + download; the device's `esp_ota_end` SHA-256 stays the
authoritative integrity gate, with the app-side checksum a fast-fail.

---

## Video overlay: sidecar ffmpeg + one rasterizer (2026-07-09)

**ffmpeg as a sidecar process, never linked.** The overlay export needs
decode → composite → encode, and the obvious shapes were linking libav
(`ffmpeg-next`) into the engine or shelling out to a separate `ffmpeg`
binary. Linking loses on every axis that has hurt this project before:
libav cross-compilation on Windows + cargokit, LGPL/GPL distribution
questions for an AGPL app, and a per-platform build that breaks in new
ways. The sidecar costs one external executable (system-installed or
`--ffmpeg`-pointed in v1) and buys ffmpeg's hardware encoders with zero
build entanglement. Process spawning violates engine purity, so the driver
lives in a dedicated `idl-rs-video-export` crate consumed by both the CLI
and the FRB bridge — written once, engine-agnostic (frames arrive through
a closure).

**One rasterizer for preview and export (WYSIWYG), one model for many
canvases.** The headless-CLI requirement forces overlay rendering into
Rust (tiny-skia + embedded IBM Plex Mono) — so the same rasterizer serves
CLI export, app export, and the app's live preview: what you tune is
pixel-identical to what you ship. The layout/sampling model
(`overlay::{model,sample}`) is deliberately canvas-agnostic and lives
beside — not under — `video`: a future chart-canvas overlay (the dormant
`WorksheetBlock.placement: overlay`) reuses the same model sampled at the
worksheet cursor but composits in Flutter, because interactive chart
chrome needs hit-testing, DPI-native text, and resize-fluid layout that a
texture stream can't give. Pixel parity between the tiny-skia and Flutter
compositors is an explicit non-goal.

**Hand-rolled ISO-BMFF walker over the `mp4` crate.** The `mp4` crate's
typed `TrackType` rejects tracks whose handler is not video/audio/subtitle
— which is exactly what a GoPro `gpmd` telemetry track is. The walker
reads only what the feature needs (gpmd sample table, creation time,
video dims/fps) with bounds-checked reads, consistent with "the engine
owns binary parsing."
