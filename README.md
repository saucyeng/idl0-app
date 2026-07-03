# IDL0

Open source mountain bike data acquisition system. High-frequency suspension and brake dynamics logging with companion analysis software.

## What it is

IDL0 is a custom data logger designed for mountain bike performance analysis and suspension tuning. It captures IMU data at 800 Hz from sprung and unsprung masses, GPS position, analog pressure inputs, and wheel speed — all logged to onboard MicroSD via an automotive-grade connector harness.

The companion app handles all signal processing, filtering, FFT, calibration, and visualization. The firmware does one thing: write raw sensor data to SD card as fast as possible.

## Hardware

- **MCU:** Seeed Studio XIAO ESP32-C6
- **IMUs:** 3× STMicroelectronics LSM6DSO32TR (±32g, 800 Hz)
- **GPS:** u-blox MAX-M10S with integrated ceramic patch antenna
- **Connector:** Deutsch DTM15-12PA (automotive-grade, 12-pin)
- **PCB:** 4-layer, designed in KiCad 9.0

## Repository layout

IDL0 spans three repos under [saucyeng](https://github.com/saucyeng):

| Repo | What |
|------|------|
| [idl0-firmware](https://github.com/saucyeng/idl0-firmware) | ESP32-C6 firmware (GPL-3.0) |
| [idl-rs](https://github.com/saucyeng/idl-rs) | Rust processing engine — DSP, parsing, math, estimator (AGPL-3.0). Included **here** as a submodule at `rust/`. |
| **idl0-app** (this repo) | Flutter companion app (AGPL-3.0) + the master spec |

This repo:

```
idl0-app/
├── docs/IDL0_SPEC.md   # Master system specification — source of truth
├── app/                # Flutter app
│   └── lib/{data,transport,ui}/
├── rust/               # → git submodule: saucyeng/idl-rs (the engine)
├── tools/              # Log inspector, CSV/FIT converters
└── CLAUDE.md  CONTRIBUTING.md  CLA.md
```

## App

Cross-platform Flutter app — Android, iOS (future), Windows, macOS.

- **Device tab:** Connect via BLE, configure sensors, calibrate IMUs, start/stop recording
- **Runs tab:** Download sessions over WiFi, manage metadata, select for analysis
- **Maths tab:** Define derived channels via expression editor
- **Analyze tab:** Time-domain traces, FFT, histograms, GPS map, lap timing, cross-rider comparison

## File Formats

- `.idl0` — Raw binary log file. Never modified after download.
- `.idl0w` — Workspace file (JSON). Lap gates, annotations, math channels, layout. Travels with the log file.

## Building

Clone with the `idl-rs` submodule (the app compiles the engine via cargokit):

```bash
git clone --recursive https://github.com/saucyeng/idl0-app
cd idl0-app/app
flutter pub get
flutter run
```

Already cloned without `--recursive`? Run `git submodule update --init`.

Firmware lives in [saucyeng/idl0-firmware](https://github.com/saucyeng/idl0-firmware); the
headless `idl-rs` CLI (read/export `.idl0` logs without Flutter) lives in
[saucyeng/idl-rs](https://github.com/saucyeng/idl-rs).

## Contributing

Read `CONTRIBUTING.md` before submitting a PR. All processing layer functions require tests. See `CLAUDE.md` for code standards.

## License

AGPL-3.0-or-later — see [LICENSE](LICENSE). The [firmware](https://github.com/saucyeng/idl0-firmware)
is GPL-3.0-or-later. Contributions require the [CLA](CLA.md) (recorded by a bot on
your first PR), which keeps commercial dual-licensing available. Vendored
third-party code keeps its own license.

## Status

Hardware design complete. App in active development. Not yet production ready.
