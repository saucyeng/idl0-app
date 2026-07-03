// IDL0 datasheet — visual theme.
//
// "Quiet field manual" aesthetic, ported to print. The app uses IBM Plex Mono
// everywhere on a warm-near-black background; the datasheet inverts that for
// paper — IBM Plex Mono dominant on a warm-cream page, with the brand
// accent red kept verbatim. Tabular numerals on by default.

// -----------------------------------------------------------------------------
// Palette — print-friendly inversion of `app/lib/ui/brand/brand_tokens.dart`.
// -----------------------------------------------------------------------------

#let palette = (
  paper:   rgb("#F5F2E8"),  // warm cream — page background
  panel:   rgb("#EDE9DD"),  // slightly darker — striped rows, code blocks
  ink:     rgb("#1A1E18"),  // ≈ brandSurface inverted for ink
  muted:   rgb("#6B6B68"),  // captions, leader dots, kicker labels
  rule:    rgb("#C8C2B5"),  // hairlines — borders, dividers
  accent:  rgb("#E63946"),  // brand accent — exact match
  good:    rgb("#5A8A60"),  // print-darkened brandGood
  hivis:   rgb("#B89A1F"),  // print-darkened brandHivis
)

// -----------------------------------------------------------------------------
// Fonts — IBM Plex everywhere, with tabular numerals enabled globally.
// -----------------------------------------------------------------------------

#let body-font   = ("IBM Plex Sans", "Arial")
#let mono-font   = ("IBM Plex Mono", "Consolas")
#let serif-font  = ("IBM Plex Serif", "Georgia")

// -----------------------------------------------------------------------------
// Inline helpers — used inside content files.
// -----------------------------------------------------------------------------

/// Inline monospace for tabular data values — hex constants, byte offsets,
/// type names, numeric ranges, units. Use liberally; this is a field manual.
#let m(body) = text(font: mono-font, size: 0.92em, features: ("tnum",))[#body]

/// Inline tabular-numeric monospace; same as `m` but reads more naturally
/// when wrapping decimal numbers in prose.
#let n(body) = text(font: mono-font, size: 0.92em, features: ("tnum",))[#body]

/// Kicker label — tracked uppercase mono, used above major dividers and
/// section titles. Echoes the app's `MinimalSectionHead` widget.
#let kicker(body) = block(below: 0.4em)[
  #text(
    font: mono-font,
    size: 8pt,
    weight: 500,
    tracking: 2pt,
    fill: palette.accent,
  )[#upper(body)]
]

/// Quiet inline label — small tracked uppercase, for sidebar metadata,
/// figure captions, status tags inside tables.
#let tag(body) = text(
  font: mono-font,
  size: 7.5pt,
  weight: 500,
  tracking: 1.4pt,
  fill: palette.muted,
)[#upper(body)]

/// Reference to a numbered section in this document. `<sec:foo>` labels
/// remain the source of truth; `s[]` is just the readable wrapper.
#let s(it) = text(font: mono-font, features: ("tnum",))[§#it]

// -----------------------------------------------------------------------------
// Page setup wrapper.
// -----------------------------------------------------------------------------

#let datasheet-page(body) = {
  set page(
    paper: "a4",
    margin: (top: 2.4cm, bottom: 2.2cm, left: 2.2cm, right: 2.2cm),
    fill: palette.paper,
  )

  set text(
    font: body-font,
    size: 10pt,
    fill: palette.ink,
    lang: "en",
    features: ("tnum",),
  )
  set par(justify: true, leading: 0.64em, first-line-indent: 0pt)

  // Headings — pagebreak handled explicitly in main.typ (Typst 0.14
  // disallows pagebreak() inside heading show rules).
  show heading.where(level: 1): it => {
    set text(font: mono-font, size: 22pt, weight: 600, fill: palette.ink)
    v(0.2em)
    if it.numbering != none {
      text(fill: palette.accent)[#counter(heading).display() ]
    }
    upper(it.body)
    v(0.3em)
    line(length: 100%, stroke: 0.6pt + palette.accent)
    v(0.4em)
  }
  show heading.where(level: 2): it => {
    v(1.0em)
    set text(font: mono-font, size: 12pt, weight: 600)
    if it.numbering != none {
      text(fill: palette.accent)[#counter(heading).display() ]
    }
    it.body
    v(0.2em)
  }
  show heading.where(level: 3): it => {
    v(0.5em)
    set text(font: mono-font, size: 9.5pt, weight: 500, tracking: 1.2pt, fill: palette.muted)
    upper(it.body)
    v(0.15em)
  }

  // Links coloured by accent for visibility on print and screen alike.
  show link: it => text(fill: palette.accent)[#it]

  // Inline raw — small, panel-coloured pill.
  show raw.where(block: false): it => box(
    fill: palette.panel,
    inset: (x: 3pt, y: 1pt),
    outset: (y: 2pt),
    radius: 1pt,
  )[#text(font: mono-font, size: 0.9em, features: ("tnum",))[#it]]

  // Block raw — left rule in accent, mono inside.
  show raw.where(block: true): it => block(
    fill: palette.panel,
    inset: 10pt,
    radius: 1pt,
    width: 100%,
    stroke: (left: 2pt + palette.accent),
  )[#text(font: mono-font, size: 8.6pt, features: ("tnum",))[#it]]

  set heading(numbering: "1.1")
  set figure(supplement: [Fig.])
  show figure.caption: it => block(above: 0.5em, below: 0.5em)[
    #text(font: mono-font, size: 8pt, fill: palette.muted, tracking: 0.8pt)[
      #upper[#it.supplement #it.counter.display()]
      #h(0.6em)
      #text(tracking: 0pt)[#it.body]
    ]
  ]

  body
}

// -----------------------------------------------------------------------------
// Block-level helpers — used inside content files.
// -----------------------------------------------------------------------------

/// Hairline divider — visual continuation of the brand's `brandRule` colour.
#let hairline = line(length: 100%, stroke: 0.4pt + palette.rule)

/// Spec table — striped, hairline-bordered, mono-friendly. First row is
/// treated as a header band (no stripe; slightly darker fill).
#let spec-table(columns: auto, align-cols: none, ..rows) = {
  set text(size: 9pt)
  table(
    columns: columns,
    stroke: 0.4pt + palette.rule,
    fill: (_, row) => if row == 0 {
      palette.ink.lighten(85%)
    } else if calc.odd(row) {
      palette.panel
    } else {
      none
    },
    inset: (x: 6pt, y: 4pt),
    align: if align-cols == none {
      (col, row) => if row == 0 { center + horizon } else { left + horizon }
    } else {
      align-cols
    },
    ..rows,
  )
}

/// Two-column spec row — left column small tracked label, right column
/// monospace value. Use in clusters for short reference blocks.
#let spec-row(label, value) = block(below: 0.3em)[
  #grid(
    columns: (35%, 1fr),
    column-gutter: 8pt,
    text(font: mono-font, size: 8pt, tracking: 1.2pt, fill: palette.muted)[#upper(label)],
    text(font: mono-font, size: 9.5pt, features: ("tnum",))[#value],
  )
]

/// Callout — note / warn / rule / spec. Coloured left rule, tracked label,
/// quiet body. Matches the app's `NoteBlock` widget.
#let callout(kind: "note", body) = {
  let (lbl, color) = if kind == "warn" {
    ("WARNING", palette.accent)
  } else if kind == "rule" {
    ("RULE", palette.accent)
  } else if kind == "spec" {
    ("SPEC", palette.good)
  } else {
    ("NOTE", palette.muted)
  }
  block(
    fill: color.lighten(92%),
    stroke: (left: 2pt + color),
    inset: (x: 10pt, y: 8pt),
    radius: 1pt,
    width: 100%,
    above: 0.6em,
    below: 0.6em,
  )[
    #text(font: mono-font, size: 7.5pt, weight: 600, tracking: 1.6pt, fill: color)[#lbl]
    #h(0.6em)
    #body
  ]
}

/// Pull-quote sized "card" — big mono number / fact, small tracked label
/// underneath. Used on the cover and at section openers for emphasis.
#let stat-card(label, value, unit: none) = block(
  fill: palette.paper,
  stroke: 0.6pt + palette.rule,
  inset: 12pt,
  radius: 1pt,
  width: 100%,
)[
  #text(font: mono-font, size: 22pt, weight: 600, features: ("tnum",))[#value]
  #if unit != none [
    #h(2pt)
    #text(font: mono-font, size: 11pt, fill: palette.muted, features: ("tnum",))[#unit]
  ]
  \
  #v(2pt)
  #text(font: mono-font, size: 7.5pt, tracking: 1.4pt, fill: palette.muted)[#upper(label)]
]

/// A tracked "PART N — TITLE" divider page-block.
#let part-divider(num, title) = block(above: 1.4em, below: 0.6em)[
  #line(length: 100%, stroke: 0.4pt + palette.rule)
  #v(4pt)
  #text(font: mono-font, size: 8pt, tracking: 2pt, fill: palette.accent)[#upper[Part #num]]
  #h(1em)
  #text(font: mono-font, size: 12pt, weight: 600, tracking: 1.2pt)[#upper(title)]
  #v(2pt)
  #line(length: 100%, stroke: 0.4pt + palette.rule)
]
