// IDL0 datasheet — diagrams.
//
// All diagrams styled to match theme.typ. Mono labels, hairline rules,
// accent-red for the things that matter most.

#import "@preview/fletcher:0.5.8" as fletcher: diagram, node, edge
#import "@preview/cetz:0.3.4"
#import "theme.typ": palette, body-font, mono-font

#let _label-text(body, size: 8.5pt, weight: 400, color: none, tracking: 0pt) = text(
  font: mono-font,
  size: size,
  weight: weight,
  fill: if color == none { palette.ink } else { color },
  tracking: tracking,
)[#body]

// =============================================================================
// 1. Architecture stack — Dart / Rust layers
// =============================================================================

#let architecture-stack = {
  set text(font: mono-font, size: 9pt)
  let layer(pos, title, sub, color) = node(
    pos,
    align(left)[
      #_label-text(weight: 700, color: white, size: 10pt, upper(title))
      \
      #_label-text(size: 7.5pt, color: white.transparentize(20%), tracking: 1.2pt, upper(sub))
    ],
    width: 9cm,
    height: 1.5cm,
    fill: color,
    stroke: none,
    corner-radius: 1pt,
  )

  diagram(
    spacing: (0pt, 3mm),
    node-stroke: none,
    layer((0, 0), [UI — Dart / Flutter], [adaptive_scaffold · Riverpod · charts], palette.ink),
    layer((0, 1), [Data — Dart], [parser · session model · workspace · SQLite], palette.ink.lighten(20%)),
    layer((0, 2), [Transport — Dart], [BLE · WiFi HTTP · Drive · config push], palette.ink.lighten(35%)),
    layer((0, 3), [Processing — Rust], [sci-rs · nalgebra · rustfft], palette.accent),
    node((0, 4), align(center)[
      #_label-text(size: 7.5pt, color: palette.muted, tracking: 1.4pt, upper[Boundary — flutter_rust_bridge])
    ], stroke: none, width: 9cm),
  )
}

// =============================================================================
// 2. Signal pipeline — left-to-right per-IMU DSP flow
// =============================================================================

#let signal-pipeline = {
  set text(font: mono-font, size: 8pt)

  let stage(pos, label, sub: none, accent: false) = node(
    pos,
    align(center)[
      #_label-text(weight: 600, size: 8.5pt, upper(label))
      #if sub != none [
        \ #_label-text(size: 7pt, color: palette.muted, sub)
      ]
    ],
    width: 2.8cm,
    height: 1.5cm,
    fill: if accent { palette.accent.lighten(85%) } else { palette.panel },
    stroke: 0.6pt + (if accent { palette.accent } else { palette.rule }),
    corner-radius: 1pt,
  )

  let buffer(pos, label) = node(
    pos,
    align(center)[
      #_label-text(weight: 600, color: white, size: 7.5pt, tracking: 1.2pt, upper(label))
    ],
    width: 1.7cm,
    height: 0.75cm,
    fill: palette.ink,
    stroke: none,
    corner-radius: 1pt,
  )

  diagram(
    spacing: (5mm, 8mm),
    node-stroke: 0.6pt + palette.rule,
    edge-stroke: 0.7pt + palette.ink,
    mark-scale: 70%,

    stage((0, 0), [Raw i16], sub: [from registry]),
    edge("-|>"),
    buffer((1, 0), [parser]),
    edge("-|>"),
    stage((2, 0), [Bias sub.], sub: [nalgebra]),
    edge("-|>"),
    stage((3, 0), [Rotation], sub: [3×3 · ISO 8855]),

    edge((3, 0), (0, 1), "-|>", corner: right, stroke: 0.7pt + palette.ink),

    stage((0, 1), [Highpass], sub: [butter · sosfilt], accent: true),
    edge("-|>"),
    stage((1, 1), [Integrate], sub: [trapezoidal], accent: true),
    edge("-|>"),
    stage((2, 1), [Highpass], sub: [post-integ.], accent: true),
    edge("-|>"),
    buffer((3, 1), [channel]),
  )
}

// =============================================================================
// 3. Hardware block — peripherals around the ESP32-C6
// =============================================================================

#let hardware-block = {
  set text(font: mono-font, size: 8pt)

  let device(pos, body, w: 2.5cm, h: 1.2cm, fill: palette.panel, stroke-color: palette.rule) = node(
    pos,
    align(center)[#_label-text(weight: 600, size: 8pt, body)],
    width: w,
    height: h,
    fill: fill,
    stroke: 0.6pt + stroke-color,
    corner-radius: 1pt,
  )

  let bus(label, color: palette.muted) = _label-text(size: 6.5pt, color: color, tracking: 1pt, upper(label))

  diagram(
    spacing: (10mm, 8mm),
    node-stroke: 0.6pt + palette.rule,
    edge-stroke: 0.6pt + palette.muted,
    mark-scale: 60%,

    // Center — MCU
    device((1, 1), [ESP32-C6\ #_label-text(size: 7pt, color: palette.muted, [XIAO module])],
      w: 3cm, h: 1.6cm, fill: palette.ink, stroke-color: palette.ink),

    // North — Storage
    device((1, 0), [MicroSD\ #_label-text(size: 7pt, color: palette.muted, [FAT32 · 256 GB])]),
    edge((1, 0), (1, 1), bus[SPI3], "-"),

    // West — IMUs
    device((0, 0), [IMU0\ #_label-text(size: 7pt, color: palette.muted, [LSM6DSO32 · sprung])]),
    device((0, 1), [IMU1\ #_label-text(size: 7pt, color: palette.muted, [LSM6DSO32 · fork])]),
    device((0, 2), [IMU2\ #_label-text(size: 7pt, color: palette.muted, [LSM6DSO32 · swingarm])]),
    edge((0, 0), (1, 1), bus[SPI2], "-"),
    edge((0, 1), (1, 1), "-"),
    edge((0, 2), (1, 1), "-"),

    // East — GPS, Pressure, Speed
    device((2, 0), [GPS\ #_label-text(size: 7pt, color: palette.muted, [MAX-M10S · UART])]),
    edge((2, 0), (1, 1), bus[UART1], "-"),

    device((2, 1), [Pressure\ #_label-text(size: 7pt, color: palette.muted, [×2 · ADC 12-bit])]),
    edge((2, 1), (1, 1), bus[GPIO], "-"),

    device((2, 2), [Wheel speed\ #_label-text(size: 7pt, color: palette.muted, [×2 · ISR])]),
    edge((2, 2), (1, 1), bus[INT], "-"),

    // South — Radios
    device((1, 2), [BLE + WiFi\ #_label-text(size: 7pt, color: palette.accent, [shared radio · coex])],
      fill: palette.accent.lighten(85%), stroke-color: palette.accent),
    edge((1, 2), (1, 1), "-"),
  )
}

// =============================================================================
// 4. Coordinate frame — ISO 8855 axes (CeTZ-drawn)
// =============================================================================

#let coordinate-frame = cetz.canvas(length: 1cm, {
  import cetz.draw: *
  set-style(
    stroke: (paint: palette.ink, thickness: 0.7pt),
    mark: (fill: palette.ink),
  )

  // Axes — X forward, Y left, Z up
  line((0, 0), (3.2, 0), mark: (end: ">"), stroke: 1pt + palette.accent)
  content((3.5, 0), anchor: "west", text(
    font: mono-font, size: 9pt, weight: 600, fill: palette.accent,
  )[X · forward])

  line((0, 0), (0, 2.6), mark: (end: ">"), stroke: 1pt + palette.ink)
  content((0, 2.85), anchor: "south", text(
    font: mono-font, size: 9pt, weight: 600,
  )[Z · up])

  line((0, 0), (-1.6, -1.0), mark: (end: ">"), stroke: 1pt + palette.ink)
  content((-1.8, -1.15), anchor: "north-east", text(
    font: mono-font, size: 9pt, weight: 600,
  )[Y · left])

  // Origin marker
  circle((0, 0), radius: 0.06, fill: palette.ink)

  // Rotation arcs
  arc((0.6, 0), start: 0deg, stop: 130deg, radius: 0.6,
    mark: (end: ">"), stroke: 0.5pt + palette.muted)
  content((0.7, 0.85), anchor: "west", text(
    font: mono-font, size: 7.5pt, fill: palette.muted,
  )[+ pitch])

  arc((-0.7, -0.45), start: 230deg, stop: 360deg, radius: 0.5,
    mark: (end: ">"), stroke: 0.5pt + palette.muted)
  content((-0.5, -1.0), anchor: "west", text(
    font: mono-font, size: 7.5pt, fill: palette.muted,
  )[+ roll])

  // Footnote
  content((0.5, -2.3), anchor: "west", text(
    font: mono-font, size: 7.5pt, tracking: 1pt, fill: palette.muted,
  )[ISO 8855 · RIGHT-HAND · BIKE-MOUNTED FRAME])
})

// =============================================================================
// 5. BLE handshake — sequence of phone ↔ device
// =============================================================================

#let ble-handshake = {
  set text(font: mono-font, size: 8pt)

  let lane(x, label) = {
    node((x, 0), align(center)[#_label-text(weight: 600, size: 8.5pt, label)],
      width: 3.2cm, height: 0.8cm,
      fill: palette.ink, stroke: none, corner-radius: 1pt)
  }

  let step(y, from-x, to-x, label, accent: false) = {
    let lbl = _label-text(
      size: 7.5pt,
      color: if accent { palette.accent } else { palette.ink },
      label,
    )
    edge((from-x, y), (to-x, y), "-|>", label: lbl, label-side: center,
      stroke: 0.6pt + (if accent { palette.accent } else { palette.ink }))
  }

  diagram(
    spacing: (0pt, 6mm),
    mark-scale: 60%,

    lane(0, [Phone (central)]),
    lane(1, [IDL0 (peripheral)]),

    step(1, 0, 1, [SCAN — service UUID 000000FF…], accent: true),
    step(2, 1, 0, [ADV — name IDL0-XXXX]),
    step(3, 0, 1, [CONNECT + MTU exchange]),
    step(4, 0, 1, [CCCD write — enable Status notify]),
    step(5, 1, 0, [Notify: WiFi/Logging/Battery/SD/GPS/IMU]),
    step(6, 0, 1, [Write 0x01 — CMD_WIFI_ON], accent: true),
    step(7, 1, 0, [Notify: WiFi: ON]),
    step(8, 0, 1, [HTTP over WiFi (file transfer)], accent: true),
    step(9, 0, 1, [Write 0x02 — CMD_WIFI_OFF]),
    step(10, 1, 0, [Notify: WiFi: OFF]),
  )
}

// =============================================================================
// 6. Calibration flow — state-machine view
// =============================================================================

#let calibration-flow = {
  set text(font: mono-font, size: 8pt)

  let state(pos, label, sub: none, accent: false) = node(
    pos,
    align(center)[
      #_label-text(weight: 600, size: 8pt, upper(label))
      #if sub != none [
        \ #_label-text(size: 7pt, color: palette.muted, sub)
      ]
    ],
    width: 3cm,
    height: 1.4cm,
    fill: if accent { palette.accent.lighten(85%) } else { palette.panel },
    stroke: 0.6pt + (if accent { palette.accent } else { palette.rule }),
    corner-radius: 1pt,
  )

  diagram(
    spacing: (6mm, 7mm),
    mark-scale: 70%,
    edge-stroke: 0.7pt + palette.ink,
    node-stroke: 0.6pt + palette.rule,

    state((0, 0), [Idle], sub: [logging armed]),
    edge("-|>", _label-text(size: 7pt, color: palette.accent, [BLE 0x05])),
    state((1, 0), [Sampling], sub: [static-hold window]),
    edge("-|>", _label-text(size: 7pt, [Σ samples])),
    state((2, 0), [Compute], sub: [bias + 3×3 R]),
    edge("-|>", _label-text(size: 7pt, [BLE payload])),
    state((3, 0), [Push to app], sub: [→ idl0_config.json], accent: true),

    edge((1, 0), (0, 1), "-|>",
      _label-text(size: 7pt, color: palette.accent, [InsufficientMotion])),
    state((0, 1), [Abort], sub: [keep previous bias], accent: true),
  )
}
