# Frequency Response (Bode + Coherence) Chart — Design

**Date:** 2026-07-10
**Status:** Approved design, pre-implementation
**Spec disposition:** Spec-first (new `ChartType`, new engine public API, new bridge
surface — spec text lands before code, per CLAUDE.md §9)

---

## 1. Goal

Characterize the suspension (and, as far as the data allows, the rider) as a
system, using the frequency-response function between an unsprung IMU
(IMU1 front-fork or IMU2 rear-swingarm — road-side input) and the sprung IMU
(IMU0 chassis — response), computed directly from acceleration channels.

This deliberately avoids chasing absolute suspension displacement. The
existing offline suspension estimator already reconstructs travel/velocity via
an IEKF, but going a layer deeper into the AC (acceleration) data sidesteps
integration and DC-drift entirely: `H1(f) = Pxy(f)/Pxx(f)` computed
accel-to-accel needs no integration at all.

Trail and rider inputs are almost entirely transient/broadband, never
periodic — that is not a blocker for this technique, it's the intended
excitation type. Welch-averaged cross/auto-spectral density (H1 estimator)
plus the coherence function `γ²(f) = |Pxy(f)|²/(Pxx(f)·Pyy(f))` is the
standard way vehicle-dynamics work extracts road-to-body transfer functions
from real-world (non-stationary) driving. Coherence is also the tool for
gauging where the estimate is trustworthy — it drops wherever something
other than the chosen input (rider input, a second uncorrelated path, noise)
is contributing to the output. There's no direct rider-input sensor, so the
rider's contribution isn't separable into its own transfer function — it
shows up mainly as coherence loss, not as a channel of its own.

**Deliverable:**
1. Rust engine primitives — `csd()`, `frequency_response()` — hand-rolled on
   the existing `stft()` primitive.
2. Bridge exposure mirroring the existing Welch pipeline.
3. A new `ChartType.bode` in the Analyze tab: gain / phase / coherence vs.
   frequency for a chosen input/output channel pair, built from a pane
   primitive shared with the existing FFT chart.

## 2. Architecture decisions

### 2.1 Engine: hand-roll on the existing `stft()`, no new dependency

Investigated `scirs2-signal` — it has exactly this
(`sysid::estimate_frequency_response(input, output, fs, method, config) ->
{frequency_response, frequencies, coherence, confidence_bounds}`, gain+phase+
coherence in one call). **Rejected:**

- **Maturity.** `scirs2` (github.com/cool-japan/scirs) is a solo/small-team
  effort porting the entirety of SciPy+NumPy+Pandas (+ quantum computing) to
  Rust across 500+ crates. `scirs2-signal` specifically: 71 downloads/month,
  26 releases with 5 breaking changes in ~13 months, latest release 8 days
  old at time of writing. Not the stable-foundation risk profile the rest of
  `idl-rs`'s dependencies (`nalgebra`, `rustfft`) have.
- **Forks the FFT backend.** `scirs2-signal` runs on `scirs2-fft`'s own
  `oxifft` backend, not `rustfft`/`realfft` (already depended on, already
  load-bearing for the shipped FFT/Spectrogram charts). Adopting it for real
  means either two FFT backends living in the binary indefinitely, or
  rewriting and re-verifying the already-shipped, already-tested
  `fft()`/`welch()`/`spectrogram()` against a different backend — real
  regression risk on working charts for zero user-facing gain.
  `scirs2-linalg` also pulls in a pure-Rust BLAS/LAPACK ("OxiBLAS"), the kind
  of dependency that has historically caused significant binary bloat; actual
  compiled-size impact was never measured because the rest of the analysis
  already ruled it out.
- **API mismatch.** `ndarray`-based (`Array1<f64>`), where the rest of
  `idl-rs` uses plain `Vec<f64>` in, struct out.
- **No comparable alternative exists either.** `sci-rs` (already a
  dependency) was re-checked directly: its `signal` module is
  `convolve`/`filter`/`resample`/`wave` only — no spectral analysis, which is
  why `welch()` was hand-rolled in the first place. `signal_processing`
  (sigurd4, the other scipy.signal-alternative on crates.io) is worse on
  every axis: last release May 2024, marked nightly/experimental, several
  dependencies flagged obsolete, no CSD/coherence/system-ID coverage at all
  (filter-design only), and a *larger* footprint (70 MB/1M SLoC) than
  `scirs2`. The Rust ecosystem does not currently have a mature,
  widely-adopted `scipy.signal` equivalent.

**Decision:** `csd()` and `frequency_response()` are hand-rolled on the
existing `stft()` primitive (`fft.rs`'s doc comment already anticipated this:
*"kept complex so phase is available to future transfer-function / coherence
/ Hilbert work"*), in the same `Vec<f64>`-in/struct-out convention as
`welch()`. One FFT backend, one convention. Future DSP techniques
(multitaper, AR/Burg PSD, wavelets, ...) get evaluated and added the same way,
one at a time, rather than adopting a broad, young dependency speculatively.
Exploratory prototyping against real SciPy (outside the Rust engine
entirely) is the preferred way to decide whether a technique is worth
porting at all, per the existing house convention
(CLAUDE.md: *"Function signatures mirror scipy where possible"*).

*(This rejection is a good candidate for a `docs/design_rationale.md` entry —
add it when this work lands, per CLAUDE.md §10.)*

### 2.2 UI: new sibling `ChartType.bode`, sharing a pane primitive with FFT

Considered merging FFT (+ possibly Spectrogram) and Bode into one
`ChartType.frequencyDomain` with an internal mode selector. **Rejected:**
FFT takes a channel *list* (N arbitrary channels/laps, overlaid in one pane);
Bode takes a channel *pair* (input/output roles). Merging the enum doesn't
reduce branching — it relocates a `chartType`-switch into a `mode`-switch one
level deeper, identical complexity, while hiding two distinct, well-known
concepts behind one vague Add-Chart picker entry. There's already a directly
comparable precedent in this codebase: `Spectrogram` is also spectral
content (same `welch`/`stft` engine calls as FFT) and is already its own
`ChartType`, not merged with FFT, because its rendering shape (heatmap)
differs enough to warrant a separate picker entry. Bode's shape (3 stacked
panes, incompatible units — dB, degrees, 0–1 ratio, can't be overlaid) differs
from FFT's (1 pane, N overlaid same-unit lines) for the same kind of reason.

What *is* genuinely shared: FFT's single pane and each of Bode's three panes
are the same primitive — a log-frequency x-axis, one y-quantity, N line
series. That gets extracted into a `FrequencyDomainPane` widget:
- `FftChart` = one `FrequencyDomainPane` with N overlaid lines (unchanged
  behavior, refactored onto the shared primitive)
- `BodeChart` = a `Column` of three `FrequencyDomainPane`s (Gain dB / Phase° /
  Coherence), sharing the x-axis

Two `ChartType`s, two picker entries, two `ChartSlot` field-sets (mirroring
how `scatterXChannelId`/`scatterYChannelId` already coexist with FFT's fields
in one `ChartSlot` class, gated by `chartType ==`) — but one shared rendering
primitive underneath instead of duplicated axis math.

## 3. Components & layer placement

### 3.1 Rust core — `rust/core/src/frequency_response.rs` (new file)

```rust
/// One-sided cross power spectral density Pxy(f) via Welch's method —
/// average of X_i(f) * conj(Y_i(f)) across segments. Calls the existing
/// stft() on both x and y with identical segmentation so csd/psd bins are
/// always aligned with welch()'s.
pub fn csd(x: Vec<f64>, y: Vec<f64>, sample_rate_hz: f64, window: FftWindow,
    nperseg: usize, noverlap: usize, detrend: Detrend) -> CsdResult

pub struct CsdResult { pub freqs_hz: Vec<f64>, pub re: Vec<f64>, pub im: Vec<f64> }

/// Frequency response + coherence between an input and output signal via the
/// H1 estimator: H1(f) = Pxy(f) / Pxx(f). Coherence:
/// gamma^2(f) = |Pxy(f)|^2 / (Pxx(f) * Pyy(f)).
pub fn frequency_response(input: Vec<f64>, output: Vec<f64>, sample_rate_hz: f64,
    window: FftWindow, nperseg: usize, noverlap: usize, detrend: Detrend)
    -> FrequencyResponseResult

pub struct FrequencyResponseResult {
    pub freqs_hz: Vec<f64>,
    pub gain_db: Vec<f64>,     // 20*log10(|H1|)
    pub phase_deg: Vec<f64>,   // unwrapped
    pub coherence: Vec<f64>,   // 0..1
}
```

**Scope cut:** `Averaging::Median` (already used by `welch()`) is not offered
for `csd`/`frequency_response` — there is no total order on complex `Pxy`, so
"median across segments" isn't well-defined the way it is for a real-valued
PSD. Mean averaging only for this pass.

### 3.2 Bridge — `rust/bridge/src/session.rs`

```rust
pub fn frequency_response_channels_windowed(
    handle: &SessionHandle, input_channel_id: String, output_channel_id: String,
    t0_secs: f64, t1_secs: f64, window: crate::fft::FftWindow,
    nperseg: u64, noverlap: u64, detrend: Detrend,
) -> FrequencyResponseResult
```

Mirrors `welch_channel_windowed`'s existing pattern exactly — reads both
channels' windowed samples from the retained handle, no bulk sample transfer
across FFI, only the result struct crosses.

### 3.3 Dart data layer

- `bodeResponseProvider` — `FutureProvider.autoDispose.family`, mirrors
  `fftSpectrumProvider`.
- `ChartSlot` gains `bodeInputChannelId` / `bodeOutputChannelId` (mirrors
  `scatterXChannelId`/`scatterYChannelId`), reuses the existing
  `SpectralParams` block for window/segment/overlap/detrend.
- New `ChartType.bode` + `chart_type_catalog.dart` entry (icon, label
  "Bode", blurb, accent color).
- `FrequencyDomainPane` — shared widget (log-freq x-axis, decade gridlines,
  y-label/y-scale/y-range, N line series), extracted from the log-freq-axis
  logic currently private to `fft_chart.dart`.
- `FftChart` refactored to compose one `FrequencyDomainPane`.
- New `bode_chart.dart` (`BodeChart`): a `Column` of three
  `FrequencyDomainPane`s. Chart properties dialog gets an input/output
  channel-pair picker, reusing the existing picker pattern from scatter's
  X/Y channel selection.

## 4. Error handling

Per CLAUDE.md §5 — typed exceptions, no hard crashes:
- Input/output channel not fixed-rate, or mismatched sample rates → typed
  error, same message pattern as FFT's existing "requires a fixed-rate
  channel."
- Empty time window → empty result, matching `welch()`'s existing behavior.

## 5. Testing

- **Golden fixtures against real scipy.** A checked-in
  `scripts/gen_golden_spectral.py` (needs `scipy`/`numpy` only when
  *regenerating* fixtures — not for `cargo test`) builds known input/output
  pairs (a simulated single-pole system, clean and with added uncorrelated
  noise), runs `scipy.signal.csd`/`coherence` on them, and saves the expected
  arrays to `rust/core/tests/fixtures/`. `cargo test` reads the fixture and
  asserts closeness (`assert_relative_eq!`) against it.
- **Hand-derived physical sanity tests**, per the existing house style:
  coherence ≡ 1 when output = input (no noise); coherence drops under added
  uncorrelated noise; a pure time delay preserves gain = 1 with
  `phase = -2π·f·τ`.
- **Dart:** resolver unit test mirroring `fft_window_resolver_test.dart`
  (pure function, no bridge).

## 6. Spec & documentation (CLAUDE.md §9/§10)

- **Spec-first.** `docs/IDL0_SPEC.md` section text (new ChartType, new engine
  API) is drafted and approved during the plan phase, before implementation.
- **`design_rationale.md`**: add an entry for the `scirs2` rejection when
  this work lands (§2.1 above is the source material).
- **CHANGELOG.md**: one line on ship.
- **TASKS.md**: add entry.

## 7. Out of scope / explicit follow-ups (YAGNI)

- Lap-mode for Bode (one curve per selected lap, same channel pair) — FFT
  already resolves this pattern (`fft_window_resolver.dart`); straightforward
  fast-follow, not required for v1.
- `Averaging::Median` for `csd`/`frequency_response`.
- Multitaper / AR-Burg / wavelet exploration — separate follow-up tasks,
  prototyped against real scipy first (§2.1), ported by hand only once
  proven useful.
