// IDL0 Datasheet.
//
// Source of truth for system behaviour is `docs/IDL0_SPEC.md`. This file
// ports the spec into a print-friendly datasheet; when content drifts,
// the markdown wins.

#import "theme.typ": *
#import "diagrams.typ": (
  architecture-stack, signal-pipeline, hardware-block,
  coordinate-frame, ble-handshake, calibration-flow,
)

#show: datasheet-page

// =============================================================================
// COVER
// =============================================================================

#set page(header: none, footer: none, margin: (top: 2.6cm, bottom: 2.4cm, left: 2.4cm, right: 2.4cm))

// Vertical accent stripe along the left edge — a quiet brand signature.
#place(top + left, dx: -0.7cm, dy: -0.5cm,
  rect(width: 0.7cm, height: 28cm, fill: palette.accent, stroke: none))

// Tiny corner tag — "IDL0 · DATASHEET · v3 · 2026-05"
#place(top + right)[
  #text(font: mono-font, size: 7.5pt, tracking: 1.6pt, fill: palette.muted)[
    IDL0 · DATASHEET · SCHEMA 3 · 2026-05-04
  ]
]

#v(2.2cm)

// Wordmark
#text(font: mono-font, size: 11pt, weight: 600, tracking: 4pt, fill: palette.accent)[IDL0]

#v(0.5cm)

#text(font: mono-font, size: 42pt, weight: 600, tracking: -1pt)[Datasheet]

#v(0.2cm)

#text(font: body-font, size: 14pt, weight: 400, fill: palette.muted)[
  Suspension data logger for motorcycle and bicycle applications.\
  Hardware, firmware, transport, and signal-processing reference.
]

#v(1.6cm)

#block(
  fill: palette.panel,
  inset: 14pt,
  radius: 1pt,
  width: 100%,
  stroke: (left: 2pt + palette.accent),
)[
  #text(font: mono-font, size: 7.5pt, weight: 600, tracking: 1.6pt, fill: palette.accent)[
    SCOPE
  ] \
  #v(2pt)
  #text(font: body-font, size: 10pt)[
    IDL0 is a three-IMU, GPS-anchored data logger for suspension and
    chassis instrumentation. The device captures raw sensor bytes to SD
    card during a logging session; all signal-processing math lives in the
    companion app. This document is the engineering contract between the
    hardware, firmware, and application layers — every field, frame, byte
    offset, and pipeline stage on the wire is specified here.
  ]
]

#v(0.7cm)

// Stat strip — three eye-catching cards
#grid(
  columns: (1fr, 1fr, 1fr),
  gutter: 8pt,
  stat-card([Max IMU rate],     [1666], unit: [Hz]),
  stat-card([Accel range],      [±32],  unit: [g]),
  stat-card([Schema version],   [3]),
)

#v(0.4cm)

#grid(
  columns: (1fr, 1fr, 1fr),
  gutter: 8pt,
  stat-card([Wire byte order],  [LE]),
  stat-card([Storage budget],   [200], unit: [MB]),
  stat-card([Magic],            [IDL0]),
)

#v(1fr)

// Footer block — three columns of small metadata
#grid(
  columns: (1fr, 1fr, 1fr),
  column-gutter: 16pt,
  [
    #tag[Document] \
    #m[IDL0 Datasheet] \
    #m[v1.0 · 2026-05-04]
  ],
  [
    #tag[Hardware] \
    #m[Seeed XIAO ESP32-C6] \
    #m[3× LSM6DSO32 · MAX-M10S]
  ],
  [
    #tag[Software] \
    #m[Flutter · Riverpod] \
    #m[Rust · sci-rs · nalgebra]
  ],
)

#v(0.8cm)
#hairline
#v(0.3cm)

#text(font: mono-font, size: 7.5pt, tracking: 1.4pt, fill: palette.muted)[
  CONFIDENTIAL · ENGINEERING REFERENCE · GENERATED FROM docs/IDL0_SPEC.md
]

#pagebreak()

// =============================================================================
// REVISION HISTORY
// =============================================================================

#set page(
  header: context {
    set text(font: mono-font, size: 7.5pt, fill: palette.muted, tracking: 1pt)
    grid(columns: (1fr, auto), align: (left, right),
      [IDL0 DATASHEET],
      [v1.0 · 2026-05-04])
    v(-4pt)
    line(length: 100%, stroke: 0.4pt + palette.rule)
  },
  footer: context {
    set text(font: mono-font, size: 7.5pt, fill: palette.muted, tracking: 1pt)
    grid(columns: (1fr, auto, 1fr), align: (left, center, right),
      [IDL0.IO],
      counter(page).display("i"),
      [SCHEMA 3])
  },
  margin: (top: 2.4cm, bottom: 2.2cm, left: 2.2cm, right: 2.2cm),
)

#counter(page).update(1)

#kicker[Front matter]
#text(font: mono-font, size: 22pt, weight: 600)[Revision history]
#v(0.2em)
#line(length: 100%, stroke: 0.6pt + palette.accent)

#v(0.6em)

This datasheet describes IDL0 binary schema version #m[3], the WiFi/BLE
transport surface as of #m[2026-05-04], and the Rust signal-processing
pipeline shipped with the companion app. Earlier schema versions remain
parseable by the app within a two-week transition window after a schema
bump; see #s[10.3].

#v(0.5em)

#spec-table(
  columns: (auto, auto, auto, 1fr),
  [*Rev*],     [*Date*],         [*Schema*], [*Notes*],
  m[1.0],      m[2026-05-04],    m[3],       [Initial public datasheet. Tracks `docs/IDL0_SPEC.md` v1.0.],
  m[0.9],      m[2026-04-12],    m[3],       [Internal draft. Channel registry consolidated; HRM channels (22, 23) added.],
  m[0.8],      m[2026-03-20],    m[3],       [Schema 3 cut over from prototype's schema 1.],
)

#v(1.4em)

#kicker[Front matter]
#text(font: mono-font, size: 16pt, weight: 600)[Document conventions]
#v(0.2em)
#line(length: 100%, stroke: 0.4pt + palette.rule)
#v(0.6em)

#grid(columns: (1fr, 1fr), column-gutter: 18pt, row-gutter: 12pt,
  [
    #tag[Cross-references] \
    Section pointers render as #m[§N] or #m[§N.M]. They are clickable in
    the PDF and resolve to the bookmarked section.
  ],
  [
    #tag[Units] \
    Wherever a number appears, its unit appears with it. The Rust API
    follows scipy naming wherever it can.
  ],
  [
    #tag[Code voice] \
    `Inline code` is monospace. Constants, types, and field names use the
    same font as the wire — IBM Plex Mono throughout.
  ],
  [
    #tag[Byte order] \
    All multi-byte integers on the wire are little-endian (ESP32 native).
    Applies to every schema version.
  ],
  [
    #tag[Coordinate frame] \
    ISO 8855, right-hand: X forward, Y left, Z up. See #s[9].
  ],
  [
    #tag[Numeric literals] \
    Prefix #m[0x] for hex; otherwise decimal. Floats include a decimal
    point even when integer-valued.
  ],
)

#v(0.8em)

#callout(kind: "rule")[
  This document is forward-looking. It describes *what the system does*,
  not the path that led there. Recent change history lives in
  #m[CHANGELOG.md]; architectural decisions and tradeoffs live in
  #m[docs/design_rationale.md].
]

#pagebreak()

// =============================================================================
// TABLE OF CONTENTS
// =============================================================================

#kicker[Front matter]
#text(font: mono-font, size: 22pt, weight: 600)[Contents]
#v(0.2em)
#line(length: 100%, stroke: 0.6pt + palette.accent)
#v(0.4em)

#show outline.entry: it => block(above: 0.4em, below: 0.4em)[
  #set text(font: mono-font, size: 9.5pt, features: ("tnum",))
  #it
]

#outline(title: none, indent: auto, depth: 2)

#v(1.4em)

#kicker[Front matter]
#text(font: mono-font, size: 16pt, weight: 600)[Figures]
#v(0.2em)
#line(length: 100%, stroke: 0.4pt + palette.rule)
#v(0.3em)

#outline(title: none, target: figure)

#pagebreak()

// =============================================================================
// BODY — switch to arabic page numbering, full header/footer
// =============================================================================

#counter(page).update(1)
#set page(
  header: context {
    set text(font: mono-font, size: 7.5pt, fill: palette.muted, tracking: 1pt)
    grid(columns: (1fr, auto), align: (left, right),
      [IDL0 DATASHEET],
      [v1.0 · 2026-05-04])
    v(-4pt)
    line(length: 100%, stroke: 0.4pt + palette.rule)
  },
  footer: context {
    set text(font: mono-font, size: 7.5pt, fill: palette.muted, tracking: 1pt)
    grid(columns: (1fr, auto, 1fr), align: (left, center, right),
      [IDL0.IO],
      counter(page).display("1"),
      [SCHEMA 3])
  },
)

#part-divider("1", [Orientation])

// -----------------------------------------------------------------------------
#pagebreak(weak: true)
= System Philosophy <sec:philosophy>

Two hard domains, no overlap.

#callout(kind: "rule")[
  *Firmware:* during a logging session, raw capture only — sensor bytes to SD
  card, minimum clock cycles, no filtering, integration, or signal
  conditioning. Outside a logging session (boot, calibration, transfer, config)
  the device may compute as those tasks require. The one absolute, in every
  mode: *analysis DSP — filtering, integration, FFT, statistics — never runs on
  the device.*
]

*App.* All analysis computation. Rust processing layer (sci-rs + nalgebra)
called via #m[flutter_rust_bridge]. Dart for everything else. The device
computes calibration _values_; the app _applies_ them when processing a log.

*File model.* Log files (#m[.idl0]) are immutable after download. All derived
work lives in the workspace file (#m[.idl0w]). Editing a session never
mutates the recording.

The architectural consequence of these two domains is shown in
@fig:architecture — the firmware is one thin layer, and the app stacks four.
The wire between them is defined byte-for-byte in #s[5]. The processing
pipeline executed on that data is defined in #s[19].

== Decision rule

Does it operate on the *physics of the bike* — sensor data, rotation,
filtering, integration, frequency analysis? → Rust.\
Does it operate on the *app's data structures*, files, or UI state? → Dart.

This line is absolute. The processing crate (#m[app/rust/]) has no
knowledge of Flutter, files, or BLE; the Dart layers never call sci-rs or
nalgebra directly. Every Rust function reachable from Dart is annotated
with #m[#[flutter_rust_bridge::frb]] and exposed through the
auto-generated bindings.

#part-divider("2", [Device & wire])

// -----------------------------------------------------------------------------
#pagebreak(weak: true)
= Hardware <sec:hardware>

#figure(
  caption: [IDL0 hardware block. The ESP32-C6 fans out to three SPI IMUs,
    a UART GPS, two ADC pressure inputs, two ISR-counted wheel-pulse
    inputs, and a single radio shared between BLE (control) and WiFi
    (data). The radio coexistence rule is enforced in firmware — see
    #s[10.4].],
  hardware-block,
) <fig:hardware>

== Microcontroller

#spec-row[Module][Seeed Studio XIAO ESP32-C6]
#spec-row[Bus][SPI2 — shared among IMUs · individual CS per device]
#spec-row[Flash][4 MB · dual-OTA partition layout]
#spec-row[Wake source][Button · BLE central · battery monitor]

== Inertial — LSM6DSO32TR (×3)

#spec-table(
  columns: (auto, 1fr),
  [*Spec*],          [*Value*],
  [Accel range],     m[±4 / ±8 / ±16 / ±32 g — configurable],
  [Gyro range],      m[±125 / ±250 / ±500 / ±1000 / ±2000 dps],
  [Sample rate],     m[12.5 – 1666 Hz · high-performance mode],
  [Output],          m[16-bit signed · little-endian · raw LSB],
  [Interface],       m[SPI · individual CS],
)

#v(0.4em)

#callout(kind: "spec")[
  *IMU index is a fixed physical location.* #m[IMU0] is the sprung-mass
  reference on the main PCB; #m[IMU1] is the front unsprung (fork);
  #m[IMU2] is the rear unsprung (swingarm). Index never enumerates
  sequentially across boots, and #m[IMU2] is absent on hardtails — the
  channel registry simply omits its axes (see #s[5.2]).
]

== GPS — u-blox MAX-M10S

#spec-row[Antenna][Linx ANT-GNSSCP-TH25L1 ceramic patch (50 mm ground plane, 50 Ω RF trace)]
#spec-row[Interface][UART · 1–10 Hz configurable]
#spec-row[Role][Absolute time anchor + GPS track for mapping / sectors]
#spec-row[NMEA sentences][GGA + RMC default · SBAS enable configurable]
#spec-row[Dynamic model][automotive (default) · portable / pedestrian / sea / airborne available]

== Analog inputs

Two general-purpose ADC channels — #m[PRESSURE_FRONT] and #m[PRESSURE_REAR] —
driven by the ESP32-C6's 12-bit ADC at a maximum 3.3 V input. Primary use is
brake pressure transducers, but any 0–3.3 V source is valid. The app applies
user-defined scale and offset from the channel registry to convert raw counts
to engineering units.

#callout(kind: "warn")[
  No input protection on the ADC pins. External sensors must be
  voltage-divided to ≤ 3.3 V before reaching the device. Out-of-range
  inputs will damage the SOC.
]

== Wheel speed

#spec-row[Inputs][#m[SPEED_FRONT] · #m[SPEED_REAR]]
#spec-row[Sensor][Hall effect · active-low digital pulse]
#spec-row[Cadence][Interrupt-driven · timestamped per pulse, not polled]
#spec-row[ISR][#m[IRAM_ATTR] · queued via #m[xQueueSendFromISR]]
#spec-row[PPR support][12 (MTB rotor) · ~60 (tone ring) · any user-defined]
#spec-row[Velocity equation][#m[circ_mm / (ppr × Δt_µs) × 3.6 → km/h]]

== Device identification

Each ESP32-C6 has a unique 6-byte MAC accessible via
#m[esp_efuse_mac_get_default()]. The firmware derives two identifiers
visible across the transport surface:

#spec-table(
  columns: (auto, auto, auto, 1fr),
  [*Identifier*],     [*Source*],            [*Format*],                       [*Visible in*],
  m[device_id],       m[All 6 MAC bytes],    m[12-char lowercase hex],         [Binary log header (#s[5.1]), #m[idl0_config.json] (#s[8])],
  [SSID suffix],      m[Last 2 MAC bytes],   m[4-char uppercase hex],          [WiFi AP SSID #m[IDL0-XXXX] (#s[6])],
  [BLE name suffix],  m[Last 2 MAC bytes],   m[4-char uppercase hex],          [BLE advertised name #m[IDL0-XXXX] (#s[7])],
)

== Connector — Deutsch DTM15-12PA

#figure(
  caption: [12-pin Deutsch DTM connector pinout. All sensor harnesses
    fan out from this single connector. Pin 1 is keyed.],
  spec-table(
    columns: (auto, auto, 1fr),
    [*Pin*],   [*Net*],              [*Function*],
    m[1],      m[+3V3],              [Power out],
    m[2],      m[GND],               [Ground],
    m[3],      m[SPI_SCK],           [SPI clock],
    m[4],      m[MOSI],              [SPI data out],
    m[5],      m[MISO],              [SPI data in],
    m[6],      m[IMU_CS_FRONT],      [Chip-select · IMU1],
    m[7],      m[IMU_CS_REAR],       [Chip-select · IMU2],
    m[8],      m[PRESSURE_FRONT],    [Analog 0–3.3 V],
    m[9],      m[PRESSURE_REAR],     [Analog 0–3.3 V],
    m[10],     m[SPEED_FRONT],       [Wheel pulse · active-low],
    m[11],     m[SPEED_REAR],        [Wheel pulse · active-low],
    m[12],     m[BUTTONS],           [User input],
  )
) <fig:dtm-pinout>

== PCB and storage

#spec-row[PCB][4-layer · KiCad 9.0 · Seeed Fusion PCBA]
#spec-row[Storage][MicroSD · FAT32 · 256 GB · SPI3]
#spec-row[Peak write][~56 KB/s at max config — ~155 MB/hr]
#spec-row[Battery][1–3 Ah LiPo · JST-PH 2.0 (J3)]

// -----------------------------------------------------------------------------
#pagebreak(weak: true)
= Firmware <sec:firmware>

== Core constraint

Zero processing. Read sensor registers. Write raw binary to SD.
Nothing else.

== Startup

+ Read #m[idl0_config.json] from SD root.
+ Parse channel mask, sample rates, enabled sensors.
+ Initialize peripherals.
+ Write session file header.
+ Await start trigger.

== Session triggers

#spec-row[Start / stop][Button press OR BLE #m[CMD_START_LOGGING] / #m[CMD_STOP_LOGGING]]
#spec-row[WiFi enable][On-demand · BLE #m[CMD_WIFI_ON] · #m[CMD_WIFI_OFF]]
#spec-row[BLE state][Continuous (control plane)]
#spec-row[WiFi role][Data transfer only — file download, config push, OTA]

== Record loop

The loop polls sensors at their configured rates and writes raw binary
records. GPS records are interspersed as they are received from the UART;
wheel pulses produce one record per ISR-debounced event. No value is
computed; no value is filtered.

== Sensor failure

If an IMU SPI read fails, firmware writes a zero-filled record with the
correct #m[imu_index] and timestamp. The session continues. The app
detects the zero pattern at parse time and surfaces it as a fault region.

== Partition table

Dual-OTA layout on 4 MB flash. The active and pending slots each get
1600 KB. OTA updates stream through #m[esp_ota_ops.h] into the inactive
slot; the bootloader verifies the embedded SHA-256 before the slot swap.

```
nvs,      data, nvs,     0x9000,   24K
phy_init, data, phy,     0xF000,    4K
otadata,  data, ota,     0x10000,   8K
ota_0,    app,  ota_0,   0x20000, 1600K
ota_1,    app,  ota_1,          , 1600K
```

After an OTA-installed image boots, it is in pending-verify state until
the app sends #m[CMD_OTA_CONFIRM] (#s[7.2]). If the device reboots
before that confirmation, the bootloader rolls back to the previous
slot. See also #s[6.1].

// -----------------------------------------------------------------------------
#pagebreak(weak: true)
= Binary Log Format <sec:binary-format>

All multi-byte integers are little-endian (ESP32 native byte order).
Applies to every schema version.

== File header <sec:file-header>

#figure(
  caption: [v3 file header — 128 bytes plus a variable-length channel
    registry. The header carries the session identity, the configuration
    CRC, and the schema needed to decode the body.],
  spec-table(
    columns: (auto, auto, auto, 1fr),
    [*Field*],           [*Type*],     [*Bytes*], [*Notes*],
    [Magic],             m[u8[4]],     m[4],      m[IDL0],
    [Schema version],    m[u8],        m[1],      m[= 3],
    [Session UUID],      m[u8[16]],    m[16],     [→ 32-char lowercase hex],
    [Device ID],         m[u8[6]],     m[6],      [→ 12-char lowercase hex],
    [Session start UTC], m[i64],       m[8],      [ms, GPS-anchored],
    [Config CRC32],      m[u32],       m[4],      [CRC-32/ISO-HDLC],
    [IMU channel mask],  m[u32],       m[4],      [bitfield, see #s[5.4]],
    [IMU count],         m[u8],        m[1],      [],
    [IMU sample rate],   m[u16],       m[2],      m[Hz],
    [GPS sample rate],   m[u8],        m[1],      m[Hz],
    [Registry count],    m[u8],        m[1],      [N entries follow],
    [Channel registry],  m[entry[]],   m[N × 40], [see #s[5.2]],
    [End marker],        m[u8[4]],     m[4],      m[0xDEADBEEF],
  )
) <fig:header>

#callout[
  Per-sample timing is carried inside the records themselves — IMU and
  GPS records each carry their own #m[timestamp_us]. The header's
  #m[Session start UTC] field stays as the wall-clock anchor; the
  device's monotonic clock is bound to UTC on first GPS fix.
]

== Config CRC32 algorithm

#spec-table(
  columns: (auto, 1fr),
  [*Parameter*],      [*Value*],
  [Polynomial],       m[0x04C11DB7 · reflected 0xEDB88320],
  [Initial value],    m[0xFFFFFFFF],
  [Reflect in / out], m[yes],
  [Final XOR],        m[0xFFFFFFFF],
  [ESP-IDF call],     raw("esp_rom_crc32_le(0, buf, len) — <rom/crc.h>"),
  [Dart verifier],    m[package:crclib · Crc32],
)

CRC-32/ISO-HDLC — same family as zlib, PKZIP, and gzip. Computed by the
firmware over the raw on-disk JSON bytes of #m[idl0_config.json] (#s[8]),
exactly as loaded from SD before any whitespace normalisation. This is a
corruption / mismatch check only — not security.

== Channel registry entry <sec:registry>

Every data source — analog channels, wheel-speed counters, and each
individual IMU axis — declares itself in the header. The parser reads
the registry once and handles all channel types from a single code path.

#figure(
  caption: [40-byte channel registry entry. The entry layout never
    changes; new sensors arrive by appending new rows.],
  spec-table(
    columns: (auto, auto, auto, 1fr),
    [*Field*],          [*Type*],    [*Bytes*], [*Notes*],
    m[channel_id],      m[u8],       m[1],      [unique per session],
    m[data_type],       m[u8],       m[1],      m[0=u8 1=u16 2=u32 3=i8 4=i16 5=i32 6=f32 7=f64],
    m[sample_rate_hz],  m[u16],      m[2],      m[0 = event-driven],
    m[scale],           m[f32],      m[4],      m[physical = stored × scale + offset],
    m[offset],          m[f32],      m[4],      [],
    m[name],            m[u8[20]],   m[20],     [null-terminated ASCII],
    m[units],           m[u8[8]],    m[8],      [null-terminated ASCII],
  )
) <fig:registry-entry>

#callout(kind: "rule")[
  *Adding a new sensor:* append a registry entry. No other format
  change. Old app versions see an unknown #m[channel_id], skip those
  records, and parse everything else normally. The header is
  forward-compatible; the records are framed.
]

== IMU channel mask <sec:imu-mask>

The mask is interpreted only by the #m[IMU_SAMPLE] record decoder. It
defines which axes are present in each payload and in what order.
Disabled axes have no slot — payloads are variable-stride.

#spec-table(
  columns: (auto, 1fr),
  [*Bits*],   [*Channels*],
  m[0 – 5],   [IMU0 accel XYZ · gyro XYZ],
  m[6 – 11],  [IMU1 same],
  m[12 – 17], [IMU2 same],
  m[18 – 31], [Reserved],
)

== Record types <sec:record-types>

All records share a common 3-byte framing header:

```
[type:u8][payload_len:u16][payload:N bytes]
```

#m[payload_len] is the byte count of the payload only (it does not
include the 3-byte header). This enables forward-compatible skipping:
on an unknown #m[type], read #m[payload_len] and advance.

#spec-table(
  columns: (auto, auto, 1fr),
  [*Tag*],    [*Name*],          [*Payload*],
  m[0x01],    m[IMU_SAMPLE],     [Raw i16 LSB — variable stride per IMU channel mask],
  m[0x02],    m[GPS_FIX],        [Fixed-width parsed GPS fix · 32 bytes],
  m[0x03],    m[CHANNEL_SAMPLE], [Generic — any channel in the registry],
  m[0xFF],    m[SESSION_END],    [Empty payload · #m[payload_len = 0]],
)

#v(0.4em)

*SESSION_END semantics.* Firmware writes #m[0xFF] and flushes the file
when the app sends #m[CMD_STOP_LOGGING] (#s[7.2]), when the user
presses the stop button, or when battery voltage drops below the
soft-cutoff threshold (#s[10.1]). On hard power loss with no
SESSION_END, the FAT append guarantees all records up to the last
flush survive — the app loads the session normally and surfaces an
*interrupted* warning.

== IMU_SAMPLE record (0x01) <sec:imu-sample>

Variable stride — only enabled axes are written. The parser computes
the payload size from the IMU channel mask once at session load.

#spec-table(
  columns: (auto, auto, auto, 1fr),
  [*Field*],          [*Type*], [*Bytes*], [*Present when*],
  m[imu_index],       m[u8],    m[1],      [always],
  m[timestamp_us],    m[i64],   m[8],      [always],
  m[accel_x],         m[i16],   m[2],      m[mask bit 0/6/12],
  m[accel_y],         m[i16],   m[2],      m[mask bit 1/7/13],
  m[accel_z],         m[i16],   m[2],      m[mask bit 2/8/14],
  m[gyro_x],          m[i16],   m[2],      m[mask bit 3/9/15],
  m[gyro_y],          m[i16],   m[2],      m[mask bit 4/10/16],
  m[gyro_z],          m[i16],   m[2],      m[mask bit 5/11/17],
)

#m[timestamp_us] is #m[esp_timer_get_time()] in microseconds since
device boot. Firmware reads the IMU FIFO in bursts and assigns
per-sample timestamps walking back from the read instant at the
nominal ODR cadence:

#callout[
  For N samples drained at #m[t_read], sample #m[i] (0 = oldest) is
  stamped #m[t_read − (N − 1 − i) × (1_000_000 / ODR)].
]

#spec-row[Min payload][9 bytes (#m[imu_index] + #m[timestamp_us], no axes enabled)]
#spec-row[Max payload][21 bytes (#m[imu_index] + #m[timestamp_us] + 6 axes)]
#spec-row[Drop detection][gap > #m[1 / ODR] between consecutive same-#m[imu_index] timestamps]

== GPS_FIX record (0x02) <sec:gps-fix>

Always 32-byte payload.

#spec-table(
  columns: (auto, auto, auto, 1fr),
  [*Field*],                [*Type*], [*Bytes*], [*Notes*],
  m[gps_epoch_ms],          m[i64],   m[8],      [UTC ms from the GPS receiver],
  m[device_timestamp_us],   m[i64],   m[8],      m[esp_timer_get_time() at fix arrival],
  m[latitude],              m[i32],   m[4],      m[deg × 1e7],
  m[longitude],             m[i32],   m[4],      m[deg × 1e7],
  m[altitude],              m[i16],   m[2],      m[m × 10],
  m[speed],                 m[u16],   m[2],      m[km/h × 100],
  m[heading],               m[u16],   m[2],      m[deg × 100],
  m[fix_quality],           m[u8],    m[1],      m[0 = none · 1 = GPS · 2 = DGPS],
  m[satellites],            m[u8],    m[1],      [count],
)

#m[gps_epoch_ms] and #m[device_timestamp_us] together anchor the
device's monotonic clock to UTC. The file header's #m[Session start UTC]
is set by the firmware on the first valid fix as
#m[gps_epoch_ms − device_timestamp_us / 1000]. Records that precede the
first fix carry #m[gps_epoch_ms = 0]; the app uses the first non-zero
value to back-fill the anchor for the whole session.

== CHANNEL_SAMPLE record (0x03) <sec:channel-sample>

Generic record for all non-IMU, non-GPS channels. Value width is
determined by the #m[data_type] field of the channel's registry entry.

#spec-table(
  columns: (auto, auto, auto, 1fr),
  [*Field*],          [*Type*],  [*Bytes*], [*Notes*],
  m[channel_id],      m[u8],     m[1],      [matches registry entry],
  m[timestamp_us],    m[i64],    m[8],      [µs since boot],
  m[value],           m[N],      m[1 – 8],  [per registry #m[data_type]],
)

// -----------------------------------------------------------------------------
#pagebreak(weak: true)
= WiFi Protocol <sec:wifi>

The ESP32 runs as an AP. The phone connects directly — no router.

#spec-table(
  columns: (auto, 1fr),
  [*Parameter*],   [*Value*],
  [SSID],          m[IDL0-XXXX · XXXX = uppercase hex of MAC bytes 4–5 (see #s[3.6])],
  [Password],      m[Per-device · current placeholder #m[datalogger123]],
  [Device IP],     m[192.168.4.1],
  [Protocol],      m[HTTP/1.1],
  [Coexistence],   m[BLE HRM dropped while WiFi up — see #s[10.4]],
)

== Endpoints

#spec-table(
  columns: (auto, auto, auto, 1fr),
  [*Endpoint*],          [*Method*], [*Response*],        [*Notes*],
  m[/files],             m[GET],     m[JSON array],       m[\[{"name":"…","size":N}\]],
  m[/download?file=N],   m[GET],     m[binary stream],    m[Range header supported],
  m[/delete?file=N],     m[GET],     m[200 / error],      [],
  m[/config],            m[POST],    m[200 / error],      m[Push idl0_config.json],
  m[/ota],               m[POST],    m[200 / error],      m[OTA firmware update],
)

== OTA

The #m[/ota] request body is the raw firmware image with
#m[Content-Type: application/octet-stream]. The device streams the
bytes into the inactive OTA partition, then validates the embedded
SHA-256 via #m[esp_ota_end()].

#spec-table(
  columns: (auto, 1fr),
  [*Result*],                                  [*Meaning*],
  m[200 · "ok\n"],                             [Image valid · device reboots after ~500 ms],
  m[400 · "image validation failed"],          [SHA-256 mismatch · device keeps running previous image],
  m[400 · "short upload"],                     m[Content-Length set but fewer bytes received],
  m[500 · …],                                  [Receive or flash-write failure · device keeps running previous image],
)

The new image boots in pending-verify state. The app commits it with
#m[CMD_OTA_CONFIRM] (#s[7.2]); without that confirmation, the next
reboot rolls back. See also #s[4.6].

// -----------------------------------------------------------------------------
#pagebreak(weak: true)
= BLE Protocol <sec:ble>

#figure(
  caption: [BLE handshake. The phone is central; the device is
    peripheral. Control writes use Write-with-Response — the app waits
    for the GATT ACK before its call returns.],
  ble-handshake,
) <fig:ble-handshake>

== GATT

#spec-table(
  columns: (auto, auto, 1fr),
  [*Characteristic*], [*UUID suffix*],   [*Type*],
  [Service],          m[000000FF-…],     [—],
  [IMU Data],         m[0000FF01-…],     m[Notify (disabled in v2)],
  [GPS Data],         m[0000FF02-…],     m[Notify (disabled in v2)],
  [Control],          m[0000FF03-…],     m[Write with Response],
  [Status],           m[0000FF04-…],     m[Notify],
)

UUIDs use the long form #m[XXXXXXXX-0000-1000-8000-00805F9B34FB].

== Control commands

Single-byte writes to the Control characteristic.

#spec-table(
  columns: (auto, 1fr),
  [*Byte*],    [*Command*],
  m[0x01],     m[CMD_WIFI_ON],
  m[0x02],     m[CMD_WIFI_OFF],
  m[0x03],     m[CMD_START_LOGGING],
  m[0x04],     m[CMD_STOP_LOGGING],
  m[0x05],     m[CMD_CALIBRATE_IMU],
  m[0x06],     m[CMD_OTA_CONFIRM],
)

== Status characteristic

UTF-8, newline-delimited, parsed case-insensitively. Unknown lines are
silently ignored so the schema may grow without breaking older
parsers.

```
WiFi:       ON | OFF
Logging:    RUNNING | STOPPED
Battery:    N%
SD:         OK | FULL | ERROR | ABSENT
GPS:        FIX | NOFIX | ABSENT
IMU:        OK | PARTIAL | ERROR | ABSENT
OTA:        PENDING_VERIFY
HR:         ABSENT | SEARCHING | CONNECTED N | NO_CONTACT N | SUSPENDED
HR_Battery: N%
```

#m[IMU] is an aggregate across enabled IMUs — #m[PARTIAL] means at
least one is responding and at least one is not. #m[OTA] is absent in
the common case; it appears only between an OTA-installed reboot and
#m[CMD_OTA_CONFIRM]. #m[HR_Battery] is absent until the first
successful battery read on connect; thereafter it persists for the
session.

== Central role — Heart Rate Monitor

The firmware runs NimBLE as both *peripheral* (GATT server for the
phone) and *central* (GATT client for an HRM strap) on a single radio.
Requires #m[CONFIG_BT_NIMBLE_ROLE_CENTRAL=y] and
#m[CONFIG_BT_NIMBLE_MAX_CONNECTIONS=2].

The strap exposes the standard Heart Rate Service (#m[0x180D]) with the
Heart Rate Measurement characteristic (#m[0x2A37]) and the Battery
Service (#m[0x180F]) with the Battery Level characteristic
(#m[0x2A19]). The firmware subscribes to #m[0x2A37] and reads
#m[0x2A19] once on connect. Each notification produces one
#m[HeartRate] record and N #m[HR_RR] records, with back-derived
timestamps walking from the notification arrival time.

#callout(kind: "warn")[
  *WiFi coexistence.* The ESP32-C6 RF coexistence matrix marks
  SoftAP + BLE as "C1 — unstable". The firmware drops the HRM
  connection when WiFi turns on and reconnects when WiFi turns off.
  HR data is sacrificed during file transfer; file transfer stability
  is preserved. The phone-facing GATT (peripheral) is unaffected.
]

// -----------------------------------------------------------------------------
#pagebreak(weak: true)
= Configuration Schema <sec:config>

File: #m[idl0_config.json] on the SD card root. Pushed manually after
review — never pushed automatically.

```json
{
  "config_version": 1,
  "device_id": "XXXXXXXXXXXX",
  "bike_profile": { "name": "Trek Session 2024",
                    "default_rider": "Rider Name" },
  "imu": {
    "sample_rate_hz": 833,
    "accel_range_g": 32,
    "gyro_range_dps": 2000,
    "imu0": { "enabled": true,
              "channels": { "accel_x": true, "accel_y": true,
                            "accel_z": true,  "gyro_x":  true,
                            "gyro_y":  true,  "gyro_z":  false } },
    "imu1": { "enabled": true, "accel_range_g": 16, "gyro_range_dps": 500,
              "channels": { ... } },
    "imu2": { "enabled": true, "accel_range_g": 16, "gyro_range_dps": 500,
              "channels": { ... } },
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
  "gps":   { "sample_rate_hz": 5, "dynamic_model": "automotive",
             "nmea_sentences": ["GGA","RMC"], "sbas_enabled": true },
  "analog":{ "sample_rate_hz": 100, "channels": [] },
  "digital":{ "channels": [] },
  "wheel_speed": {
    "front": { "enabled": false, "points_per_revolution": 12,
               "wheel_circumference_mm": 2300 },
    "rear":  { "enabled": false, "points_per_revolution": 12,
               "wheel_circumference_mm": 2300 }
  },
  "heart_rate_monitor": {
    "enabled": true,
    "device_address": "AA:BB:CC:DD:EE:FF",
    "device_name": "Polar H10 12345678"
  }
}
```

== Valid sample-rate values

The app UI must expose these discrete options. Off-list values produce
undefined chip behaviour.

#spec-table(
  columns: (auto, 1fr, auto),
  [*Config path*],            [*Valid values*],                             [*On invalid*],
  m[imu.sample_rate_hz],
    m[High-perf: 12.5 · 26 · 52 · 104 · 208 · 416 · 833 · 1666 Hz \ Low-power: 1.6 · 12.5 · 26 · 52 · 104 · 208 Hz],
    [Undefined],
  m[gps.sample_rate_hz],       m[Integer 1–10 Hz],                          [Clamp or reject],
  m[analog.sample_rate_hz],    m[Not yet defined],                          [—],
)

== Read-only fields

The app preserves these on push — they are never user-edited.

#spec-row[#m[device_id]][12-char lowercase hex of #m[esp_efuse_mac_get_default()] (see #s[3.6])]
#spec-row[#m[config_version]][App-managed · increment only for breaking firmware-compat changes]

#callout(kind: "spec")[
  Firmware ignores unknown JSON fields. The app warns when the device
  firmware is newer than the app. Breaking changes increment
  #m[config_version]. The push transport is WiFi POST #m[/config] —
  not BLE.
]

// -----------------------------------------------------------------------------
#pagebreak(weak: true)
= Coordinate System <sec:coordinate>

#grid(
  columns: (1.4fr, 1fr),
  column-gutter: 24pt,
  [
    *ISO 8855 · right-hand.* The vehicle frame the calibration matrix
    rotates raw sensor vectors into.

    #spec-row[X axis][Forward — direction of travel]
    #spec-row[Y axis][Left lateral]
    #spec-row[Z axis][Up]

    #v(0.5em)

    *Sign conventions · right-hand rule.*

    #spec-row[Roll (about X)][Positive = left side down]
    #spec-row[Pitch (about Y)][Positive = nose up]
    #spec-row[Yaw (about Z)][Positive = turning left]

    #v(0.5em)

    #callout[
      *Suspension note.* Fork compression produces *negative Z* on the
      sprung IMU and *positive Z* on the unsprung IMU. Account for this
      sign asymmetry in travel calculation.
    ]

    #v(0.5em)

    *Sensor sign convention.* The LSM6DSO32 reports specific force
    reaction, not gravitational acceleration. Stationary and upright,
    #m[accel_z ≈ +g]. This is the gravity vector target during
    calibration (#s[20]).
  ],
  [
    #figure(
      caption: [Vehicle frame — ISO 8855, right-hand, bike-mounted.],
      coordinate-frame,
    ) <fig:coord-frame>
  ],
)

// -----------------------------------------------------------------------------
#pagebreak(weak: true)
= Device Behavior <sec:behavior>

== Power

#spec-row[Soft cutoff][~3.3 V/cell · write SESSION_END · flush SD · BLE notify · power off]
#spec-row[Hard cutoff][Hardware undervoltage lockout · FAT32 survives ungraceful loss]
#spec-row[App display][Battery level shown · warning below 20 %]

== SD card

#spec-row[Layout][All session files under #m[/sessions/] at FAT32 root]
#spec-row[Temp file][#raw("/sessions/tmp_<boot_ms>.idl0") until first valid GPS fix]
#spec-row[Final name][#m[/sessions/YYYY-MM-DD_HH-MM-SS.idl0] · UTC from #m[gps_epoch_ms]]
#spec-row[Min free space][200 MB · ~1.3 hr at peak load]
#spec-row[At threshold][Stop logging · BLE notify · do not crash]

== Version compatibility

#spec-table(
  columns: (auto, 1fr),
  [*Surface*],         [*Rule*],
  [Config JSON],       [Firmware ignores unknown fields · app warns if firmware newer than app],
  [Binary format],     [Current schema + immediately prior schema, for ~2 weeks after a bump],
  [Binary records],    [New types skipped by old parsers · never modify existing record layouts],
)

#part-divider("3", [App])

// -----------------------------------------------------------------------------
#pagebreak(weak: true)
= App Architecture <sec:architecture>

#figure(
  caption: [IDL0 app architecture. Four Dart layers above one Rust
    processing crate. The Dart–Rust boundary is the
    #m[flutter_rust_bridge] auto-generated bindings.],
  architecture-stack,
) <fig:architecture>

== Decision rule

Physics of the bike → Rust. App data structures, files, UI → Dart.

== Platform targets

#spec-table(
  columns: (auto, 1fr),
  [*Platform*],          [*Capability*],
  [Android],             [Primary — BLE + WiFi + analysis],
  [Desktop (Win / mac)], [Analysis · BLE optional],
  [iOS / web],           [PWA via Flutter web · analysis only · no BLE],
  [Breakpoint],          raw("< 600 px = bottom nav · ≥ 600 px = side rail"),
)

== State management

Riverpod only. No Provider, no Bloc, no #m[setState] except local
widget state. Math channel providers use
#m[FutureProvider.family] — evaluated lazily on demand, never
pre-computed.

== File model

#spec-table(
  columns: (auto, auto, 1fr),
  [*File*],     [*Ext*],     [*Mutable*],
  [Raw log],    m[.idl0],    [Never — immutable after download],
  [Workspace],  m[.idl0w],   [Yes — all derived work],
)

#m[.idl0w] is versioned JSON. It contains lap and sector gates,
annotations, math channels, the workbook layout, and channel colours.

== Selection model — XOR

The user is either selecting whole sessions OR individual laps, never
mixed. This eliminates the cognitive complexity of comparing "session
A as a whole" vs "lap 3 of session B" — typical comparisons are
session-vs-session or lap-vs-lap.

Toggling an entry of the inactive kind flips the global mode and
clears the inactive set. The Data tab and the Analyze tab's Session
Sheet read and write the same provider.

// -----------------------------------------------------------------------------
#pagebreak(weak: true)
= Error Handling <sec:errors>

== Exception hierarchy

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
    ├── DeviceNotFoundException
    ├── DeviceUnreachableException
    ├── FileListParseException
    ├── TransferTimeoutException
    └── TransferChecksumException
```

== Behaviour

#spec-table(
  columns: (auto, auto, 1fr),
  [*Exception*],                       [*Behaviour*],          [*User message*],
  m[InvalidMagicBytes],                [Reject file],          ["Not a valid IDL0 log"],
  m[UnsupportedSchemaVersion],         [Reject file],          ["Update the app to open this file"],
  m[TruncatedRecord],                  [Return partial session], ["Log incomplete — showing data to \[t\]"],
  m[UnknownRecordType],                [Skip · continue],      [Silent · debug log],
  m[UnknownChannel],                   [Inline editor error],  ["Channel '\[name\]' not in this session"],
  m[ExpressionSyntax],                 [Inline editor error],  ["Syntax error at position N"],
  m[TransferTimeout],                  [Retry 3× · backoff],   ["Transfer timed out. Check WiFi."],
  m[TransferChecksum],                 [Discard · offer retry], ["Transfer error. Retry?"],
  m[CalibrationException],             [Abort · keep previous], ["Calibration failed — was bike stationary?"],
)

#callout(kind: "rule")[
  Hard crashes in response to bad data are *never* acceptable. The
  debug log ring buffer (last 500 entries) is accessible via
  Settings → tap version 5×.
]

#part-divider("4", [Processing])

// -----------------------------------------------------------------------------
#pagebreak(weak: true)
= Signal Processing Pipeline <sec:signal-pipeline>

All steps in Rust (#m[app/rust/] crate), called via
#m[flutter_rust_bridge].

#figure(
  caption: [Default per-IMU-channel pipeline. Steps run in order. Each
    arrow is one buffer hop. Highpass and integration use sci-rs;
    rotation uses nalgebra.],
  signal-pipeline,
) <fig:pipeline>

== Dependencies

```toml
sci-rs               = "0.4"   # scipy.signal equivalent
nalgebra             = "0.33"  # linear algebra
rustfft              = "6.2"   # FFT
flutter_rust_bridge  = "2"
```

== Default pipeline per IMU channel

+ *Bias subtraction.* #m[nalgebra] vector subtract using #m[imu.bias]
  from config.
+ *Rotation.* #m[nalgebra] 3×3 matrix multiply → vehicle frame
  (ISO 8855, see #s[9]).
+ *Input.* IMU samples arrive as physical values (g and dps); the
  parser applied scale and offset from the channel registry
  (#s[5.2]) before handoff.
+ *Highpass filter.* sci-rs #m[butter] order 2, cutoff 0.15–0.3 Hz,
  applied via #m[sosfiltfilt]. Rust API:
  #m[highpass(data, order, cutoff_hz, sample_rate_hz)].
+ *Integration · where needed.* Trapezoidal rule. #m[output[0] = 0.0],
  output length = input length. Rust: #m[integrate(data, sample_rate_hz)].
+ *Highpass — post-integration.* Second #m[sosfiltfilt] pass.

All steps user-overridable via math-channel expressions.

== Rust API notes

#spec-row[Filters][#m[highpass(data, order, cutoff_hz, sample_rate_hz)] / #m[lowpass(...)]]
#spec-row[FFT][#m[fft(data, window)] → one-sided linear magnitude · #m[n/2 + 1] bins]
#spec-row[Rotation matrix][Flat 9-element row-major #raw("Vec<f64>") · FRB cannot serialise #raw("[[f64;3];3]")]

== Math channel function catalogue

#spec-table(
  columns: (auto, 1fr),
  [*Category*],     [*Functions*],
  [Filters],        m[butter(order, cutoff, type, ch) · sosfilt(sos, ch)],
  [Time-domain],    m[integrate · differentiate · rms · mean · std · median],
  [Frequency],      m[fft(ch, window) · spectrogram(ch) · hilbert(ch)],
  [Correlation],    m[correlate(a, b) · convolve(ch, kernel)],
  [Resampling],     m[resample(ch, hz)],
  [Math],           m[abs · sqrt · pow · sign · min · max · clamp · floor · ceil · round],
  [Trig],           m[sin · cos · tan · asin · acos · atan · atan2 · sinh · cosh · tanh · deg2rad · rad2deg],
  [Logic],          m[if(cond, t, f) · and · or · not],
  [Range],          m[ch\[t_start:t_end\] · ch\[lap_n\]],
  [Lap],            m[current_lap() · lap_start_time(n) · sector_number()],
  [Variance],       m[variance_time(ch) · variance_dist(ch)],
)

#callout(kind: "warn")[
  *Logic keyword syntax.* #m[and], #m[or], #m[not] are infix / prefix
  keywords, not call-style functions. Valid: #raw("x > 0 and y < 10").
  Invalid: #raw("and(x, y)"). #m[if] is the only Logic entry that uses
  call syntax.
]

== Time as a base channel

#m[Time] is a synthesised built-in channel with
#m[samples[i] = i / sampleRateHz], where #m[sampleRateHz] is the
highest non-event-driven channel rate in the session. Not stored on
disk — re-synthesised on each session load. Appears in the channel
picker alongside #m[GPS_SpeedKmh] et al., and lets math expressions
reference session-relative time directly (the tutorial #m[LapTime]
channel is #m[Time - lap_start_time(current_lap())]).

// -----------------------------------------------------------------------------
#pagebreak(weak: true)
= Calibration <sec:calibration>

#figure(
  caption: [Calibration state machine. Trigger comes in over BLE as
    #m[CMD_CALIBRATE_IMU]; the device samples a static-hold window,
    computes per-IMU bias and rotation, and ships the result back to
    the app for persistence in #m[idl0_config.json].],
  calibration-flow,
) <fig:calibration>

== Trigger and preconditions

#spec-row[Trigger][BLE #m[CMD_CALIBRATE_IMU] (0x05) · "Calibrate IMUs" button in Device tab]
#spec-row[Precondition][Bike stationary · upright · rider off]
#spec-row[Mode][Non-logging · self-contained on-device routine]

The device captures a static-hold sample window, then computes the
per-IMU bias offsets and the 3×3 orientation matrix *on-device*. Computation
outside the logging path is permitted (see #s[1]). The device does
*not* stream raw IMU data over BLE during calibration.

== Result delivery

The result — per-IMU bias #m[[ax, ay, az, gx, gy, gz]] and the
orientation matrix — is delivered to the app over BLE as a compact,
fixed-size payload. The app writes the values into the bike's
#m[idl0_config.json] (#s[8] — #m[bias] / #m[orientation] fields), so
calibration is stored per bike profile and travels with that bike's
config.

#callout(kind: "spec")[
  The firmware never *applies* calibration. It writes raw #m[i16] LSB
  values into the log (#s[5.5]). The parser converts raw values to
  physical units using the per-channel scale and offset from the
  registry (#s[5.2]). The app then applies bias correction and
  orientation rotation in the Rust processing layer, matching log to
  config via the header #m[config_crc32] (#s[5.1]).
]

#part-divider("A", [Appendix])

// -----------------------------------------------------------------------------
#pagebreak(weak: true)
= Channel Reference <sec:channel-reference>

Consolidated reference for every channel ID in the registry at v3
launch. Adding a sensor appends new rows; existing rows never change.
The parser applies #m[physical = stored × scale + offset] using the
values stored in the per-session header (#s[5.2]).

#figure(
  caption: [Channel registry — v3 launch.],
  spec-table(
    columns: (auto, auto, auto, auto, auto, 1fr),
    [*ID*], [*Name*],          [*Type*], [*Rate (Hz)*],   [*Units*], [*Scale*],
    m[0],   m[IMU0_AccelX],    m[i16],   m[(IMU rate)],  m[g],     m[accel_range_g / 32768],
    m[1],   m[IMU0_AccelY],    m[i16],   m[(IMU rate)],  m[g],     m[accel_range_g / 32768],
    m[2],   m[IMU0_AccelZ],    m[i16],   m[(IMU rate)],  m[g],     m[accel_range_g / 32768],
    m[3],   m[IMU0_GyroX],     m[i16],   m[(IMU rate)],  m[dps],   m[gyro_range_dps / 32768],
    m[4],   m[IMU0_GyroY],     m[i16],   m[(IMU rate)],  m[dps],   m[gyro_range_dps / 32768],
    m[5],   m[IMU0_GyroZ],     m[i16],   m[(IMU rate)],  m[dps],   m[gyro_range_dps / 32768],
    m[6],   m[IMU1_AccelX],    m[i16],   m[(IMU rate)],  m[g],     m[accel_range_g / 32768],
    m[…],   m[IMU1 axes],      m[i16],   m[(IMU rate)],  [],       [as IMU0],
    m[11],  m[IMU1_GyroZ],     m[i16],   m[(IMU rate)],  m[dps],   [as IMU0],
    m[12],  m[IMU2_AccelX],    m[i16],   m[(IMU rate)],  m[g],     [as IMU0],
    m[…],   m[IMU2 axes],      m[i16],   m[(IMU rate)],  [],       [as IMU0],
    m[17],  m[IMU2_GyroZ],     m[i16],   m[(IMU rate)],  m[dps],   [as IMU0],
    m[18],  m[WheelFront],     m[u32],   m[0 (event)],   m[pulse], m[1.0],
    m[19],  m[WheelRear],      m[u32],   m[0 (event)],   m[pulse], m[1.0],
    m[20],  m[PressureFront],  m[u16],   m[100],         m[bar],   [from config],
    m[21],  m[PressureRear],   m[u16],   m[100],         m[bar],   [from config],
    m[22],  m[HeartRate],      m[u8],    m[1],           m[bpm],   m[1.0],
    m[23],  m[HR_RR],          m[u16],   m[0 (event)],   m[ms],    m[1000/1024],
  )
) <fig:channel-registry>

#v(0.8em)

The IMU rate column carries "(IMU rate)" because the actual Hz is
chosen at session start from #m[imu.sample_rate_hz] (#s[8]). The
registry's #m[sample_rate_hz] field carries the resolved value
verbatim; the parser does not consult the config.

#v(2em)
#line(length: 100%, stroke: 0.4pt + palette.rule)
#v(0.4em)

#text(font: mono-font, size: 7.5pt, tracking: 1.4pt, fill: palette.muted)[
  END OF DOCUMENT · IDL0 DATASHEET v1.0 · 2026-05-04 · idl0.io
]
