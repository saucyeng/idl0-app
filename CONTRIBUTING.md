# Contributing to IDL0

## Licensing of contributions

Contributions are accepted under the repository's license (AGPL-3.0-or-later
here and for `idl-rs`; GPL-3.0-or-later for firmware) **and** the [CLA](CLA.md),
which lets the project offer commercial/dual licenses. A bot (CLA Assistant)
records your agreement on your first pull request.

## Before You Start

Read `docs/IDL0_SPEC.md`. It is the source of truth for all architecture decisions. If your contribution conflicts with the spec, open an issue to discuss the spec change first — don't silently deviate in code.

## Code Standards

### Test-Driven Development
Write the test file before the implementation. Tests must pass before a PR is mergeable. Coverage targets:
- `lib/processing/`: > 90% line coverage
- `lib/data/`: > 80% line coverage

### Documentation
Every public class, method, and field requires a `///` doc comment. Comments must state units explicitly — never leave a numeric value's units ambiguous between raw LSB, g, m/s², etc.

### Layer Separation
```
lib/processing/   Pure Dart. Zero Flutter imports. No I/O.
lib/data/         Parsing, models, SQLite. No DSP.
lib/transport/    BLE, WiFi. No processing.
lib/ui/           Widgets, Riverpod providers. No direct math.
```

Processing layer functions must be importable as plain Dart and testable without a device or emulator.

### State Management
Riverpod only. No Provider, no Bloc, no raw setState except for local widget state.

### Naming
```
snake_case        files
PascalCase        classes
camelCase         functions and variables
SCREAMING_SNAKE   constants
```

### TODOs
```dart
// TODO(idl0): description
```
Never use bare `// TODO`.

## Pull Request Checklist

- [ ] `flutter test` passes with zero failures
- [ ] Coverage targets met for affected layers
- [ ] All public symbols have `///` doc comments with units
- [ ] Complex algorithms have mathematical basis comments
- [ ] No bare TODOs
- [ ] Implementation matches spec — no silent deviations
- [ ] `CHANGELOG.md` updated if meaningful change

## Firmware Contributions

- Zero processing in firmware — the firmware reads raw binary from sensors and writes to SD card. No filtering, integration, or signal conditioning belongs in firmware.
- All structs use `__attribute__((packed))`
- ISR handlers marked `IRAM_ATTR`
- Document every register read sequence with datasheet section reference

## Questions

Open an issue. Don't guess at architectural decisions — if something isn't covered by the spec, ask.
