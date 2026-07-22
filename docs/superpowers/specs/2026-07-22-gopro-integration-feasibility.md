# GoPro Integration — Feasibility Study

**Date:** 2026-07-22
**Status:** Feasibility / pre-spec (no code, no spec change yet)
**Spec disposition when this proceeds:** **spec-first** — new external device, new
control surface on the firmware, new session-linking concept, new hardware
(physical buttons), likely a new UI section. Per CLAUDE.md §9, the spec text
lands and is approved *before* implementation.

**Decision recorded (2026-07-22, project owner):** control topology is
**device-side** — the ESP32 is the BLE controller of the GoPro, so one physical
button on the logger starts/stops *both* devices fairly in sync. The GoPro's
files go **straight to the phone over the GoPro's own WiFi AP**; the ESP32 never
joins the GoPro over WiFi. Auto co-trigger; Android-first for the phone's WiFi
pull. This revision reflects that decision; §4 records the analysis behind it,
including a correction to an earlier draft that overstated the objections.

---

## 1. Executive summary

**Verdict: feasible, and the app is already two-thirds of the way there.** IDL0
already parses GoPro telemetry (GPMF), already time-aligns a GoPro `.mp4` to a
session on the GPS-UTC clock (`video::sync`, confidence 0.9), already renders
burned-in overlays from that footage, and already has a workspace slot for
per-session video links (`videos[]`, workspace v8). What does **not** exist yet
is the *acquisition* half: **controlling** the camera and **pulling files off
it**, then linking the downloaded clip to the matching session automatically.

The GoPro **Open GoPro API** (HERO 9 Black and later) exposes exactly the two
transports we need — a BLE GATT control service and a WiFi HTTP media API — so
no reverse-engineering is required.

**Control topology (decided): the ESP32 controls the GoPro over BLE.** A physical
button on the logger — or the app's existing `CMD_START_LOGGING` — starts the
IDL0 session and, in the same firmware action, sends the GoPro its shutter-on
command. One touch, both roll, within a fraction of a second; GPMF GPS-UTC sync
cleans up the residual offset at ingest. File transfer stays phone-centric: the
GoPro raises its own WiFi AP and the **phone** pulls the clips — the ESP32 is
BLE-only to the camera and never touches the GoPro's AP.

---

## 2. What already exists (the head start)

These are shipped, tested pieces of the exact pipeline GoPro footage feeds into.
None of this needs to be built:

| Capability | Where | Relevance to GoPro |
|---|---|---|
| GPMF KLV parsing (`DEVC→STRM→GPS5/GPS9`, `SCAL`, `GPSU`) | `idl-rs` `video::gpmf` (SPEC §33.3) | GPMF *is* GoPro's on-camera telemetry format. We already read the camera's embedded GPS. |
| ISO-BMFF walker, no ffmpeg (`gpmd` track, `mvhd creation_time`, track dims/fps) | `idl-rs` `video::mp4box` | Reads GoPro `.mp4` containers directly. |
| Video↔session time sync | `idl-rs` `video::sync::estimate_sync` → `SyncEstimate{offset_s, confidence, method}` (SPEC §33.3) | `gpmf` method: GoPro GPS-UTC vs session `GPS_EpochMs` clock, **confidence 0.9**. Already solves the "which video frame lines up with which log sample" problem *post-hoc*, independent of how sloppy the start-of-recording trigger is. |
| Per-session video links | workspace `videos[]`, workspace_version 8 (SPEC §15.4) | `path`, `file_size_bytes`, `file_mtime_ms`, `sync_offset_s`, `sync_method`, `sync_confidence`, `label`. The linking + re-link-on-move machinery is done. |
| Burned-in overlay render + export | `idl-rs` `video::render`, `video-export` crate, `idl-rs overlay` CLI (SPEC §33.4–33.6) | The end consumer of GoPro footage already works headless. |
| BLE central role on a phone-facing device | SPEC §7.5 (HRM strap over NimBLE central) | Proves the *pattern* of "connect out to a standard GATT peripheral, subscribe, read" — but see §4 for why the phone, not the ESP32, should host the GoPro link. |
| WiFi-AP file transfer with resumable HTTP + Android per-socket routing | `wifi_transfer.dart`, `wifi_network_binder.dart`, link reconciler (SPEC §6.1–6.2) | The GoPro is *also* a WiFi AP serving files over HTTP. The hard-won Android "AP has no internet → bind the socket, keep the reconciler" work is directly reusable in shape. |

The missing third: **camera control + camera file pull + auto-link on download.**

---

## 3. The GoPro Open API surface (what we'd build against)

Open GoPro is GoPro's official, documented, versioned developer API (HERO 9 and
later; HERO 13 is current). No hacks. Two transports matter to us; a third (USB)
is out of scope.

**Sources:**
[Open GoPro docs](https://gopro.github.io/OpenGoPro/docs/),
[BLE spec](https://gopro.github.io/OpenGoPro/ble/),
[HTTP spec](https://gopro.github.io/OpenGoPro/http),
[Commands & settings](https://deepwiki.com/gopro/OpenGoPro/2.2-commands-and-settings-api).

### 3.1 BLE control (GoPro is a GATT **peripheral**; the controller is central)

- **Service** `0000FEA6-…` (GoPro assigned 16-bit `0xFEA6`); command/query/
  settings characteristics under GoPro's `b5f9xxxx-…` base UUID (request +
  notify-response pairs).
- **Start/stop recording:** the "shutter" command (`set_shutter` on / off).
- **Enable the camera's WiFi AP:** an "AP control" command — you turn the
  camera's AP *on over BLE*, read back its SSID/password (query), then join it
  for file transfer.
- **Set date/time / GPS:** ensures the camera stamps GPMF GPS-UTC we sync on.
- **Query status:** battery, SD space, encoding state, busy — mirrors our own
  §7.3 status feed.
- **Keep-alive:** the camera expects a periodic BLE keep-alive (~every few
  seconds) or it sleeps / tears down its AP. This is the one ongoing obligation
  of whoever holds the BLE link (relevant to §4).

> Exact opcodes/UUIDs are versioned per camera in the Open GoPro spec and **must
> be pinned at implementation time against the target models' spec tables** —
> CLAUDE.md §2 (no guessing field encodings). They are stable and published; this
> study does not hard-code them.

### 3.2 WiFi HTTP transfer (GoPro is the **AP**; phone is the client)

- Camera AP; client base `http://10.5.5.9:8080`.
- **Media list:** `GET /gopro/media/list` → JSON of files with sizes.
- **Download:** `GET` the media path (range/resumable in shape like our
  `/download?file=`).
- Same shape as our device's `/files` + `/download` (SPEC §6.1), so the
  `wifi_transfer.dart` design generalizes cleanly.

### 3.3 Telemetry (already handled)

GoPro embeds GPS + IMU as GPMF in the `.mp4`. Requires GPS enabled on the camera
(a setting we can push over BLE). We already parse it (§2). This is what makes
**auto time-sync** work without any hardware trigger wire.

---

## 4. Control topology: the ESP32 controls the GoPro (decided)

The chosen split: **the ESP32 owns the GoPro's BLE control link during recording;
the phone owns the GoPro during file transfer.** Rationale below, including a
correction to an earlier draft of this study that recommended against device-side
control — that draft over-weighted two objections that don't actually bind here.

### Why device-side control is the right call

- **One touch, both devices.** The owner is adding physical start/stop buttons to
  the logger; the point is a single trailhead action that starts logging *and*
  the camera, without fishing a phone out at the line. Only the device can do
  that. The GoPro's own on-camera button doesn't help — it can't also start the
  logger. So the trigger must live on the logger, and the logger must reach the
  camera → device-side BLE control.
- **The co-trigger is uniform regardless of trigger source.** Because the ESP32
  is the one talking to the GoPro, *any* start — physical button or the app's
  `CMD_START_LOGGING` (SPEC §7.2) — co-starts the camera. The app doesn't need
  its own camera-trigger path; it just starts logging as it does today.
- **Sync is good enough, and GPMF finishes the job.** A BLE shutter write is tens
  of ms; camera spin-up adds up to ~1 s. "Fairly in sync" is met, and the residual
  is corrected *post-hoc* by GPMF GPS-UTC at confidence 0.9 (§2) at ingest — so
  frame-accuracy is never riding on the trigger latency.

### Correcting the earlier draft's two objections

1. **"Keep-alive violates *zero processing while logging*."** — Overstated.
   CLAUDE.md §2 / SPEC §1's absolute is that **analysis DSP** (filtering,
   integration, FFT) never runs on the device; the "raw bytes to SD, nothing
   else" clause is about not signal-conditioning the log and spending minimum
   clock cycles. A ~3 s BLE keep-alive is control-path work, and it is *less* than
   the HRM notification handling (HR_BPM / HR_RR CHANNEL_SAMPLE writes) the
   firmware already performs during logging (SPEC §7.5). The project owner has
   explicitly ruled this acceptable and part of the recording-control path. It is
   **still a deliberate deviation from the literal §1 text**, so it must be
   written into the spec as an approved carve-out (§8 here) and recorded in
   `design_rationale.md` — not left implicit. CLAUDE.md §9: the human approves
   the spec text; that approval is on record.
2. **"SoftAP+BLE is C1-unstable, so a third BLE link fights coexistence."** —
   Does not apply to the recording phase. `CMD_WIFI_ON` and `CMD_START_LOGGING`
   are **mutually exclusive** (SPEC §7.2): while logging, the ESP32's SoftAP is
   **off**. The GoPro control link is therefore **BLE-only, with no SoftAP
   running**, coexisting with the HRM central link the firmware *already* holds
   during logging. The "C1 — unstable" table entry (SPEC §7.5/§10.4) is a
   SoftAP+BLE problem; there is no SoftAP up while recording, so it doesn't bind.
   And crucially — per the owner — **the ESP32 never joins the GoPro over WiFi**;
   the GoPro streams its files straight to the phone over the GoPro's own AP. So
   no third-AP juggling exists on the device at all.

### What genuinely remains (care-points, not blockers)

- **`CONFIG_BT_NIMBLE_MAX_CONNECTIONS` 2 → 3.** During logging the device holds
  three links: phone (peripheral, status notify), HRM (central, ~1 Hz notify),
  GoPro (central, ~0.3 Hz keep-alive). NimBLE supports this; cost is a little RAM
  per connection and connection-interval tuning so the radio serves all three
  without starving the SD-write path. The rates are low, but this wants
  validation on real hardware — it is the one firmware risk worth a bench test
  early.
- **The GoPro almost certainly accepts one BLE central at a time.** So the *record*
  phase (ESP32↔GoPro) and the *transfer* phase (phone↔GoPro) can't overlap on
  BLE. Two clean options — a design fork to settle in the spec, not now:
  - **(a) Hand-off.** After stop, the ESP32 drops the GoPro; the **phone**
    connects BLE to the GoPro to enable its AP + keep-alive, then pulls files.
    Cost: a GoPro-BLE implementation on *both* sides (firmware for record, Dart
    for transfer).
  - **(b) ESP orchestrates.** The ESP32 keeps the GoPro BLE link, enables the AP
    over BLE, hands the SSID/password to the phone (over the existing phone↔ESP
    link), and keep-alives the AP while the phone pulls. Cost: one GoPro-BLE
    implementation (firmware only) but a device-side transfer state machine.
    *(a) is simpler to reason about; (b) keeps all GoPro protocol knowledge in
    one place.*
- **Physical buttons are new hardware + firmware.** GPIO with debounce, ISR-queued
  like the existing hall-sensor pattern (SPEC §3.5). Touches SPEC §3 (Hardware)
  and §10 (Device Behavior).
- **Paired-GoPro identity in config.** A stored camera address (peer of
  `heart_rate_monitor.device_address`, SPEC §8) so the device knows which camera
  to command.

---

## 5. Constraints & gotchas (all surmountable)

1. **A phone joins only one WiFi AP at a time.** The IDL0 device is an AP *and*
   the GoPro is an AP. You **cannot** be on both simultaneously → **file
   transfer is inherently sequential**: pull the GoPro's clips over its AP, tear
   down, then pull the IDL0 log over its AP (or vice-versa). This matches the
   owner's phrasing ("once everything's been downloaded from the respective
   devices"). The transfer orchestrator (phone-side) must own this as an explicit
   sequential state machine, one AP at a time. Note this is *only* a phone-side
   concern — the ESP32 never joins the GoPro AP.
2. **Android AP-has-no-internet routing.** The GoPro AP hits the *same* Android
   10+ problem the IDL0 AP already solved: traffic wants to escape to cellular.
   Reuse the `idl0/wifi_network` binder pattern (per-socket loopback proxy,
   `WifiNetworkSpecifier`, the single-flight link reconciler — SPEC §6.2)
   generalized to "the AP I'm currently pulling from." This is design reuse, not
   a copy — one reconciler that can target either SSID.
3. **GoPro BLE keep-alive during recording.** The ESP32 must send a periodic
   keep-alive (~3 s) or the camera sleeps. This is the one **explicit deviation**
   from SPEC §1's "raw bytes to SD, nothing else while logging" — approved by the
   owner as control-path work (§4), and it must be written into the spec as a
   carve-out, not left implicit (§8). Load: below the HRM handling already done
   during logging.
4. **GPS must be enabled on the camera**, or GPMF carries no GPS-UTC and sync
   degrades from `gpmf` (0.9) to `creation_time` (0.3). The ESP32 can push the
   GPS-on setting over BLE at pairing time; the phone-side ingest warns if a
   pulled clip lacks a GPS stream.
5. **iOS WiFi-join friction (deferred — Android-first).** iOS restricts
   programmatic AP joins (`NEHotspotConfiguration`, entitlement-gated) far more
   than Android. Per the scope decision, the phone's GoPro-AP pull is
   **Android-first**; iOS (if ever) gets a guided "join the GoPro network" step.
   BLE control is device-side and platform-independent, so this only affects the
   phone's file pull.
6. **Model coverage.** Open GoPro is HERO 9+. Older cameras and non-GoPro
   action cams are out. Worth stating a supported-models list in the spec. Note:
   the ESP32 must implement the GoPro BLE command set for the target models
   (opcodes are model-versioned in the Open GoPro spec).
7. **Clip granularity & chaptering.** Long GoPro recordings split into chaptered
   files; a single session may map to *several* `.mp4` files. `videos[]` is
   already an array (SPEC §15.4), so the model handles it — but the auto-linker
   must group a chaptered set and sync each chapter's own GPMF.

---

## 6. Proposed end-to-end workflow (device-controlled record, phone-side ingest)

1. **Pair** the GoPro once (BLE bond from the ESP32; store the camera address in
   `idl0_config.json`, peer of `heart_rate_monitor.device_address`, SPEC §8).
   Push GPS-on + set time over BLE so GPMF carries a good UTC anchor.
2. **Record:** the rider presses the logger's **physical start button** (or the
   app sends `CMD_START_LOGGING`). The firmware starts the session and, in the
   same action, sends the GoPro `set_shutter on` over its BLE central link.
   Stop → session ends + `set_shutter off`. Keep-alives run for the duration.
   Loose sync is fine (§4); GPMF corrects it later.
3. **Ingest (sequential, phone-side, §5.1):**
   a. Bring up the GoPro's AP — either the ESP32 enables it over BLE and relays
      SSID/pw to the phone (fork **b** in §4), or the phone connects BLE to the
      GoPro and enables it itself (fork **a**).
   b. Phone joins GoPro AP (reconciler), `GET /gopro/media/list`, downloads new
      clips with resume. Tear down.
   c. Phone joins IDL0 AP, pulls new `.idl0` logs as today (SPEC §24). Tear down.
4. **Auto-link:** for each downloaded session and each downloaded clip, run the
   existing `estimate_video_sync` (§33.3) against the retained `SessionHandle`.
   Overlapping clip → write a `videos[]` entry with the estimated offset. No
   overlap → don't link (surface as "unmatched footage"). This is
   "link them with sessions once everything's downloaded" — *mostly already
   built*; it just needs driving automatically after a GoPro pull instead of only
   on manual file-pick.
5. **Analyze/Export:** unchanged — overlay render already consumes `videos[]`.

---

## 7. Session-linking design (small, mostly reuse)

The `videos[]` model (SPEC §15.4) already carries everything except *provenance*
and a couple of camera fields. Likely additive fields (spec-during within §15.4,
plus new persistent device state):

- `source: "manual" | "gopro"` on the video link (so re-ingest can dedupe by
  camera + on-camera filename rather than only by path/size/mtime).
- A camera identity + on-camera filename to make re-download idempotent.
- A **paired-camera** record (address, model, label) in `idl0_config.json`
  alongside the HRM entry (SPEC §8) — the ESP32 reads it to know which camera to
  command; the app reads it to label footage. This is the new persistent state.

Auto-link acceptance stays exactly as §15.4 already defines it: overlap-checked,
GPMF-preferred, manual-offset-preserving, re-link-on-move via size+mtime. We are
feeding an existing intake, not inventing one.

---

## 8. Spec impact (for the follow-up spec-first task)

| Section | Change |
|---|---|
| **New §34 "GoPro / Action Camera Integration"** (Part 9 video, or new Part) | The whole story: pairing, the ESP32's GoPro BLE command set, co-trigger behavior, phone-side WiFi ingest, sequential-AP orchestration, auto-link. |
| **§1 System Philosophy** | **Carve-out:** the "raw bytes to SD, nothing else while logging" clause explicitly permits the GoPro BLE keep-alive/control as recording-control work. Analysis-DSP-never-on-device is untouched. This is the approved deviation (§4). |
| **§3 Hardware** | Physical start/stop button(s): GPIO, debounce, wiring. |
| **§7 BLE** | The device's **central** link to the GoPro (a second central alongside HRM); `MAX_CONNECTIONS` 2→3; the GoPro GATT surface and command opcodes used; the record-phase vs transfer-phase BLE-ownership fork (§4). |
| **§8 Configuration** | Persisted paired-camera record (address, model, label), peer of `heart_rate_monitor`. |
| **§10 Device Behavior** | Button-driven start/stop; GoPro co-trigger on any logging start/stop; keep-alive lifecycle; AP-enable-for-transfer orchestration if fork **b**. |
| **§6 / new §6.x** | Phone-side: GoPro WiFi AP as a *second* AP target; generalize the reconciler's "which SSID" ownership; Android-first. |
| **§15.4 `videos[]`** | Additive `source` + camera provenance fields (spec-during). |
| **UI (§22–27)** | Camera pairing/status/ingest — likely the Device tab (pairing + record indicator) and the Data tab (ingest + unmatched-footage). |
| **design_rationale.md** | Record the device-vs-phone control decision, the §1 keep-alive carve-out and why it's acceptable, and the record/transfer BLE-ownership fork. |

## 9. Effort & phasing (rough)

- **Phase G0 — firmware BLE bring-up (bench):** `MAX_CONNECTIONS=3`, GoPro BLE
  central (connect/bond, shutter on/off, GPS-on, keep-alive), validate 3-link
  scheduling doesn't starve the SD-write path. *Medium-high* — the one real
  firmware risk; do it first on hardware.
- **Phase G1 — co-trigger + buttons:** GPIO start/stop; on logging start/stop,
  co-command the paired GoPro; paired-camera config field. *Medium* (firmware).
- **Phase G2 — phone-side GoPro WiFi ingest:** generalize the AP reconciler to a
  second SSID; `transport/gopro/` (BLE AP-enable if fork **a**, media list +
  resumable download); sequential-AP orchestrator. *Medium-high* (Dart).
- **Phase G3 — auto-link on ingest:** drive `estimate_video_sync` after a pull;
  write `videos[]`; chaptered-clip grouping; unmatched-footage surface. *Low-
  medium* — reuses §33.3 + §15.4.
- **Phase G4 — UI:** pairing flow, record/camera status, ingest progress,
  unmatched footage. *Medium.*

The heavy engine work (GPMF, sync, overlay) is **already done**. Net new work is
firmware (GoPro BLE central + buttons + co-trigger), a phone-side
`transport/gopro/` ingest layer reusing the existing WiFi reconciler, an
auto-link step on the existing `estimate_video_sync`, and a modest UI.

## 10. Settled decisions & remaining open questions

**Settled (project owner, 2026-07-22):**
- Control topology: **ESP32 controls the GoPro over BLE** (device-side).
- Co-trigger: **auto** — logging start/stop co-starts/stops the camera.
- File path: **GoPro → phone over the GoPro AP**; the ESP32 never joins GoPro WiFi.
- Phone AP-pull platform: **Android-first**.

**Still open (settle in the spec-first task):**
1. **Record vs transfer BLE ownership** — fork **a** (phone takes over GoPro BLE
   for transfer; two impls) vs fork **b** (ESP orchestrates the AP; one impl,
   device state machine). See §4.
2. **Supported cameras** — Open-GoPro HERO 9+ only, or also a manual "any `.mp4`
   we can sync" path alongside the automated GoPro one?
3. **Button UX** — one button (start/stop toggle) vs separate start/stop; long-
   press semantics; what happens if the GoPro is unpaired/absent at button-press
   (log anyway + warn, presumably).

---

## 11. Bottom line

Feasible, well-supported by GoPro's official Open API, and unusually cheap because
the hard half (telemetry parse, time-sync, overlay, per-session video links)
already ships. The decided architecture — **ESP32 controls the GoPro over BLE for
a one-touch synced start; the phone pulls the footage over the GoPro's own AP** —
is sound: during logging the ESP32's SoftAP is off (WiFi/logging mutex), so the
GoPro control link is BLE-only alongside the existing HRM central link, and the
keep-alive is a negligible, explicitly-approved control-path exception to §1. The
one firmware risk worth an early bench test is three concurrent BLE links not
starving the SD-write path (Phase G0). Everything downstream — ingest, auto-link,
overlay — is Dart transport reuse plus a step wired onto machinery that already
exists, all behind a proper spec-first §34.
