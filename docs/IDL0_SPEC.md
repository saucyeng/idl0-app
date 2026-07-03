# IDL0 Master Specification
**Version:** 1.0  **Last Updated:** 2026-05-04

---

## Table of Contents

| § | Section | Read for |
|---|---------|----------|
| **PART 1 — ORIENTATION** | | |
| 1 | System Philosophy | Always |
| 2 | Document Conventions | Always |
| **PART 2 — DEVICE & WIRE** | | |
| 3 | Hardware | Hardware/firmware tasks |
| 4 | Firmware | Firmware tasks |
| 5 | Binary Log Format | Parser, firmware |
| 6 | WiFi Protocol | Transport layer |
| 7 | BLE Protocol | Transport layer |
| 8 | Configuration Schema | Config, firmware |
| 9 | Coordinate System | Processing, calibration |
| 10 | Device Behavior | Firmware, power tasks |
| **PART 3 — APP ARCHITECTURE** | | |
| 11 | App Architecture | Any implementation |
| 12 | State Management | Any Dart implementation |
| 13 | Selection Model | Any Dart implementation |
| 14 | Error Handling | Any Dart implementation |
| **PART 4 — APP DATA MODEL** | | |
| 15 | Session & File Model | Data layer |
| 16 | Track Entity | Track-related work |
| 17 | Multi-Track & TrackVisits | Track-related work |
| 17a | Workbook Entity | Analyze tab, Drive sync |
| 18 | Bike Profiles & Riders | Profile, metadata tasks |
| **PART 5 — APP PROCESSING** | | |
| 19 | Signal Processing Pipeline | Rust layer tasks |
| 20 | Calibration | Calibration tasks |
| 21 | Analysis Features | Analyze tab, lap detection |
| **PART 6 — APP UI** | | |
| 22 | UI Structure | UI tasks |
| 23 | Tab — Device | Device tab work |
| 24 | Tab — Data | Data tab work |
| 25 | Tab — Maths | Maths tab work |
| 26 | Tab — Analyze | Analyze tab work |
| 27 | Tab — Settings | Settings tab work |
| **PART 7 — CROSS-CUTTING** | | |
| 28 | Google Drive Sync | Transport, sync |
| 29 | Data Export | Export tasks |
| 30 | First Launch / Onboarding | First launch |
| **PART 8 — DISTRIBUTION** | | |
| 31 | Distribution | Build/release |
| 32 | Open Source | Setup |

---

# PART 1 — ORIENTATION

## 1. System Philosophy

Two hard domains, no overlap:

**Firmware:** During a **logging session** the firmware does raw capture only — sensor bytes to SD card, minimum clock cycles, no filtering, integration, or signal conditioning. Outside a logging session — boot/initialisation, calibration, file transfer, config handling — it is a normal embedded device and may compute as those tasks require (e.g. the calibration routine averages a static-hold window and derives bias + orientation). The one absolute, in every mode: **analysis DSP** — filtering, integration, FFT, statistics — never runs on the device. That is exclusively the app's job.

**App:** All analysis computation — signal processing, filtering, integration, FFT, visualization, analysis. Rust processing layer (sci-rs + nalgebra) called via flutter_rust_bridge. Dart for everything else. The device computes calibration *values*; the app *applies* them when processing a log.

**File model:** Log files (`.idl0`) are immutable after download. All derived work lives in the workspace file (`.idl0w`).

---

## 2. Document Conventions

This document is the contract for the IDL0 system. It describes WHAT the system does, not the path that led there.

**How to read this spec.** The spec is organised in eight Parts following data flow from device to UI. Read top-to-bottom for an end-to-end orientation; jump to a Part using the Table of Contents for task-specific reference. The CLAUDE.md task-type table maps common task categories to the sections they need.

**Section numbers are stable.** After the 2026-05-04 overhaul, section numbers do not change. New sections are appended (or inserted with a deliberate decision recorded in `docs/design_rationale.md`). This stability is what makes inline cross-references (`§N.M`) reliable.

**Specification vs project management.** The spec describes specification only. Work-to-do lives in `TASKS.md`. Recently-shipped changes live in `CHANGELOG.md`. Architectural decisions and tradeoffs live in `docs/design_rationale.md`. See CLAUDE.md §10 for the full artifact map.

**Inline `**TODO:**` markers** indicate gaps in the specification itself — places where the system's behaviour is not yet defined. They are visible flags inside the spec; they are NOT project tasks (those live in TASKS.md). Inline references of the form `TODO #N` resolve to entries in `TASKS.md` under the "Migrated from spec §2 Open Items" section.

**Spec disposition.** When updating this document, follow the rules in `CLAUDE.md §9 Spec Discipline`: spec-first for architectural changes, spec-during for additive features, no-change-needed must be explicitly stated.

**Units.** Wherever a numeric value or threshold appears, units are mandatory. See CLAUDE.md §4.

**Code references** (paths, type names, function names) are rendered in `inline code` formatting. Section cross-references use `§N` or `§N.M`.

---

# PART 2 — DEVICE & WIRE

## 3. Hardware

### 3.1 Microcontroller
- **Module:** Seeed Studio XIAO ESP32-C6
- **SPI bus:** All high-speed sensors share SPI2, individual CS per device

### 3.2 IMUs — LSM6DSO32TR ×3
- ±32g accel, up to 1600 Hz ODR
- **IMU0:** Sprung mass (onboard PCB)
- **IMU1:** Front unsprung (fork, remote via harness)
- **IMU2:** Rear unsprung (swingarm, remote via harness) — absent on hardtails
- Index = fixed physical location, never sequential enumeration

### 3.3 GPS — u-blox MAX-M10S
- Antenna: Linx ANT-GNSSCP-TH25L1 ceramic patch (50mm ground plane, 50Ω RF trace)
- Interface: UART. 1–10 Hz configurable.
- Role: absolute time anchor + GPS track for mapping/sectors

### 3.4 Analog Inputs
- **PRESSURE_FRONT, PRESSURE_REAR** — ESP32-C6 ADC, 12-bit, **0–3.3V max**
- General-purpose: any 0–3.3V source. Primary use: brake pressure.
- v1 status: pins wired to harness, physically unconnected
- ⚠️ **No input protection. User must voltage-divide external sensors to ≤3.3V.**
- App applies user-defined scale/offset (from datasheet) to convert counts → engineering units

### 3.5 Wheel Speed
- **SPEED_FRONT, SPEED_REAR** — Hall effect sensor, active-low digital pulse
- Interrupt-driven, timestamped per pulse (not polled)
- ISR: `IRAM_ATTR`, queued via `xQueueSendFromISR`
- Supports: MTB rotor (12 pt/rev), tone ring (~60 pt/rev), or any user-defined PPR
- Velocity: `circumference_mm / (ppr × Δt_µs) × 3.6` → km/h

### 3.6 Device Identification

Each ESP32-C6 has a unique 6-byte MAC accessible via `esp_efuse_mac_get_default()`. From it the firmware derives two identifiers that are visible across the transport surface:

| Identifier | Source | Format | Visible in |
|------------|--------|--------|------------|
| `device_id` | All 6 MAC bytes | 12-char lowercase hex (e.g. `7c87ce4a32f1`) | Binary log header (§5.1), `idl0_config.json` `device_id` field (§8) |
| SSID suffix | Last 2 MAC bytes | 4-char uppercase hex (e.g. `B2C3`) | WiFi AP SSID `IDL0-XXXX` (§6) |
| BLE name suffix | Last 2 MAC bytes | 4-char uppercase hex | BLE advertised name `IDL0-XXXX` (§7) |

The firmware writes `device_id` into the binary log header at session start and into the `idl0_config.json` it persists. The companion app surfaces the same string in the Device tab so users can tell devices apart.

### 3.7 Connector — Deutsch DTM15-12PA

| Pin | Net | Function |
|-----|-----|----------|
| 1 | +3V3 | Power out |
| 2 | GND | Ground |
| 3 | SPI_SCK | SPI clock |
| 4 | MOSI | SPI data out |
| 5 | MISO | SPI data in |
| 6 | IMU_CS_FRONT | CS — IMU1 |
| 7 | IMU_CS_REAR | CS — IMU2 |
| 8 | PRESSURE_FRONT | Analog |
| 9 | PRESSURE_REAR | Analog |
| 10 | SPEED_FRONT | Wheel pulse |
| 11 | SPEED_REAR | Wheel pulse |
| 12 | BUTTONS | User input |

### 3.8 PCB & Storage
- 4-layer PCB, KiCad 9.0, Seeed Fusion PCBA
- MicroSD 256 GB, SPI, peak write ~56 KB/s at max config
- Battery: 1–3 Ah LiPo via JST-PH 2.0 (J3)

**TODO:** LSM6DSO32 sample-rate ceiling (1600 Hz over SPI) not yet validated against hardware. Deferred until next hardware revision.

---

## 4. Firmware

### 4.1 Core Constraint
Zero processing. Read sensor registers. Write raw binary to SD. Nothing else.

### 4.2 Startup
1. Read `idl0_config.json` from SD root
2. Parse channel mask, sample rates, enabled sensors
3. Initialize peripherals
4. Write session file header
5. Await start trigger

### 4.3 Session Triggers
- Start/stop: button press OR BLE command (`CMD_START_LOGGING` / `CMD_STOP_LOGGING`)
- WiFi is on-demand only — enabled via `CMD_WIFI_ON`, disabled via `CMD_WIFI_OFF`
- BLE stays active continuously (control plane). WiFi is data transfer only.

### 4.4 Record Loop
- Poll sensors at configured rates, write raw binary records
- GPS records interspersed as received
- Wheel pulses written per-interrupt event
- No computation on any value

### 4.5 Sensor Failure
If IMU SPI read fails: write zero-filled record with correct index and timestamp. Do not halt.

### 4.6 Partition Table
Dual-OTA layout on 4 MB flash. `partitions.csv`:
```
nvs,      data, nvs,     0x9000,  24K
phy_init, data, phy,     0xF000,   4K
otadata,  data, ota,     0x10000,  8K
ota_0,    app,  ota_0,   0x20000,  1600K
ota_1,    app,  ota_1,          ,  1600K
```

OTA update: app pushes `.bin` to `/ota` endpoint over WiFi (§6.1). ESP-IDF `esp_ota_ops.h` handles slot selection, streaming write, SHA-256 verification, and boot-partition switching. After an OTA-installed image boots, it is in pending-verify state until the app sends `CMD_OTA_CONFIRM` (§7.2); if it reboots before that confirmation, the bootloader rolls back to the previous slot.

---

## 5. Binary Log Format

**Byte order:** All multi-byte integers are **little-endian** (ESP32 native byte order).

### 5.1 File Header

| Field | Type | Bytes | Notes |
|-------|------|-------|-------|
| Magic | u8[4] | 4 | `IDL0` |
| Schema version | u8 | 1 | = 3 |
| Session UUID | u8[16] | 16 | App converts to 32-char lowercase hex → `Session.sessionId` |
| Device ID | u8[6] | 6 | App converts to 12-char lowercase hex → `Session.deviceId` |
| Session start UTC | i64 | 8 | ms, GPS-anchored |
| Config CRC32 | u32 | 4 | |
| IMU channel mask | u32 | 4 | see §5.3 |
| IMU count | u8 | 1 | |
| IMU sample rate | u16 | 2 | Hz |
| GPS sample rate | u8 | 1 | Hz |
| Channel registry count | u8 | 1 | N entries follow |
| Channel registry | entry[] | N×40 | see §5.2 |
| End marker | u8[4] | 4 | `0xDEADBEEF` |

> **Note.** Per-sample timing is carried inside the records themselves (see §5.5 for IMU_SAMPLE and §5.6 for GPS_FIX). The header's `Session start UTC` field stays as the wall-clock anchor; the device clock used for record-level timestamps is anchored against it on first GPS fix.

**Config CRC32 algorithm.** CRC-32/ISO-HDLC (a.k.a. zlib/PKZIP/gzip CRC32):
- Polynomial: `0x04C11DB7` (reflected: `0xEDB88320`)
- Initial value: `0xFFFFFFFF`
- Reflect input / reflect output: yes
- Final XOR: `0xFFFFFFFF`

Computed by the firmware over the raw on-disk JSON bytes of `idl0_config.json` (§8), exactly as loaded from the SD card before any whitespace normalisation. Available in ESP-IDF as `esp_rom_crc32_le(0, buf, len)` from `<rom/crc.h>`. The companion app verifies with `package:crclib`'s `Crc32` (which uses this same standard variant by default).

This is a corruption / mismatch check only; not security.

### 5.2 Channel Registry Entry (40 bytes each)

Every data source — analog channels, wheel-speed counters, and each individual IMU axis — declares itself in the header. The parser reads the registry once and handles all channel types from a single code path.

| Field | Type | Bytes | Notes |
|-------|------|-------|-------|
| channel_id | u8 | 1 | unique per session, referenced in 0x03 records |
| data_type | u8 | 1 | 0=u8 1=u16 2=u32 3=i8 4=i16 5=i32 6=f32 7=f64 |
| sample_rate_hz | u16 | 2 | 0 = event-driven (not fixed rate) |
| scale | f32 | 4 | physical = stored × scale + offset |
| offset | f32 | 4 | added after scaling |
| name | u8[20] | 20 | null-terminated ASCII e.g. `IMU0_AccelX`, `WheelFront` |
| units | u8[8] | 8 | null-terminated ASCII e.g. `g`, `dps`, `pulse`, `bar` |

**Adding a new sensor:** add an entry to the channel registry. No other format change. Old app versions see an unknown channel_id in the registry, skip those 0x03 records, parse everything else normally. No new parser required.

**Current channels in registry at v3 launch:**
| ID | Name | Type | Rate (Hz) | Units | Scale | Offset |
|----|------|------|-----------|-------|-------|--------|
| 0  | IMU0_AccelX | i16 | (configured) | g   | accel_range_g / 32768 | 0 |
| 1  | IMU0_AccelY | i16 | (configured) | g   | accel_range_g / 32768 | 0 |
| 2  | IMU0_AccelZ | i16 | (configured) | g   | accel_range_g / 32768 | 0 |
| 3  | IMU0_GyroX  | i16 | (configured) | dps | gyro_range_dps / 32768 | 0 |
| 4  | IMU0_GyroY  | i16 | (configured) | dps | gyro_range_dps / 32768 | 0 |
| 5  | IMU0_GyroZ  | i16 | (configured) | dps | gyro_range_dps / 32768 | 0 |
| 6  | IMU1_AccelX | i16 | (configured) | g   | accel_range_g / 32768 | 0 |
| 7  | IMU1_AccelY | i16 | (configured) | g   | accel_range_g / 32768 | 0 |
| 8  | IMU1_AccelZ | i16 | (configured) | g   | accel_range_g / 32768 | 0 |
| 9  | IMU1_GyroX  | i16 | (configured) | dps | gyro_range_dps / 32768 | 0 |
| 10 | IMU1_GyroY  | i16 | (configured) | dps | gyro_range_dps / 32768 | 0 |
| 11 | IMU1_GyroZ  | i16 | (configured) | dps | gyro_range_dps / 32768 | 0 |
| 12 | IMU2_AccelX | i16 | (configured) | g   | accel_range_g / 32768 | 0 |
| 13 | IMU2_AccelY | i16 | (configured) | g   | accel_range_g / 32768 | 0 |
| 14 | IMU2_AccelZ | i16 | (configured) | g   | accel_range_g / 32768 | 0 |
| 15 | IMU2_GyroX  | i16 | (configured) | dps | gyro_range_dps / 32768 | 0 |
| 16 | IMU2_GyroY  | i16 | (configured) | dps | gyro_range_dps / 32768 | 0 |
| 17 | IMU2_GyroZ  | i16 | (configured) | dps | gyro_range_dps / 32768 | 0 |
| 18 | WheelFront     | u32 | 0 (event) | pulse | 1.0 | 0 |
| 19 | WheelRear      | u32 | 0 (event) | pulse | 1.0 | 0 |
| 20 | PressureFront  | u16 | 100 | bar | from config | from config |
| 21 | PressureRear   | u16 | 100 | bar | from config | from config |

Scale and offset values in the table are resolved per-axis at session start from the active config and written verbatim into the registry entry. The parser treats them as opaque floats and applies `physical = stored × scale + offset` without reference to any config.

Disabled IMU axes (per the channel mask in §5.3) have no registry entry — the registry count reflects only axes that are enabled and recorded. The channel mask in §5.3 still drives stride decoding inside `IMU_SAMPLE` (0x01) records; the registry defines what each value means.

In the Scale column, `accel_range_g` and `gyro_range_dps` refer to the per-IMU resolved values from §8 — per-IMU sub-block value if present, else the top-level default.

**BLE Heart Rate Monitor (added when `heart_rate_monitor.enabled` in §8):**
| ID | Name | Type | Rate | Units | Scale | Offset |
|----|------|------|------|-------|-------|--------|
| 22 | HR_BPM | u8 | 1 | bpm | 1.0 | 0.0 |
| 23 | HR_RR | u16 | 0 (event) | ms | 1000/1024 | 0.0 |

**Future sensors (no format change needed):**
| ID | Name | Type | Rate | Units | Scale | Offset |
|----|------|------|------|-------|-------|--------|
| 24+ | anything | any | any | any | TBD | TBD |

### 5.3 Record Types

All records share a common 3-byte framing header:

```
[type:u8][payload_len:u16][payload:N bytes]
```

`payload_len` is the byte count of the payload only (does not include the 3-byte header). This enables forward-compatible skipping: on an unknown `type`, read `payload_len` and advance that many bytes, then continue parsing.

| Tag | Name | Payload description |
|-----|------|---------------------|
| 0x01 | IMU_SAMPLE | Raw int16 LSB — variable stride per IMU channel mask |
| 0x02 | GPS_FIX | Fixed-width parsed GPS fix |
| 0x03 | CHANNEL_SAMPLE | Generic — any channel in registry |
| 0xFF | SESSION_END | Empty payload (payload_len = 0) |

**SESSION_END semantics.** Firmware writes `0xFF` with `payload_len = 0` and flushes the file when:
1. The companion app sends `CMD_STOP_LOGGING` over BLE (§7.2).
2. The user presses the stop button.
3. Battery voltage drops below the soft-cutoff threshold (§10.1).

On a hard power loss with no SESSION_END, every record up to the last periodic fsync survives a normal read: the firmware commits the file's directory-entry **size** — not just its data clusters — at the ~1 Hz flush cadence (§10.2), so even without a clean close the file is parseable up to that point. It carries no SESSION_END marker, so the app treats it as an "interrupted" session and surfaces a warning while loading it normally. Samples written in the final ≤1 s between the last fsync and the cut reach the card's clusters but fall outside the committed size — a normal read does not see them; salvaging them needs a raw-device scan (`idl-rs recover`).

### 5.4 IMU Channel Mask (for 0x01 records only)

| Bits | Channels |
|------|---------|
| 0–5 | IMU0 accel XYZ, gyro XYZ |
| 6–11 | IMU1 same |
| 12–17 | IMU2 same |
| 18–31 | Reserved |

### 5.5 IMU_SAMPLE Record (0x01)

Variable stride — only enabled axes are written. Parser computes payload size from the IMU channel mask once at session load.

Framing: `[0x01][payload_len:u16][payload]`

| Field | Type | Bytes | Present when |
|-------|------|-------|-------------|
| imu_index | u8 | 1 | always |
| timestamp_us | i64 | 8 | always |
| accel_x | i16 | 2 | mask bit 0/6/12 |
| accel_y | i16 | 2 | mask bit 1/7/13 |
| accel_z | i16 | 2 | mask bit 2/8/14 |
| gyro_x | i16 | 2 | mask bit 3/9/15 |
| gyro_y | i16 | 2 | mask bit 4/10/16 |
| gyro_z | i16 | 2 | mask bit 5/11/17 |

`timestamp_us` is `esp_timer_get_time()` microseconds from device boot. Firmware reads the IMU FIFO in bursts and assigns per-sample timestamps walking back from the read instant at the nominal ODR cadence: for N samples drained at `t_read`, sample `i` (0 = oldest) is stamped `t_read - (N - 1 - i) * (1_000_000 / ODR)`. The device clock is anchored to wall-clock time by `gps_epoch_ms` carried in §5.6 GPS_FIX records.

Minimum payload: 9 bytes (`imu_index` + `timestamp_us`, no axes enabled).
Maximum payload: 21 bytes (`imu_index` + `timestamp_us` + 6 axes).

**Drop detection.** A dropped sample inside the FIFO is visible app-side as a gap larger than `1 / ODR` between consecutive `timestamp_us` values on the same `imu_index`. No separate "drop" record is emitted; firmware logs FIFO overruns to the serial / BLE status string for debugging but does not write them to the file. The parser reconciles these gaps onto the nominal grid — linear-filling the dropped samples and recording each run in the channel's gap list — so all IMU channels stay equal-length and time-aligned (§15.2).

**App-side channel names** (produced by `BinaryParser`, consumed by charts and math expressions):

| imu_index | Channel names (axis order: AccelX, AccelY, AccelZ, GyroX, GyroY, GyroZ) |
|-----------|--------------------------------------------------------------------------|
| 0 | `IMU0_AccelX` `IMU0_AccelY` `IMU0_AccelZ` `IMU0_GyroX` `IMU0_GyroY` `IMU0_GyroZ` |
| 1 | `IMU1_AccelX` … `IMU1_GyroZ` |
| 2 | `IMU2_AccelX` … `IMU2_GyroZ` |

Stored values are raw `i16`. The parser scales each axis using its registry entry's `scale` and `offset` fields: `physical = stored × scale + offset`. The channel mask defines which axes are present in the payload and in what order; the registry entry for each axis name defines what the raw value means. The Rust processing layer (§19) receives already-scaled physical values.

### 5.6 GPS_FIX Record (0x02)

Framing: `[0x02][payload_len:u16][payload]` — payload is always 32 bytes.

| Field | Type | Bytes | Notes |
|-------|------|-------|-------|
| gps_epoch_ms | i64 | 8 | UTC ms from the GPS receiver |
| device_timestamp_us | i64 | 8 | `esp_timer_get_time()` at fix arrival |
| latitude | i32 | 4 | deg × 1e7 |
| longitude | i32 | 4 | deg × 1e7 |
| altitude | i16 | 2 | m × 10 |
| speed | u16 | 2 | km/h × 100 |
| heading | u16 | 2 | deg × 100 |
| fix_quality | u8 | 1 | 0=none 1=GPS 2=DGPS |
| satellites | u8 | 1 | count |

**Wall-clock anchor.** `gps_epoch_ms` and `device_timestamp_us` together anchor the device's monotonic `esp_timer` clock to UTC. Records that precede the first fix carry `gps_epoch_ms = 0`. When the header `Session start UTC` (§5.1) is 0, the app back-fills the session's start as the wall clock at the recording's **first sample**, from the first non-zero fix:

```
session_start_utc_ms = gps_epoch_ms − (device_timestamp_us − first_sample_device_timestamp_us) / 1000
```

Per-sample times are zeroed at that first sample (§15.2), so each sample's absolute wall time is `session_start_utc_ms + sample_time`. (`first_sample_device_timestamp_us` is the earliest record timestamp in the file; `device_timestamp_us` is monotonic since device boot, not since the recording, so the offset to the first sample — not the raw device timestamp — is what places the start at recording time rather than boot.)

### 5.7 CHANNEL_SAMPLE Record (0x03)
Generic record for all non-IMU, non-GPS channels. Value width determined by `data_type` in registry.

Framing: `[0x03][payload_len:u16][payload]`

| Field | Type | Bytes | Notes |
|-------|------|-------|-------|
| channel_id | u8 | 1 | matches registry entry |
| timestamp_us | i64 | 8 | µs since boot |
| value | N bytes | 1–8 | per registry data_type |

**App-side channel names** (produced by the `idl-rs` engine for GPS_FIX records):

| Channel | Source field | Storage |
|---------|-------------|---------|
| `GPS_EpochMs` | `gps_epoch_ms` | raw `i64` ms |
| `GPS_Latitude` | `latitude` | raw `i32` (deg × 1e7) |
| `GPS_Longitude` | `longitude` | raw `i32` (deg × 1e7) |
| `GPS_Altitude` | `altitude` | raw `i16` (m × 10) |
| `GPS_SpeedKmh` | `speed` | `i32`, engine scale **0.01** → physical km/h |
| `GPS_Heading` | `heading` | raw `u16` (deg × 100) |
| `GPS_FixQuality` | `fix_quality` | raw `u8` |
| `GPS_Satellites` | `satellites` | raw `u8` |

Values are stored as raw wire integers in the on-disk record. Registry-defined `CHANNEL_SAMPLE` channels are returned with `physical = stored × scale + offset` from the channel's registry entry (§5.2). The GPS_FIX-derived channels above carry no registry entry. **`GPS_SpeedKmh` is the one exception that is engine-scaled**: the firmware logs km/h × 100, and the engine stores the raw `i32` with a `0.01` scale so `materialize()` yields **physical km/h** — every consumer (`Distance` synthesis, math, FIT export, colour-by) reads physical speed directly, none divides. The remaining GPS_FIX channels are returned **raw**; consumers that need physical units divide by the documented factor (e.g. `GPS_Latitude` ÷ 1e7, `GPS_Altitude` ÷ 10, `GPS_Heading` ÷ 100).

**Wheel pulse example** (channel_id=18, data_type=u32):
- `value` = monotonic pulse counter (rollover detectable)
- `sample_rate_hz` = 0 (event-driven, one record per pulse)

**Heart rate example** (channel_id=22, data_type=u8):
- `value` = BPM from BLE heart rate monitor
- `sample_rate_hz` = 1

**RR-interval example** (channel_id=23, data_type=u16):
- `value` = raw 1/1024-second ticks per beat-to-beat interval
- `sample_rate_hz` = 0 (one record per heartbeat, back-derived timestamps)
- Parser converts to ms via `physical = stored × 1000/1024 + 0.0`

---

## 6. WiFi Protocol

ESP32 runs as AP. Phone connects directly, no router.

| Parameter | Value |
|-----------|-------|
| SSID | `IDL0-XXXX` where `XXXX` = uppercase hex of MAC bytes 4–5. See §3.6. |
| Password | Per-device (TODO #16). Current: `datalogger123` |
| Device IP | `192.168.4.1` |
| Protocol | HTTP/1.1 |

### 6.1 Endpoints

| Endpoint | Method | Response | Notes |
|----------|--------|----------|-------|
| `/ping` | GET | JSON object | Status + identity. See below. Handler is allocation-light and never touches the SD card. |
| `/handoff` | POST | 200 | App acknowledges the HTTP link is up; firmware then drops BLE (disconnects + stops advertising). Idempotent. See §10.4. |
| `/wifi_off` | POST | 200 | Exits WiFi mode. Response flushes (~500 ms delay), then AP tears down and BLE advertising resumes. The normal WiFi-exit path once BLE is off. |
| `/files` | GET | JSON array | `[{"name":"...", "size":N, "session_id":"<32-hex>"}]` — `session_id` is the 16-byte header UUID as 32 lowercase hex chars (no dashes), read from each file; omitted only if the header is unreadable. The app diffs it against the library to mark files NEW vs in-library (§24). |
| `/download?file=N` | GET | binary stream | `Range: bytes=START[-END]` supported (`206` + `Content-Range`). The app resumes interrupted downloads from the received offset — safe because session files are immutable after recording. |
| `/delete?file=N` | GET | 200/error | |
| `/config` | POST | 200/error | Push `idl0_config.json`. **On success the device reboots** (`esp_restart`, ~500 ms after the `200`) to apply the new config in full — it is read at boot only (HRM enable/address, IMU ODR/ranges). The GPS module is UART-only with no power-enable GPIO, so its fix survives the SoC reset. The app re-establishes the BLE link after the push; the device boots back into idle mode. |
| `/ota` | POST | 200/error | OTA firmware update — see below |

`/ota` request body is the raw firmware image (`Content-Type: application/octet-stream`). `Content-Length` SHOULD be set; if present, the device rejects a short upload (HTTP 400) so a truncated stream never reaches validation. The device streams the bytes into the inactive OTA partition, then validates the image's embedded SHA-256 via `esp_ota_end()`:
- **200** with body `ok\n` — image valid; the device reboots ~500 ms after the response. A `SocketException` on the immediately-following request is expected.
- **400 `image validation failed`** — SHA-256 mismatch (corrupt upload). Device keeps running the previous image.
- **400 `short upload`** — `Content-Length` set but fewer bytes received.
- **500 …** — receive or flash-write failure. Device keeps running the previous image.

The new image boots in pending-verify state. The app commits it with `CMD_OTA_CONFIRM` (§7.2); without that confirmation, the next reboot rolls back. See §4.6.

**`/ping` payload.** The WiFi-mode status feed and identity check:

```json
{
  "device": "IDL0-A3F2",
  "fw": "1.4.0",
  "proto": 1,
  "battery": 87,
  "sd": "OK",
  "mode": "wifi",
  "ble": "on"
}
```

`device` is `idl0_device_name()` — the app verifies it against the expected
device before trusting the link (every IDL0 AP shares `192.168.4.1`).
`proto` is the WiFi control-protocol version (currently 1); on a major
mismatch the app refuses operations and surfaces a firmware-update prompt.
`ble` is `on` until `/handoff`, `off` after. The remaining fields mirror the
§7.3 status characteristic: once BLE drops, `/ping` **is** the status feed
(§7.3). Unknown fields are ignored by the app, so the set may grow.

### 6.2 App ↔ Device Link Management

**Android network binding.** Android 10+ routes HTTP to the default
(cellular) network when a WiFi AP has no internet. The app requests the
device AP with `WifiNetworkSpecifier` via the `idl0/wifi_network` platform
channel. The plugin is a pure sensor/actuator: commands `request(ssid,
password)` / `release()` (immediate return, no timers, no policy) plus an
event stream (`available` / `lost` / `unavailable`). The network request
stays registered for the whole linked period; `onUnavailable` and `release`
both unregister, and the network↔SSID association is keyed so switching
devices never reuses a stale network. Android 11+ stores the user's AP
approval, so repeat requests auto-connect with no dialog; on Android 10 a
re-request may re-prompt, so unattended relink attempts are capped there
(one automatic retry, then a manual Retry affordance).

**Per-socket routing (loopback proxy).** The process is never globally
bound to the AP (`bindProcessToNetwork` is not used). While the AP network
is available, the plugin runs a minimal TCP forwarder: `127.0.0.1:<ephemeral
port>` ↔ a `Network.socketFactory` socket ↔ `192.168.4.1:80`. The port is
delivered in the `available` event and the app's device base URL becomes
`http://127.0.0.1:<port>`. Internet traffic (Drive sync, §28) flows
normally during transfers. On every other platform the app talks to
`192.168.4.1` directly and the user joins the AP in system settings.

**Link reconciler.** A single-flight state machine in the app owns the
link: `unlinked → requesting → verifying → linked`, with failures feeding
back through bounded backoff (1 s / 2 s / 4 s, then `failed`; `failed`
re-arms on user Retry, app resume, or WiFi-mode re-entry). Desired state
derives from device mode (read through the §7.3 staleness model); actual
state from platform events plus the heartbeat. `verifying` requires an
identity-checked `/ping` (wrong `device` → release + `failed`, never talk
to the wrong logger); the first success after WiFi-mode entry triggers
`POST /handoff`. While `linked`, `/ping` runs every 10 s (any successful
operation counts as a heartbeat); 3 consecutive failures → relink. The
machine is an explicit transition table with full-coverage tests, and the
last ~100 transitions are journaled for diagnosis. All device operations go
through one serialized, link-gated facade: ops wait up to 15 s while the
reconciler is converging, and fail fast with a typed error when the link is
`failed` or the device is not in WiFi mode.

---

## 7. BLE Protocol

### 7.1 GATT

| Characteristic | UUID | Type |
|----------------|------|------|
| Service | `000000FF-0000-1000-8000-00805F9B34FB` | — |
| IMU Data | `0000FF01-0000-1000-8000-00805F9B34FB` | Notify (disabled in v2) |
| GPS Data | `0000FF02-0000-1000-8000-00805F9B34FB` | Notify (disabled in v2) |
| Control | `0000FF03-0000-1000-8000-00805F9B34FB` | Write with Response |
| Status | `0000FF04-0000-1000-8000-00805F9B34FB` | Notify |
| Config RX | `0000FF05-0000-1000-8000-00805F9B34FB` | Write with Response |
| Config TX | `0000FF06-0000-1000-8000-00805F9B34FB` | Read |

Control characteristic uses **Write with Response** — app waits for GATT ACK before the command call returns. Firmware must acknowledge. If declared as Write Without Response in the firmware GATT table, update this and flip `withoutResponse` in `BleConnection._sendCommand`.

### 7.2 Control Commands (single byte write)

| Byte | Command |
|------|---------|
| 0x01 | CMD_WIFI_ON |
| 0x02 | CMD_WIFI_OFF |
| 0x03 | CMD_START_LOGGING |
| 0x04 | CMD_STOP_LOGGING |
| 0x05 | CMD_CALIBRATE_IMU |
| 0x06 | CMD_OTA_CONFIRM |
| 0x07 | CMD_CONFIG_BEGIN |
| 0x08 | CMD_CONFIG_COMMIT |
| 0x09 | CMD_CONFIG_READ_BEGIN |

`CMD_OTA_CONFIRM` (0x06) commits the currently-running image after an OTA. After an `/ota` POST and the subsequent reboot, the new image runs in pending-verify state — the status characteristic includes an `OTA: PENDING_VERIFY` line (§7.3). The app must send `CMD_OTA_CONFIRM` to cancel the pending rollback; if the device reboots before the confirmation, the bootloader switches back to the previous slot. Sending the command in any other state is a no-op.

**Config push over BLE.** `idl0_config.json` is pushed over BLE — no WiFi changeover. The app:

1. writes `CMD_CONFIG_BEGIN` (0x07) to Control, opening an 8 KB reassembly buffer on the device;
2. streams the JSON to the **Config RX** characteristic (FF05) in MTU-sized chunks (each a Write with Response);
3. writes `CMD_CONFIG_COMMIT` (0x08) to Control.

On COMMIT the firmware validates the reassembled bytes as JSON and atomically writes them to `idl0_config.json` (temp-file + rename), then reboots ~500 ms later to apply (config is read at boot only, §4.2). The app re-establishes BLE after the reboot and lands back in idle mode. BEGIN/COMMIT and the FF05 writes carry the §7.2 ACK protocol: a chunk that would exceed 8 KB, a COMMIT with no buffered data, malformed JSON, or an SD write error are rejected (`0x80`/`0x81`) and no partial config is persisted. A BLE disconnect mid-transfer discards the buffer. This shares one validate+atomic-write path with the WiFi `POST /config` handler (§6.1), which remains available as a fallback.

**Config read-back over BLE.** `CMD_CONFIG_READ_BEGIN` (0x09) snapshots the live `idl0_config.json` into a device-side buffer and resets a cursor; the app then reads the **Config TX** characteristic (FF06) repeatedly — each read returns the next ≤200-byte chunk and advances the cursor — until an **empty read** signals EOF. The app reassembles and `jsonDecode`s the bytes. READ_BEGIN returns `0x81` if no config file exists. The snapshot is discarded on disconnect. The app uses this to **verify a push**: after the reboot+reconnect it pulls the config back and compares it (compact JSON) to what it sent; a mismatch (or read-back unsupported on older firmware) is surfaced to the user but never silently treated as success.

**ACK protocol.** Every write to the Control characteristic (FF03)
returns an ATT result code as the GATT write response:

| Code | Meaning |
|------|---------|
| `0x00` | Success — command accepted and dispatched |
| `0x03` | `WRITE_NOT_PERMITTED` — mutex or precondition refusal |
| `0x80` | `IDL0_ACK_BUSY` (reserved) |
| `0x81` | `IDL0_ACK_PRECONDITION` (reserved) |
| `0x82` | `IDL0_ACK_NOT_IMPLEMENTED` (reserved) |

Acceptance (0x00) does NOT mean the work completed — only that the
firmware accepted the command and will execute it. The corresponding
FF04 status notify carrying the new state is the completion signal.

**Mutex.** `CMD_WIFI_ON` and `CMD_START_LOGGING` are mutually
exclusive. The firmware returns `0x03` (and refuses to act) when:

- `CMD_WIFI_ON` is issued while a session is running.
- `CMD_START_LOGGING` is issued while SoftAP is up.

Mode changes are automatic (§23.9) — recording from the Device hero's
primary button, WiFi driven on demand by file sync (§24) / OTA (§27) — so the
app never lets the user request a mutex-violating transition directly.

In WiFi mode, BLE control is available only until the §10.4 radio
handoff: after `POST /handoff` the phone link drops and control moves
to HTTP (`/wifi_off` exits the mode). `CMD_WIFI_OFF` over BLE remains
the abort path for a WiFi entry that never achieved an HTTP link.

### 7.3 Status Characteristic
UTF-8, newline-delimited. Parse case-insensitively. Unknown lines are ignored, so the set may grow without breaking older parsers.
```
WiFi: ON|OFF
Logging: RUNNING|STOPPED
Battery: N%
SD: OK|FULL|ERROR|ABSENT
GPS: FIX|NOFIX|ABSENT
IMU: OK|PARTIAL|ERROR|ABSENT
Firmware: <semver>      (running image version, e.g. 1.5.0)
OTA: PENDING_VERIFY     (present only while the running image is awaiting CMD_OTA_CONFIRM — see §7.2)
HR:         ABSENT | SEARCHING | CONNECTED N | NO_CONTACT N | SUSPENDED
HR_Battery: N%
```
`SD` reflects mount + free-space state. `GPS` reflects fix acquisition. `IMU` is an aggregate across the enabled IMUs — `PARTIAL` means at least one enabled IMU is responding and at least one is not. `Firmware` carries the running image's embedded version (`esp_app_desc_t.version`), the same value `/ping` reports as `fw`; the app uses it to offer over-the-air updates (§27.7). `OTA` is absent in the common case; it appears only between an OTA-installed reboot and the app's `CMD_OTA_CONFIRM`.

`HR` reflects the HRM central-role state (§7.5). `CONNECTED N` carries the latest BPM. `NO_CONTACT N` means the strap's sensor-contact-detected flag (bits 1–2 of the HR Measurement flags byte) reports no skin contact; BPM continues to stream but is unreliable. `SUSPENDED` means the HRM link has been dropped because WiFi SoftAP is active (§10.4). `HR_Battery` is absent until the first successful battery read on connect; thereafter it stays present (with the last-read value) for the duration of the session.

**Status sources and staleness.** This characteristic is the status feed in
idle and recording modes. In WiFi mode, after the §10.4 radio handoff drops
BLE, the `/ping` heartbeat (§6.1) carries the same fields as JSON. The app's
`DeviceState` never resets to defaults on link loss: it holds last-known
values with a timestamp and source (`ble` | `ping`), and derives staleness
(no payload from any source within 25 s). Mode derivation reads through
this, so BLE absence during WiFi mode is the designed state, not an error;
only a deliberate user disconnect clears device state. UI renders stale
values dimmed rather than substituting defaults.

### 7.4 Connection Sequence
1. Scan for service UUID `000000FF-...`
2. Connect GATT, negotiate MTU
3. Enable notifications on the Status characteristic (wait for the CCCD descriptor-write ACK). Control is write-only — it has no notifications to enable; just hold its handle for writing.
4. Read initial status

### 7.5 BLE Central Role (Heart Rate Monitor)

The firmware runs NimBLE as both **peripheral** (GATT server for the phone) and **central** (GATT client for an HRM strap) on a single radio. Requires `CONFIG_BT_NIMBLE_ROLE_CENTRAL=y` and `CONFIG_BT_NIMBLE_MAX_CONNECTIONS=2` in `sdkconfig`.

The central role connects to one HRM per session, identified by the 6-byte BLE address stored in `idl0_config.json` `heart_rate_monitor.device_address` (§8). The strap exposes the standard Heart Rate Service (`0x180D`) with the Heart Rate Measurement characteristic (`0x2A37`) and the Battery Service (`0x180F`) with the Battery Level characteristic (`0x2A19`).

The firmware subscribes to `0x2A37` notifications and reads `0x2A19` once on connect. Each notification produces:
- One `HR_BPM` (channel 22) CHANNEL_SAMPLE record, value = BPM from the notification's HR byte.
- N `HR_RR` (channel 23) CHANNEL_SAMPLE records, one per RR interval in the notification payload, with back-derived timestamps walking from the notification arrival time.

**WiFi coexistence.** The ESP32-C6 RF coexistence table marks SoftAP + BLE as "C1 — unstable." The firmware drops the HRM connection when WiFi turns on (file transfer / OTA / config push) and reconnects when WiFi turns off. See §10.4.

### 7.6 IMU Calibration

`CMD_CALIBRATE_IMU` (0x05) puts the device into **calibration mode** — a non-logging mode. The device runs a self-contained routine: it captures a static-hold sample window, then computes per-IMU bias offsets and the 3×3 orientation matrix on-device (permitted outside the logging path — see §1). It does **not** stream raw IMU data over BLE.

The result — per-IMU bias `[ax, ay, az, gx, gy, gz]` and the orientation matrix — is delivered to the app over BLE as a compact, fixed-size payload (one packet or a short bounded set; the exact characteristic is pinned when the calibration flow is implemented). The app writes the values into the bike's `idl0_config.json` (§8 `bias` / `orientation` fields), so calibration is stored per bike profile and travels with that bike's config.

The firmware never *applies* calibration — it writes raw int16 LSB values into the log (§5.5). The parser converts raw values to physical units using the per-channel scale/offset stored in the channel registry (§5.2). The app then applies bias correction and orientation rotation in the Rust processing layer, matching log to config via the header `config_crc32` (§5.1).

---

## 8. Configuration Schema

**File:** `idl0_config.json` on SD card root. Pushed manually by user after review — never pushed automatically.

```json
{
  "config_version": 1,
  "device_id": "XXXXXXXXXXXX",
  "bike_profile": {
    "name": "Trek Session 2024",
    "default_rider": "Rider Name"
  },
  "imu": {
    "sample_rate_hz": 833,
    "accel_range_g": 32,
    "gyro_range_dps": 2000,
    "low_power_mode": false,
    "high_performance_mode": true,
    "imu0": {
      "enabled": true,
      "accel_range_g": 32,
      "gyro_range_dps": 2000,
      "channels": { "accel_x": true, "accel_y": true, "accel_z": true,
                    "gyro_x": true, "gyro_y": true, "gyro_z": false }
    },
    "imu1": {
      "enabled": true,
      "accel_range_g": 16,
      "gyro_range_dps": 500,
      "channels": { "accel_x": true, "accel_y": true, "accel_z": true,
                    "gyro_x": false, "gyro_y": false, "gyro_z": false }
    },
    "imu2": {
      "enabled": true,
      "accel_range_g": 16,
      "gyro_range_dps": 500,
      "channels": { "accel_x": true, "accel_y": true, "accel_z": true,
                    "gyro_x": false, "gyro_y": false, "gyro_z": false }
    },
    "orientation": {
      "imu0_rotation_matrix": [[1,0,0],[0,1,0],[0,0,1]],
      "imu1_rotation_matrix": [[1,0,0],[0,1,0],[0,0,1]],
      "imu2_rotation_matrix": [[1,0,0],[0,1,0],[0,0,1]]
    },
    "bias": {
      "imu0": [0,0,0,0,0,0],
      "imu1": [0,0,0,0,0,0],
      "imu2": [0,0,0,0,0,0]
    }
  },
  "gps": {
    "sample_rate_hz": 5,
    "dynamic_model": "automotive",
    "nmea_sentences": ["GGA", "RMC"],
    "sbas_enabled": true
  },
  "analog": {
    "sample_rate_hz": 100,
    "channels": []
  },
  "digital": {
    "channels": []
  },
  "wheel_speed": {
    "front": { "enabled": false, "points_per_revolution": 12, "wheel_circumference_mm": 2300 },
    "rear":  { "enabled": false, "points_per_revolution": 12, "wheel_circumference_mm": 2300 }
  },
  "heart_rate_monitor": {
    "enabled": true,
    "device_address": "AA:BB:CC:DD:EE:FF",
    "device_name": "Polar H10 12345678"
  }
}
```

**Heart rate monitor.** `device_address` is the 6-byte BLE public address, colon-separated uppercase hex. `device_name` is informational (preserved across pushes, used as the UI label). `enabled: false` retains the saved address but suppresses connection. Omitting the block is equivalent to `enabled: false`. The firmware adds channels 22 (`HR_BPM`) and 23 (`HR_RR`) to the per-session channel registry only when `enabled` is true (§5.2).

**Bike profile.** The `bike_profile` block carries only user-facing metadata — `name` (also written into `SessionMetadata.bike` for matching across the app) and `default_rider`. The presence of IMU1/IMU2 is derived from `imu.imu1.enabled` and `imu.imu2.enabled`, not from a separate `imu_count` or `type` field.

**Analog channels.** Each element of `analog.channels` is:

```json
{ "key": "strain_left", "label": "Strain Left",
  "adc_pin": 4, "units": "kN",
  "scale": 0.0123, "offset": -1.5, "enabled": true }
```

No default entries — users add channels via the Device tab as they wire up sensors. The firmware iterates the array at session start to configure ADC channels dynamically. `analog.sample_rate_hz` is shared across all analog channels (the ADC scheduler round-robins between configured pins). Per-channel rate overrides are forward-compatible but not yet implemented.

**Digital channels.** Each element of `digital.channels` is:

```json
{ "key": "marker_btn", "label": "Marker", "kind": "marker",
  "gpio_pin": 21, "active_low": true, "debounce_ms": 20, "enabled": true }
```

`kind` is one of `marker` (event-driven push button — one CHANNEL_SAMPLE per debounced press, value = monotonic press counter), `level` (low-rate sampled binary state, u8 at 50 Hz), or `pwm` (frequency / duty measurement, u32 at 50 Hz). Spec 1 ships `marker` in the app's `+ Add channel…` picker; `level` and `pwm` are reserved in the schema but not yet exposed.

**Wheel speed defaults.** Both `front.enabled` and `rear.enabled` default to `false` — wheel-pulse counters require a Hall-effect sensor that not every bike has wired. Users enable per slot via the Device tab.

**Per-IMU range resolution.** Each `imu.imu0`, `imu.imu1`, and `imu.imu2` sub-block carries its own `accel_range_g` and `gyro_range_dps`. The top-level `imu.accel_range_g` and `imu.gyro_range_dps` fields (shown above) act as defaults: the firmware seeds all three IMU slots from those values, then applies any per-IMU overrides. A config file that omits the per-IMU sub-blocks entirely is valid — all three IMUs inherit the top-level range. The resolved per-axis values are written verbatim into the channel registry entry (§5.2) at session start; the parser uses those registry values without further reference to the config.

**Configurable chip options:**

LSM6DSO32: sample rate (12.5–1666 Hz), accel range (±4/8/16/32g), gyro range (±125–2000 dps), high-performance vs low-power mode, anti-aliasing filter bandwidth.

u-blox MAX-M10S: sample rate (1–10 Hz), dynamic model (portable/pedestrian/automotive/sea/airborne), NMEA sentences (GGA+RMC default), SBAS enable.

**Valid `sample_rate_hz` values — app UI must expose these discrete options:**

| Config path | Valid values | On invalid value |
|-------------|-------------|-----------------|
| `imu.sample_rate_hz` | High-perf: 12.5, 26, 52, 104, 208, 416, 833, 1666 Hz. Low-power: 1.6, 12.5, 26, 52, 104, 208 Hz. | Undefined — firmware maps directly to ODR register; off-list values produce undefined chip behavior. |
| `gps.sample_rate_hz` | Integer 1–10 Hz | Firmware clamps or rejects. |
| `analog.sample_rate_hz` | **Not yet defined.** ADC chip and valid rate set unspecified — define before implementing analog parsing. | — |

**Read-only fields — app preserves on push, never user-edited:**
- `device_id`: 12-char lowercase hex of `esp_efuse_mac_get_default()`. See §3.6.
- `config_version`: App-managed. Increment only for breaking firmware-compatibility changes.

**Compatibility:** Firmware ignores unknown JSON fields. App warns if device firmware is newer than app. Breaking changes increment `config_version`.

**Push transport:** "Push Config" sends `idl0_config.json` over BLE (FF05 + `CMD_CONFIG_BEGIN`/`CMD_CONFIG_COMMIT`, §7.2); the device reboots to apply. Requires idle mode (BLE control is suspended in WiFi mode, §10.4). The WiFi `POST /config` path (§6.1) remains as a fallback.

---

## 9. Coordinate System

**ISO 8855, right-hand:**
- X: forward
- Y: left lateral
- Z: up

**Sign conventions (right-hand rule):**
- Roll (about X): positive = left side down
- Pitch (about Y): positive = nose up
- Yaw (about Z): positive = turning left

**Suspension note:** Fork compression → negative Z on sprung IMU, positive Z on unsprung. Account for this in travel calculation.

**Sensor sign convention:** LSM6DSO32 reports specific force reaction (not gravitational acceleration). Stationary and upright: `accel_z ≈ +g`. Used as gravity vector target during calibration (see §20).

---

## 10. Device Behavior

### 10.1 Power
- Soft cutoff at minimum LiPo voltage (~3.3V/cell): write SESSION_END, flush SD, BLE notify "Battery critical", power off
- Hard cutoff: hardware undervoltage lockout. FAT32 survives ungraceful power loss on append-only files.
- App shows battery level, warning below 20%

### 10.2 SD Card

**Layout.**
- All session files live under `/sessions/` at the root of the FAT32 partition.
- At session start the firmware opens `/sessions/tmp_<boot_ms>.idl0` where `<boot_ms>` is `esp_timer_get_time() / 1000`. This name is used until the first valid GPS fix arrives.
- On first fix, the file is renamed to `/sessions/YYYY-MM-DD_HH-MM-SS.idl0` using UTC from `gps_epoch_ms`.
- If no fix is ever acquired during a session, the temp name persists. The app's `/files` listing (§6.1) is filename-agnostic and accepts both.
- No subfolders by date — the flat layout matches what the prototype produced and keeps the `/files` JSON simple.

**Durability.** During logging the writer commits on a ~1 Hz cadence: it flushes the 16 KB stdio buffer to the card and `fsync`s the file, writing back the directory-entry **size** (and the FAT). FATFS does not otherwise update a file's size until `f_close` (here: the first-fix rename and session close), so this periodic fsync is what keeps a power-interrupted session from reading as truncated — it bounds the frozen-size window to one flush interval. See §5.3 (SESSION_END semantics). Samples in the final ≤1 s before a hard cut reach the card but lie beyond the committed size and require raw-device recovery.

- Min free space threshold: 200 MB (~1.3 hr at peak load)
- At threshold: stop logging, BLE notify — do not crash
- Future: overwrite oldest session (config option, default off) — TODO #17

### 10.3 Version Compatibility
- All versions from v1.0 forward are mutually compatible
- Config JSON: firmware ignores unknown fields; app warns if firmware is newer
- Binary format: the app supports the current schema and the immediately prior schema during a transition window (≈2 weeks after a schema bump). After the window closes, the older parser is removed; files in that older schema are no longer readable by the current app.
- Binary record types: new types skipped by old parsers — never modify existing record layouts

### 10.4 RF coexistence — WiFi SoftAP vs. BLE

The firmware enforces a hard mutex between SoftAP and BLE central
(HRM) via the §7.2 ACK protocol: `CMD_WIFI_ON` returns `0x03` while
a session is running, and `CMD_START_LOGGING` returns `0x03` while
SoftAP is up. Coordination between subsystems happens through a
FreeRTOS event group (`mode_state.{h,c}`) with bits for `WIFI_UP`
and `LOGGING_ACTIVE`. `wifi_server.c` and `session.c` are the only
producers; subsystems that need to react (HRM, IMU, GPS) subscribe
via `xEventGroupWaitBits` / `xEventGroupGetBits`. New mode-aware
subsystems opt themselves in — no central-code changes required.

When WiFi comes up the HRM link is dropped (STREAMING → SUSPENDED)
and re-established when WiFi turns off. The IMU and GPS tasks likewise
suspend their sensor bus reads while `WIFI_UP` is set: the mutex
guarantees no session is logging, so there is no consumer for sensor
data, and IMU0 shares the SPI bus with the SD card — suspending hands
the bus and CPU to the `/download` path. The IMU FIFOs are drained
(discarded) and the GPS UART flushed on resume.

**Radio handoff — BLE off in WiFi mode.** The coexistence table marks
SoftAP (station connected) + BLE as "C1 — unstable", and the
time-slicing scheme cedes up to ~50% of radio time to a connected BLE
link. The firmware therefore drops the *peripheral* GATT (phone
connection) too, once the app no longer needs it:

1. `CMD_WIFI_ON` (BLE) brings the AP up. BLE stays fully up.
2. The app links over HTTP and verifies identity via `/ping` (§6.1).
3. The app sends `POST /handoff`; firmware disconnects the phone and
   stops advertising. WiFi now owns the radio outright.
4. WiFi mode ends via `POST /wifi_off` (HTTP), after which the AP
   tears down and BLE advertising resumes; the app reconnects.

Until `/handoff` arrives, `CMD_WIFI_OFF` over BLE remains the abort
path — a phone that never achieves an HTTP link is never stranded
without a control channel.

**No-activity failsafe.** While in WiFi mode the firmware tracks AP
station count and the last-HTTP-request time. Five minutes with no
connected station, or five minutes with no HTTP request, exits WiFi
mode autonomously and resumes BLE advertising — the device can never
be stranded in AP mode draining battery. The app's 10 s `/ping`
heartbeat keeps an active link alive indefinitely.

---

# PART 3 — APP ARCHITECTURE

## 11. App Architecture

### 11.1 Layers

```
UI (Dart/Flutter)
  └─ flutter_adaptive_scaffold, Riverpod providers, charts
Data (Dart)
  └─ Binary parser, session model, workspace, SQLite index
Transport (Dart)
  └─ BLE (flutter_blue_plus), WiFi HTTP, Google Drive, config push
Processing (Rust)
  └─ sci-rs: filters, FFT, integration, statistics
  └─ nalgebra: rotation matrices, vectors
  └─ Called via flutter_rust_bridge — compiles native on all platforms
```

**Decision rule:** Physics of the bike → Rust. App data structures, files, UI → Dart.

### 11.2 Platform Targets
- Android: primary (BLE + WiFi + analysis)
- Desktop (Windows/macOS): analysis, BLE optional
- iOS/web: PWA via Flutter web — analysis only, no BLE
- Responsive breakpoint: <600px = bottom nav, ≥600px = side rail (`flutter_adaptive_scaffold`)

### 11.3 State Management
Riverpod only. No Provider, no Bloc, no setState except local widget state.

### 11.4 File Model
| File | Ext | Mutable |
|------|-----|---------|
| Raw log | `.idl0` | Never — immutable after download |
| Workspace | `.idl0w` | Yes — all derived work |

`.idl0w` is versioned JSON (current schema: v7). Contains: lap/sector gates, annotations, channel colors, track visits with their cached detected laps (§17.4). Math channels and workbook layout live on the owning Workbook (`.idl0wb`, §17a) — they are not stored in `.idl0w`.

**Workspace lap gate list:** `lap_gates` is an ordered list. Only `lap_gates[0]` is used for timing; additional entries represent candidate positions the user has experimented with. An empty list means no gate has been placed yet.

**Workspace version handling:**
- `.idl0w` includes a `workspace_version` field
- If app opens a workspace with a higher version than it supports: surface a clean error — "This workspace was created with a newer version of IDL0. Update the app." Do not silently load partial data.
- If app opens a workspace with a lower version: migrate silently — forward migrations only, never destructive

### 11.5 Local Database
SQLite (sqflite) — session index cache only. Source of truth is always the files. Rebuild by rescanning session folder.

**Index API contract:** The index has no knowledge of the filesystem. To rebuild, the caller scans the session folder, parses each `.idl0` header into a `SessionMetadata` object (via the binary parser), and passes the full list to `SessionIndex.rebuildFromSessions()`. The index atomically replaces its contents with the provided list. The caller is responsible for reading the files; the index is responsible only for storing and querying the derived metadata.

**Session list population:** `sessionProvider` is populated once per app lifecycle by `sessionIndexLoaderProvider`, which fires when the Data tab is first built. After that point, `sessionProvider` is updated only by direct `SessionNotifier.addSession()` calls (e.g., after a file import or WiFi download completes). `sessionIndexLoaderProvider` does not poll or re-run unless explicitly invalidated.

---

## 12. State Management

**Riverpod only.** No Provider, no Bloc, no setState except local widget state.

Provider structure:
```
providers/
├── device_provider.dart         — BLE state, device config, recording
├── session_provider.dart        — loaded session metadata list
├── selection_provider.dart      — XOR session-or-lap app-wide selection
├── channel_provider.dart        — raw + calibrated channel data
├── math_channel_provider.dart   — lazy-evaluated math channel output
├── workspace_provider.dart      — active workbook/worksheet, layout
├── lap_provider.dart            — lap detection, gate definitions
├── data_filters_provider.dart   — Data tab faceted-search state
└── data_results_provider.dart   — derived SessionRow / TrackRow /
                                    FacetCounts for the Data tab
```

Math channel providers use `FutureProvider.family` — evaluated lazily on demand, never pre-computed.

**Selection (XOR).** `selectionProvider` is the single source of truth
for what the Analyze tab and other downstream consumers should render.
It carries a `mode` (`session` or `lap`) and exactly one populated set —
either `sessionIds: Set<String>` or `lapKeys: Set<LapKey>`. Toggling an
entry of the inactive kind flips mode and clears the inactive set; the
"session selected AND a lap selected" mixed state cannot exist.
Downstream consumers prefer the derived providers `effectiveSessionIdsProvider` (sessions to render — sessionIds in
session-mode, distinct sessionIds drawn from lapKeys in lap-mode) and
`effectiveLapKeysProvider` (lap-mode lapKeys, empty otherwise). The
Analyze tab currently honours session resolution only; the lap keys are
exposed for a follow-up pass to filter charts to specific laps.

See §13 for the full Selection Model specification.

---

## 13. Selection Model

### 13.1 Purpose

Selection state is app-global with a strict XOR rule: the user is either selecting whole sessions OR individual laps, never mixed. This eliminates the cognitive complexity of comparing "session A as a whole" vs "lap 3 of session B" — the typical comparisons are session-vs-session or lap-vs-lap.

**File.** `app/lib/providers/selection_provider.dart`.

### 13.2 Types

```dart
enum SelectionMode { session, lap }

class LapKey {
  final String sessionId;
  final int lapNumber;        // 1-based
  // Implements ==, hashCode, toString for Set semantics.
}

class Selection {
  final SelectionMode mode;
  final Set<String> sessionIds;     // populated when mode == session
  final Set<LapKey> lapKeys;        // populated when mode == lap
  final LapKey? mainLapKey;         // N-lap comparison reference; lap-mode only.
                                    // null ⇒ auto = fastest selected lap.
  bool get isEmpty => sessionIds.isEmpty && lapKeys.isEmpty;
}
```

`mainLapKey` designates the **Main** lap for N-lap comparison (§26.13) — the reference every selected lap is measured against. It is meaningful only in lap-mode and only when it is a member of `lapKeys`; `null` means "auto" (the fastest selected lap is Main). The overlay laps are derived (selected laps minus Main), never stored.

### 13.3 Provider

```dart
final selectionProvider =
    NotifierProvider<SelectionNotifier, Selection>(SelectionNotifier.new);

class SelectionNotifier extends Notifier<Selection> {
  Selection build() => const Selection(
    mode: SelectionMode.session, sessionIds: {}, lapKeys: {},
  );

  void toggleSession(String sessionId);   // flips to session-mode if needed
  void toggleLap(LapKey key);              // flips to lap-mode if needed
  void selectMany({Set<String>? sessions, Set<LapKey>? laps});
  void setMainLap(LapKey? key);            // designate Main, or null for auto
  void setMode(SelectionMode mode);        // also clears the inactive set
  void clear();
}
```

`setMainLap` is a no-op outside lap-mode or when `key` is not a current lap selection. The Main designation auto-resets to `null` (auto) when the Main lap is deselected, the selection is cleared, or the mode leaves lap.

### 13.4 Toggle Semantics

When the operation disagrees with the current mode, the inactive set is cleared and mode flips. Concretely: calling `toggleSession` while in lap-mode clears `lapKeys`, sets `mode = session`, then adds the sessionId. Same in reverse. UI surfaces (Data tab checkboxes, Session Sheet checkboxes) honor this — clicking a "muted" checkbox flips the global mode.

### 13.5 Derived Providers

Charts that operate on whole-session windows watch `effectiveSessionIdsProvider`, which returns `selection.sessionIds` in session-mode and `{for k in selection.lapKeys} k.sessionId}` in lap-mode (the parent sessions). Lap-aware charts watch `effectiveLapKeysProvider`, which returns `selection.lapKeys` in lap-mode and `{}` in session-mode.

```dart
final effectiveSessionIdsProvider = Provider<Set<String>>((ref) {
  final s = ref.watch(selectionProvider);
  return s.mode == SelectionMode.session
      ? s.sessionIds
      : s.lapKeys.map((k) => k.sessionId).toSet();
});

final effectiveLapKeysProvider = Provider<Set<LapKey>>((ref) {
  final s = ref.watch(selectionProvider);
  return s.mode == SelectionMode.lap ? s.lapKeys : const {};
});
```

### 13.6 Scope

Single source of truth, app-wide. No per-tab or per-worksheet selection state. The Data tab and Analyze tab's Session Sheet both read and write the same provider.

---

## 14. Error Handling

### 14.1 Exception Hierarchy
```
IdlException
├── ParseException
│   ├── InvalidMagicBytesException
│   ├── UnsupportedSchemaVersionException
│   ├── TruncatedRecordException
│   └── UnknownRecordTypeException
├── CalibrationException
│   └── InsufficientMotionException
├── MathChannelException
│   ├── UnknownChannelException
│   ├── ExpressionSyntaxException
│   └── DivisionByZeroException
└── TransportException
    ├── DeviceNotFoundException       — BLE scan: no device with IDL0 service UUID found
    ├── DeviceUnreachableException    — WiFi: connection refused, host unreachable, or non-200 on control endpoint
    ├── FileListParseException        — WiFi: /files response is not a valid JSON array (firmware version mismatch)
    ├── TransferTimeoutException      — file download did not complete within retry budget
    └── TransferChecksumException     — received file checksum does not match expected
```

### 14.2 Behavior

| Exception | Behavior | User message |
|-----------|----------|--------------|
| InvalidMagicBytes | Reject file | "Not a valid IDL0 log" |
| UnsupportedSchemaVersion | Reject file | "Update the app to open this file" |
| TruncatedRecord | Return partial session | "Log incomplete — showing data to [timestamp]" |
| UnknownRecordType | Skip record, continue | Silent (debug log only) |
| UnknownChannel | Inline editor error | "Channel '[name]' not in this session" |
| ExpressionSyntax | Inline editor error | "Syntax error at position N" |
| TransferTimeout | Retry 3× with backoff (transport layer retries — caller sees final result or exception) | "Transfer timed out. Check WiFi." |
| TransferChecksum | Discard, offer retry | "Transfer error. Retry?" |
| CalibrationException | Abort, keep previous | "Calibration failed — was bike stationary?" |

Hard crashes in response to bad data are never acceptable. Debug log ring buffer (last 500 entries) accessible via Settings → tap version 5×.

---

# PART 4 — APP DATA MODEL

## 15. Session & File Model

The `.idl0` binary parser and the parser-output data model live in the pure-Rust
**`idl-rs`** engine (`/rust/core`). The app consumes them through the
`idl-rs-bridge` flutter_rust_bridge shim: parsing returns a
`RustOpaque<SessionHandle>` that owns the parsed session in Rust, and the app
pulls output-shaped views on demand — a compact `session_metadata` summary, the
`session_channels` list, and per-channel `channel_samples` /
`channel_sample_times`. The handle is **retained** for the session lifetime by
`sessionHandleProvider`; chart/lap/UI consumers pull bounded views from it by
channel id (Y-bounds, tiles, spectra, slices, fix lists — see §15.3) rather than
draining whole channels into Dart. The handle also
carries an interior-mutable, **typed derived-channel store** keyed by kind:
math-channel outputs by name, and lap-windowed slices by their
`(source, role, lap)` identity, so a lap slice can never collide with a base or
math channel. The math evaluator (§19) reads base, synthesized, and resolved
math channels from it via a channel lookup; resolved math outputs are written by
name (`store_math`) so they never re-cross the FFI boundary as samples. Lap
slices are written by `slice_lap_into_store`, which returns the opaque storage
token the chart decimates by; the store is reclaimed declaratively by
`retain_derived` on the eval path (a deleted/renamed channel's entries drop,
while base-channel and live-math slices survive). The engine also synthesizes the derived `Time` and `Distance` base channels (the
highest fixed-rate time base; cumulative distance from `GPS_SpeedKmh`). GPX import
is the exception: parsed in Dart (`GpxParser`, §15.1) and wrapped into a handle via
`session_from_channels`. Because the engine is native code, the Rust path is
unavailable on the web build target until WASM bindings land (roadmap Phase 6).

### 15.1 Session Metadata

Source: `app/lib/data/session_model.dart`. Every field is `final` (immutable instance — copy via `copyWith` to mutate).

```dart
enum SessionSourceType { idl0, gpx }

class SessionMetadata {
  final String sessionId;             // UUID (stable identity), from the header
  final String filePath;              // absolute path to .idl0 (or .gpx)
  final String workspacePath;         // absolute path to .idl0w
  final int createdTimestampMs;       // recording start, UTC ms since epoch
  final int fileSizeBytes;
  final String rider;                 // default from bike profile
  final String bike;
  final String bikeComment;           // e.g. "Fresh tires"
  final String venueName;
  final String eventName;
  final String eventSession;          // "Practice 2", "Race run", etc.
  final String shortComment;          // shown in session list
  final String longComment;
  final String deviceId;              // last 4 hex of MAC, or "gpx-import"
  final int? lapCount;                // null if no gate set
  final int? durationMs;              // null if not yet computed
  final SessionSourceType sourceType; // default: SessionSourceType.idl0
  final String tag;                   // free-text label, default ""
}
```

**String field convention:** All `String` metadata fields are non-nullable and default to `""` when not yet entered. `""` means "not set" — there is no null representation. The UI must treat an empty string as "not entered yet."

**`createdTimestampMs` is the recording start time** — the engine's back-filled session start (`Session.timestampUtcMs`, §5.6), captured at import/parse. The Data tab date filter, grouping, and sort all operate on it.

**On-disk file naming.** A session's `.idl0`/`.gpx` log and its `.idl0w` workspace are named by the recording start in **local** time — `YYYY-MM-DD_HH-MM-SS` (`app/lib/data/session_filename.dart`) — so the raw files are human-browsable and sort chronologically. A same-second collision appends `-2`, `-3`, …; when the recording time is unknown (a log with no GPS fix to back-fill from, §5.6) the base falls back to the `sessionId`. `sessionId` stays the session's stable identity (SQLite index key, Drive naming §13, workspace ownership) — only the filename is timestamp-derived. The on-device SD card uses the same `YYYY-MM-DD_HH-MM-SS.idl0` scheme in UTC (§10).

**`tag`** is a free-text user-set label (e.g. `Practice`, `Heat 1`, `Race`, `Warmup`) that drives the tag chip filter in the Data tab. Default `""` (no tag).

**Track binding is not stored on `SessionMetadata`.** Cross-session anchoring (Track entities) is described in §16. Multi-track sessions and visit detection are described in §17.

No minimum session length. A few bunny hops is valid.

**Session source type:** `SessionMetadata.sourceType` distinguishes device-recorded `.idl0` sessions from imports. Two values today:
- `idl0` — recorded by an IDL0 device, parsed by the `idl-rs` engine. `filePath` points to a `.idl0` binary log.
- `gpx` — imported from a Garmin/Strava `.gpx` track via `GpxParser`. `filePath` points to the original `.gpx` file (kept verbatim — never converted to `.idl0`). `deviceId` is the literal string `gpx-import`. GPX-derived channels: `GPS_Latitude`, `GPS_Longitude`, `GPS_Altitude`, `GPS_EpochMs`, plus `HR_BPM` / `Cadence_RPM` / `Power_W` when the corresponding `<extensions>` are present. The Data tab shows a small `GPX` badge next to imported runs; the Drive sync row substitutes `.gpx` for the `.idl0` slot. Lap gates, sectors, and analyze-tab features apply uniformly across both source types.

### 15.2 Session Data Tree
```
Session
├── session_id, device_id, timestamp_utc
├── bike_profile snapshot, config_checksum
├── laps[]
│   ├── lap_number, lap_time_ms
│   └── sectors[] → sector_name, sector_time_ms
└── channels[] → channel_id, sample_rate_hz, samples[], sample_times_secs?, gaps[]?
```

`sample_times_secs` is present only for event-driven channels (`sample_rate_hz == 0`: HR_RR, wheel pulses, digital markers). It holds one timestamp per sample, in seconds relative to session t=0 — defined as the earliest record `timestamp_us` in the file (the first IMU/sensor sample). Fixed-rate channels leave it null; their sample `i` is implicitly at `i / sample_rate_hz`. The parser fills it from each `CHANNEL_SAMPLE`'s `timestamp_us` (§5.7); the Analyze chart plots event-driven channels against these times instead of the nominal rate (§21.2).

**IMU channels share one nominal rate on a reconciled grid.** Every IMU axis (`IMU{0,1,2}_*`) is assigned a single nominal `sample_rate_hz = 1e6 / period_us`, where `period_us = 1_000_000 / ODR` (integer division; `10_000` µs / 100 Hz when ODR is 0) — the same integer period the firmware back-counts each FIFO drain at (§5.5). A per-IMU received-rate (`(n − 1) / span`) is **not** used: the firmware stamps every sample on that integer grid and the only deviation is a dropped-sample event, so a per-IMU average just encodes each sensor's drop rate and would make co-located IMUs report different rates — blocking cross-IMU element-wise math. At parse finalization the engine reconciles each IMU channel onto one grid anchored at the earliest IMU first-sample (`t0`, step `period_us`). Each sample is placed at its **absolute** grid slot `round((ts − t0) / period_us)` — never by accumulating per-step advances — so the time→slot mapping is identical for every IMU and a sensor's own drops never drift its later samples. A forward jump leaves `advance − 1 = round(Δt / period_us) − 1` empty slots, linearly interpolated (in raw `i16` space) between the bracketing real samples; leading/trailing offsets are padded with held edge values; an out-of-order sample whose slot does not advance past the previous kept one (a sub-period backward step or duplicate at a FIFO drain boundary) is **dropped**. The result: all IMU channels are **equal-length and time-aligned**, so two co-temporal events land on the same sample index across IMUs to within ½ period — regardless of how differently the sensors dropped. Reconciliation is drop-proportional — a clean (no-drop) log is a no-op.

`gaps` records every synthesized run as `{start, len}` in sample-index (grid-slot) coordinates — interior interpolated fills and held edge pads alike — shared across an IMU's six axes. It is the honest record of where data was reconstructed: empty for every non-IMU channel and for any IMU channel with no drops. No consumer reads it yet (no FFT gap-exclusion, no UI shading); it exists so future quality features can threshold on it.

**TODO:** Workspace file forward-migration details (which fields are migrated, which are dropped, and what the user-facing message looks like when a newer-version `.idl0w` is opened by an older app) are not yet fully specified beyond the high-level policy in §11.4.

### 15.3 Sample lifecycle for chart rendering

The retained `SessionHandle` (§15 intro) owns every channel's samples — base, synthesized, and resolved math channels (the math store written via `add_channel`). Samples are stored **compactly**: each channel is a typed raw column (`RawColumn`) — IMU axes and i16/i32/f32 registry channels keep their raw wire values plus a `scale`/`offset` pair (2–4 bytes/sample); GPS and math channels are verbatim f64; synthesized `Time` is a zero-storage ramp (`value(i) = i / rate`) and `Distance` stores only GPS-rate metres, lazily interpolated onto the Time grid. Physical f64 is **materialized lazily** as `physical = (raw as f64) × scale + offset`, only for the consumer that asks, and is never resident. The Analyze chart decimates min/max tiles directly from it: `decimate_tile(handle, channel_id, tier, tile_index)` folds min/max per bucket over the raw column — no f64 window is materialized at any tier (an all-NaN tile for an absent channel). A session's samples therefore exist in exactly one place — the engine, in compact form — and never round-trip Dart→Rust for charting.

**The charts self-source every view by channel id.** Dart holds no copy of a channel's samples. Each Analyze chart is handed only channel *metadata* (`SessionChannelData`: `sessionId`, `channelId`, `sampleRateHz`, `length`, `isEventDriven`, built from `sessionChannelMetaProvider`) and pulls the bounded view it needs from the handle: the time-series line decimates tiles (`decimate_tile`) and reads Y-bounds from `channel_min_max` (engine-folded, no materialization) plus event-driven sample times from `channel_sample_times`; the FFT reads its spectrum from `welch_channel` (computed in the engine — only the `WelchResult` crosses FFI, never the samples); the histogram reads its value distribution from `channel_histogram` (binned in the engine — only the `HistogramResult` crosses FFI); the GPS map reads the fix list from `gps_track`, and for a channel-coloured trace one value per fix from `gps_channel_values` (the channel resampled nearest-sample onto the GPS fixes — only the small per-fix vector crosses FFI, never the column). Everything the chart renders is therefore a channel resident in the handle, addressed by id — including derived traces: a displayed **math channel** is evaluated-and-stored entirely engine-side (`eval_math_into_store(handle, expression, store_as, lap_ctx)` upserts the result under the channel name and returns only `(length, sample_rate_hz)` — the sample vector never crosses FFI), and a **lap-window slice** for the lap-compare overlay is sliced-and-stored engine-side via `slice_by_time_into_store` under a `'<id> (main)'` / `'<id> (overlay)'` name (only the length crosses FFI), then decimated like any channel. The Maths-tab expression preview likewise reads one decimated tile of the stored result, never the samples.

Decimated tiles are cached in the app (`ChartTileCache`, §26.8) and invalidated when:
- The session is removed from the active selection (which fires on session deletion from the library) — `SelectionNotifier` clears the cache slice.
- A math channel's expression changes — the tile cache is invalidated across every session for that channel id, and the next render decimates the upserted evaluator output straight from the handle. Hooked from `MathChannelNotifier.updateChannel` / `deleteChannel`.

The retained handle has a **bounded lifetime** (Phase E): `sessionHandleProvider`
is `autoDispose` and pins itself with `keepAlive()`, handing its link to a
`HandleResidencyController` along with the handle's engine-reported resident
size (`session_resident_bytes`). The controller keeps every selected session
resident plus the most-recently-used deselected ones that fit a **byte budget**
(1 GiB default — byte-based, not handle-count-based, so eight small sessions
and one season-scale log are budgeted alike); beyond it, it closes the
least-recently-used handle's link (the handle autodisposes; the provider's
`onDispose` calls `dispose()` on the handle, freeing its Rust samples
deterministically rather than at GC-finalizer time) and invalidates that
session's chart tiles. The per-session providers
that read the handle (`sessionChannelMetaProvider`, `channelBoundsProvider`,
`channelSampleTimesProvider`, `fftSpectrumProvider`, `gpsTrackProvider`,
`lapSlicedChannelProvider`, `sessionStartMsProvider`, `sessionLapsProvider`,
`visitLapsProvider`, `lapDistanceAccumulatorProvider`, `mathChannelEvalProvider`)
are `autoDispose` so deselect releases their handle subscriptions. Re-selecting
within the warm window reuses the live handle (no re-parse); beyond it, the
session re-parses on demand.

The `.idl0` file is the source of truth; the engine parses it and owns the parsed session. There is no separate process-global sample registry — the chart reads the handle the same way the math evaluator (§19) does.

---

## 16. Track Entity

### 16.1 Purpose

A Track is a venue + reference polyline + canonical gates that multiple sessions can be associated with. Tracks live in Drive (`IDL0/tracks/<uuid>.idl0t`) with a local SQLite cache for fast queries. This enables cross-session comparison ("my best lap on A-Line over the past year") without each session storing its own gate copy.

**File.** `app/lib/data/track.dart`. Local cache: `app/lib/data/track_index.dart`.

### 16.2 Track Shape

```dart
class Track {
  final String trackId;                        // UUID
  final String name;                           // user-facing
  final String venueName;                      // optional, free-text
  final LapTiming? lapTiming;                  // sealed union: Circuit | PointToPoint; null = no lap timing
  final List<NeutralZone> neutralZones;        // timing-pause regions
  final List<SectorGate> sectorGates;          // canonical sectors
  final List<GpsFix> referencePolyline;        // reference run geometry
  final int createdAtMs;
  final int updatedAtMs;

  factory Track.create({...});  // generates UUID + timestamps
  Map<String, dynamic> toJson();
  factory Track.fromJson(Map<String, dynamic> json);
}
```

### 16.2.a LapTiming Types

`LapTiming` is a sealed union defining how a Track's lap is bounded:

- **`Circuit(startFinish: LapGate, name: String?)`** — single gate that acts as both start and finish. Each crossing ends the current lap and begins the next. Lap 1 starts at the first GPS fix of the session. Useful for closed-loop tracks.

- **`PointToPoint(start: LapGate, finish: LapGate)`** — two distinct gates. Lap n runs from the nth `start` crossing to the nth `finish` crossing. Used for stages (downhill, enduro, time trials) where start and finish are at different locations.

- **`null`** — no lap timing configured. Sessions visiting this Track will produce zero laps until the user sets timing via the Track editor.

### 16.2.b NeutralZone

A region whose duration is excluded from lap timing:

```dart
class NeutralZone {
  final String name;                   // display label, e.g. "Pit lane"
  final LapGate enter;                 // gate that pauses lap timing
  final LapGate exit;                  // gate that resumes lap timing
}

class NeutralZoneVisit {
  final String neutralZoneName;        // name of the NeutralZone
  final int enterMs;                   // UTC ms, GPS-anchored
  final int exitMs;                    // UTC ms, GPS-anchored
  int get durationMs => exitMs - enterMs;
}
```

When lap detection encounters a crossing of `enter` while in a lap, the timer pauses. Crossing `exit` resumes. The duration `(exitMs - enterMs)` is subtracted from the lap's raw elapsed time. `Lap.neutralZoneVisits` records each detected enter→exit pair for lap-table display.

### 16.2.c Reference polyline only (canonical polyline rolled back)

Tracks no longer carry a derived "canonical" polyline. The 2026-05-08 polyline-averaging architecture (`canonicalPolyline`, `polylineSourceSessionId`, `polylineSourceLapCount`, `polylineDerivedAtMs` and `polyline_averager.dart`) is rolled back wholesale. Reference matching for variance now uses the user-designated **overlay lap's GPS verbatim** (no averaging, no synthesised geometry) — see §19 (`variance_time` / `variance_dist`) and §21.3 (main/overlay/starred designation). `Track.referencePolyline` is retained for the tracks-browser map preview and `TrackMatcher.findVisits`; loading a Track JSON with the four removed keys silently ignores them.

### 16.3 Storage Model

Drive is the source of truth; SQLite is a cache.
- Drive: `IDL0/tracks/<trackId>.idl0t` — JSON file, one per Track.
- Local cache: SQLite table `tracks` mirroring SessionIndex pattern. Columns: `track_id PRIMARY KEY`, `name`, `venue_name`, `created_at_ms`, `updated_at_ms`, `full_json TEXT`. The full JSON column lets us read the complete Track without joining other tables.

### 16.4 Drive Folder Layout

```
IDL0/
├── sessions/
│   └── YYYY-MM-DD_venue_rider/
│       ├── <session_uuid>.idl0   (or .gpx for imported)
│       └── <session_uuid>.idl0w
└── tracks/
    └── <track_uuid>.idl0t
```

### 16.5 TrackProvider

`app/lib/providers/track_provider.dart`. AsyncNotifier returning `List<Track>`. On build: load from local TrackIndex; in background, sync with Drive (download newer/missing tracks). Conflict policy: **last-write-wins by `updatedAtMs`**. Methods: `createTrack`, `updateTrack`, `deleteTrack`.

### 16.6 .gpx Import

Multi-select via file_picker (`allowMultiple: true`). One Track created per file. Default name = filename without `.gpx`. Reference polyline = parsed GPX trkpt list. Gates and sectors default to empty (user places them later via the Analyze tab gate UI). Duplicates allowed; deduplication is not attempted.

### 16.7 Track Creation from Session

Existing alternative path: pick a session, GPS becomes the reference polyline, current Workspace gates copy to the new Track. Useful when no external .gpx exists.

### 16.8 Venue Field

`Track.venueName` is a free-text grouping key with no separate Venue entity. The Tracks view's detail card surfaces an editable Venue field via `Autocomplete<String>` sourced from `distinct Track.venueName ∪ distinct SessionMetadata.venueName`. Submitting a new value creates the venue lazily; submitting an existing value merges this Track into that venue group. Renaming a venue is performed by `TrackNotifier.renameVenue(oldName, newName)`, which patches `venueName` on every Track matching `oldName` in a single batch write.

---

## 17. Multi-Track & TrackVisits

### 17.1 Purpose

A single session can visit multiple Tracks (e.g., a trail ride that hits 5 trails sequentially). The data model represents this as a list of TrackVisits per session, each with a time window. Lap detection runs per-visit using that visit's Track gates.

**Engine.** Visit detection runs in the `idl-rs` engine (`tracks::detect_visits`): it reads the session's `GPS_*` channels from the retained `SessionHandle` and takes each Track's reference polyline as input. The app maps Track config in and visit windows back through `track_matching_bridge.dart`, minting the `visitId` (the engine returns deterministic windows with no id). Storage in `Workspace.trackVisits` (per-session `.idl0w`). The track library / catalog remain app-side.

### 17.2 TrackVisit Shape

```dart
class TrackVisit {
  final String trackId;
  final int startTimestampMs;     // UTC ms, GPS-anchored
  final int endTimestampMs;
  final List<Lap> laps;           // cached laps detected within this window (§17.4)
}
```

Stored in `Workspace.trackVisits: List<TrackVisit>`. Workspace schema bump required when this is added (`_kSupportedWorkspaceVersion` increments; `fromJson` accepts missing field with default empty list). The `laps` array caches the laps detected within the visit window — see §17.4.

### 17.3 Visit Detection Algorithm

`tracks::detect_visits(handle, tracks, params)` reads the session GPS from the handle and returns an ordered list of visit windows. Tuning defaults (30 m / 5 s / 30 s) live once in the engine's `VisitParams::default()` — the app passes no overrides.

1. **Bounding-box pre-filter.** Reject Tracks whose polyline bbox doesn't overlap the session bbox. Cheap; rejects most Tracks for any given session.
2. **Distance-mark phase.** For each surviving Track, mark each session GPS sample as "on track" if its closest-point distance to the Track polyline is < `threshold_m` (default 30 m), in a flat-earth metric frame around the session centroid. Uses the engine's `closest_point_on_polyline`.
3. **Coalesce.** Group contiguous "on track" samples into windows. Allow up to `gap_tolerance_s` (default 5 s) of off-track samples within a window — covers GPS noise.
4. **Resolve overlaps.** If a sample is "on" multiple Tracks (rare), attribute to the one with smallest distance.
5. **Filter short visits.** Discard windows shorter than `min_visit_s` (default 30 s) — typically drive-bys, not real laps.

### 17.4 Caching

Run on session import; cache results in `Workspace.trackVisits`. Don't re-run on every session load. A "Rescan Tracks" action manually re-runs for a session — useful when new Tracks are added after import.

**Laps are cached with their visits.** When a session is parsed (import, WiFi download, GPX-as-session, or rescan), lap detection runs per visit using that visit's Track config, and the result is stored on `TrackVisit.laps`. The Data tab (§24) reads these cached laps to build its session/track aggregates and lap-time facets — it never parses a session on open. Cached laps are invalidated together with their visits: a rescan recomputes both under the current `trackVisitsLibraryHash`. The Analyze tab still detects laps live (`visitLapsProvider`, §17.6) so the lap table reflects in-session Track-gate edits immediately; only the read-only Data-tab browse uses the cache. A pre-cache workspace (visits present, `laps` absent) shows no laps in the Data tab until the next rescan populates them — opening the tab does not trigger a parse.

### 17.5 Lap Detection Reads Only Track

**Lap detection reads only Track.** `visitLapsProvider` resolves laps using `Track.lapTiming`, `Track.sectorGates`, and `Track.neutralZones`. The legacy workspace-over-track fall-through has been removed; `Workspace.lapGates` and `Workspace.sectorGates` remain in the model dormant — see future Session Gates feature for per-session analysis overlays that do not pollute the canonical Track.

**Detection runs in the engine.** The detection algorithm lives in the `idl-rs` engine (`laps::detect_laps`): it reads the session's `GPS_Latitude`/`GPS_Longitude`/`GPS_EpochMs` from the retained `SessionHandle`, takes the Track's gates / sector gates / neutral zones as input, and restricts to the visit window. It returns the lap table (laps, sectors, neutral-zone visits); the gate-crossing geometry, circuit / point-to-point timing, sector splits, and neutral-zone subtraction all live Rust-side. The Track config models and the track library remain app-side — only the algorithm is in the engine.

### 17.6 Lap Detection Provider

```dart
final visitLapsProvider = FutureProvider.family<
  List<Lap>,
  ({String sessionId, String visitId})>((ref, key) async {
    final ws = await ref.watch(sessionWorkspaceProvider(key.sessionId).future);
    final visit = ws.trackVisits.firstWhere((v) => v.visitId == key.visitId);
    final track = (await ref.watch(trackProvider.future))
        .firstWhere((t) => t.trackId == visit.trackId);
    final handle = await ref.watch(sessionHandleProvider(key.sessionId).future);
    // Engine reads GPS from the handle, restricts to the visit window, and
    // detects laps using Track.lapTiming / sectorGates / neutralZones.
    final results = await rust.detectLaps(
      handle: handle, timing: timingArg(track.lapTiming!),
      sectorGates: [...], neutralZones: [...],
      windowStartMs: visit.startTimestampMs, windowEndMs: visit.endTimestampMs);
    return [for (final r in results) lapFromRust(r)];
});
```

### 17.7 Lap Recording-Seconds

Each `Lap` and `Sector` carries both wall-clock epoch bounds
(`startTimestampMs` / `endTimestampMs`, UTC ms) and **recording-time second
bounds** (`startTimeSecs` / `endTimeSecs`, seconds on the uniform `Time` axis
where `Time[i] = i / rate`). The seconds are **engine-computed** in
`detect_laps`: it stamps every lap and sector boundary via
`SessionHandle::epoch_ms_to_time_secs`, which interpolates the epoch against the
`GPS_EpochMs` channel (the recording's wall-clock index) and divides by the GPS
rate, falling back to `(epoch_ms − timestamp_utc_ms) / 1000` against the
back-filled session origin when GPS is absent.

The engine owns epoch→Time conversion; Dart performs none. Consumers needing a
lap/sector position on the chart's time axis (math lap-context, chart lap
windowing) read these fields directly rather than converting from samples — laps
carry their own analysis-frame coordinates.

---

## 17a. Workbook Entity

A Workbook is a portable analysis template — worksheets, charts, math
channels, axes, layout — independent of any specific session.

### 17a.1 Storage

- File: `<workbookId>.idl0wb` (JSON, pretty-printed).
- Drive: `IDL0/workbooks/<workbookId>.idl0wb` — the canonical store.
- Local mirror: `<sessions-base>/workbooks/<workbookId>.idl0wb`.
- Cache: SQLite table `workbooks` mirroring the JSON in a `full_json` blob
  column, ordered by `updated_at_ms` descending.
- Conflict policy: last-write-wins by `updated_at_ms`.

### 17a.2 Schema (workbook_version = 1)

| Field             | Type     | Notes                                         |
|-------------------|----------|-----------------------------------------------|
| `workbook_id`     | string   | UUIDv4, stable across rename and sync.        |
| `name`            | string   | Display name; renameable.                     |
| `worksheets`      | list     | Ordered list of worksheets (see §26).         |
| `math_channels`   | list     | Derived channels (see §25).                   |
| `constants`       | list     | Named numeric constants for expressions.      |
| `created_at_ms`   | int      | UTC ms since epoch.                           |
| `updated_at_ms`   | int      | UTC ms since epoch; LWW key.                  |
| `workbook_version`| int      | Schema version. Currently 1.                  |

Each `math_channels` entry: `id` (string, stable; **optional** — defaults to
`name` when omitted so hand-authored files stay name-only), `name`, `expression`,
`quantity`, `units`, `sample_rate_hz` (number; `0` = inherit), `decimal_places`
(int), `color` (hex string `#AARRGGBB`). Each `constants` entry: `id` (optional,
defaults to `name`), `name`, `value` (number).

Newer-than-supported version throws `UnsupportedWorkbookVersionException`.
Missing optional fields default; older versions load cleanly (a `.idl0wb` with no
`constants` array loads with an empty constant set).

### 17a.3 Session binding (view context)

Workbooks are session-agnostic. At view time a `WorkbookViewContext` binds a
**primary** session and an optional **overlay** session. Charts render their
channels from the bound sessions. The view context lives in memory only —
not part of the `.idl0wb` payload.

### 17a.4 Sync

Drive upload is debounced per workbook (default 30 s, configurable per
workbook). Mutations within the debounce window coalesce into one upload.
"Force sync now" flushes pending uploads immediately. Per-workbook sync can
be disabled — then mutations stay local until the user toggles it back on.

### 17a.5 Import policy

When importing a `.idl0wb` file:

- No local match (UUID not in the local index) → import as-is, preserve UUID.
- Local UUID match → user picks **Replace** (overwrite local) or **Import
  as copy** (fresh UUID, "(Copy)" suffix).

---

## 17b. Track Artifact (`.idl0t`)

A **portable Track file** — one Track's analysis config (gates, timing,
reference polyline), independent of any session. The GUI authors Tracks (§16)
and exports them; the `idl-rs` engine and CLI consume them for headless lap /
track analysis (§29.6). One Track per file.

### 17b.1 Schema (`track_artifact_version = 1`)

JSON, pretty-printed. A version wrapper around the Track entity's serialization
(`Track.toJson`), so the file *is* the Dart↔engine contract:

```json
{
  "track_artifact_version": 1,
  "track": {
    "track_id": "…uuid…", "name": "A-Line", "venue_name": "Whistler",
    "lap_timing": { "kind": "circuit", "name": "S/F", "start_finish": { …gate… } },
    "sector_gates":  [ { "name": "S1", "gate": { …gate… } } ],
    "neutral_zones": [ { "name": "Pit", "enter": { …gate… }, "exit": { …gate… } } ],
    "reference_polyline": [ { "timestamp_ms": 0, "latitude_deg": …, "longitude_deg": … } ],
    "created_at_ms": …, "updated_at_ms": …
  }
}
```

Gates are `lat1_deg`/`lon1_deg`/`lat2_deg`/`lon2_deg` (+ optional `name`);
`lap_timing` is omitted when unset; coordinates are raw degrees × 1e7. The
engine reads `track_id` (visit identity) + `name`/`venue_name` (display) and the
analysis fields; it ignores the timestamps. A reader rejecting a higher
`track_artifact_version` surfaces a typed error.

### 17b.2 Storage

Not in the SQLite catalog — a standalone file the user saves/opens via an OS
file picker (export from the track editor; import from the Tracks panel).

### 17b.3 Import policy

- No local match (`track_id` not in the library) → import as-is, **keeping the
  file's `track_id`** (preserves identity across share / re-import).
- `track_id` match → user picks **Update in place** (replace fields, keep id) or
  **Import as new copy** (fresh id). Matching is `track_id`-only.

---

## 18. Bike Profiles & Riders

### 18.1 Profile Model
```json
{
  "profile_id": "uuid",
  "name": "Trek Session 2024",
  "type": "full_suspension",
  "imu_count": 3,
  "default_rider": "Isaac",
  "wheel_circumference_front_mm": 2300,
  "wheel_circumference_rear_mm": 2300
}
```

`default_rider` pre-populates rider field on every downloaded session. Overridable per session in Data tab.

### 18.2 Profile Management
- Created/managed in Device tab
- Stored in SQLite
- **Config never auto-pushed** — user reviews and pushes manually
- Post-session: profile editable in Data tab metadata editor (updates `.idl0w` only, not log file)

### 18.3 Multi-Device
- App manages multiple IDL0 devices simultaneously
- Devices identified by `IDL0-XXXX` (last 4 of MAC)
- Data tab filterable by device ID and rider

---

# PART 5 — APP PROCESSING

## 19. Signal Processing Pipeline

All steps run in Rust — the `idl-rs` engine crate in the repo-root `/rust/`
cargo workspace — exposed to the app through the `idl-rs-bridge`
flutter_rust_bridge shim and reusable headlessly via the `idl-rs` CLI.

**Engine (`idl-rs`) dependencies — pure, no Flutter:**
```toml
sci-rs = "0.4"      # scipy.signal equivalent
nalgebra = "0.33"   # linear algebra
rustfft = "6.2"     # FFT
```
`flutter_rust_bridge` is a dependency of `idl-rs-bridge` only — never the engine.

**Default pipeline per IMU channel:**
1. Bias subtraction — nalgebra vector subtract (`imu.bias` from config)
2. Rotation — nalgebra 3×3 matrix multiply → vehicle frame (ISO 8855)
3. Input — IMU samples arrive as physical values (g and dps); the parser applied scale/offset from the channel registry (§5.2) before handoff.
4. High-pass filter — sci-rs `butter` order 2, cutoff 0.15–0.3 Hz, applied via `sosfiltfilt` → Rust: `highpass(data, order, cutoff_hz, sample_rate_hz)`
5. Integration (where needed) — trapezoidal rule, `output[0] = 0.0`, output length = input length → Rust: `integrate(data, sample_rate_hz)`. sci-rs 0.4 has no `cumtrapz`; implemented directly.
6. High-pass filter (post-integration) — second `sosfiltfilt` pass

All steps user-overridable via math channel expressions.

**Rust API notes (flutter_rust_bridge):**
- Filters: `highpass(data, order, cutoff_hz, sample_rate_hz)` / `lowpass(...)`. No single `butter()` function. Math channel `butter(order, cutoff, type, ch)` maps to these at eval time.
- FFT: `fft(data, window)` → one-sided linear magnitude spectrum, `n/2 + 1` bins. Caller computes `freq[k] = k × sample_rate_hz / n`. Output is `|X[k]|`, not power. Backs the math-channel `fft(ch, window)` function.
- Welch: `welch(data, sample_rate_hz, window, nperseg, noverlap, detrend, averaging, scaling)` → `WelchResult { freqs_hz, values }`, both `nperseg/2 + 1` bins. Segmented, averaged spectral estimation composed on `rustfft` (sci-rs has no spectral API). `nperseg = 0` or `≥ len` ⇒ one full-record segment, which with rectangular window and no detrend reproduces `fft()` bin-for-bin. `detrend` ∈ {None, Mean, Linear}; `averaging` ∈ {Mean, Median}; `scaling` ∈ {Magnitude (RMS, input units), Density (PSD, units²/Hz)}. Backs the FFT chart. See `docs/signal_pipeline.md`.
- Windowed Welch: `welch_channel_windowed(handle, channel, t0_secs, t1_secs, …)`
  slices the channel to an inclusive time window then runs `welch()` at the
  channel's rate — backs the auto-windowing FFT chart (§26).
- Spectrogram: `spectrogram(data, sample_rate_hz, window, nperseg, noverlap,
  detrend, scaling) → SpectrogramResult { freqs_hz, times_secs, power (flat
  row-major n_times × n_freqs), n_times, n_freqs }`. Same segmentation as
  `welch()` (shared `stft()` core), kept per-frame instead of averaged. The
  `spectrogram_channel(handle, channel, t0_secs, t1_secs, …)` accessor windows
  it; `times_secs` are absolute session seconds. Backs the spectrogram chart
  (§26) and the `idl-rs spectrogram` CLI command (§29). The math-channel
  `spectrogram(ch)` function stays deferred (a 2-D result has no 1-D channel form).
- Rotation matrix: flat 9-element row-major `Vec<f64>` (FRB cannot serialize `[[f64;3];3]`). Format shared by `rotation_from_gravity()` output and `apply_rotation()` input.
- Declip: `declip(data, sample_rate_hz)` → same-length signal with ±32 g-clipped segments reconstructed via a tuned analytic pulse. Shape constants are tuned offline against real sub-limit events (dev-only Rust harness, `#[cfg(test)]`) and baked into `default_params()` in `rust/core/src/clip_reconstruct.rs`. Non-clipped input returned unchanged.
- Cross-session analysis: `table::evaluate_table_multi(...)` evaluates a table whose rows bind different sessions (per-row `SessionHandle`, cross-row `{col[]}` preserved in one pass; `main({col[]})` reads the Main row) and `variance::variance_traces(reference, targets, channel_id, mode)` computes N overlay-vs-Main delta series in time or distance — the N-lap comparison substrate. See §26.11, §26.13.

**Math channel functions (scipy-equivalent names):**

| Category | Functions |
|----------|-----------|
| Filters | `butter(order, cutoff, type, ch)`, `sosfilt(sos, ch)` |
| Time-domain | `integrate(ch)`, `differentiate(ch)`, `rms(ch, w)`, `mean(ch, w)`, `std(ch, w)`, `median(ch, w)`, `detrend(ch)` / `detrend(ch, mode)` — global least-squares trend removal over the sample index; `mode` = `"linear"` (default) \| `"constant"` (alias `"mean"`) \| `"none"`; NaN-aware (fit over finite samples, dropouts left in place) |
| Aggregates (channel → scalar) | `mean(ch)`, `max(ch)`, `min(ch)`, `sum(ch)`, `std(ch)`, `rms(ch)`, `median(ch)`, `p(ch, q)`, `first(ch)`, `last(ch)`, `count(ch)` |
| Reconstruction | `declip(ch)` — rebuilds acceleration peaks clipped at the ±32 g rail by fitting a smooth asymmetric pulse to each clipped segment's shoulders; `ch` unchanged where nothing is clipped |
| Frequency | `fft(ch, window)`, `spectrogram(ch)`, `hilbert(ch)` |
| Correlation | `correlate(a, b)`, `convolve(ch, kernel)` |
| Resampling | `resample(ch, hz)` |
| Math | `abs`, `sqrt`, `pow`, `sign`, `min`, `max`, `clamp`, `floor`, `ceil`, `round` |
| Trig | `sin`, `cos`, `tan`, `asin`, `acos`, `atan`, `atan2`, `sinh`, `cosh`, `tanh`, `deg2rad`, `rad2deg` |
| Vector | `vec(x, y, z)`, `vx(v)`, `vy(v)`, `vz(v)`, `vadd(a, b)`, `vsub(a, b)`, `vscale(v, s)`, `cross(a, b)`, `dot(a, b)`, `norm(v)`, `normalize(v)`, `angle(a, b)` |
| Rotation | `rotate_mat(v, r00, r01, r02, r10, r11, r12, r20, r21, r22)`, `rotate_axis(v, ax, ay, az, angle)`, `rotate_euler(v, roll, pitch, yaw)` |
| Logic | `if(cond, t, f)`, `and`, `or`, `not` |
| Range | `ch[t_start:t_end]`, `ch[lap_n]` |
| Variance — temporal | `variance_time(ch)` — main − overlay at the same lap-relative time, position-matched via Rust track projection |
| Variance — spatial | `variance_dist(ch)` — main − overlay at the same arc length along the overlay lap |
| Lap | `current_lap()` — 1-based lap number at each sample, `0` outside any lap |
| Lap | `lap_start_time(n)` — session-relative start time (s) of lap `n`, `NaN` when out of range |
| Lap | `sector_number()` — 0-based sector index at each sample, `NaN` outside any sector |

**Aggregates (channel → scalar).** Each reduces a channel (or a `{col[]}` table
column, §26.11) to one value over its finite samples — non-finite samples are
skipped; an empty/all-non-finite input yields `NaN`. `p(ch, q)` is a
linear-interpolated percentile (`q` in 0..=100); `std(ch)` is the population
standard deviation. **Arity selects** for the names that also have a
windowed/elementwise form: one channel argument is the scalar aggregate
(`mean([Fork])` = whole-channel mean), two arguments keep the prior form
(`mean([Fork], w)` = rolling mean; `min(a, b)` = elementwise). This makes
de-meaning natural in channel math — `[Fork] - mean([Fork])` — as well as
backing table cells. `sum`/`p`/`first`/`last`/`count` have no two-argument form.
A scalar-valued top-level expression returns a single-sample, rate-0 channel.

**Logic keyword syntax:** `and`, `or`, `not` are infix/prefix keywords, not call-style functions. Valid: `x > 0 and y < 10`. Invalid: `and(x, y)`. The validator does not check `and`/`or`/`not` against the function-call pattern; `if` is the only Logic entry that uses `(` syntax.

**Vector & rotation primitives.** `vec(x, y, z)` assembles a 3-vector from scalars or channels (scalars broadcast across every sample). A 3-vector is an **intermediate** value: charts plot scalars, so the top-level result of an expression must reduce back to a scalar channel via `vx`/`vy`/`vz` (component) or `norm` (magnitude) — a bare top-level vector is a typed error advising which extractor to use. All operations work element-wise over the component buffers, following the same broadcasting rules as scalar/channel arithmetic (channel operands must share sample rate and length). `cross`/`dot`/`norm`/`normalize`/`angle` are the usual `nalgebra` operations; `angle(a, b)` returns radians in `[0, π]`. Rotations apply inline (no matrix/quaternion data type): `rotate_mat` takes a 3×3 **row-major** matrix (same layout as `rotation_from_gravity` output), `rotate_axis` is axis-angle (axis normalised internally; a zero axis is an error), and `rotate_euler` takes intrinsic roll/pitch/yaw — its angle args may be channels, giving a per-sample (time-varying) rotation. The frame-at-axle rigid-body acceleration transfer (lever-arm `a_O + α×r + ω×(ω×r)`) is the motivating consumer. Implemented in `idl-rs` `math::vector`.

**User-defined constants:** Constants created in the Maths tab Constants panel are inserted as inline numeric literals (e.g., selecting `g = 9.81` inserts `9.81`). There is no symbolic constant reference syntax for user constants — changing a stored value does not update existing expressions that used it. User constants travel with the workbook (`.idl0wb` `constants`, §17a).

**Universal constants:** Four scalar constants are recognised as **bare identifiers** in any expression and resolve to a literal at parse time — no store, always available, portable: `pi` (π), `tau` (2π), `e` (Euler's number), and `g` (standard gravity, `9.80665` m/s²). They are lowercase and case-sensitive. Because channel references are always bracketed (`[g]`), a bare `g` is unambiguously the constant — e.g. `[IMU1_AccelZ] * g` converts an acceleration in g-units to m/s². Defined in `idl-rs` `math::parse`. (The chip editor renders expressions that use a bare constant in Text mode rather than as chips.)

**Variance functions.** `variance_time` and `variance_dist` compare the session's **main lap** against an **overlay lap** (which may live in another session — cross-session compare). Both reads come from the per-session workspace's `mainLapNumber` and `overlayLapKey` fields (§21.3). `variance_time` projects each main-lap sample's `(E, N, heading)` onto the overlay lap's GPS polyline (Rust `Projector`, `rust/core/src/track_projection.rs`) — heading mismatch > 90° rejects the segment (kills the switchback case) — then linearly interpolates the overlay channel value at the projected `t_ref` and subtracts from the main sample. `variance_dist` interpolates the overlay channel at the main sample's arc length. Samples that fail to project (out of range, heading mismatch, overlay shorter than main) emit `NaN`; the expression does not abort. When either `mainLapNumber` or `overlayLapKey` is unset the function throws a `MathChannelEvaluationException` with a user-facing message — variance does not silently fall back to a default lap. The new gate-aware functions `current_lap()`, `lap_start_time(n)`, and `sector_number()` read lap and sector windows from the same per-session workspace (Rust helpers in `rust/core/src/variance.rs`). See §21.3 for the main/overlay/starred model.

**Time as a base channel.** `Time` is a synthesised built-in channel with `samples[i] = i / sampleRateHz`, where `sampleRateHz` is the highest non-event-driven channel rate in the session. Not stored on disk — re-synthesised on each session load. Appears in the channel picker alongside `GPS_SpeedKmh` etc., and lets math expressions reference session-relative time directly (e.g., the tutorial `LapTime` channel is `Time - lap_start_time(current_lap())`).

**Expression engine.** The math-channel expression engine — tokenizer, recursive-descent parser, evaluator, value types (channel / scalar / string), and the function set above — lives in the `idl-rs` core `math` module and is consumed by the app through the bridge call `eval_math_into_store(handle, expression, store_as, lap_ctx)`, which evaluates, upserts the result into the handle's math store under `store_as`, and returns only `(length, sample_rate_hz)`. The evaluator reads `[ChannelName]` references from the retained `SessionHandle` (§15) via a channel lookup over base, synthesized, and resolved math channels; lap-aware and variance functions consume an injected lap context (lap/sector windows in session-relative seconds, plus the overlay session as a second handle for `variance_*`). A scalar-valued expression returns a single-sample, rate-0 channel. Errors surface as a typed `MathChannelException` (§14). The **cross-channel dependency resolver** — which evaluates referenced math channels first and writes their results back into the handle via `add_channel` — lives in the `idl-rs` core (`math::resolve`); the app invokes it through the bridge call `resolve_math_dependencies(handle, target, defs, lap_ctx)` before evaluating the target expression, while the lap context itself is still assembled in Dart from the session's `.idl0w` annotations. Reading a **portable workbook** (`.idl0wb`) and applying its math channels to a session is likewise an engine capability (`workbook::apply_workbook`), consumed headlessly by the CLI (§29.5). The deferred functions `spectrogram`, `hilbert`, `correlate`, `convolve`, `resample`, and `sosfilt` parse and validate but throw "not yet implemented" at evaluation time; the two-argument rolling `median(ch, w)` is likewise deferred, while the one-argument aggregate `median(ch)` is implemented. The same evaluator backs **table cells** through `evaluate_scalar` (require a single scalar result) with a cell-aware channel lookup; channel math never sees the `{cell}` namespace — `ChannelLookup::lookup_cell` defaults to "none", so the Maths editor is structurally firewalled from cells (§26.11).

---

## 20. Calibration

**Trigger:** "Calibrate IMUs" button in Device tab. Precondition: bike stationary, upright, rider off.

**Process:** ~5 seconds of samples averaged. Computes per IMU:
- **Rotation matrix** (3×3): maps sensor body frame → vehicle frame
- **Bias** (6-element): zero-g accel offset + zero-rate gyro offset

**Output:** Written to `imu.orientation` and `imu.bias` in `idl0_config.json`.

**Tolerance:** ±1° from vertical acceptable. Warn if gravity vector >5° from Z axis.

**Sensor sign convention:** LSM6DSO32 reports specific force reaction. Stationary and upright: sensor reads ≈ `[0, 0, +g]`. Calibration target is vehicle Z = `[0, 0, 1]`.

**Rotation matrix format:** 9-element flat row-major `Vec<f64>`. Stored in `idl0_config.json` as a 9-element JSON array. Degenerate case (sensor exactly antiparallel to vehicle Z): falls back to 180° rotation about vehicle X axis.

---

## 21. Analysis Features

### 21.1 Data Views
- Time-series graph — multi-channel, overlay laps, synchronized cursor
- FFT — multi-channel, one line per assigned channel sharing the frequency axis; event-driven channels skipped. Computed via Welch's method (`welch()`). Slot properties, configured in the chart properties dialog: window function (Hann/Hamming/rectangular per `FftWindow`), segment length (blank = auto: largest power of two ≤ n/8, clamped 256–8192), overlap %, detrend (None/Mean/Linear), averaging (Mean/Median), scaling (Magnitude/Density), the frequency X scale (linear/log), and the shared magnitude-Y scale (`yScale`, §26.12). Defaults (auto segment, 50 % overlap, Mean detrend, Mean averaging, Magnitude) yield a smoothed, DC-suppressed spectrum out of the box; a single full-record segment with no detrend reproduces the raw periodogram. Log / non-linear transforms applied app-side (fl_chart has no native non-linear axis).
- Histogram — suspension travel, velocity, brake pressure
- GPS map — track display, channel-colored overlay, lap/sector gate editor
- Gauge — single-value at cursor
- Lap time table — lap × sector matrix
- Lap-time progression chart — line per session, X = lap index, Y = lap time s
- Ghost-delta chart — per-sample time delta vs a reference lap (see `docs/design_rationale.md` for sector timing & ghost lap implementation rationale)
- Statistics panel — min/max/mean/RMS for selected range

**Worksheet kinds** (runtime workbook in `WorkspaceState`, persisted via `shared_preferences`):

- **Standard** — blank slate the user fills with chart slots manually.
- **Session Sheet** — pins a `lapTable` slot at index 0 and a `lapProgression`
  slot at index 1; both refuse removal via `WorkspaceNotifier.removeChart`
  (no-op + `debugPrint`). Below the pinned pair, the user may add any
  standard chart (time series, FFT, GPS map, ghost). The `_ChartHeader`
  renders a pin badge on pinned slots and hides the properties / remove
  buttons. Multiple Session Sheets per workbook are supported.

A new workbook ships with one of each (`Session` + `Charts`); legacy
workbooks loaded from prefs that pre-date Session Sheets get one prepended
on first read (one-shot at load time, never on save — so a user who deletes
their Session Sheet keeps it deleted within the same app session). The
worksheet-tab `+` is a `PopupMenuButton<WorksheetKind>` offering both
kinds; Session Sheet tabs render with a leading `Icons.list_alt` badge.

The lap table and lap progression chart honour the global XOR selection
model (`selectionProvider`, §13): per-row checkboxes call `toggleSession`
or `toggleLap`, mute the inactive-mode column at 40 % opacity, and tapping
a muted box flips the mode atomically. The lap-progression chart's "scope"
is `effectiveSessionIdsProvider` so it works in both modes — the parent
session of any pinned lap key surfaces its full progression line.

### 21.2 X Axis Modes (all time-series graphs)
- **Time** — elapsed from gate (default)
- **Wheel distance** — integral of wheel speed (requires sensor)
- **GPS distance** — cumulative along GPS track

**Channel presence detection:** Wheel distance mode requires a channel with ID `WheelFront` or `WheelRear`. GPS distance mode requires `GPSSpeed`. Detection is by exact ID equality, not substring match.

**Fallback when data absent:** If the selected mode's required channel is not present in the active channel set, the chart falls back to time-axis display and shows a warning banner. The `workspaceProvider` retains the requested mode — it does not revert to `time` automatically. When the required channel is subsequently loaded, the chart switches without user action.

**Event-driven channels (`sampleRateHz == 0`):** Channels with zero sample rate (HR_RR, wheel pulses, digital markers) are plotted against their per-sample timestamps, self-sourced from the handle via `channel_sample_times` (`channelSampleTimesProvider`) — sample `i` is placed at `sampleTimesSecs[i]` seconds, not `i / rate`. This keeps an irregular channel on the correct wall-clock position: without it, one sample per heartbeat plotted at the fallback 1 Hz stretches the axis by the mean event rate (e.g. HR_RR at ~120 bpm would span 2× the real session duration). Decimation is unchanged — tiles still hold index-bucketed min/max envelopes; only the bucket→X mapping and the viewport→sample-range mapping read the timestamp array (`sampleXSeconds` / `sampleIndexAtTime` in `time_series_chart.dart`). A channel that somehow has no per-sample times still falls back to the 1.0 Hz index mapping.

### 21.3 Lap Detection
- Start/finish gate drawn on GPS map by tapping two points
- Placeable after first lap — retroactively scores lap 1
- Sector gates defined same way — multiple per lap
- **Circuit mode** (one gate, acts as start and finish): each crossing ends the current lap and starts the next. Lap 1 starts at the first GPS fix of the session. 0 crossings → 0 laps.
- **Point-to-point mode** (separate start gate + finish gate): each start→finish pair = one lap. Used for stages (downhill, enduro) where start and finish are at different locations.
- **Crossing algorithm:** 2D line-segment intersection with the flat-earth approximation (lat/lon treated as Cartesian x/y). Accurate to centimetres for gate lines under ~100 m.
- **Sector gates** are global to the workspace — they apply to every lap regardless of which start/finish gate configuration is active.

**Gate model and storage (workspace_version 2):** Each `LapGate` carries a `name` field (display label, defaults to empty string for v1 files; the UI substitutes `Start/Finish` or `S<n>` when empty). All gate coordinates are stored at the firmware × 1e7 scale (deg × 1e7) — same scale as `GPS_Latitude` / `GPS_Longitude` channel samples — so the detector can compare gate vs. track without any unit conversion. The first entry of `Workspace.lapGates` is the start (and the finish, in circuit mode); a second entry promotes the session to point-to-point with that entry as the finish line. Additional entries beyond the second are stored but unused, so users can park alternative gate positions in the same file.

**Ghost lap timing:** `Workspace.referenceLapNumber` (nullable, also new in v2) pins which lap acts as the comparison baseline for ghost-delta charts. `null` means "use the fastest lap" — the comparison auto-selects whichever lap currently has the shortest time, even when a faster one is recorded later in the session. Ghost-delta views are transient (full-screen modal route, not stored as workbook chart slots); pin a reference lap to make the auto-selection deterministic across runs of the comparison.

**Main / Overlay / Starred designation.** Per-session `.idl0w` carries three nullable fields (`Workspace.mainLapNumber: int?`, `Workspace.overlayLapKey: ({String sessionId, int lapNumber})?`, `Workspace.starredLapNumber: int?`) that replace the old top-level `WorkspaceState.baselineLapKey`. **Main** is the lap variance functions evaluate over (the "this lap"). **Overlay** is the reference lap they compare against — it carries a `sessionId` so the overlay can live in a different session (cross-session compare), and is resolved at evaluation time through `sessionProvider` + `sessionWorkspaceProvider` + the overlay session's retained handle (its lap-window slice is taken with `slice_by_time_into_store`). **Starred** is independent of main/overlay; it drives lap-table emphasis and gauge defaults, defaults to the fastest non-ignored lap when null, and is user-overridable from the lap-table star column. `variance_time` and `variance_dist` (§19) read `mainLapNumber` and `overlayLapKey` directly; missing either throws a `MathChannelEvaluationException`. Lap-table UI surfaces both designations as radio columns; a "Pick from another session…" affordance opens the cross-session overlay picker scoped to sessions whose workspaces have a `TrackVisit` to the active Track. The legacy `Workspace.referenceLapNumber` (introduced in workspace v2 for ghost-delta charts) is retained — it pins the ghost-delta reference and is independent of main/overlay/starred.

**Ghost lap delta filtering.** Raw per-sample deltas pass through a three-phase pipeline. Phase 1 is the forward-monotonic projection matcher with a direction filter that surfaces both the delta and the squared projection residual (target-to-polyline distance) per sample. Phase 2 is a narrow centered median (default width 3) that kills isolated single-sample garbage. Phase 3 is a confidence-weighted Gaussian: each output sample is a weighted mean of neighbours within a ± time window, weighted jointly by temporal proximity and per-sample confidence (`exp(-residual / driftSensitivity²)`), so noisy samples in switchback terrain attenuate to near zero while clean projections carry the result. The smoothing window is expressed in seconds rather than samples so behaviour is consistent across 1 Hz Strava exports and 10 Hz device data. A rider stopping mid-track produces a small residual (the target parks on the polyline at one point), so confidence stays high, no smoothing is applied, and the legitimate 1 s/s slope passes through cleanly.

### 21.4 Cross-Rider Comparison
- Overlay multiple sessions on shared X axis
- Time-from-gate: phase shifts = time deltas
- Lap time delta derived channel: `t_A(x) - t_B(x)` at same X value
- See §21.2 for X axis options — wheel/GPS distance available for position-normalized comparison

See `docs/design_rationale.md` for sector timing & ghost lap implementation rationale.

---

# PART 6 — APP UI

## 22. UI Structure

### 22.1 Navigation
- Mobile: bottom nav bar (4 tabs)
- Desktop: left side rail (4 tabs)
- `flutter_adaptive_scaffold`, breakpoint 600px
- **Small desktop window (< 600 dp):** bottom NavigationBar — same as mobile. A Drawer is never used (`useDrawer: false`). Width alone determines the navigation widget; platform (mobile vs. desktop) does not.

### 22.2 Tab responsibilities

Everything about a connected device lives on the **Device tab** (§23): the
Device card (status, recording, push/pull config, **file sync**) and the Config
card (profile + channels). The **Data tab** (§24) is purely the **library** —
browsing/filtering recorded sessions and tracks plus Drive sign-in; it has no
device-connection surface. Device file download is reached from the Device
card's Files entry (which drives WiFi automatically), not the Data tab.

---

## 23. Tab — Device

The Device tab manages the BLE connection, the active bike profile, and the per-channel configuration that gets pushed to the device.

The tab is organised as **two cards**: the **Device card** (the hero — live status, mode-as-info, recording, push/pull config, and file access; §23.10) and the **Config card** (profile bar + channel table; §23.2/§23.3). Calibration (§23.5) is a collapsed section below both cards.

### 23.1 Connection panel

BLE scan / connect / disconnect, with the §7.3 status characteristic rendered as a live status pane: battery, SD, GPS, IMU, and (when Spec 2 lands) HR + HR_Battery. Status rows showing values that are not auto-refreshed are annotated as such — auto-refresh / refresh-button is tracked as a follow-up task.

### 23.2 Profile bar

A profile is one complete bike-specific configuration; the app stores a library of N profiles as JSON files at `<docs>/profiles/<uuid>.idl0p`. One profile is active at a time; **Push Config** pushes only that profile's `config` sub-object.

- **Dropdown** — lists profiles by `profile_name`, single-select. Selection updates the active pointer.
- **`+`** — opens "New profile" dialog (name + "Duplicate active" toggle, defaulting on).
- **Kebab** — Rename · Duplicate · Delete · Import from file · Export to file. Delete is refused for the last remaining profile (a profile library cannot be empty).

The active profile id is persisted to `SharedPreferences` key `idl0.profiles.active_id`.

### 23.3 Channel table

One expandable parent row per `ChannelSource` (IMU0/1/2, GPS, Wheel Speed, Analog, Digital, and Spec 2's HRM). Columns: **Source · Rate Hz · Channels (`enabled/total`) · Enabled · ⚙** (source-level dialog).

Expanded child rows show each individual channel: **Name · Rate Hz · units · scale · offset · Enabled**. Tapping a child opens its per-channel dialog.

For sources whose sample rate is hardware-shared across instances (IMUs all on one SPI bus, analog channels round-robined by the ADC scheduler), the child rate cells display the effective rate but are read-only — editing the rate goes through the source-level dialog so the shared nature stays explicit.

Hardware-pinned sources (IMU, GPS, Wheel Speed) are always present in a profile. User-added sources (Analog, Digital marker, HRM) appear once added via **+ Add channel…**.

### 23.4 `+ Add channel…` picker

A modal listing sources the user can add — driven by `kChannelSourceFactories` in code. Selecting an entry creates a new `ChannelSource` instance with default values, opens its dialog, and commits to the active profile on save. Spec 1 ships **Analog channel** and **Marker button**. Spec 2 adds **Heart Rate Monitor**.

### 23.5 Calibration

The Calibration panel runs `CMD_CALIBRATE_IMU` per §7.6 and writes the resulting `bias` / `orientation` matrices into the active profile's `config.imu` block via `profileProvider.updateConfig`.

### 23.6 Push Config

Sends `activeProfile.config` (the inner config sub-object, with app-side metadata stripped) to the device over BLE (FF05 + `CMD_CONFIG_BEGIN`/`CMD_CONFIG_COMMIT`, §7.2); the device then reboots to apply and the app reconnects. Requires idle mode (BLE control is suspended in WiFi mode, §10.4); the button is disabled when disconnected.

Config pushes are never automatic — per §8, the user must review changes and explicitly press Push Config. The `BleService` interface exposes `pushConfigBle` (the chunked BLE path) and `pushConfig` (the WiFi `POST /config` fallback, §6.1).

### 23.7 Recording controls

Start / Stop session — sends `CMD_START_LOGGING` / `CMD_STOP_LOGGING` per §7.2.

### 23.8 Deferred

Recently connected devices list — requires persistent storage of past device names/IDs across sessions; not present in v1.

### 23.9 Mode status (info-only)

Mode is **automatic** — there is no manual mode picker. WiFi is driven on
demand by file sync (§24) and OTA (§27): each enters WiFi when needed and
returns to idle when done. Recording is driven by the hero card's primary
button. The Device card shows the current mode as a non-interactive status
line (`Idle` / `Syncing…` / `Recording`).

Transitions still run through `ModeController.switchTo` and the §7.2 mutex
still applies (WiFi and recording are exclusive). Transitions out of WiFi run
over HTTP (`POST /wifi_off`, §10.4) followed by a BLE-reconnect leg.

**Recording starts immediately.** Sensor health — HR strap, GPS, SD, IMU,
battery — never gates recording; a degraded sensor surfaces as a non-blocking
warning on the Device hero card (§23.10). `idle → recording` sends
`CMD_START_LOGGING` directly with no HR-up wait.

Mode-transition refusals are surfaced by an always-mounted `ModeResultListener`
wrapping the Device tab — so feedback survives even though there is no picker —
per `TransitionResult`:

- `RefusedByFirmware(attCode, reason)` and `RefusedByPolicy(reason)` surface as
  SnackBars with the reason text.
- `TimedOutAwaitingConfirm(expected)` surfaces as a persistent `MaterialBanner`
  with a Reconnect action (v1: action only dismisses).
- `AbortedByDisconnect` / `AbortedByCancel` are silent.

### 23.10 Device hero card

The Device tab leads with a hero card — the single prominent status +
primary-action surface — a state machine over the live device state:

- **No device** (`!isConnected`): a full-width **"Select a device ▾"**
  dropdown that opens the picker.
- **Ready** (connected, not recording): a **"Connected · {name} ▾"** device
  dropdown + battery + a live **RX/TX** activity pair (RX blinks on each
  status frame, TX on each command sent), the colour-coded peripheral
  readout, and a large green **Start recording** CTA.
- **Recording**: a pulsing live indicator + `mm:ss` timer, RX/TX, the
  peripheral readout, and a large amber **Stop recording** CTA.

The **peripheral readout** (SD / GPS / IMU / HR / HRM battery) is folded
into the hero, colour-coded so a degraded sensor reads as an in-place
warning — green healthy, amber degraded, red fault — never blocking
recording (§23.9). There is no separate Connection section. Richer detail
(GPS fix-type + satellite count, SD free space, signal RSSI, firmware
version) is planned, pending the firmware §7.3 status carrying it.

The card is intentionally dense — no instructional copy (first-run
guidance is a separate walkthrough). Start/Stop route through
`ModeController.switchTo`; refusals surface via the always-mounted
`ModeResultListener` wrapping the tab (§23.9); Connect/Disconnect are handled
on the hero and never surface an uncaught transport error.

On app open the nearest IDL0 **auto-connects** once (the "headphones"
model), so the common case needs no tap; a manual **Disconnect** then
stays disconnected for the session rather than reconnecting.

A device **dropdown** (`StatusDropdownTrigger`) on the hero opens the
device **picker** sheet — the single surface for choosing / disconnecting
the source. Today it scans and connects the nearest IDL0, disconnects the
current one, and lists **"This phone"** as a forthcoming GPS source.
Auto-connecting only a *known* (previously-paired) device, listing every
nearby IDL0 in the dropdown (system-Bluetooth style), true multi-unit
switching, a persisted paired-device list (§23.8), the phone-GPS recording
mode, and the on-device download/transfer card are still deferred.

---

## 24. Tab — Data

### 24.1 Purpose

The Data tab is a McMaster-Carr-style faceted search interface that operates over both sessions and tracks. The driving use case is "find my best lap on Track X to look up the bike setup that produced it." It replaces the previous flat Runs list.

**File.** `app/lib/ui/tabs/data/`.

### 24.2 Layout

- **Wide (≥ 720 dp):** three-column — filter rail (~280 dp) | results list | detail pane. The detail pane is empty until the user opens a detail card.
- **Narrow (< 720 dp):** filter rail collapses behind a "Filter" button at the top of the results panel; tapping opens a modal bottom sheet (active filter count badge on the button). The detail pane is also presented as a modal bottom sheet rather than a fixed column.

### 24.3 Two Views, One Filter Set

- **Sessions view (default)** — sessions grouped by Date · Venue, with inline lap expansion.
- **Tracks view** — Tracks grouped into collapsible venue sections (mirroring the Sessions Date·Venue grouping), with right-pane `TrackDetailPanel`.

View toggle: `SegmentedButton<DataView> { sessions, tracks }`. The active filter set persists when switching views; facets not applicable to the current view (e.g., lap-time range when viewing tracks) are hidden or greyed.

### 24.4 Filter Rail

Sections, top to bottom:
- **Date** — chips (Today / Week / Month / Custom). Single-select; presets clear the custom range.
- **Track** — multi-select with inline search + per-option count badge.
- **Venue** — multi-select. "(none)" pseudo-entry covers tracks/sessions with an empty `venueName`.
- **Bike** — multi-select. "(none)" pseudo-entry covers sessions with an empty `bike` field.
- **Rider** — multi-select. "(none)" pseudo-entry.
- **Tag** — multi-select. "(none)" pseudo-entry.
- **Lap time** — `RangeSlider` with mm:ss text inputs. Domain linear `[0, ceilTo5Min(maxKnownLapTime)]` clamped `[60 s, 10800 s]`. Recomputed when the library changes. Two `TextField` mm:ss inputs below the slider are two-way bound; typing updates the slider, dragging updates the text. Empty Max = no upper bound.
- **Source** — checkboxes for `.idl0` and `.gpx`.

Each multi-select facet uses a `_FacetGroup` widget: section heading, inline `TextField` search when ≥ 8 options, list of `CheckboxListTile`s with label + count "(N)", virtualised when > 200 options.

### 24.5 Search Bar

Top of the results panel. Case-insensitive substring match across `venueName ∪ shortComment ∪ longComment ∪ Track.name ∪ tag`.

### 24.6 Active Filter Chips

Row above results; one chip per active facet value. Tap × on a chip to remove that single filter. "Clear all" at the right end clears everything except search text.

### 24.7 Sessions View

Sessions are grouped by `(Date, Venue)`. A day with two different venues produces two separate header rows under the same date.

**Header row tap behaviour:**
- Tapping the venue text portion of the header opens a `VenueDetailCard` in the detail pane.
- Tapping the rest of the header body toggles expand/collapse for that Date·Venue group.

**Session row layout:** `[ checkbox ] [ chevron ] [ body ]`

- **Checkbox** — writes via `selectionProvider.toggleSession` (session-mode) or `selectionProvider.toggleLap` (lap-mode). Mode flips automatically per §13 semantics.
- **Chevron** — toggles inline lap expansion for that session row (independent of the detail pane).
- **Body** — opens a `SessionDetailCard` in the detail pane.

```
Tuesday · 2026-05-15
  Whistler Bike Park                              ← venue header (tap venue → VenueDetailCard; tap body → collapse)
  ☐ ▾ 14:32  A-Line, Dirt Merchant +1 more · Stumpjumper · [Practice] · 5 laps · 47:12
       Lap 1  A-Line     00:48.2
       Lap 2  A-Line     00:46.8 ★
       Lap 3  Dirt Merchant  01:14.3
```

When a session has TrackVisits, the track list renders inline as `name1, name2 +K more` (truncated to avoid overflow). ★ marks the fastest visible lap per session. Within a session, laps render flat with the track name on each row (not nested by track).

Sessions with zero filter-matching laps are hidden. Lap counts and total time recompute from filter-matching laps only.

**Data flow — no parse on open.** The Sessions and Tracks views, lap-time facet domain, and the "compare with" picker build their aggregates from the laps cached on `TrackVisit.laps` (§17.4), read directly from each session's already-loaded `.idl0w`. Opening the Data tab never parses a `.idl0` session — parsing happens only on import, explicit rescan, or when a file is opened in Analyze.

### 24.8 Tracks View

Flat sortable table. Columns: Name | Sessions | Laps | Best lap | Last ridden. Clicking a row opens `TrackDetailPanel` in the detail pane (desktop) or as a full-screen route (mobile). See §24.10 for the Track detail card contents.

### 24.9 Detail Pane

The detail pane is driven by `detailSelectionProvider`, which holds a `DetailSelection(kind: DetailKind, id: String?)`. `DetailKind` is an enum: `none | session | venue | track`. This axis is fully independent of `selectionProvider` (the XOR multi-select used for Analyze).

Opening any detail card sets `detailSelectionProvider` to the corresponding kind + id. Pressing the back/close button sets it back to `none`.

### 24.10 Session Detail Card (`SessionDetailCard`)

At the top, a non-interactive **GPS map preview** (`SessionMapPreview`) renders
the session's GPS polyline (`sessionGpsPreviewProvider` → engine `gpsTrack`) on
the app basemap (`tileSpecsFor`), fit to its bounds, so the user can recognise
*where* a session was before any Track work. Sessions without GPS show a "No GPS
data" placeholder. When the session has GPS, a **"Create track from this
session"** button opens the Track Editor in create mode (§24.12) — naming
happens there, with the map visible.

The header venue falls back to a matched Track's venue when the session carries
no explicit `venueName` (mirroring the venue filter facet and the Sessions-tree
heading). The editable **Venue** field is *pre-filled* with this same resolved
venue when `venueName` is empty, so saving the card persists the venue into the
session's own metadata rather than leaving it blank.

Hosts `MetadataForm` (extracted from `MetadataEditor`) with the following fields:
- Rider — `Autocomplete<String>` sourced from distinct known rider names.
- Bike — `Autocomplete<String>` sourced from distinct known bike names.
- Venue — `Autocomplete<String>` sourced from distinct `Track.venueName ∪ SessionMetadata.venueName`.
- Event — free-text `TextField`.
- Tag — free-text `TextField`.
- Comments — multi-line `TextField`.

Below `MetadataForm`:
- **Tracks visited row** — inline list of `TrackVisit` names with tap-to-open.
- **File info** — collapsible section showing session UUID, file path, file size, and per-file Drive sync status (see §28). Field values are selectable text (highlight/copy). The file-path row carries two quick actions: a copy-path button (all platforms) and, on desktop only, a reveal-in-file-manager button (`explorer /select` on Windows, `open -R` on macOS, `xdg-open` of the containing folder on Linux).
- **Delete button** — opens a confirmation dialog with three options:
  - **Cancel** — dismisses dialog.
  - **Remove from app** — deletes the session from local storage only; Drive files are untouched.
  - **Delete everywhere** — deletes local files and calls `DriveService.deleteRemote(sessionId)` to remove Drive files. This button is disabled with an explanatory tooltip when the user is not signed in to Drive.

### 24.11 Venue Detail Card (`VenueDetailCard`)

Venues are derived groupings, not first-class entities. The card aggregates all Tracks sharing the same `venueName`:
- **Name field** — editable. Saving calls `TrackNotifier.renameVenue(oldName, newName)`, which batch-renames `venueName` on every matching Track.
- **Tracks list** — all Tracks in this venue; tapping a Track opens its `TrackDetailPanel`.
- **Stats** — total sessions, total laps, best lap across all tracks in the venue.
- **Kebab menu → "Delete venue…"** — clears `venueName` on every Track in the venue (sets to empty string); does not delete the Tracks themselves.

### 24.12 Track Detail Card (`TrackDetailPanel`)

- **Name field** — editable `TextField`.
- **Venue field** — `Autocomplete<String>` sourced from `distinct Track.venueName ∪ distinct SessionMetadata.venueName`. Submitting a new value creates the venue lazily; submitting an existing value merges this Track into that venue group (see §16.8).
- **Delete** — deletes the Track (calls `TrackNotifier.deleteTrack`).
- **Edit gates on map…** — button that opens the Track Editor modal (map + sidebar) for placing/editing lap gates, sectors, and neutral zones.

Additional read-only fields: polyline preview, gate count, sector count, fastest lap with link to parent session, last ridden, sessions count, laps count. "Open in Analyze" button switches to the Analyze tab with all sessions on this track selected (session-mode).

The Track Editor modal has a **create mode**, entered from a session — the
detail-card "Create track from this session" button (§24.10) or the Tracks
toolbar "Create from session…" (§24.14). In create mode the sidebar gains a
**TRACK** section with Name + Venue (autocomplete) fields, Save is disabled
until Name is non-empty, and Save **creates** the Track (`createTrack`) and
rescans the source session's visits, rather than updating an existing Track.
Cancel discards without persisting anything.

The editor is **responsive**: wide (≥ 720 dp) is map + pinned right sidebar;
narrow is the map over a scrollable controls panel (~45% / ~55%), and while a
gate is being placed the map takes the whole area so the two taps are precise,
restoring the controls once placement commits or is cancelled. So track
creation and gate editing work on mobile, not only desktop.

### 24.13 Sort Options

Sort is a **field + direction**: a field chooser plus an ascending/descending
toggle (`DataSortField` + `DataFilters.sortAscending`), so any column can be
sorted either way.
- Sessions fields: Date (default), Best lap, Duration, Lap count.
- Tracks fields: Last ridden (default), Name, Lap count, Best lap.

Each field has a default direction (Best-lap and Name ascending; the rest
descending); selecting a field resets to its default and the toggle flips it. In
the Sessions tree the day-group order follows the active sort (the day holding
the top-ranked session leads).

### 24.14 Toolbar Actions

- **Search** — toggles the search bar.
- **Sessions / Tracks toggle** — `SegmentedButton<DataView>`.
- **Sort** — a compact field chooser + ascending/descending toggle for the active view's fields (§24.13).
- **Import** — imports `.idl0` or `.gpx` files (sessions) or `.gpx` tracks depending on active view.
- **Create from session…** — builds the session's GPS polyline and opens the Track Editor modal in **create mode** (§24.12): Name/Venue are entered in the editor with the map visible, and the Track is created on Save.
- **Rescan visits** — calls `RunsNotifier.rescanAllTrackVisits` over all sessions; re-runs TrackVisit detection without re-downloading source files, showing a per-row spinner and surfacing the first error on failure.

### 24.15 Selection & Analyze Launcher

Floating bar at the bottom of the body when `selection.isEmpty == false`: `[ ANALYZE N selected » ]`. Tapping switches to the Analyze tab via `shellIndexProvider`. This selection (via `selectionProvider`) is independent of the detail-pane selection (via `detailSelectionProvider`).

### 24.16 Empty States

- No sessions imported: "No sessions yet. Import your first .idl0 or .gpx file."
- Sessions exist but filters exclude all: "No matches. Try clearing filters." with a Clear All button.
- Tracks view, no tracks: "No tracks yet. Import .gpx tracks…"

### 24.17 Device Sync (WiFi download)

Device file download is launched from the **Device card's Files entry** (§23),
not the Data tab — the Data tab is library-only (§22.2). The Files entry shows a
"N new" badge (device files not yet in the library) and, on tap, **auto-enters
WiFi mode** (`ModeController.switchTo(Mode.wifi)`) and opens the full-screen
**Sync screen** (`SyncScreen`), dropping back to idle on return. The screen is
driven by `SyncController` (`syncControllerProvider`); its classification and
download behaviour below are unchanged regardless of where it is launched from.

**Classification.** `SyncController.list()` calls `GET /files` (§6.1) and, for each entry, compares the reported `session_id` against the in-memory `sessionProvider` session IDs:
- in the library → **IN LIBRARY**,
- not in the library → **NEW**,
- `session_id` empty (older firmware) → **NEW?** identity-unknown (shown as downloadable).

Entries are sorted newest-first (filename descending, per the `YYYY-MM-DD_HH-MM-SS.idl0` convention in §15.1) and rendered as a tightly-packed list.

**Two behaviours, switched by one setting.** The screen serves two distinct cases cleanly:
- **Pick a few (default).** The list is a file picker: every NEW row is a checkbox **unchecked by default**, so connecting to an unfamiliar device never pulls everything at once. The user checks the files they want and taps **Download (N)** (disabled until something is selected). This runs `SyncController.sync()`, which downloads only the checked files.
- **Connect and forget.** When the `autoSyncOnOpen` setting (§27, default **OFF**) is enabled, opening the screen runs `SyncController.syncAllNew()` — it selects every NEW file and downloads them automatically, no interaction needed.

**Download queue.** In both cases files download **strictly one at a time** — the device serves a single HTTP request at a time, so the queue is sequential by design, not as a limitation. Each file streams via `WifiService.downloadFile`; the progress fraction is derived from the known file size from `/files` (the firmware streams chunked with no `Content-Length`), shown per-file as `MB / MB · %` with a bar, plus an overall "N of M done · K queued" banner. On completion each file is registered via `RunsNotifier.registerDownloadedByName` (parse → index → track-visit detection → Drive upload queue) and flips to IN LIBRARY. A per-file failure marks that entry as errored and the queue continues; a Stop control cancels the active download and halts the queue.

**WiFi-mode gate.** The file APIs require WiFi mode. When the device is not in `Mode.wifi`, the screen shows a "Switch to WiFi mode" prompt; bringing the AP up and binding to it is the `ModeController`'s responsibility (gated by the WiFi/logging mutex), not the screen's.

---

## 25. Tab — Maths

Math channels and named constants are per-workbook — stored in the `.idl0wb` file (§17a), not per-session and not in any global store. The Maths tab edits the **active workbook's** channels and constants in place; switching the active workbook switches the channel set. A channel's identity is its stable `id` (charts reference channels by `id`, so an in-app rename does not drop them); expressions reference channels by `name`, and `idl-rs` resolves cross-channel dependencies by name.

Math channel expression editor modeled on i2pro:
- Channel metadata bar: name, quantity, units, rate, decimal places, color
- Expression text area with real-time validation
- Context-sensitive function help panel
- Insert panels: Channels / Functions / Constants
- Operator toolbar: `+ - * / < > <= >= == != and or ( ) [ ]`
- **Interactive preview plot** (`ExpressionPreview`): the active channel's evaluated result rendered through the *same* Analyze `TimeSeriesChart` (full Ctrl/Shift-wheel zoom/pan, cursors, right-click menu, and per-viewport re-decimation via the shared tile cache), so a filter's effect can be inspected at any zoom while its parameters change. Re-evaluation is debounced behind the 300 ms validation pass. The chart is hosted outside a worksheet via a synthetic `worksheetId` (`__math_preview__`) and a local, ephemeral Y override (never persisted) supplied through the dispatcher's `onApplyYScale` seam (§26.7); Properties and Remove-chart are suppressed since there is no slot.
- **Responsive breakpoint:** 700 dp (wider than the shell's 600 dp). Below 700 dp, Insert panels collapse to a `BrandSegmented` selector + `IndexedStack` (one panel visible at a time). Above 700 dp, all three panels are shown as columns.

**Expression channel scope:** The Channels insert panel and `validate()` are both passed `mathExpressionChannelNamesProvider` — the sorted, deduplicated union of channel names from the currently selected sessions (`availableChannelNamesProvider`) and the names of every math channel in the library. A `[ChannelName]` reference to another math channel therefore appears in the picker, passes validation, and is resolved at evaluation time by the evaluator's cross-channel dependency pass. A reference whose name matches neither a session channel nor a math channel fails validation.
- **Channel grouping:** The Channels insert panel groups session channels into collapsible sections by the prefix before the first `_` (`GPS`, `IMU0`, `IMU1`, `IMU2`, `HR`); channels with no prefix render flat beneath the groups. A non-empty search query flattens the panel to a filtered flat list. Grouping is automatic and presentation-only — user-defined groups are a deferred follow-up.
- **Duplicate:** Each math channel row has a duplicate action that copies the channel (new id, `"<name> copy"` name, all other fields verbatim) and selects the copy. Built-in tutorial channels may be duplicated; the copy is an ordinary editable user channel.
- **Channel list ordering:** Channels appear in the order they are stored on the workbook (insertion order). They persist on the active workbook's `.idl0wb` — there is no separate math-channel database. There is no user-reorder affordance in v1.
- Template library (shipped expressions):
  - `Fork velocity`: `integrate([IMU1_AccelZ])`
  - `Shock velocity`: `integrate([IMU2_AccelZ])`
  - `Suspension travel`: `integrate(integrate([IMU1_AccelZ]))` — double integration, requires two high-pass filter passes (pre and post each stage) to control drift
  - `Wheel distance`: `integrate([WheelFront])`
  - `GPS distance`: `integrate([GPSSpeed])`
  - `Lap time delta`: `[LapTime_A] - [LapTime_B]`

**Lap and variance functions in the function help panel.** The Functions insert panel surfaces `current_lap()`, `lap_start_time(n)`, `sector_number()`, `variance_time(ch)`, and `variance_dist(ch)` alongside the scipy-equivalent entries listed in §19. Help text describes the projection model (overlay-lap-verbatim, ±90° heading match) and points users at the lap-table main / overlay columns (§21.3) — variance fails loudly when either designation is unset. The `declip(ch)` reconstruction function appears under a `Reconstruction` category in the same panel.

**Built-in tutorial math channels.** Five tutorial channels (`kBuiltinMathChannels` in `app/lib/data/math_channel.dart`, with `builtin:`-namespaced stable ids) are seeded into a fresh install's **default workbook** — `Workbook.createDefault` writes them into its `mathChannels`: `LapNumber` (`current_lap()`), `LapTime` (`[Time] - lap_start_time(current_lap())`), `LapDistance` (`[Distance] - lap_start_distance(current_lap())`), `Lap Delta T` (`variance_time([LapTime])`), and `Lap Delta D` (`variance_dist([LapTime])`). They are **ordinary workbook channels — editable, duplicatable, and deletable like any other** (the `builtin:` prefix only namespaces their stable ids; it does not lock them). They teach the expression language by example and give every install a working lap-delta set with no setup. The shipped **template library** (`MathChannelLibrary.shipped`) is a separate set the user copies into the active workbook on demand. `Time` is the synthesised base channel described in §19; user expressions can reference it like any sampled channel.

---

## 26. Tab — Analyze

- **Workbook/Worksheet** structure (mirrors i2pro project/page model); a 24 dp strip of primary and overlay session-binding chips renders below the workbook bar so sessions can be swapped at view time without altering the workbook definition (see §17a.3).
- Drag-resize components, synchronized cursor
- Zoom: pinch/scroll, linked or independent
- Range selection, cursor annotations
- Overlay mode: multiple sessions/laps on same axis
- Channel color, line style, visibility toggle
- The Add Channel dialog groups session channels into collapsible sections by name prefix (`GPS`, `IMU0`, `IMU1`, `IMU2`, `HR`); the Math Channels section is listed separately.

**`Worksheet` state:** Each worksheet holds `name: String` and `xAxisMode: XAxisMode`. Zoom state, channel assignments per chart, chart count, and cursor history are not yet in `Worksheet` — they will be added when those features are wired up. When workspace persistence is added, all per-worksheet display state must move from local widget state into `Worksheet`.

**X axis mode scope:** `WorkspaceNotifier.setXAxisMode()` applies to the currently active worksheet only (no worksheet-index parameter). `XAxisSelector` reads and writes the active worksheet via the same assumption. Both break if two worksheets are ever displayed simultaneously — when that happens, refactor both to take an explicit worksheet index.

**Chart count:** The number of charts on a worksheet is local widget state (`ConsumerStatefulWidget._chartCount`), not stored in `WorkspaceState`. It resets to 1 when the worksheet changes. Moving it into `Worksheet` is required before persistence is added.

**Per-chart channel assignment:** All charts in a worksheet currently receive an empty channel list. Per-chart channel selection is not yet implemented; when it is, each chart will need its own `List<SessionChannelData>` stored in a `ChartConfig` class within `Worksheet`.

**Synchronized cursor contract:** One cursor per worksheet, shared across every chart in that worksheet. Cursor position is in data-space x-axis units — seconds for time mode, metres for distance modes — not pixel coordinates. The cursor is cleared when the worksheet's x-axis mode changes. Cursor state is not persisted to `.idl0w`.

**Cursor position — current placeholder:** `cursorProvider` is typed `double? (seconds)` but `TimeSeriesChart._moveCursor` currently stores the raw pixel offset from `onTapDown`, not data-space seconds. The pixel-to-data-space conversion is stubbed with a TODO. Do not treat cursor values as seconds until that conversion is implemented.

**Cursor readout.** A pinned cursor A surfaces an fl_chart tooltip on each time-series chart showing every plotted channel's value at A, formatted with the smart sig-fig rules in `formatChannelValue` (3 significant figures, magnitude-aware decimal places, `—` for NaN, `+∞ / −∞` for infinities). The tooltip is brand-styled (IBM Plex Mono, hairline border, `brandSurface` fill) and persists after touch lifts; it is suppressed while more than one pointer is down so pinch-zoom focal-point thrash does not redraw values. When cursor B is also pinned, an `A → B  Δ <t>` chip renders above the chart on a single line. Raw cursor values for both A and B are exported via the chart context menu's `Copy Cursor Values` command.

**Channel colour ownership:** Each channel plotted in a chart has a user-configurable colour stored in the workspace file (`.idl0w`) under the chart component's layout entry. On first addition, colours are assigned by cycling a fixed palette in order of channel addition. Two channels in the same chart will not share a colour provided the palette is larger than the channel count.

### 26.0.a GPS Map & Track Gates

**Toolbar button.** The GPS map chart's toolbar includes a new `Tracks…` button that opens a popup listing all Tracks visited by the active sessions. The popup shows Track name, lap count, and an [Edit] button that opens the Track Editor modal.

**Read-only gate overlays.** Gate placement and deletion UI has been removed from the GPS map. Track gates (lap start/finish and sector gates) render as read-only overlays on the map. Neutral zones are visualized similarly. To edit gates, use the Track Editor modal (opened via the Tracks popup or the Data tab Track detail card).

**Segment-selection mode.** New affordance for Track creation: when `Create from session…` is tapped in the Data tab or invoked from the Analyze map's Tracks popup, the map enters segment-selection mode. A horizontal range slider (with time or GPS distance on X) allows the user to select a start and end point. Preview gates render perpendicular to the polyline at those points. Tapping [Continue] opens a name+venue dialog, creates the Track with those gates as start/finish, and optionally opens the Track Editor for further refinement.

**Multi-session rendering.** The GPS map renders every selected session's track (sourced from the effective selection), not just the bound primary/overlay pair — a map is a spatial overlay, not a Main/Overlay lap comparison. Each session draws in its palette colour; the chart-properties per-session colour rows are labelled by session date.

**Channel-coloured trace.** A GPS chart can colour its trace by one channel value (chart properties → *Colour by*; `None` = solid per-session colours). The engine resamples the channel onto each GPS fix (`gps_channel_values`, nearest-sample); the app maps the values through the Turbo colormap into a per-vertex gradient polyline on a single min/max scale shared across all visible traces (auto, or a manual range). A colorbar legend shows the active scale and channel. The colour-by channel and optional manual range persist on the chart slot (`gpsColorChannelId` / `gpsColorMin` / `gpsColorMax`).

### 26.1 WorksheetKind

Worksheet gains a `kind` field:

```dart
enum WorksheetKind { standard, sessionSheet }
```

Stored on Worksheet, defaulting to `standard`. `copyWith / toJson / fromJson` updated. Workspace `_kSupportedWorkspaceVersion` bumps; `fromJson` accepts missing field by defaulting to standard.

### 26.2 Default Workbook Contents

When a workbook is first created, it ships with two worksheets:
- `Worksheet(kind: sessionSheet, name: "Session", charts: [LapTable, LapProgression])`
- `Worksheet(kind: standard, name: "Charts", charts: [])`

Existing workbooks loaded from `.idl0w` that have no Session Sheet get one prepended on migration (one-shot at load time, not on save).

### 26.3 Session Sheet Behaviour

A worksheet with `kind == sessionSheet` has two **mandatory, non-deletable** chart slots at the top:

1. **Lap Time Table** — full lap data for every parent session in the current selection scope. Lap rows have checkboxes that mirror `selectionProvider`.
2. **Lap Time Progression** — `fl_chart` LineChart, x-axis = lap index within session (1..N), y-axis = lap time in seconds. One series per session in scope. Highlights fastest lap per session with a marker. Renders **all laps** in scope regardless of any active Data-tab Track filter — the chart's purpose is "did I get faster", filtering defeats it.

Below the mandatory slots, the user can add any standard chart slots (math channels, time-series, ghost charts, etc.). The slot-removal handler refuses to delete the mandatory slots (no-op + log). The user can delete the entire Session Sheet worksheet itself; that's allowed because the core lap data lives in the Data tab.

### 26.4 Multiple Session Sheets per Workbook

The "New Worksheet" menu offers two options: Standard / Session Sheet. Useful when the user wants different math-channel attachments per Session Sheet.

### 26.5 Lap Table Mode-Aware Checkboxes

The lap table widget gains per-row checkboxes:
- Session-row checkbox → calls `selectionProvider.notifier.toggleSession`.
- Lap-row checkbox → calls `selectionProvider.notifier.toggleLap`.
- In session-mode: lap checkboxes visually muted (still clickable, flips mode).
- In lap-mode: session checkboxes visually muted.

Bidirectional sync: changes in the Data tab flow to the Session Sheet's lap table; changes here flow back. One source of truth (`selectionProvider`).

### 26.6 Workbook Bar Visual Marker

Session Sheet worksheet tabs show a small icon (`Icons.list_alt`) next to the tab label to distinguish from Standard sheets.

### 26.7 Chart context menu

Each time-axis chart (TimeSeries, Ghost, FFT, LapProgression) wraps in a `ChartContextMenu` that opens on right-click (desktop) or long-press (mobile). The menu is a cascading `MenuAnchor` opened at the pointer: Cursor / Zoom / Pan collapse into hover-out submenus, with Reset View, Copy Cursor Values, and Properties at the top level and the deferred v2 placeholders under a disabled **More** submenu. Implementation in [`app/lib/ui/widgets/chart_context_menu.dart`](../app/lib/ui/widgets/chart_context_menu.dart); dispatcher in [`app/lib/ui/widgets/chart_action.dart`](../app/lib/ui/widgets/chart_action.dart). The dispatcher is slot-agnostic — vertical-zoom Y writes go through an `onApplyYScale` callback (worksheet slot, or local state for the Maths preview, see §25), so the same chart renders inside and outside a worksheet.

**Cursor model.** Each worksheet has an A/B cursor pair stored as `CursorPair(aSecs, bSecs)` keyed by worksheet UUID in `WorkspaceState.worksheetCursors`. Cursor A is the historical "the cursor" (set by 1-finger chart drag, hover preview); cursor B is set explicitly via the menu. Both render as vertical lines spanning every time-axis chart in the worksheet — A solid white, B dashed amber. Channel values at A surface in the per-chart fl_chart tooltip (see **Cursor readout** above); an `A → B  Δ <t>` chip appears above the chart when both cursors are pinned.

**Persistence.** X-axis range (`worksheetRanges`) and cursor pair (`worksheetCursors`) both persist in SharedPreferences alongside the workbook structure, so zoom and cursor restore together on app reopen. Manual Y range persists per slot via the existing `ChartSlot.yScaleMode + yMin + yMax` fields.

**Reset View.** Clears the worksheet's X range, both cursors, and the slot's manual Y mode (back to auto). Triggered by the menu item OR by double-tap on the chart canvas.

**Default keybindings (hardcoded). A read-only reference of these lives in Settings → Controls (§27); an *editable* rebinding table is a v2 follow-up.**

| Action | Keys |
|---|---|
| Pan horizontal | Shift + ←/→, Shift + Scroll |
| Pan vertical | Shift + ↑/↓ |
| Zoom horizontal | Alt + ←/→, Ctrl + Scroll |
| Zoom vertical | Alt + ↑/↓ |
| Zoom Full Out X | F2 |
| Zoom Full Out Y | Alt+F2 |
| Zoom to Cursors | Z |
| Copy Cursor Values | Ctrl+Shift+C |
| Properties... | F5 |

Direction convention: pan arrow shifts the view toward the arrow; zoom Up/Right is in (more magnification), Down/Left is out.

**Scroll-wheel scheme.** Over a chart, **Ctrl + wheel** zooms the shared X range at the cursor and **Shift + wheel** pans it; a plain wheel passes through to worksheet page-scroll. The decision is the pure `wheelModeFor(ctrl, shift)` in `chart_action.dart` — the single source of truth shared with the Settings reference. **Alt is deliberately not a wheel modifier:** a stuck Alt after an Alt+Tab focus change (a known desktop `HardwareKeyboard` desync) would otherwise turn every plain wheel into a zoom. Wheel handling lives only in the chart (`TimeSeriesChart`), not the wrapper, so one notch = one action.

**Mobile gestures.**

| Gesture | Action |
|---|---|
| 1-finger horizontal drag | Move cursor A |
| 1-finger vertical drag | Scroll the worksheet (not claimed by the chart) |
| 2-finger pinch | Free-form X+Y zoom from `horizontalScale` × `verticalScale` independently |
| 2-finger drag | Pan X+Y from `focalPointDelta` |
| Long-press | Open context menu at touch point |
| Long-press-drag | Zoom Window — drag-rectangle that applies X+Y range on release |
| Double-tap | Reset View |

Gestures route through `ChartGestureArea`, whose `ChartZoomScrubGestureRecognizer` claims the gesture arena only for a 2-finger pinch or a *horizontally*-dominant 1-finger drag; a vertically-dominant 1-finger drag is left unclaimed so the enclosing chart-list scrolls. This keeps the chart's scale recognizer from competing with the scroll view's vertical-drag recognizer (combining `onScale*` with `onVerticalDrag*` in one detector is disallowed, and the unclaimed-then-evicted race throws in the framework's scale recognizer).

Vertical pinch only acts when the slot is in `YScaleMode.manual` — auto-fit values aren't accessible from outside fl_chart in v1.

**Zoom Window.** Right-click-drag (desktop, secondary button) or long-press-drag (mobile) paints a translucent rectangle and applies its X range and manual Y range on release. Drags shorter than 8 px in either dimension fall through to a normal click → menu.

**Ghost-chart properties.** Ghost-delta chart slots expose three filter sliders in the Properties dialog (in addition to the Y-axis controls common to all chart slots). Values persist on the slot via `ChartSlot.ghostSmoothingSeconds`, `ChartSlot.ghostMedianWindow`, and `ChartSlot.ghostConfidenceMeters`:

- **Smoothing window** — 0.0 – 10.0 s, default 3.0 s. Width of the Phase 3 confidence-weighted Gaussian, expressed in seconds. 0 disables Phase 3 (Phase 2 output passes through unchanged).
- **Spike rejection (median window)** — Off / 3 / 5 / 7 / 9, default 3. Width of the Phase 2 centered median pre-pass. Off disables Phase 2.
- **Drift sensitivity** — 1 – 50 m, default 8 m. Confidence-kernel scale: residuals beyond this distance attenuate sharply in the Phase 3 weighting. Slider response is quadratic so finer control sits at the low end of the range.

**v2 deferral list:** Active Channel concept and per-channel scale modes (i2Pro "Channel/Auto") — the next priority follow-up; editable keybinding settings table; Maximise; Cut/Copy/Paste/Delete chart slot; Print / Print to Clipboard; Export Data; GpsMapChart context menu (different op set — XY pan/zoom); LapTable context menu; Pan to Cursor A/B; Zoom Default; worksheet-level "Reset All Charts."

### 26.8 Chart rendering engine — tile-based decimation

The Analyze tab's time-series charts render via tile-based min/max decimation. Each channel's samples are owned by the retained `SessionHandle` (see §15.3) — there is no separate sample handoff or registry. At render time the chart picks a decimation tier from the viewport's samples-per-pixel ratio and requests the visible tiles via `decimate_tile(handle, channel_id, tier, tile_index)`, caching them in a process-wide LRU cache (`ChartTileCache`, 30 MB cap), and renders two FlSpot per bucket (min, max at the same X) so single-sample spikes remain visible at every zoom level.

Tiers are geometric base-8: tier 0 = raw, tier 1 = 1:8, ..., tier 6 = 1:262144 (the ceiling — one tier-6 tile spans ~268M samples, so a full-session view of a season-scale log stays at pixel-scale spot counts; high tiers are cheap because the engine folds raw columns per bucket without materializing). Tile size is 1024 buckets at every tier. Cache misses dispatch async Rust calls (off-isolate via flutter_rust_bridge); the chart shows a brief gap at the missing span while the tile streams in (typically within one frame given off-isolate FRB).

The in-chart tooltip displays the decimated bucket value because
`getTooltipItems` is a synchronous callback that cannot await Rust. An exact,
interpolated cursor readout would be a small additive `decimate_*`-style
handle method; it is not currently wired in the UI.

Gesture model: multi-finger pinch zooms X+Y, anchored at the gesture focal point in both axes (Y zoom only applies when the slot is in `YScaleMode.manual`). A horizontally-dominant single-finger drag moves cursor A; a vertically-dominant single-finger drag is left unclaimed so the enclosing chart-list scrolls. Double-tap resets the X range, both cursors, and the slot's manual Y. X range is shared across every chart in a worksheet. `setXAxisRange` writes are coalesced to ~60 Hz during a gesture; the final position is flushed on `_onScaleEnd`.

### 26.9 Chart-type picker & properties editor

Each user-addable chart type carries display metadata (glyph, label, one-line
blurb, signature accent colour) in a single catalog, `chart_type_catalog.dart`
(`kChartTypeCatalog` + `kAddableChartTypes`). The accent colour-codes the type
in both the picker and the rail. Adding a chart type is one catalog entry plus
its render widget and property section. Addable types: `timeSeries`, `fft`,
`gpsMap`. The pinned Session-Sheet types (`lapTable`, `lapProgression`) are
catalogued for labelling but never offered in the picker.

The Add-Chart and properties flows are layout-adaptive (breakpoint: viewport
width `> 700` dp, matching the Maths tab):

- **Narrow (mobile).** Two steps. "Add chart" opens a type picker — one row per
  addable type showing its glyph, label, and blurb — then the
  `ChartPropertiesDialog` opens for channel-bearing types. Editing an existing
  chart opens the properties dialog directly. Chart type is fixed once created.
- **Wide (desktop).** The type picker and properties editor are one panel. The
  `ChartPropertiesDialog` renders a left **type rail** (the addable glyphs, each
  in its accent colour; the current type lit with a tinted fill + matching
  border) beside the property sections. Selecting a
  rail entry converts the slot **in place** via
  `updateChartProperties(copyWith(chartType:))`, preserving assigned channels
  (a type that ignores them, e.g. `gpsMap`, simply leaves them unused); the
  property sections re-render for the live type. "Add chart" creates a default
  `timeSeries` slot and opens this panel with `isNew: true` — **Add** commits,
  **Cancel**/dismiss discards the placeholder slot.

The rail is shown only for the addable types; pinned lap slots do not open this
dialog. On narrow layouts the dialog has no rail, so type stays fixed there. The
desktop rail cards are sized so each type label fits without breaking mid-word.

**GPS Colour-by section.** A `gpsMap` chart's property panel adds a *Colour by*
group: a single-channel picker (`None` = solid per-session colours) and, when a
channel is chosen, an optional manual scale range (blank fields = auto, the
shared min/max across visible traces). See §26.0.a for the rendered heatmap and
the persisted `gpsColor*` slot fields.

### 26.10 Histogram chart

`ChartType.histogram` — the value distribution of a single channel over the
whole rendered session, drawn as equal-width bars. The staple suspension tool
(a velocity histogram reads damper balance; a travel histogram reads sag and
bottom-out usage).

- **Engine.** Binning lives in `idl-rs` (`channel_histogram` →
  `histogram::histogram`): the channel's samples materialize transiently from
  the compact column and are binned in Rust; only the small
  `HistogramResult { bin_edges, counts, total }` crosses FFI (the §15.3 seam,
  like `welch_channel`). Non-finite samples are skipped. An optional explicit
  `[min, max]` range pins the binning extent so an overlay's series share edges;
  otherwise the range is the data min/max (zero-centred when `symmetric`).
  Binning has no sci-rs equivalent — it is a tight O(n) count, not a
  reimplementation of library DSP.
- **Overlay.** Every assigned **(session × channel)** series is overlaid as a
  staircase outline with a translucent fill, sharing one value axis: the chart
  unions each channel's `channel_min_max` into a common range — widened to
  `[−m, m]` when `histogramSymmetric` — and bins every series onto identical
  edges via the explicit-range `channel_histogram` param. So front + rear, and
  the main + N overlay sessions, lie on top of one another; the legend
  colour-codes them. Each series is normalised to **its own** sample total, so
  series of different lengths stay comparable.
- **Axes.** Y is the percentage of each series' samples per bin
  (`count / total`); the shared `yScale == log` switches Y to a base-10 log axis
  that exposes the sparse high-velocity tails (§26.12). X is the channel value.
- **Rendering.** Each series is a stepped staircase tracing the bars' tops by
  default; `histogramSmooth` swaps it for a fitted polyline through the bin
  centres (anchored to the baseline at the range ends), which reads more
  clearly at high bin counts. Both forms carry a translucent fill.
- **Slot fields.** `histogramBinCount` (default 40, clamped 2–200),
  `histogramSymmetric` (false — zero-centred range), `histogramSmooth` (false —
  fitted polyline) — persisted on the slot, emitted to JSON only for histogram
  slots. The count-axis scale is the shared `yScale` (§26.12).
- **Window.** Computed over the whole rendered session — the histogram windows
  by neither zoom nor lap (unlike the FFT and spectrogram charts, which window
  to the active zoom / lap — §26.10.a).

### 26.10.a FFT windowing & Spectrogram chart

**FFT windowing.** The FFT chart no longer transforms the whole session; it
auto-windows to what the worksheet is showing. In session-mode the window is
the current horizontal zoom span (or the full session when unzoomed); in
lap-mode it draws **one spectrum line per selected lap** (per channel), each
windowed to that lap's engine-computed `[startTimeSecs, endTimeSecs]` — the
1-to-N lap comparison. Overlaid lines are capped at `kMaxFftSpectra` (10) with a
visible "showing first N" note rather than a silent drop. The window is resolved
in `chart_workspace` (zoom from `worksheetRanges`, laps from `sessionLapsProvider`)
via the pure `resolveFftWindows`; the engine computes each spectrum with
`welch_channel_windowed` so samples never cross FFI. Segment length auto-resolves
from the **windowed** sample count.

**Spectrogram chart** (`ChartType.spectrogram`). A time×frequency heatmap of one
channel (X = time, Y = frequency, colour = magnitude/PSD), computed in `idl-rs`
(`spectrogram_channel` → `spectrogram()`, sharing the `stft()` core with
`welch()`). One channel per slot; auto-windows like the FFT chart but to a single
window (zoom span in session-mode, the primary lap — `mainLapNumber` else the
lowest selected lap — in lap-mode). The colour scale is the shared `yScale`
(default `log`); the frequency axis is linear or log via `SpectralParams.freqScale`.

Because its X axis is time, the spectrogram carries the worksheet's shared A/B
cursor like the time-series chart (a tap pins A; the A/B/hover lines render at
the matching time so a spectral peak can be read against track position), plus
frequency and time gridlines aligned to the axis ticks. The heatmap is rendered
on its own repaint-isolated layer with frequency bins aggregated to ~one band
per vertical pixel, so cursor motion and unrelated worksheet repaints never
re-rasterize it (rendering detail; the visual contract is unchanged).

Segment length sets the frequency resolution as on the FFT chart, but the
**time-column count is a display concern, not a Welch-averaging one**: the
spectrogram does not honour the FFT chart's `overlapPercent`. Instead it
auto-sizes the STFT hop (`ChartSlot.autoSpectrogramOverlap`) to fill its time
axis with roughly `kSpectrogramTargetColumns` (240) frames — the short-hop,
high-overlap regime a heatmap needs — bounded so very short windows pack the
maximum frames the window allows (hop ≥ 1) and very long windows stay
non-overlapping. This is independent of the segment length's frequency
resolution.

**Shared spectral params.** Both charts read one `SpectralParams` group on the
slot — `window`, `segmentLength` (auto when null), `overlapPercent`, `detrend`,
`scaling`, `freqScale` — migrated from the legacy flat `fft*` keys on load.
`overlapPercent` drives the FFT chart's Welch hop; the spectrogram derives its
hop from a target time-column count instead (above). The FFT chart adds
`fftAveraging` (Welch averaging); the spectrogram omits it (keeping every frame
is what makes it a spectrogram). The math-channel `spectrogram(ch)` function
stays deferred (a 2-D result has no 1-D channel form).

### 26.11 Tables

Tables are first-class worksheet content alongside charts. A worksheet holds an
ordered list of **`WorksheetBlock`s**, each a chart or a table with a
`placement` (`inFlow` | `sideBySide` | `overlay`). v1 honours only `inFlow`
(stacked in document order); `placement` is persisted so the flexible-layout
subsystem can read it later. Charts always precede tables in a worksheet — a new
table appends below the charts — which keeps the chart-index call sites and the
Session-Sheet pinned-slot guards unchanged. A legacy worksheet's flat `charts`
array migrates to chart blocks on load.

**Hybrid grid.** A table is columns × rows of cells. A **column** carries an
optional `name` (the `{name}` reference target) and a `template` formula applied
to every cell in the column that has no own formula. A **row** carries an
optional `RowContext { sessionId, lapIndex }` that binds the row to a lap, so
the row's `[Channel]` references resolve to that lap's time window. A **cell** is
a literal value (short-circuits evaluation), an explicit formula, or blank
(falls back to the column template). The per-lap summary preset (the Add-table
entry) builds one row per lap of the bound session, a Lap-number label column, a
`max([Channel])` metric column per default channel, and a delta-to-best column.

**Cell references — the `{ … }` namespace.** Inside a cell formula:
- `{A1}` / `{$A$1}` — a single cell (column letter + 1-based row) → **scalar**.
- `{name}` — the named column, **this row** → scalar (same-row reference).
- `{name[]}` — the whole named column → **array**, for aggregates such as
  `min({fork_max[]})`.

Channel references stay bracketed (`[Fork]`); the `{cell}` sigil is a disjoint
namespace. A cell must reduce to a single value — a bare `[Channel]` (multi
-sample) is an error advising an aggregate (e.g. `mean([Fork])`).

**Engine evaluation.** Tables evaluate entirely in `idl-rs` (`table::evaluate_table`):
cells are topologically ordered by their `{cell}` dependencies (a cycle marks
the cells on it with a "Circular reference" error rather than looping), then each
is evaluated with `math::evaluate_scalar` against a `CellLookup` that slices
`[Channel]` references to the row's lap window and resolves `{cell}` / `{col[]}`
from already-computed cells. Only the small per-cell `CellResult { value, error }`
grid crosses FFI (the §15.3 seam); a row's lap window `(t0, t1)` is supplied by
the app from the lap cache. The **firewall**: `ChannelLookup::lookup_cell`
defaults to "none", so channel math (the Maths editor) cannot see cells and the
two namespaces never cross (§19).

**Multi-session evaluation.** `table::evaluate_table_multi(handles, row_handles,
table, row_windows, baseline_row)` is the substrate for rows that bind **different
sessions**: each row resolves its `[Channel]` references against
`handles[row_handles[r]]`, while cross-row `{cell}` / `{col[]}` references resolve
from the global values map in a single pass exactly as before. `evaluate_table`
is a single-handle convenience delegate. `baseline_row` (when set) is the row the
`main({col[]})` aggregate reads from — it returns that column's value in the
baseline (Main) row, or `NaN` when no baseline row is set, so a delta-vs-Main
column is `{metric} - main({metric[]})`. This substrate backs both the live N-lap
comparison table (§26.13) and cross-session table evaluation in the CLI.

**Portability.** The `TableModel` (columns / rows / cells) is a serde-portable
engine type with camelCase keys matching the Dart `toJson`; it persists inside
the worksheet block in the `.idl0wb` and is the single artifact a headless caller
(CLI / Python / WASM) reads to recompute a table — the same status math channels
have. The widget edits the model; evaluation is always engine-side.

### 26.12 Y-axis scale (shared)

Every chart with a continuous Y axis — time-series, FFT magnitude, histogram
count, lap progression — shares one `ChartSlot.yScale`: `linear` (default),
`log`, `sqrtSigned`, or `squareSigned`, chosen from the **Y scale** control in
the properties dialog. It replaces the former per-chart `fftYScale` and
`histogramLogCount` (both migrate to `yScale: log` on load). GPS map and the lap
table have no continuous Y and ignore it.

- **Transforms.** A pure Dart module (`y_scale.dart`) maps real values to
  display space and back. `log` is **signed log** (symlog): linear in a small
  auto-sized band around zero, log in both tails — so it works on zero-crossing
  data (velocity, acceleration) and reduces to plain log₁₀ on always-positive
  data. `sqrtSigned` = `sign(y)·√|y|` (compresses spikes); `squareSigned` =
  `sign(y)·y²` (emphasises them). All are monotonic and continuous through zero.
- **Where it runs.** A display concern, not signal processing — applied in Dart
  to the already-decimated spots (no engine round-trip; because the transforms
  are monotonic the decimated min/max envelope is preserved). The symlog band is
  sized from the chart's Y *range*, so the axis is stable across pan/zoom. Tick
  labels are inverse-transformed back to real units; cursors and tooltips always
  read real values.
- **FFT / histogram `log`.** These keep their existing specialised `log`
  rendering (decade-minor gridlines, count-axis floor); only `linear` / `sqrt` /
  `square` route through the shared transform for them.
- **v1.** Ticks are placed evenly in display space, so labels are correct
  real-unit values but not necessarily round numbers; "nice" non-linear tick
  placement is a deferred follow-up.

### 26.13 N-Lap Comparison

Compares the laps in the current lap-mode selection — up to ten, spanning
multiple sessions — against a **Main** reference lap. Main defaults to the
**fastest** selected lap (min lap time) and is overridable to any selected lap
via `selectionProvider.setMainLap` (§13). The other selected laps are
**overlays**, capped at **`kMaxOverlayLaps = 9`** (10 laps total; the bound keeps
the chart legible and within the colour palette). `comparisonLapsProvider` derives
the ordered set — Main first, then overlays by lap time ascending, with a
"showing N of M" note when the selection exceeds the cap. This generalises the
legacy two-lap Main/Overlay path (one overlay → up to nine, cross-session); that
path is unchanged and coexists.

**Comparison table.** A worksheet table block with `rowSource = lapSelection`
(vs the default `authored`) derives one row per `comparisonLapsProvider` lap —
Main first — live from the selection; only its columns, not its rows, persist. It
evaluates through `table::evaluate_table_multi` (§26.11) with each row bound to its
lap's session handle and `baseline_row = 0`, so a delta-vs-Main column reads
`{metric} - main({metric[]})`.

**Lap Variance chart** (`ChartType.varianceTrace`). Plots one per-sample delta
line per overlay lap — `overlay − Main` at the matching position — with Main as
the zero baseline, up to nine lines per channel. Deltas are computed in `idl-rs`
by `variance::variance_traces(reference, targets, channel_id, mode)`, which builds
the reference (Main) geometry once and reuses the `variance_time` / `variance_dist`
core per target. `ChartSlot.varianceChannelIds` selects the channels;
`ChartSlot.varianceMode` (`time` | `distance`) the alignment. Both modes match
laps by **GPS position** — projecting each overlay lap's samples onto the Main
lap's own GPS path (the same `variance_geom` projection the legacy two-lap variance
uses), so laps of differing length still line up and **no Track or stored
centerline is required**. **Time** resolves the matched Main value by the Main
lap's elapsed time at that position; **Distance** by arc length along the path.
Both require GPS (`GPS_Latitude` / `GPS_Longitude`) on the Main and overlay laps;
the chart surfaces a typed inline message when GPS is missing.

### 26.14 Scatter / G-G chart

`ChartType.scatter` — one channel plotted against another, tuned so the **G-G
diagram** is first-class: lateral acceleration on X, longitudinal on Y, each point
the bike's combined-acceleration state at one instant, the cloud tracing the
traction envelope. It serves any channel-vs-channel view (travel-vs-velocity,
front-vs-rear travel) too.

- **Engine.** Pairing, decimation, binning, and bound computation live in `idl-rs`
  (`scatter::{scatter_points, scatter_density}`): two channels slice from the
  retained handle over the resolved `[t0, t1]` window, pair index-aligned over their
  common length (the same-rate G-G case is exact), and drop non-finite pairs. Only
  the reduced result crosses FFI — a decimated cloud or a binned grid, never the raw
  samples (the §15.3 seam). Each render is **one** `handle in → result out` call: the
  engine returns the data extent it used, so equal-aspect squaring and density binning
  never round-trip an axis bound back across the boundary.
- **Modes** (`ScatterMode`). **Points** — a uniform-stride-decimated cloud
  (`scatter_points`, capped at a few thousand spots), coloured by a solid
  per-session colour or, when `scatterColorChannelId` is set, by a third channel
  through the Turbo colormap. **Density** — a `scatterBinCount × scatterBinCount`
  2D count heatmap (`scatter_density`) showing time-at-state, Turbo on count.
- **Equal aspect & reference circles.** When `scatterEqualAspect`, the plot is square
  at 1:1 data-units-per-pixel over a single shared range covering both axes (symmetric
  about 0 for the straddle-zero G-G case), so a friction circle renders round. When
  `scatterReferenceCircles`, concentric g-rings at 0.5-unit spacing plus a quadrant
  cross at the origin are drawn behind the data. Both default on.
- **Rendering.** A single `CustomPainter` owns the plot-area transform and draws every
  layer — reference overlay, cloud or heatmap, axes, colour bar — through one
  coordinate mapping (the spectrogram-chart pattern), so the rings, the points, and the
  grid always agree. `fl_chart` is not used (its fill-the-box layout fights equal-aspect
  and has no data-space circle primitive).
- **Scope.** Reuses `ChartScope`: `auto` → the designated Main lap's window when one
  resolves on the single rendered session, else the full session; `session` → always
  full. A per-lap G-G falls out for free.
- **Slot fields.** `scatterXChannelId` / `scatterYChannelId` (axis channels, base ∪
  math), `scatterMode` (default `points`), `scatterColorChannelId` +
  `scatterColorMin` / `scatterColorMax` (points colour-by; null ⇒ auto/solid),
  `scatterEqualAspect` (default true), `scatterReferenceCircles` (default true),
  `scatterBinCount` (default 64, clamped 8–256) — persisted on the slot, emitted to
  JSON only for scatter slots.

---

## 27. Tab — Settings

Tab 5 of the [AdaptiveScaffold](../app/lib/ui/shell/adaptive_shell.dart) shell. Icon: `Icons.settings`.

**Layout.** Narrow (< 720 dp): a single vertical scroll of the §27.4 sections, each a `MinimalSectionHead` + content (Firmware is a collapsed-by-default `CollapsibleSection`). Wide (≥ 720 dp): a two-pane layout — a left list of the sections + a right detail pane showing the selected section (default Profile), matching the Data tab's wide idiom (§24.2). Every control is reachable in both layouts.

### 27.1 AppSettings model

`app/lib/data/app_settings.dart`

| Field | Type | Default | Persistence key |
|-------|------|---------|-----------------|
| `riderName` | `String` | `''` | `rider_name` |
| `unitSystem` | `UnitSystem` | `imperial` | `unit_system` (int index) |
| `autoSyncOnDownload` | `bool` | `true` | `auto_sync_on_download` |
| `syncOnWifiOnly` | `bool` | `true` | `sync_on_wifi_only` |
| `autoSyncOnOpen` | `bool` | `false` | `auto_sync_on_open` |
| `firmwareChannel` | `FirmwareChannel` | `stable` | `firmware_channel` (int index) |
| `autoCheckFirmware` | `bool` | `true` | `auto_check_firmware` |

`autoSyncOnOpen` is the "connect and forget" switch for the Data tab's Sync screen (§24.17). Default **OFF**: the screen opens as an unchecked file picker. When ON, opening the screen downloads all NEW device files automatically.

`UnitSystem` enum: `imperial`, `metric`.

Backed by `shared_preferences`. `SettingsNotifier` starts at `AppSettings.defaults()` and updates once the async load completes.

### 27.2 Unit system — defaultUnit()

`String defaultUnit(MathQuantity q, UnitSystem system)` in `app/lib/data/math_quantity.dart`.

Imperial overrides: Speed → mph, Length & Distance → ft, Pressure & Stress / Delta → psi, Temperature / Delta → °F, Force → lbf, Torque → ft·lbf, Spring Constant → lb/in, Mass → lb, Power → hp. All other quantities return their primary unit (index 0) regardless of system.

Called by `ChannelMetadataBar._onQuantityChanged` to set the default unit when the user picks a quantity.

### 27.3 Shell navigation

`shellIndexProvider` (`StateProvider<int>`) in `adaptive_shell.dart` replaces local `_selectedIndex` state. Any widget in the tree can navigate tabs by writing to `ref.read(shellIndexProvider.notifier).state`.

### 27.4 Sections

| # | Title | Content |
|---|-------|---------|
| 1 | Profile | Rider name — debounced 500 ms text field |
| 2 | Units | `SegmentedButton<UnitSystem>` + summary line |
| 3 | Drive Sync | Sign in/out, auto-sync toggle, WiFi-only toggle, auto-sync-on-open toggle |
| 4 | Firmware | OTA update. Auto-checks the selected channel (stable/beta) against the running version (§7.3 `Firmware:`) and shows an "update available vX → vY" card that downloads from GitHub Releases (§27.7) and runs the OTA push. Channel picker, auto-check toggle, "Check now", plus the manual `.bin` picker as fallback. Progress / reboot states, pending-verify commit/rollback card. See §4.6 / §6.1 / §27.7. Collapsed by default in the narrow layout. |
| 5 | Controls | Read-only reference of the chart keyboard / mouse / wheel shortcuts (mirrors `kDefaultChartBindings` + `wheelModeFor`, §26.7), grouped Mouse wheel / Mouse / Keyboard as leader-dot `SpecRow`s. Editable rebinding is a v2 follow-up. |
| 6 | How-Tos | 4 markdown articles + Full Reference link |
| 7 | About | App version (hardcoded 0.1.0), Open Source Licenses, Report an Issue |

### 27.5 How-to articles

Assets in `assets/howtos/`. Rendered via `flutter_markdown` in a pushed `Scaffold` route.

| File | Title |
|------|-------|
| `first_setup.md` | First Setup |
| `wifi_download.md` | WiFi Download |
| `lap_gate.md` | GPS Lap Gate |
| `math_channels.md` | Math Channels |

### 27.6 Data tab redirect

`_DriveSection` in the Data tab: when not signed in and user taps the Sign In button, navigates to Settings tab (index 4) via `shellIndexProvider` and shows `SnackBar("Sign in to Google Drive in Settings")`.

### 27.7 Firmware auto-update

The app pulls published firmware from a dedicated GitHub repository
(`kFirmwareRepoSlug`, a single app constant) via the public GitHub Releases
REST API — no auth token, no server.

**Version of record.** The git tag is the firmware version: CI sets the build
version from the tag (leading `v` stripped), so the embedded
`esp_app_desc_t.version` — reported over `/ping` `fw` and the §7.3 `Firmware:`
line — equals the release tag. The app parses both ends as semver and offers an
update only when hosted `>` device.

**Channels.** `stable` = the latest non-prerelease release (`/releases/latest`);
`beta` = the newest non-draft release including prereleases. A tag with a
`-beta`/`-rc` suffix is published as a GitHub prerelease.

**Flow.** On connect/open (when auto-check is on) and on demand, the app fetches
the channel's latest release, compares versions, and surfaces an "update
available" card (Settings → Firmware) and a Device-hero banner. Accepting
downloads the `.bin` into memory — optionally verifying a published
`firmware.bin.sha256` — then hands the bytes to the existing OTA push (§6.1
`/ota` → reboot → §7.2 `CMD_OTA_CONFIRM`). The device's embedded SHA-256
(`esp_ota_end`) remains the authoritative integrity gate; the app-side check is
a fast-fail.

**Failure modes.** Offline or absent device version → no banner, manual push
still available. An update is offered only when hosted is strictly newer; a
channel switch that leaves the device ahead of the channel shows an
informational note, not a downgrade prompt.

---

# PART 7 — CROSS-CUTTING

## 28. Google Drive Sync

**Goal:** Automatic, invisible — experience like Google Docs. Session appears on all devices without user action.

**Behavior:**
- One-time setup: sign in + configure Drive folder (Settings → Google Account)
- Auto-upload source file (`.idl0` for device-recorded, `.gpx` for imported) + `.idl0w` workspace after every WiFi download or import
- Workspace changes sync within seconds of save
- Offline: queues sync, uploads when connectivity returns
- Auth: `google_sign_in`, scope `drive.file` (least privilege)

**Drive folder structure:**
```
IDL0/
├── sessions/
│   └── YYYY-MM-DD_venue_rider/
│       ├── uuid.idl0     (or uuid.gpx for imported runs)
│       └── uuid.idl0w
├── tracks/
│   └── <trackId>.idl0t   (one Track per file, see §16)
├── workbooks/
│   └── <workbookId>.idl0wb  (one Workbook per file, see §17a)
└── exports/
    ├── uuid.csv
    └── uuid.fit
```

Workbooks (`.idl0wb`) are synced under `IDL0/workbooks/<workbookId>.idl0wb` with last-write-wins by `updated_at_ms`. See §17a.

**Per-session sync status in Data tab:** source file (`.idl0` or `.gpx`) / `.idl0w` / `.csv` / `.fit` — states: not uploaded / queued / uploading / synced / error. The indicator always renders all four file types regardless of whether the file exists on disk; `.csv` and `.fit` show `notUploaded` until export generates them. File-type keys in the sync status map are lowercase strings without dots. For GPX-sourced sessions, the `idl0` slot is replaced by a `gpx` key.

**`DriveService` surface:**
- `uploadSession(sessionId)` — uploads source file + `.idl0w` for the given session; queues if offline.
- `uploadWorkspace(sessionId)` — uploads only the `.idl0w`; called on every workspace save.
- `uploadTrack(trackId)` — uploads the `.idl0t` file; called by `TrackNotifier` after create/update.
- `deleteRemote(sessionId)` — removes all Drive files for the given session (`uuid.idl0`/`.gpx` + `uuid.idl0w`). Called by `RunsNotifier.deleteSession` when the user selects "Delete everywhere". Errors propagate to the caller so that the local delete is aborted if the remote delete fails; the user sees an error and the session remains intact locally.

**Future (v2):** Download sessions from Drive — coach reviews rider data from home without physical device access.

---

## 29. Data Export

### 29.1 CSV
- Column per channel, row per sample
- Timestamp: relative (s from start) + absolute UTC (if GPS anchor available)

### 29.2 FIT (Garmin)

FIT activity export for Strava / Garmin Connect upload, produced by the `idl-rs`
engine (`export::write_fit`) and exposed on the CLI as `idl-rs fit` (§29.5). The
encoder is hand-rolled in the pure core (the Rust ecosystem has FIT readers but
no mature writer); it streams to any `io::Write`.

**Messages emitted** (FIT-valid order): `file_id` (type=activity,
manufacturer=development), `device_info` (fixed branding: manufacturer=development,
`product_name="IDL0"`), one `record` per GPS fix, `lap` message(s), `session`,
and `activity`.

**Field mapping** (all from existing channels): timestamp from `GPS_EpochMs`
(unix→FIT epoch, offset 631 065 600 s); `position_lat`/`position_long` from
`GPS_Latitude`/`GPS_Longitude` as semicircles (`deg × 2³¹/180`); `altitude` from
`GPS_Altitude`; `speed` from `GPS_SpeedKmh`; `distance` as cumulative haversine;
`heart_rate` from `HR_BPM`. Altitude / speed / heart-rate fields are included in
the `record` definition only when their source channel is present.

**Heart rate** is carry-forward merged onto the GPS record stream: `HR_BPM` is
event-driven (session-relative time → wall clock via the GPS-anchored session
start), and each record takes the most recent beat at-or-before its timestamp.
`session.avg_heart_rate`/`max_heart_rate` are emitted when HR is present.

**Laps:** the encoder takes a slim `FitLap` list (`start_ms`, `end_ms`,
`elapsed_ms` — the effective lap time, neutral zones removed) and emits one `lap`
message per entry, or a single whole-ride lap when the list is empty. The CLI
builds it from `detect_laps` (`--track`, `.idl0t`); the app builds it from the
session's cached track-visit laps (§29.2.1). The slim type keeps the full lap
model off the FFI boundary — the encoder only ever needs the three timing fields.

**Out of scope:** IMU and other non-standard data have no native FIT fields.
They are expressible only via Developer Data Fields (a `developer_data_id` +
`field_description` per custom field), which Strava / Garmin Connect carry but do
not render — so they are not emitted. A position-less session is rejected
(`NoGpsData`): a FIT activity without a GPS track is not meaningful for upload.

### 29.2.1 In-app FIT export

The Data-tab session detail card offers **Export .fit** beside **Create track**,
shown only for GPS sessions (FIT export requires a position track, so the
`NoGpsData` path is unreachable from the UI). The app calls the engine's
`export_fit_to_vec` bridge wrapper — which returns the FIT bytes in memory — then
writes them to a user-chosen path via a file picker. Laps come from the session's
cached `TrackVisit` laps (all visits, chronological) as `FitLap`s; an untracked
session exports a single whole-ride lap. Sport is cycling. The default filename is
`YYYY-MM-DD_<venue>.fit` (the resolved display venue, else the local time).

After a successful save, a desktop-only affordance appears beside the button: a
drag handle that drags the saved `.fit` into a browser upload target (e.g.
Strava), and a reveal-in-file-manager action. Direct Strava upload (OAuth) and
embedding an activity description are out of scope — a `.fit` cannot carry a
Strava description, so uploads are manual.

### 29.3 LD (MoTeC i2pro)
- ⚠️ **Not for distribution.** Opening `.ld` in i2pro requires MoTeC license.
- Not yet implemented; if built, a personal utility excluded from releases
- ⚠️ **Format is byte-exact.** Header field offsets, string padding, channel descriptor layout must match precisely or i2pro silently fails. Validate every output against i2pro before considering done.

### 29.4 Future
HDF5 (`.h5`) — preserves metadata + sample rates, native Python/MATLAB support. Low priority.

### 29.5 CLI export (`idl-rs` engine)

Headless export from the `idl-rs` CLI. The serialization is a capability of the
`idl-rs` **core** (`export` module — pure, streaming to any writer), so the CLI,
the app, and future Python/WASM bindings share one implementation. Input is
`.idl0` only (GPX import is app-side). The `export` command's channel set is the
raw parsed channels plus the synthesized `Time`/`Distance`; derived math channels
are produced by the separate `math` command below.

```
idl-rs export <file.idl0> [-o OUT] [--format csv|json] [--channel NAME]...
```

- **Format resolution:** `--format` wins; otherwise inferred from the `-o`
  extension (`.csv`/`.json`); with no `-o`, output goes to stdout as CSV.
- **`--channel NAME`** (repeatable) restricts output to an allow-list, in the
  given order; default is all channels. An unknown id is an error listing the
  available channels.
- **CSV is long/tidy** — header `channel,time_s,value`, one row per sample.
  `time_s` is `index / sample_rate_hz` for fixed-rate channels and the
  per-sample time for event-driven channels. This differs from §29.1's
  app-side column-per-channel layout: long/tidy handles mixed sample rates in
  one file without resampling or inventing data.
- **JSON is nested and lossless** — a `session` metadata object plus a
  `channels` array; each channel carries `sample_rate_hz`, `synthesized`,
  `is_event_driven`, `samples`, and (event-driven only) `sample_times_secs`.
- Truncated logs still export (recover what is readable) with a stderr warning.

**Headless workbook evaluation.** The `math` command evaluates a portable
workbook's math channels against a session and exports the derived results:

```
idl-rs math <file.idl0> --workbook <wb.idl0wb> [-o OUT] [--format csv|json] [--include-base] [--channel NAME]...
```

- The `.idl0wb` is read for its `math_channels` only (`workbook::apply_workbook`);
  worksheets/layout are display state the engine ignores.
- Default output is the **derived channels only**; `--include-base` prepends the
  base + synthesized channels, and `--channel` filters within the result set.
- Cross-channel dependencies resolve in the engine (§19). Lap-aware functions
  (`variance_*`, `current_lap`, …) require a lap context the CLI does not yet
  build (headless main/overlay-lap selection is a separate follow-up, even
  though lap *detection* now exists — §29.6): such channels are reported
  `skipped` on stderr and omitted from the output, while the rest export normally.
- Per-channel outcomes (`ok` / `skipped` / `error`) print to stderr; the data
  stays on the output sink. Partial success is success; the command fails only
  if the workbook cannot be read or no channel evaluates.

**FIT activity export.** The `fit` command converts a session to a Garmin FIT
file (§29.2):

```
idl-rs fit <file.idl0> [-o OUT] [--sport cycling|motorcycling|running|generic] [--track <t.idl0t>]
```

- `--sport` defaults to `cycling`; `-o` defaults to the input path with a `.fit`
  extension.
- `--track` (optional) reads a `.idl0t` artifact, requires its lap timing, runs
  `detect_laps`, and writes the splits as FIT `lap` messages.
- Errors if the session has no GPS data.

Parquet is not yet supported (deferred until a concrete columnar consumer).

### 29.6 CLI lap & track analysis

Headless lap timing and track matching, taking a portable Track artifact
(§17b) alongside the `.idl0` session. The engine reads the `.idl0t`
(`track_artifact` module) and runs the Phase-4 `detect_laps` / `detect_visits`.

```
idl-rs laps   <file.idl0> --track <t.idl0t> [--format json]
idl-rs visits <file.idl0> --track <a.idl0t> [--track <b.idl0t> …] [--format json]
```

- **`laps`** prints the lap table for the track's timing (lap number, start,
  lap time, raw elapsed; sector splits and neutral-zone subtractions indented
  beneath). Errors if the artifact has no `lap_timing`.
- **`visits`** prints which tracks the session visited and when (track name,
  start, end, duration), in time order. `--track` is repeatable.
- Output is human text by default; `--format json` emits the enveloped success
  form (§29.7). CSV is not offered here — nested lap/sector data maps poorly to
  flat rows; use `export` for tabular channel data.

### 29.7 CLI output envelope

Every `idl-rs` command speaks one versioned JSON **envelope** so a script or
agent has a single shape to parse and one error path to branch on. The wrapper
is a CLI concern (`rust/cli/src/envelope.rs`); the engine and app call the core
directly and never see it.

**Shape.** Success and error share a head — `schema` (contract version,
currently `1`), `ok` (mirrors the exit code), `command`, and `engine` (the CLI's
version string) — then exactly one of `data` or `error`:

```json
{ "schema": 1, "ok": true,  "command": "laps", "engine": "0.1.0",
  "data": { "laps": [ … ] },
  "warnings": [ { "kind": "truncated_log", "message": "log incomplete — 3 records dropped at EOF" } ] }

{ "schema": 1, "ok": false, "command": "laps", "engine": "0.1.0",
  "error": { "kind": "invalid_input", "message": "…", "details": { "track": "whistler.idl0t" } } }
```

- `data` (success only) is **always an object**, never a bare array — collections
  live in a named field (`{"laps":[…]}`) so the shape stays additively extensible.
- `warnings` (optional, omitted when empty) carries non-fatal machine-readable
  caveats as `{kind, message}`. A truncated log surfaces as `truncated_log` here,
  not only as a stderr line.
- `error` (failure only) is `{kind, message, details?}`. `details` is an open
  object — by convention `not_found` carries the `available` list (one-retry
  self-correction), `eval` carries `eval_kind`, `invalid_input` carries the
  offending `track` / `expected_magic`.

**Error `kind`** is a closed set a consumer branches on; finer detail lives in
`details`, never in new kinds:

| `kind` | Meaning |
|---|---|
| `io` | A file could not be read or written. |
| `invalid_input` | A file is present but unusable: bad magic, unsupported schema, malformed config, or a missing required field. |
| `not_found` | A named entity is absent in the loaded data (unknown channel / track / header). |
| `eval` | A math-channel expression failed to evaluate; `details.eval_kind` echoes the engine discriminant. |
| `unsupported` | A deferred / not-yet-implemented capability was requested. |
| `usage` | Invalid arguments past clap (e.g. a format that cannot be inferred). |
| `internal` | An unexpected failure — a bug. |

Consumers MUST tolerate an unknown `kind` (treat as `internal`) and ignore
unknown `data`/`warning` fields. Additive changes (new `data` fields, new
kinds, new commands) keep `schema`; only a breaking change to an existing field
bumps it.

**Structured vs. bulk.** Commands split by output size:

- **Structured** — `info`, `channels`, `laps`, `visits`, `table`: small
  aggregated/metadata results. Default output is **human text**; `--format json`
  emits the success envelope on stdout. Failures emit the error envelope on
  stdout.
- **Bulk** — `export`, `math`, `fit`, `recover`, `scan`: sample streams /
  binaries. Success writes the raw CSV/FIT/`.idl0` artifact to stdout or `-o`
  unchanged; failure writes the error envelope to **stderr** and exits non-zero.
  Bulk commands have no success envelope, so their per-item diagnostics
  (e.g. `math`'s per-channel `ok`/`skipped`/`error` lines) stay stderr-only.

The universal rule: **every command emits a JSON error envelope on failure** —
on stdout for structured commands, on stderr for bulk commands. The raw-output
streams (stdout / `-o`) of a bulk command never carry an error.

**Streams & exit codes.** stdout carries the one machine artifact (envelope or
raw output); stderr is human-only and never required to parse. `-o <path>`
receives the successful payload only — an error always returns on the standard
streams, never into the output file. Exit `0` = success, `1` = enveloped runtime
error (parse `error.kind`), `2` = clap argument/usage error raised before
dispatch (clap's native stderr message, **not** enveloped). "No results" is
success: a command that completes but finds nothing returns `ok: true` with an
empty collection.

**Per-command `data`** (structured commands; field names follow the engine's
serde output):

- `info` → `{ session_id, device_id, timestamp_utc_ms, config_checksum, channel_count, duration_ms }`.
- `channels` → `{ channels: [ { channel_id, sample_rate_hz, length, synthesized } ] }`.
- `laps` → `{ laps: [ Lap ] }`, the engine's `Lap` serde shape.
- `visits` → `{ visits: [ { track_id, name, start_ms, end_ms, duration_ms } ] }`.
- `table` → the self-describing table result (columns + resolved row windows +
  cells); the envelope is its wrapper.

JSON is pretty-printed. The human defaults are unchanged (`text` for the
structured inspect commands, `csv` for `export`/`math`); a machine consumer
passes `--format json` explicitly.

### 29.8 CLI table evaluation

Headless evaluation of a workbook's tables (§26 worksheet blocks) against a
session. The engine
surfaces table blocks from the `.idl0wb` (`Workbook::tables`), resolves each
row's lap window (`table::lap_windows`), evaluates with the shared cell evaluator
(`table::evaluate_table`), and validates structure (`table::validate`). A nested
`table` command group exposes three sub-actions, each taking exactly the
arguments it needs:

```
idl-rs table eval  <session.idl0> --workbook <wb.idl0wb> [--track <t.idl0t>] [--table <block_id>] [--format text|csv|json]
idl-rs table list                  --workbook <wb.idl0wb>                                          [--format text|json]
idl-rs table check [<session.idl0>] --workbook <wb.idl0wb> [--track <t.idl0t>]                     [--format text|json]
```

- **`eval`** evaluates the workbook's tables against one session (the v1 scope —
  see below) and returns the resolved grids. `--table` narrows to one block id
  (else all tables, same `{ tables: [...] }` shape). `--track` is required iff a
  selected table has lap-bound rows; a missing track then is a `usage` error.
  `--format csv` emits a raw grid (header of column names, `#ERR` for a cell
  error), `text` an aligned grid, `json` the enveloped self-describing form.
- **`list`** enumerates the tables a workbook contains — no session, no
  evaluation — for discovery before a run.
- **`check`** validates every table and reports problems; the session is
  optional (with one, an eval pass also reports cell errors). It always exits `0`
  — problems are a *result*, not a command failure.

`table` is a **structured** command (§29.7): JSON enveloped, `text`/`csv` for
humans. Per-action `data`:

- **`eval`** → `{ tables: [ { block_id, worksheet, placement, overlay_target_id,
  columns: [Column], rows: [ { context, window: {t0,t1}|null, cells: [CellResult] } ] } ] }`.
  `columns`/`cells`/`context` are the engine's `Column` / `CellResult` /
  `RowContext` serde shapes; `window` is the row's resolved recording-time span.
  A per-cell `error` is data, not a command failure.
- **`list`** → `{ tables: [ { block_id, worksheet, placement, overlay_target_id,
  columns: [name], row_count } ] }`.
- **`check`** → `{ tables: [ { block_id, worksheet, problems: [ { row, col, kind,
  message } ] } ] }`, where `kind` is `dimension_mismatch` / `parse_error` /
  `unknown_reference` / `cycle` (static) or `eval_error` (session pass).

**Warnings** (`eval`, in the envelope `warnings`): `session_mismatch` (a row's
bound `sessionId` differs from the passed session) and `lap_out_of_range` (a
`lapIndex` past the session's detected laps; that row's window is null).

**Layout metadata** (`placement`, `overlay_target_id`) is surfaced for the
consumer's awareness; the CLI never renders layout.

**Scope:** a table is evaluated against a **single** session. Cross-session tables
(rows binding different sessions) are not yet supported — the cell evaluator is
single-handle.

**Authoring** is not a CLI command: the `.idl0wb` is portable JSON, edited
directly, then validated with `table check`. The table-block schema inside a
workbook is `worksheets[].blocks[]` where a block is
`{ id, placement, content }` and a table block's `content` is
`{ "kind": "table", "table": <TableModel> }`; a `TableModel` is
`{ columns: [ {id, name?, template?} ], rows: [ {id, context?: {sessionId, lapIndex}} ], cells: [[ {formula?, literal?, name?} ]] }`
(camelCase keys, identical to the engine's serde).

### 29.9 CLI frequency analysis (`idl-rs fft` / `idl-rs spectrogram`)

Headless Welch spectrum and spectrogram of a single channel, backed by
`welch_channel` / `welch_channel_windowed` / `spectrogram_channel` in the
engine (§19). Samples never cross the CLI boundary — only the compact result
does. Both commands are **structured** (§29.7): text mode is the default;
`--format json` emits a success envelope on stdout.

#### `idl-rs fft`

```
idl-rs fft <session.idl0> --channel <id>
           [--from <secs>] [--to <secs>]
           [--window hann|hamming|rect]    (default: hann)
           [--nperseg <n>]                (default: 0 = one full-record segment)
           [--noverlap <n>]               (default: 0)
           [--detrend none|mean|linear]   (default: mean)
           [--averaging mean|median]      (default: mean)
           [--scaling magnitude|density]  (default: magnitude)
           [--format text|json]           (default: text)
```

- When `--from` and `--to` are both absent the whole session is used
  (`welch_channel`). If either is present the windowed path runs
  (`welch_channel_windowed`) with the missing bound filled from
  `[0, duration_secs]`.
- `--nperseg 0` (default) selects a single full-record segment — rectangular
  window with no detrend reproduces the raw periodogram bin-for-bin.
- **Text mode** — one `freq_hz\tvalue` line per bin, stdout.
- **JSON mode** — success envelope with:
  ```json
  "data": {
    "channel": "<id>",
    "freqs_hz": [0.0, …],
    "values":   [0.0, …]
  }
  ```
  `freqs_hz` and `values` are the same length (`nperseg_used / 2 + 1`).
  Units of `values` follow `--scaling`: Magnitude = RMS in input units;
  Density = PSD in input-units²/Hz.

#### `idl-rs spectrogram`

```
idl-rs spectrogram <session.idl0> --channel <id>
                   [--from <secs>] [--to <secs>]
                   [--window hann|hamming|rect]    (default: hann)
                   [--nperseg <n>]                (default: 0)
                   [--noverlap <n>]               (default: 0)
                   [--detrend none|mean|linear]   (default: mean)
                   [--scaling magnitude|density]  (default: density)
                   [--format text|json]           (default: text)
```

- There is no whole-session spectrogram accessor; when `--from`/`--to` are
  absent the full `[0, duration_secs]` span is passed to
  `spectrogram_channel`. The `times_secs` in the result are absolute
  session seconds (shifted by `t0`).
- **Text mode** — prints `n_times\t<n>` and `n_freqs\t<n>` (the heatmap
  dimensions), stdout.
- **JSON mode** — success envelope with:
  ```json
  "data": {
    "channel":    "<id>",
    "freqs_hz":   [0.0, …],           // length n_freqs
    "times_secs": [0.0, …],           // length n_times, absolute session seconds
    "power":      [0.0, …],           // flat row-major n_times × n_freqs
    "n_times":    7,
    "n_freqs":    33
  }
  ```
  `power[t * n_freqs + f]` is the value at time frame `t`, frequency bin `f`.
  Units follow `--scaling` (same as `fft`).

**Error handling:** an unknown `--channel` returns a `not_found` envelope
with `data.available` listing the session's channel ids. All other engine
errors follow the §29.7 envelope contract.

---

## 30. First Launch / Onboarding

**Path A (have device):** Device tab → connect → load existing config or push default → calibrate → record.
**Path B (have files):** Data tab → import `.idl0` / `.gpx` from local
or Drive → faceted search → select sessions / laps → Analyze.

---

# PART 8 — DISTRIBUTION

## 31. Distribution

| Platform | Format | Notes |
|----------|--------|-------|
| Android | APK / AAB | Primary target |
| iOS | PWA (Flutter web) | Analysis-only, no BLE |
| Windows | MSIX / EXE | No store required |
| macOS | DMG | Requires Apple notarization (automated in CI) |
| Linux | AppImage | Optional |

Build: `flutter build apk|web|windows|macos`

---

## 32. Open Source

- **License: AGPL-3.0-or-later** (app + `idl-rs` engine); firmware is **GPL-3.0-or-later**.
- Contributions require signing the CLA (`CLA.md`).
- Three public repos under `github.com/saucyeng`:
  - `saucyeng/idl0-app` — the Flutter app (this repo); `idl-rs` is vendored as a git submodule at `rust/`.
  - `saucyeng/idl-rs` — the pure-Rust processing engine (`idl-rs` core, `idl-rs-bridge` FRB shim, `idl-rs-cli`).
  - `saucyeng/idl0-firmware` — the ESP32-C6 firmware.
- App repo structure: `app/` `rust/` (submodule) `tools/` `docs/`.

---

*This document is the source of truth. Update before implementing. Claude Code reads only sections relevant to the current task — see TOC.*
