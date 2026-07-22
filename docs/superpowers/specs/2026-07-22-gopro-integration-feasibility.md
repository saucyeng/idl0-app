# GoPro Integration — Feasibility Study

**Date:** 2026-07-22
**Status:** Feasibility / pre-spec (no code, no spec change yet)
**Spec disposition when this proceeds:** **spec-first** — new external device, new
transport surface, new session-linking concept, likely a new UI section. Per
CLAUDE.md §9, the spec text lands and is approved *before* implementation.

---

## 1. Executive summary

**Verdict: feasible, and the app is already two-thirds of the way there.** IDL0
already parses GoPro telemetry (GPMF), already time-aligns a GoPro `.mp4` to a
session on the GPS-UTC clock (`video::sync`, confidence 0.9), already renders
burned-in overlays from that footage, and already has a workspace slot for
per-session video links (`videos[]`, workspace v8). What does **not** exist yet
is the *acquisition* half the user is asking for: **controlling** the camera
(BLE) and **pulling files off it** (WiFi), then linking the downloaded clip to
the matching session automatically.

The GoPro **Open GoPro API** (HERO 9 Black and later) exposes exactly the two
transports we need — a BLE GATT control service and a WiFi HTTP media API — so
no reverse-engineering is required.

**One architectural correction to the user's proposal.** The request was for the
*IDL0 device (ESP32-C6)* to be the BLE controller of the GoPro. That collides
with two hard constraints in this repo and should be rejected in favour of a
**phone-as-hub** design where the phone app is BLE central to *both* the IDL0
device and the GoPro. See §4 — this is the single decision that shapes the whole
project, and it is the one place the user's sketch and the existing architecture
disagree.

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

## 4. The pivotal decision: who is the GoPro's BLE central?

The user proposed: *"ble connect to the idl0 device as a ble host for control."*
Read literally, that makes the **ESP32-C6 the BLE central controlling the
GoPro** (device→camera). There is a second option: the **phone** is BLE central
to both the IDL0 device and the GoPro. This choice determines the entire
project's shape.

### Option A — ESP32 controls the GoPro (device→camera BLE)

*Appeal:* trackside autonomy — press record on the logger and the camera rolls,
no phone needed.

*Why it's the wrong call here:*

1. **Violates "firmware does zero processing while logging" (CLAUDE.md §2,
   SPEC §1).** Holding a GoPro BLE central link means periodic keep-alives and
   status handling *during the logging session*. That is exactly the compute the
   firmware is forbidden from doing mid-session. It is not a mode-boundary
   action; it is a continuous obligation for the whole recording.
2. **Collides with the RF coexistence rule (SPEC §7.5, §10.4).** The ESP32-C6
   already runs NimBLE as peripheral (phone) **+** central (HRM), `MAX_
   CONNECTIONS=2`, and the coexistence table marks SoftAP+BLE as "C1 — unstable"
   — so the firmware already *drops* the HRM link whenever WiFi turns on. Adding
   a *second* central link (GoPro) means `MAX_CONNECTIONS=3`, a third scheduled
   BLE role on one radio, and a direct fight with the same coexistence limit that
   already forced HRM to be dropped. This is a firmware-stability risk, not a
   feature toggle.
3. **The GoPro's own WiFi AP can't be reached by the ESP32 anyway.** File
   transfer must happen over the camera's AP to *the phone*. So even in Option A,
   the phone still does the WiFi pull. Option A only moves the *control* link
   onto the already-overcommitted device radio, for marginal benefit.
4. **Sync doesn't need it.** The whole reason a hardware trigger would matter is
   frame-accurate alignment — and we already get that *post-hoc* from GPMF
   GPS-UTC at confidence 0.9 (§2). A loose "both start within a second" trigger
   is plenty, because `estimate_sync` corrects the residual at render time.

### Option B — Phone is BLE central to both devices (**recommended**)

The phone app already *is* the BLE central for the IDL0 device (SPEC §7). Phones
comfortably hold several concurrent BLE central connections. So:

- Phone ↔ IDL0 device: existing BLE control (start/stop logging, status).
- Phone ↔ GoPro: **new** BLE control (start/stop, enable AP, keep-alive, status)
  — a peer of the existing HRM-style central pattern, but hosted on the phone.
- Phone ↔ GoPro WiFi AP: **new** HTTP media pull, reusing the shape of
  `wifi_transfer.dart` + the Android network-binding reconciler.

*Advantages:*

- **Zero firmware change.** The IDL0 device is untouched; the "zero processing
  while logging" and coexistence invariants are preserved intact.
- Fits the existing architecture — the transport layer is already the phone's job
  (`app/lib/transport/`), and adding a `gopro/` sibling to `ble_service.dart` /
  `wifi_transfer.dart` is the natural home.
- The GoPro Open API is *designed* for exactly this (a phone/app as controller).
- The user's real end goal — "download from the respective devices and link them
  to sessions" — is inherently phone-centric already.

**Recommendation: Option B.** The only thing lost is phone-free trackside
triggering; if that is ever truly required, it belongs in a *later* hardware
study (e.g. a GPIO shutter pulse from the device), not in this integration, and
not on the BLE radio.

---

## 5. Constraints & gotchas (all surmountable)

1. **A phone joins only one WiFi AP at a time.** The IDL0 device is an AP *and*
   the GoPro is an AP. You **cannot** be on both simultaneously → **file
   transfer is inherently sequential**: pull the GoPro's clips over its AP, tear
   down, then pull the IDL0 log over its AP (or vice-versa). This matches the
   user's own phrasing ("once everything's been downloaded from the respective
   devices"). The transfer orchestrator must own this as an explicit sequential
   state machine, one AP at a time.
2. **Android AP-has-no-internet routing.** The GoPro AP hits the *same* Android
   10+ problem the IDL0 AP already solved: traffic wants to escape to cellular.
   Reuse the `idl0/wifi_network` binder pattern (per-socket loopback proxy,
   `WifiNetworkSpecifier`, the single-flight link reconciler — SPEC §6.2)
   generalized to "the AP I'm currently pulling from." This is design reuse, not
   a copy — one reconciler that can target either SSID.
3. **GoPro BLE keep-alive.** Whoever holds the link must send periodic
   keep-alives or the camera sleeps and drops its AP. On the phone this is a
   trivial timer; on the ESP32 mid-session it is forbidden compute (another nail
   in Option A).
4. **GPS must be enabled on the camera**, or GPMF carries no GPS-UTC and sync
   degrades from `gpmf` (0.9) to `creation_time` (0.3). We can push the GPS-on
   setting over BLE at pairing time and warn if the pulled clip lacks a GPS
   stream.
5. **iOS WiFi-join friction.** iOS restricts programmatic AP joins
   (`NEHotspotConfiguration`, entitlement-gated) far more than Android. The IDL0
   WiFi transfer already lives mostly on Android terms (SPEC §6.2 "on every other
   platform the user joins the AP in system settings"). GoPro file transfer on
   iOS likely means a guided "join the GoPro network" step. BLE control is fine
   on both. **Scope decision needed:** which platforms get *automatic* GoPro AP
   join vs. a manual guided join.
6. **Model coverage.** Open GoPro is HERO 9+. Older cameras and non-GoPro
   action cams are out. Worth stating a supported-models list in the spec.
7. **Clip granularity & chaptering.** Long GoPro recordings split into chaptered
   files; a single session may map to *several* `.mp4` files. `videos[]` is
   already an array (SPEC §15.4), so the model handles it — but the auto-linker
   must group a chaptered set and sync each chapter's own GPMF.

---

## 6. Proposed end-to-end workflow (Option B)

1. **Pair** the GoPro once (BLE bond, remember its address — mirrors how the HRM
   address is stored in config, SPEC §7.5/§8). Push GPS-on + set time.
2. **Record:** user starts a session from the Device hero (SPEC §23.9). The app,
   already BLE-central to the logger, *also* sends `set_shutter on` to the paired
   GoPro. Stop logging → `set_shutter off`. Loose sync is fine (§4).
3. **Ingest (sequential, §5.1):**
   a. Over BLE, tell the GoPro to enable its AP; read SSID/pw.
   b. Join GoPro AP (reconciler), `GET /gopro/media/list`, download new clips to
      app storage with resume. Tear down AP.
   c. Join IDL0 AP, pull new `.idl0` logs as today (SPEC §24). Tear down.
4. **Auto-link:** for each downloaded session and each downloaded clip, run the
   existing `estimate_video_sync` (§33.3) against the retained `SessionHandle`.
   Overlapping clip → write a `videos[]` entry with the estimated offset. No
   overlap → don't link (surface as "unmatched footage"). This is the
   "link them with sessions once everything's downloaded" the user asked for,
   and it is *mostly already built* — it just needs to be driven automatically
   after a GoPro pull instead of only on manual file-pick.
5. **Analyze/Export:** unchanged — overlay render already consumes `videos[]`.

---

## 7. Session-linking design (small, mostly reuse)

The `videos[]` model (SPEC §15.4) already carries everything except *provenance*
and a couple of camera-control fields. Likely additive fields (spec-during within
§15.4, plus a new device concept):

- `source: "manual" | "gopro"` on the video link (so re-ingest can dedupe by
  camera + on-camera filename rather than only by path/size/mtime).
- A camera identity + on-camera filename to make re-download idempotent.
- A small **paired-camera** record (address, model, label) alongside the HRM
  entry in config (SPEC §8) — this is the new persistent state.

Auto-link acceptance stays exactly as §15.4 already defines it: overlap-checked,
GPMF-preferred, manual-offset-preserving, re-link-on-move via size+mtime. We are
feeding an existing intake, not inventing one.

---

## 8. Spec impact (for the follow-up spec-first task)

| Section | Change |
|---|---|
| **New §34 "GoPro / Action Camera Integration"** (Part 9 video, or new Part) | The whole acquisition story: pairing, BLE control command set, WiFi ingest, sequential-AP orchestration, auto-link. |
| **§6 / new §6.x** | GoPro WiFi AP as a *second* AP target; generalize the reconciler's "which SSID" ownership. |
| **§7 / new §7.x** | Phone-as-central-to-GoPro (explicitly *not* device-side); the GoPro GATT surface we use. |
| **§8 Configuration** | Persisted paired-camera record (peer of `heart_rate_monitor`). |
| **§15.4 `videos[]`** | Additive `source` + camera provenance fields (spec-during). |
| **§10.4** | Note: GoPro control lives on the phone; the device radio budget is unchanged (explicitly closes the door on Option A). |
| **UI (§22–27)** | Where camera pairing/status/ingest live — likely the Device tab (pairing + record indicator) and the Data tab (ingest + unmatched-footage). New surface ⇒ spec-first. |
| **design_rationale.md** | Record the Option A vs B decision and *why* device-side control was rejected. |

## 9. Effort & phasing (rough)

- **Phase G1 — GoPro BLE control (phone):** pair/bond, shutter on/off, enable AP,
  keep-alive, status query. Dart `transport/gopro/`. *Medium.* No Rust, no spec
  to the engine.
- **Phase G2 — GoPro WiFi ingest:** generalize the AP reconciler to a second
  SSID; `gopro_transfer.dart` (media list + resumable download); sequential-AP
  orchestrator. *Medium-high* (the reconciler generalization is the fiddly part).
- **Phase G3 — Auto-link on ingest:** drive `estimate_video_sync` after a pull;
  write `videos[]`; chaptered-clip grouping; unmatched-footage surface. *Low-
  medium* — reuses §33.3 + §15.4.
- **Phase G4 — UI:** pairing flow, record co-trigger toggle, ingest progress,
  unmatched footage. *Medium.*
- **Phase G5 (optional, later, separate study):** device-side GPIO shutter pulse
  for phone-free trackside triggering — *hardware*, explicitly out of this scope.

The heavy engine work (GPMF, sync, overlay) is **already done**. The remaining
work is Dart transport + orchestration + a modest UI, plus the spec.

## 10. Open questions for the user (drive the spec-first task)

1. **Control topology:** confirm **Option B (phone controls both)** vs. the
   originally-sketched device-side control. *(Study strongly recommends B.)*
2. **Record co-trigger:** should starting an IDL0 session auto-start the GoPro,
   or keep camera start/stop manual and rely purely on GPMF auto-sync at ingest?
3. **Platforms for automatic AP join:** Android-first (matching current WiFi
   transfer posture), or is iOS auto-join in scope (entitlement work)?
4. **Supported cameras:** Open-GoPro HERO 9+ only, or a broader
   "any camera whose `.mp4` we can sync" manual path alongside?

---

## 11. Bottom line

Feasible, well-supported by GoPro's official API, and unusually cheap because the
hard half (telemetry parse, time-sync, overlay, per-session video links) already
ships. Build it **phone-side** (Option B) to keep the logger firmware's
zero-processing and RF-coexistence invariants intact. The net new work is a
`transport/gopro/` control+ingest layer, a generalization of the existing WiFi
reconciler to a second AP, an auto-link step wired onto the existing
`estimate_video_sync`, and a modest UI — all behind a proper spec-first §34.
