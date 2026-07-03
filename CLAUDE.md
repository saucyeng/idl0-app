# CLAUDE.md — IDL0 Project Standing Orders

Read this file and `docs/IDL0_SPEC.md` before starting any task.
These rules apply to every task, every file, every session.

---

## 1. Before You Start

The spec has a table of contents at the top. Read only the sections relevant to the current task — not the full document. Use this guide:

| Task type                         | Read these sections           |
|-----------------------------------|-------------------------------|
| **Hardware / Firmware**           |                               |
| Firmware                          | §1, §3, §4, §5, §10           |
| Binary parser                     | §1, §5                        |
| **Transport**                     |                               |
| BLE transport                     | §1, §7                        |
| WiFi transport                    | §1, §6, §10                   |
| Config system                     | §1, §8, §10                   |
| **App Architecture**              |                               |
| Selection model                   | §1, §13                       |
| **App Data**                      |                               |
| Session model / data layer        | §1, §15                       |
| Track entity / multi-track        | §1, §16, §17                  |
| GPX import                        | §1, §15, §28                  |
| **App Processing**                |                               |
| Rust processing                   | §1, §19, §20                  |
| Calibration                       | §1, §9, §20                   |
| **App UI**                        |                               |
| UI — Device tab                   | §1, §22, §23                  |
| UI — Data tab                     | §1, §22, §24                  |
| UI — Maths tab                    | §1, §22, §25                  |
| UI — Analyze tab                  | §1, §22, §26                  |
| UI — Settings tab                 | §1, §22, §27                  |
| **Cross-Cutting**                 |                               |
| Drive sync                        | §1, §28                       |
| First launch / onboarding         | §1, §30                       |
| Export                            | §1, §29                       |

**Always read §1 (System Philosophy).** Everything else is task-specific.

**When in doubt about a decision:** Check the spec before asking. If the spec doesn't cover it, stop and ask — do not make architectural decisions silently.

**Ambiguous implementation details:** stop and ask — see §2 (Ambiguity Policy).

---

## 2. Ambiguity Policy — Read This Before Writing Any Code

**A wrong assumption costs more to fix than a question costs to ask.**

If anything is unclear — a field type, a behavior on an edge case, 
a function signature, whether something belongs in Rust or Dart — 
**stop and ask before writing code.**

The following always require explicit clarification before proceeding:
- Any field type, size, or encoding not explicitly stated in the spec
- Any behavior on error or edge case not covered in §16
- Any new file, class, or function whose layer placement is ambiguous
- Any decision that would require changing an existing tested function to implement

Do not:
- Infer a type from context and proceed
- Pick the "most reasonable" behavior for an unspecified edge case
- Create a new abstraction layer not described in the spec
- Interpret silence as permission

One clarifying question asked upfront is worth ten test failures caught later.

### Layer Separation
The processing layer is Rust. Everything else is Dart. This line is absolute.

The Rust engine is the `idl-rs` crate in the repo-root `/rust/` cargo workspace —
consumed by the Flutter app (through the `idl-rs-bridge` flutter_rust_bridge
shim) and by the standalone `idl-rs` CLI. The engine now owns `.idl0` **binary
parsing and the parser-output model** (Session/Channel), exposed to the app as a
`RustOpaque<SessionHandle>` (SPEC §15). The engine also owns the **math-channel
evaluator** (`idl-rs` `math` module — tokenizer, parser, evaluator, function
set), consumed via `eval_math`; the handle is now retained for the session
lifetime with an interior-mutable, **typed derived-channel store** (math outputs
by name via `store_math`; lap slices by `(source, role, lap)` via
`slice_lap_into_store`), reclaimed by `retain_derived` on the eval path. The cross-channel **dependency resolver** has also landed in the
engine (`idl-rs` `math::resolve`, consumed via `resolve_math_dependencies`), so
recursive math-channel dependencies resolve Rust-side in one pass. Still
migrating into the engine: lap/track
analysis and the `.idl0w` workspace model — these remain in Dart until their
phases land. GPX parsing also stays Dart for now.

```
rust/core/       crate `idl-rs` — ALL signal processing math. PURE: no Flutter,
                 no flutter_rust_bridge, no I/O beyond std::fs. Data in, data out.
                 sci-rs: filters, FFT, integration, statistics.
                 nalgebra: rotation matrices, vectors, linear algebra.

rust/bridge/     crate `idl-rs-bridge` — thin #[frb] wrappers over `idl-rs`;
                 the only crate Flutter sees. FRB codegen runs here.

rust/cli/        crate `idl-rs-cli` — the `idl-rs` CLI binary. Depends on `idl-rs` only.

app/lib/data/    Session catalog (SQLite index), `.idl0w` workspace, `.idl0wb`
                 workbook (owns its math channels + constants), GPX import,
                 lap/track analysis. No DSP, no `.idl0` parsing, no expression
                 evaluation or dependency resolution (the engine owns those —
                 consumed via the session handle + `eval_math`).

app/lib/transport/  BLE, WiFi transfer, config push.
                    No processing. No data layer concerns.

app/lib/ui/      Widgets, Riverpod providers, navigation.
                 Calls the engine via flutter_rust_bridge. Never touches sci-rs directly.
```

**Decision rule:** Does it operate on the physics of the bike — sensor data, rotation, filtering, integration, frequency analysis? → Rust. Does it operate on the app's data structures, files, or UI state? → Dart.

### Rust Processing Rules
- Use `sci-rs` for filters, FFT, integration, statistics — **never reimplement what sci-rs provides**
- Use `nalgebra` for rotation matrices, vector math — **never reimplement**
- Function signatures mirror scipy where possible — users find scipy docs and they work in idl-rs
- `idl-rs` core functions are **pure** (no `flutter_rust_bridge` dependency). Each function exposed to the app gets a thin `#[flutter_rust_bridge::frb]` wrapper in `idl-rs-bridge`; cross-boundary structs/enums use `#[frb(mirror(...))]` there
- After any Rust change to the bridged surface: run `flutter_rust_bridge_codegen generate` from `app/` (its `rust_root` points at `../rust/bridge`) to regenerate Dart bindings

### Other Hard Constraints
- **Firmware does zero processing while logging.** During a logging session: raw bytes to SD card, nothing else. Non-logging activities (boot, calibration, file transfer, config) may compute as needed. Analysis DSP — filtering, integration, FFT — never runs on the device in any mode; that is always the app. See SPEC §1.
- **Log files (`.idl0`) are never modified after download.** All derived work goes in `.idl0w`.
- **Math channels are evaluated lazily.** Store the expression. Evaluate on demand.
- **State management: Riverpod only.** No Provider, no Bloc, no setState except local widget state.

---

## 3. Testing

Tests verify logic you own. Do not test library internals (sci-rs, nalgebra, sqflite, flutter_blue_plus).

### What to Test and How

**Rust layer (`cargo test`):**
Verify correct wiring — right sci-rs/nalgebra function, right parameters, physically correct output
for known inputs. Test cases come from domain knowledge, not from confirming what the code does.

```rust
#[test]
fn rotate_vector_90_degrees_about_z_swaps_x_and_y() {
    // Arrange
    let rotation = rotation_matrix_z_90_degrees();
    let input = vec![1.0, 0.0, 0.0];  // pointing along X axis

    // Act
    let result = apply_rotation(input, rotation);

    // Assert — physically: 90° about Z maps X → Y
    assert_relative_eq!(result[0], 0.0, epsilon = 1e-6);
    assert_relative_eq!(result[1], 1.0, epsilon = 1e-6);
    assert_relative_eq!(result[2], 0.0, epsilon = 1e-6);
}
```

**Data layer (`flutter test`):**
Binary parser round-trips, malformed input, lap detection, workspace serialization.

```dart
test('parseImuRecord — all channels enabled — returns correct field values', () {
  // Arrange
  final buffer = buildKnownImuRecord(
    imuIndex: 0, sampleCounter: 42,
    accelX: 1000, accelY: -500, accelZ: 16384,
  );

  // Act
  final record = BinaryParser.parseImuRecord(buffer, channelMask: 0x3F);

  // Assert
  expect(record.imuIndex, equals(0));
  expect(record.sampleCounter, equals(42));
  expect(record.accelX, equals(1000));
});
```

**What not to test:** sci-rs/nalgebra internals, UI widget rendering, BLE/WiFi transport directly (mock at boundary).

### Test Structure
Every test: **Arrange / Act / Assert** with a blank line between sections.
Naming: `'methodName — condition — expected result'`
Rust tests: inline `#[cfg(test)]` modules. Dart tests: mirror source file structure.

### Coverage Targets
- Rust: > 90% (`cargo tarpaulin`)
- `app/lib/data/`: > 80% (`flutter test --coverage`)
- Overall Dart: > 60%

---

## 4. Documentation

### Every Public Symbol Gets a Doc Comment

```dart
/// Parses the binary header from a downloaded log file.
///
/// Returns [SessionMetadata] with device ID, schema version, channel mask,
/// and session start timestamp in UTC milliseconds.
///
/// Throws [InvalidMagicBytesException] if magic bytes are not `IDL0`.
/// Throws [TruncatedRecordException] if the header is incomplete.
///
/// See docs/IDL0_SPEC.md §5 for header field layout.
SessionMetadata parseHeader(Uint8List buffer) { ... }
```

```rust
/// Applies the IMU calibration rotation matrix to a raw sensor vector.
///
/// `sensor_vec`: 3-element [x, y, z] in sensor body frame, raw LSB counts.
/// Returns the vector in vehicle frame (X=forward, Y=left, Z=up, ISO 8855).
///
/// Rotation matrix computed during static calibration. See docs/IDL0_SPEC.md §20.
pub fn apply_rotation(sensor_vec: Vec<f64>, rotation: [[f64; 3]; 3]) -> Vec<f64>
```

### Units Are Mandatory
Never leave a numeric value's units ambiguous.

```dart
// WRONG
final threshold = 200.0;

// CORRECT
/// Minimum free SD space in MB before a new session is refused.
/// At peak load (~155 MB/hr) this provides ~1.3 hours of headroom.
static const double minFreeSpaceMb = 200.0;
```

### Rust Algorithm Comments
Document what the operation does physically, which sci-rs/nalgebra function is used and why,
and input/output units.

```rust
// Suppresses DC offset and low-frequency drift from accelerometer data
// before integration. Uses sosfiltfilt (zero-phase, forward-backward pass)
// to avoid phase distortion that would corrupt velocity and position output.
// sci-rs: butter_dyn() designs coefficients, sosfiltfilt_dyn() applies them.
// Input/output: raw LSB counts, drift removed.
```

### TODO Format
```
// TODO(idl0): description
```
Never use bare `// TODO`.

---

## 5. Error Handling

- All data/transport failures throw typed exceptions — never `Exception('something went wrong')`
- Hard crashes in response to bad data are never acceptable
- Corrupt/truncated log → recover what's readable, surface a warning
- Missing math channel reference → inline validation error, don't block other channels
- BLE/WiFi failure → retry with backoff, surface status, never hang

See `docs/IDL0_SPEC.md §16` for the full exception hierarchy.

---

## 6. Done Checklist

- [ ] `cargo test` passes (if Rust was touched)
- [ ] `flutter test` passes with zero failures (if Dart was touched)
- [ ] Coverage targets met for the affected layer
- [ ] All public symbols have doc comments with units where applicable
- [ ] Rust functions document which sci-rs/nalgebra call is used and why
- [ ] No bare TODOs — all use `// TODO(idl0):`
- [ ] No silent deviations from spec
- [ ] CHANGELOG.md updated if this is a meaningful change

---

## 7. Building (cargokit)

The Rust engine is cross-compiled and bundled **automatically** for every
platform by the **`rust_lib_idl0` cargokit plugin** (`app/rust_builder`, a
`flutter_rust_bridge` `rust_builder`). On every `flutter run` / `flutter build`
(Windows, Android, macOS, Linux, iOS), cargokit builds the `/rust/bridge`
crate (`idl_rs_bridge` cdylib, which links the pure `idl-rs` core) and bundles
the resulting library next to the app / into the APK. No `.so`/`.dll` files are
committed. cargokit auto-installs missing rustup targets.

The build is wired per platform in `app/rust_builder/<platform>/` — each points
cargokit at `../../../rust/bridge` with `libname = idl_rs_bridge`. There is **no
hand-rolled cargo hook** (the old `cargoBuildRust` Gradle task and Windows
`build_rust_release.bat` were removed in the cargokit migration).

> **Crate-name note:** the bridge *package* is `idl_rs_bridge` (underscores),
> not `idl-rs-bridge` — cargokit derives the expected cdylib filename from the
> package name without dash→underscore normalization, so the package name must
> match the `idl_rs_bridge` cdylib. It is the unpublished FRB shim; the
> published `idl-rs` engine + `idl-rs-cli` keep their dashed brand names.

**No manual step is needed after editing `rust/core/src/` or
`rust/bridge/src/`** — cargokit rebuilds on change.

Note: changing a Rust **function signature** (not just its body) still
requires regenerating the Dart bindings with `flutter_rust_bridge_codegen
generate` — that is dev-machine codegen, separate from the build.

Prerequisites (one-time): a Rust toolchain, and the Android NDK (28.x via
Android Studio SDK Manager) for Android builds. cargokit installs the per-target
rustup targets itself; `cargo-ndk` is no longer required.

---

## 8. Key Files

| File | Purpose |
|------|---------|
| `docs/IDL0_SPEC.md` | Master spec — source of truth (binary format §5, calibration §9/§20, math expressions §19) |
| `docs/signal_pipeline.md` | DSP pipeline with equations |
| `docs/design_rationale.md` | Why of architectural decisions |
| `docs/workbook_format.md` | `.idl0wb` workbook + math-channel authoring reference |
| `TASKS.md` | Build queue — current task is at the top |
| `rust/` | Cargo workspace submodule: `idl-rs` engine (core), `idl-rs-bridge` (FRB shim), `idl-rs-cli` (`idl-rs` binary) |

## 9. Spec Discipline

The spec (docs/IDL0_SPEC.md) is the contract between human, agent, and
future contributors. The README invitation is "clone the repo, read
the spec, ship work." Anything that breaks that invitation is a bug.

Every task has one of three spec dispositions, declared up front:

1. **Spec-first.** Architectural changes, schema bumps, new entities,
   new tab/section in the app, new file format, new public API. Agent
   proposes the spec change BEFORE writing code. Human approves the
   spec text. Implementation must match.

2. **Spec-during.** Additive features within an existing architectural
   surface. Agent updates the relevant spec section in the same PR as
   the code. Both reviewed together.

3. **No spec change needed.** Bug fixes, refactors, internal cleanup.
   Agent must explicitly state this in the task plan. Silent
   no-spec-change is not allowed — say it out loud.

Done is defined by the spec, not by the agent's judgement. A task is
not complete until either:
  - The spec section it implements describes the shipped behaviour, OR
  - The agent has stated "no spec change needed" with reasoning.

When in doubt, ask before assuming. CLAUDE.md §2 (ambiguity policy)
applies — silence is not approval.

---

## 10. Documentation Artifacts

Five artifacts, each with a clear role. Do not confuse them.

| Artifact | Role | Audience | When updated |
|----------|------|----------|--------------|
| `README.md` | Front door. What IDL0 is, who it's for, links to SPEC and CLAUDE.md, quickstart. | Someone who has never seen the repo. | Audience-facing description changes (new tab, major capability, platform). |
| `docs/IDL0_SPEC.md` | The contract. WHAT the system does. Forward-looking. | Agents and contributors building the system. | Per spec disposition rules in §9. |
| `docs/design_rationale.md` | WHY of architectural decisions. Tradeoffs accepted, alternatives rejected. | Future contributors who need to know "why this way?" | Spec-first tasks land here when architectural. |
| `CHANGELOG.md` | Log of shipped changes. WHAT was shipped, dated. | Anyone reviewing what's recently changed. | One line per material change, appended at task end. |
| `TASKS.md` | Work queue. Active tasks at top, completed below the line, blocked separate. | Human and agents planning next work. | Tick boxes as work ships; add new entries when follow-ups are spotted. Historical entries stay accurate. |

Every task touching shipped behaviour writes to **at least one** of CHANGELOG and TASKS, plus SPEC if disposition is spec-first or spec-during. `design_rationale.md` gets an entry only on architectural turns. `README.md` updated only when audience-facing description changes.

Use `docs/prompt_template.md` for every task prompt. Its done-checklist enforces the artifact-set rule above.
