/// Brand tokens for the quiet field manual visual system.
///
/// IBM Plex Mono throughout — display, body, labels. Tabular numerals on
/// by default so digits align in tables and charts. Semantic colours
/// (good / hivis / accent / fg-dim) carry state; the warm off-white
/// foreground carries everything else.
library;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

// ---------------------------------------------------------------------------
// Color tokens
// ---------------------------------------------------------------------------

/// Page background — near-black with a faint warm green cast.
const Color brandBg = Color(0xFF121412);

/// Primary surface for panels, tables, charts.
const Color brandSurface = Color(0xFF1A1E18);

/// Secondary surface — used for nested or recessed regions.
const Color brandSurface2 = Color(0xFF161915);

/// Resting fill for interactive controls — segmented containers, chips, tool
/// groups, text fields. A subtle warm step above [brandBg] so a tappable
/// control reads as raised instead of dissolving into the near-black page.
const Color brandControlFill = Color(0xFF20251D);

/// Active / selected fill for interactive controls — a clearer step up from
/// [brandControlFill] so the selected segment, active chip, or picked row reads
/// unmistakably "on".
const Color brandControlActive = Color(0xFF2D3327);

/// Foreground / primary text — warm off-white.
const Color brandFg = Color(0xFFEFEAE0);

/// Dim foreground — labels, captions, leader dots.
const Color brandFgDim = Color(0xFF9A968A);

/// Hairline rule — borders, dividers, gridlines.
const Color brandRule = Color(0xFF353A32);

/// Accent — alert/error/required-action. Borders, ticks, dots, dim fills.
/// NEVER used as a large fill on a healthy surface.
const Color brandAccent = Color(0xFFE63946);

/// Healthy / go — connected, enabled, OK, start-a-good-thing. A saturated
/// green that reads as a confident dash light against the near-black canvas
/// (the old muted sage looked washed-out / "default AI grey"). Use for state
/// indicators (peripheral OK, device connected, fix acquired) and the filled
/// "go" CTA.
const Color brandGood = Color(0xFF35C46E);

/// High-visibility — reserved for live action (recording in progress,
/// armed-and-firing states). Treat like a dash light.
const Color brandHivis = Color(0xFFF5D547);

/// Connectivity / transport — the command category for Bluetooth (BLE),
/// WiFi transfer, device pairing, and informational connect actions. A
/// confident azure, distinct from the go/live/alert states. Use for the
/// filled "connect" CTA and BLE/WiFi affordances.
const Color brandInfo = Color(0xFF3B92E8);

/// Faintest foreground — placeholder text, tertiary captions, the "×"-marked
/// unavailable rows. Dimmer than [brandFgDim]; use only where text must
/// recede almost fully into the surface.
const Color brandFgFaint = Color(0xFF6C6A60);

/// Default trace palette for multi-series charts (time-series, FFT, GPS, lap
/// progression) and the cycle of per-session colours on the GPS map.
///
/// Eight luminous, well-separated hues tuned for legibility on the warm
/// near-black [brandBg] canvas — the Material primaries (`Colors.blue/red/…`)
/// read as washed-out and clash with the field-manual palette. The first four
/// lean on the brand's semantic anchors (azure/green/amber/orange); the rest
/// add violet, teal, rose, and coral to fill out an 8-series cycle. The coral
/// is deliberately distinct from [brandAccent] so a data line never reads as
/// the reserved alert red. Assigned by series order, wrapping with `% length`.
/// Users override per channel via the colour picker; this is only the default.
const List<Color> brandChartPalette = [
  Color(0xFF5BA6F0), // azure
  Color(0xFF35C46E), // green (brandGood)
  Color(0xFFF5D547), // amber (brandHivis)
  Color(0xFFE8964B), // orange
  Color(0xFFB98AE6), // violet
  Color(0xFF3FC9C0), // teal
  Color(0xFFE86FA6), // rose
  Color(0xFFE05A63), // coral
];

// ---------------------------------------------------------------------------
// Geometry tokens
// ---------------------------------------------------------------------------

/// Maximum corner radius for structural surfaces (cards, sheets, panels) and
/// the crisp legacy control look. Anything ≥ 4 here is out of system.
/// Surfaces with no radius use [BorderRadius.zero].
const double brandControlRadius = 2.0;

/// Corner radius for **interactive controls** in the softened redesign —
/// filled buttons, segmented toggles, text fields, chips. A deliberate middle
/// ground between the crisp 2 px structural [brandControlRadius] and a fully
/// rounded control: friendlier controls inside a still-crisp shell.
/// Structural surfaces keep [brandControlRadius].
const double brandControlRadiusSoft = 7.0;

/// Hairline border thickness.
const double brandHairlineWidth = 1.0;

/// Standard padding step — most layout spacing is multiples of 4.
const double brandPad = 4.0;

// ---------------------------------------------------------------------------
// Typography
// ---------------------------------------------------------------------------

/// Tabular figures — applied to every TextStyle so digits align in tables
/// and charts. Must be a `const` list because [TextStyle] requires it.
const List<FontFeature> brandTabularFeatures = [
  FontFeature.tabularFigures(),
];

/// Letter-spacing for uppercase tracked labels (kicker, nav, status).
const double brandLabelTracking = 1.6;

/// Letter-spacing for the prominent tracked labels in section heads.
const double brandKickerTracking = 2.0;

/// Returns the IBM Plex Mono `TextStyle` for body and UI use.
///
/// All numerics are tabular by default. Falls back to `monospace` if
/// google_fonts cannot fetch the font (offline first launch).
TextStyle plexMono({
  double fontSize = 14,
  FontWeight fontWeight = FontWeight.w400,
  Color? color,
  double? letterSpacing,
  double? height,
}) {
  return GoogleFonts.ibmPlexMono(
    textStyle: TextStyle(
      fontSize: fontSize,
      fontWeight: fontWeight,
      color: color,
      letterSpacing: letterSpacing,
      height: height,
      fontFeatures: brandTabularFeatures,
      fontFamilyFallback: const ['monospace'],
    ),
  );
}

/// Returns the IBM Plex Sans `TextStyle` for **body / instructional /
/// descriptive paragraph text** — the readability upgrade for new users.
///
/// Mono ([plexMono]) stays the face for all data, numbers, labels, kickers,
/// status text, and button labels; Sans is for prose only (wherever the
/// prototype used `.body` / `.body-dim`). Defaults to a 1.5 line height for
/// comfortable multi-line copy. No tabular figures — this is not for numerics.
///
/// Falls back to the platform `sans-serif` if google_fonts cannot fetch the
/// font (offline first launch), mirroring [plexMono]'s monospace fallback.
TextStyle plexSans({
  double fontSize = 14,
  FontWeight fontWeight = FontWeight.w400,
  Color? color,
  double? height = 1.5,
  double? letterSpacing,
}) {
  return GoogleFonts.ibmPlexSans(
    textStyle: TextStyle(
      fontSize: fontSize,
      fontWeight: fontWeight,
      color: color,
      height: height,
      letterSpacing: letterSpacing,
      fontFamilyFallback: const ['sans-serif'],
    ),
  );
}
