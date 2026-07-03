# IDL0 Datasheet (Typst)

Renders the IDL0 specification as a polished PDF datasheet with a cover page,
linked TOC, cross-references, and Fletcher-drawn diagrams.

## Status

**Spike.** Four sections (§1 Philosophy, §5 Binary Log Format, §11
App Architecture, §19 Signal Processing Pipeline) are reproduced here verbatim
from `docs/IDL0_SPEC.md` so you can judge layout on real content. The other
28 sections still need to be ported.

## Install Typst

One-time, ~25 MB single binary, no LaTeX install required.

```powershell
winget install Typst.Typst
# or download: https://github.com/typst/typst/releases
```

Verify:

```powershell
typst --version
```

## Build

```powershell
.\build.ps1                 # one-shot → idl0-datasheet.pdf
.\build.ps1 --watch         # live rebuild on save (recommended while editing)
```

First build takes a few extra seconds — Typst downloads the pinned Fletcher
package from `@preview` and caches it.

## Files

| File           | Purpose                                                        |
|----------------|----------------------------------------------------------------|
| `main.typ`     | Document entry — cover, TOC, sections.                         |
| `theme.typ`    | Palette, fonts, page setup, `spec-table` / `callout` helpers.  |
| `diagrams.typ` | Fletcher diagrams: architecture stack + signal pipeline.       |
| `build.ps1`    | One-line build wrapper.                                        |

## What the spike demonstrates

- **Cover page** with accent stripe, abstract block, and metadata table.
- **Linked TOC** — `#outline()` produces clickable entries and PDF bookmarks
  automatically.
- **Cross-references** — every `<sec:foo>` label resolves to a clickable link
  in the PDF; example uses include "see @fig:pipeline" and "defined in
  @sec:binary-format".
- **Figure list** — separate `#outline(target: figure)` for diagrams + tables.
- **Front matter pagination** — roman numerals for TOC, arabic for body.
- **Running header + footer** — section context, page number, doc identity.
- **Callouts** — note / warn / rule variants with coloured left rule.
- **Tables** — striped rows, bordered, with units called out where applicable.
- **Code blocks** — monospaced with accent left rule.
- **Two Fletcher diagrams** — vertical layered architecture, and horizontal
  pipeline with buffer hops.

## Next steps (not in this spike)

1. Port the remaining 28 sections from `IDL0_SPEC.md`. Likely path: a small
   markdown→Typst transform script, since the spec is structured (heading
   levels, tables, code fences are all predictable).
2. Decide on diagrams for the remaining sections — at minimum the BLE/WiFi
   transport handshake, the calibration routine flow, and a frame-of-reference
   diagram for §9 (ISO 8855 axes).
3. Wire into CI so `idl0-datasheet.pdf` is published as a release artifact.
