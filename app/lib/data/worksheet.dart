import 'package:idl0/data/spectral_params.dart';
import 'package:idl0/data/worksheet_block.dart';
import 'package:idl0/data/y_scale.dart';
import 'package:idl0/src/rust/fft.dart' show Averaging;
import 'package:uuid/uuid.dart';

// Sentinel for nullable copyWith parameters — distinguishes "not provided"
// from explicit null. Private to this file; used only by [ChartSlot.copyWith].
class _Unset {
  const _Unset();
}

const _unset = _Unset();

// ---------------------------------------------------------------------------
// Enums
// ---------------------------------------------------------------------------

/// Chart type discriminator for a [ChartSlot]. See §14.1.
enum ChartType {
  /// Multi-channel time-series line chart.
  timeSeries,

  /// Multi-channel FFT magnitude spectrum — one line per assigned channel,
  /// sharing the frequency axis. Event-driven and empty channels are skipped.
  fft,

  /// Time × frequency heatmap — short-time Fourier transform rendered as a
  /// colour-coded spectrogram. Shares [SpectralParams] with [fft] but keeps
  /// every STFT frame rather than averaging across segments.
  spectrogram,

  /// Value-distribution histogram — bars showing what fraction of samples fall
  /// in each equal-width value bin, over the whole rendered session. One
  /// channel is the typical case (e.g. a suspension-velocity distribution);
  /// extra assigned channels overlay translucently. Computed in `idl-rs`
  /// (`channel_histogram`).
  histogram,

  /// GPS track polyline on a map.
  gpsMap,

  /// Per-session lap × sector data table. Pinned as the first slot of every
  /// [WorksheetKind.sessionSheet] worksheet; not addable from the Add Chart
  /// picker because the Session Sheet always carries one.
  lapTable,

  /// Lap-time progression chart — one line per session in scope, X = lap
  /// index within the session, Y = lap time in seconds. Pinned as the second
  /// slot of every [WorksheetKind.sessionSheet] worksheet.
  lapProgression,

  /// N-lap variance chart — one per-sample delta line per overlay lap
  /// (`overlay − Main` at the matching position), up to nine, with the Main
  /// (fastest, overridable) lap as the zero baseline. Aligned by lap-relative
  /// time or track distance per [ChartSlot.varianceMode]. Deltas are computed
  /// in `idl-rs` (`variance_traces`). See the N-lap variance design §4, §8.
  varianceTrace,

  /// Channel-vs-channel XY scatter, tuned for the G-G diagram (lateral g on X,
  /// longitudinal g on Y). Two render modes ([ScatterMode]): a decimated point
  /// cloud (optionally colour-by a third channel) and a 2D density heatmap.
  /// Equal-aspect with reference g-circles by default. Pairing, decimation, and
  /// binning are computed in `idl-rs` (`scatter_points` / `scatter_density`).
  scatter,
}

/// Render mode for a [ChartType.scatter] chart.
enum ScatterMode {
  /// A decimated point cloud, coloured by session or a third channel.
  points,

  /// A 2D count heatmap (time-at-state), coloured by sample density.
  density,
}

/// Alignment mode for a [ChartType.varianceTrace] chart. Maps to the engine
/// `variance_traces` mode argument (time → 0, distance → 1).
enum VarianceMode {
  /// Align overlay laps to Main by lap-relative time (no Track required).
  time,

  /// Align by track distance — position projected onto the Track's canonical
  /// polyline. Requires every selected lap's session bound to the same Track
  /// with a derived polyline.
  distance,
}

/// Discriminator for a [Worksheet]. See §15.5.
///
/// [WorksheetKind.standard] worksheets are blank slates the user fills with
/// chart slots manually. [WorksheetKind.sessionSheet] worksheets pin a
/// `lapTable` and `lapProgression` slot at the top — they cannot be removed
/// while the worksheet exists, but the user can delete the whole worksheet.
enum WorksheetKind {
  /// Default user-built worksheet with no pinned slots.
  standard,

  /// Worksheet that pins `gpsMap` + `lapTable` + `lapProgression` slots at
  /// indices 0, 1, and 2 respectively.
  sessionSheet,
}

/// Number of pinned slots at the top of every [WorksheetKind.sessionSheet]
/// worksheet — the GPS map, lap table, and lap progression chart. The
/// slot-removal path refuses to drop slots in `[0, _kSessionSheetPinnedSlotCount)`.
const int kSessionSheetPinnedSlotCount = 3;

/// X axis display mode for time-series charts. See §14.2.
enum XAxisMode {
  /// Elapsed time in seconds from session start (default).
  time,

  /// Distance in metres derived from front wheel speed sensor integration.
  ///
  /// Requires a `WheelFront` or `WheelRear` channel in the session.
  wheelDistance,

  /// Distance in metres derived from cumulative GPS track.
  ///
  /// Requires a `GPSSpeed` channel in the session.
  gpsDistance,
}

/// Y axis scaling mode for a [ChartSlot].
enum YScaleMode {
  /// Auto-scale based on the visible data range (default).
  auto,

  /// User-defined fixed Y axis range via [ChartSlot.yMin] and [ChartSlot.yMax].
  manual,
}

/// X-axis scope for a [ChartSlot]. Controls whether the chart shows
/// session-wide data or clips to the active main-lap / overlay-lap pair.
enum ChartScope {
  /// Session when no main/overlay designation is active; lap-pair (main
  /// and overlay laps overlaid on a lap-relative x-axis) when both are
  /// designated on the rendered session's workspace. Default for new
  /// charts — most worksheets benefit from the chart following the lap
  /// table's M/O state without per-chart configuration.
  auto,

  /// Always render full-session data, even when main/overlay are set.
  /// User opts in via the chart properties dialog when they want a
  /// channel to stay session-wide while neighbouring charts switch to
  /// lap-pair view.
  session,
}

// ---------------------------------------------------------------------------
// XAxisRange
// ---------------------------------------------------------------------------

/// Per-worksheet zoom range for time-series charts. See §15.5.
///
/// Persisted alongside [WorkspaceState.worksheetCursors] so zoom and cursor
/// positions restore together on app reopen.
/// Null range (absent from [WorkspaceState.worksheetRanges]) = full view.
class XAxisRange {
  /// Start of the visible X range in seconds from session start.
  final double startSecs;

  /// End of the visible X range in seconds from session start.
  final double endSecs;

  /// Creates an [XAxisRange].
  const XAxisRange({required this.startSecs, required this.endSecs});
}

// ---------------------------------------------------------------------------
// ChartSlot
// ---------------------------------------------------------------------------

/// One chart slot within a worksheet, holding the chart type, assigned
/// channel IDs, and display properties. See §15.5.
class ChartSlot {
  /// Determines which chart widget is rendered for this slot.
  final ChartType chartType;

  /// Registry-name channel IDs assigned to this chart, in insertion order.
  ///
  /// Ignored for [ChartType.gpsMap] (GPS channels are resolved automatically).
  final List<String> channelIds;

  /// Math channel UUIDs assigned to this chart, in insertion order.
  ///
  /// Ignored for [ChartType.gpsMap].
  final List<String> mathChannelIds;

  /// Y axis scaling mode. Defaults to [YScaleMode.auto].
  final YScaleMode yScaleMode;

  /// Minimum Y value when [yScaleMode] is [YScaleMode.manual]. Null otherwise.
  final double? yMin;

  /// Maximum Y value when [yScaleMode] is [YScaleMode.manual]. Null otherwise.
  final double? yMax;

  /// Relative chart height multiplier (0.5–3.0). Default 1.0.
  ///
  /// Applied to the base chart height (300 dp) — a value of 2.0 doubles height.
  final double heightFactor;

  /// Per-channel colour overrides, stored as ARGB int values.
  ///
  /// Keyed by channel ID for [ChartType.timeSeries] and [ChartType.fft],
  /// or by session UUID for [ChartType.gpsMap] (polyline colour per session).
  /// Channels absent from this map use the auto-assigned palette colour.
  /// Stored as int so the model is JSON-serializable.
  /// Convert to [Color] at the widget layer via [Color(value)].
  final Map<String, int> channelColors;

  /// X-axis scope. Defaults to [ChartScope.auto] — chart follows the lap
  /// table's M/O state automatically. Users opt a chart into session-wide
  /// rendering via the chart properties dialog when they want it to stay
  /// full-session even when M/O are designated.
  final ChartScope scope;

  /// Shared DSP parameters for [ChartType.fft] and [ChartType.spectrogram] —
  /// window, segment length, overlap, detrend, scaling, and frequency-axis
  /// scale. Ignored for other chart types. Configurable from the chart
  /// properties dialog. Defaults are chart-type-specific: FFT seeds
  /// [SpectralParams.fftDefaults]; spectrogram seeds
  /// [SpectralParams.spectrogramDefaults].
  final SpectralParams spectral;

  /// Cross-segment averaging mode for the FFT. Defaults to [Averaging.mean].
  /// Ignored for non-FFT slots (spectrogram keeps every STFT frame).
  final Averaging fftAveraging;

  /// Y-axis display scale. Shared by every chart type with a continuous Y axis
  /// (replaces the old per-chart `fftYScale` / `histogramLogCount`). Defaults to
  /// [YScale.linear]. See `y_scale.dart` and SPEC §26.
  final YScale yScale;

  /// Whether to draw a horizontal reference line at Y=0 across the plot.
  /// Off by default; enabled per-chart via the properties dialog.
  /// Ignored for [ChartType.gpsMap] and [ChartType.lapTable].
  final bool showZeroLine;

  /// Number of equal-width bins for [ChartType.histogram]. Ignored for other
  /// chart types. Configurable in the chart properties dialog; defaults to 40,
  /// which balances value resolution against per-bin sample count for typical
  /// sessions.
  final int histogramBinCount;

  /// When true, a [ChartType.histogram] is binned over a zero-centred range
  /// (`[-m, m]`) so compression and rebound sit symmetrically — the natural
  /// frame for a signed suspension-velocity distribution. Off by default
  /// (range = data min/max). Ignored for non-histogram slots.
  final bool histogramSymmetric;

  /// When true, a [ChartType.histogram] is drawn as a smooth polyline through
  /// the bin centres instead of stepped bars — a fitted-distribution look that
  /// reads more clearly at high bin counts. Off by default. Ignored for
  /// non-histogram slots.
  final bool histogramSmooth;

  /// Channels compared in a [ChartType.varianceTrace] chart — one set of N
  /// overlay-vs-Main delta lines per channel id. Empty until the user picks.
  final List<String> varianceChannelIds;

  /// Alignment mode for a [ChartType.varianceTrace] chart (time or distance).
  final VarianceMode varianceMode;

  /// Channel id whose value colours the GPS trace (Turbo heatmap), or null for
  /// solid per-session colours. Only meaningful for [ChartType.gpsMap].
  final String? gpsColorChannelId;

  /// Manual lower bound of the GPS colour scale; null ⇒ auto (shared min across
  /// every visible trace). Only meaningful for [ChartType.gpsMap].
  final double? gpsColorMin;

  /// Manual upper bound of the GPS colour scale; null ⇒ auto (shared max across
  /// every visible trace). Only meaningful for [ChartType.gpsMap].
  final double? gpsColorMax;

  /// X-axis channel id for a [ChartType.scatter] chart (base or math), or null
  /// until the user picks one. For a G-G plot this is lateral acceleration.
  final String? scatterXChannelId;

  /// Y-axis channel id for a [ChartType.scatter] chart. For a G-G plot this is
  /// longitudinal acceleration.
  final String? scatterYChannelId;

  /// Render mode — point cloud or density heatmap. Only meaningful for
  /// [ChartType.scatter].
  final ScatterMode scatterMode;

  /// Points-mode colour-by channel id (Turbo heatmap), or null for a solid
  /// per-session colour. Ignored in density mode.
  final String? scatterColorChannelId;

  /// Manual lower bound of the points colour scale; null ⇒ auto.
  final double? scatterColorMin;

  /// Manual upper bound of the points colour scale; null ⇒ auto.
  final double? scatterColorMax;

  /// Whether to draw the plot square at 1:1 data-units-per-pixel — the G-G
  /// friction-circle requirement. Default true.
  final bool scatterEqualAspect;

  /// Whether to draw concentric reference g-circles + a quadrant cross at the
  /// origin. Default true.
  final bool scatterReferenceCircles;

  /// Density-mode grid resolution (square `bins × bins`). Default 64.
  final int scatterBinCount;

  /// User-editable chart title overlay (top-left inside the canvas).
  /// `null` means "use default" — typically a comma-separated list of
  /// rendered channel names. Settable via the inline tap-to-edit affordance
  /// or via the chart properties dialog.
  final String? title;

  /// Stable identity for this slot — used as the key in
  /// [ReorderableListView] so the framework can animate slot moves
  /// correctly even though `ChartSlot` is otherwise replaced wholesale on
  /// every workspace update via [copyWith]. Auto-generated when omitted
  /// from the constructor; preserved through [copyWith] and round-trips
  /// via JSON.
  final String slotId;

  /// Creates a [ChartSlot]. [slotId] auto-generates a fresh UUID when
  /// omitted; supply it only when restoring from JSON.
  ///
  /// When [spectral] is omitted the default is seeded from [chartType]:
  /// [SpectralParams.spectrogramDefaults] for [ChartType.spectrogram],
  /// [SpectralParams.fftDefaults] for all other types.
  ChartSlot({
    String? slotId,
    this.chartType = ChartType.timeSeries,
    this.channelIds = const [],
    this.mathChannelIds = const [],
    this.yScaleMode = YScaleMode.auto,
    this.yMin,
    this.yMax,
    this.heightFactor = 1.0,
    this.channelColors = const {},
    this.scope = ChartScope.auto,
    SpectralParams? spectral,
    this.fftAveraging = Averaging.mean,
    this.yScale = YScale.linear,
    this.showZeroLine = false,
    this.histogramBinCount = 40,
    this.histogramSymmetric = false,
    this.histogramSmooth = false,
    this.varianceChannelIds = const [],
    this.varianceMode = VarianceMode.distance,
    this.gpsColorChannelId,
    this.gpsColorMin,
    this.gpsColorMax,
    this.scatterXChannelId,
    this.scatterYChannelId,
    this.scatterMode = ScatterMode.points,
    this.scatterColorChannelId,
    this.scatterColorMin,
    this.scatterColorMax,
    this.scatterEqualAspect = true,
    this.scatterReferenceCircles = true,
    this.scatterBinCount = 64,
    this.title,
  })  : spectral = spectral ??
            (chartType == ChartType.spectrogram
                ? SpectralParams.spectrogramDefaults()
                : SpectralParams.fftDefaults()),
        slotId = slotId ?? const Uuid().v4();

  /// Returns the resolved Welch segment length in samples for a record of
  /// [sampleCount] samples when [SpectralParams.segmentLength] is null (auto).
  ///
  /// Auto = the largest power of two ≤ `sampleCount / 8`, clamped to
  /// `[256, 8192]` and never exceeding `sampleCount`. Targets roughly 8+
  /// averaged segments at 50% overlap — enough smoothing to suppress
  /// periodogram variance while keeping usable low-frequency resolution.
  static int autoFftSegmentLength(int sampleCount) {
    if (sampleCount <= 0) return 0;
    final target = sampleCount ~/ 8;
    // Largest power of two ≤ target (min 1 so the loop terminates).
    var pow2 = 1;
    while (pow2 * 2 <= target) {
      pow2 *= 2;
    }
    final clamped = pow2.clamp(256, 8192);
    return clamped > sampleCount ? sampleCount : clamped;
  }

  /// Target number of time columns (X-axis frames) the spectrogram heatmap
  /// aims to fill its time axis with.
  ///
  /// A spectrogram *displays* every STFT frame, unlike the FFT chart which
  /// *averages* ~8 Welch segments. So where the FFT wants few, near-independent
  /// segments (50% overlap), the spectrogram wants many short-hop frames. ~240
  /// reads as a smooth heatmap on typical chart widths (≈400–1000 px) without
  /// over-drawing sub-pixel columns, and caps both the per-frame FFT count and
  /// the `n_times × n_freqs` matrix transferred over FFI.
  static const int kSpectrogramTargetColumns = 240;

  /// Returns the STFT overlap in samples (`noverlap`) so a spectrogram over a
  /// window of [winLen] samples at segment length [seg] renders roughly
  /// [kSpectrogramTargetColumns] time frames.
  ///
  /// Frequency resolution is fixed by [seg]; this sets only the time-column
  /// density by choosing the hop (`step = seg - noverlap`). Unlike the FFT
  /// chart's fixed [SpectralParams.overlapPercent] (Welch's 50%, for variance
  /// reduction when averaging), the spectrogram auto-sizes the hop to fill its
  /// time axis — a display concern, not an averaging one. The result is in
  /// `[0, seg - 1]` (hop ≥ 1), matching `stft()`'s own clamp. Returns 0 for a
  /// degenerate window (`winLen <= 0`, `seg <= 0`, or `winLen <= seg` — a single
  /// full-window frame).
  ///
  /// Frame count follows the engine: `n_times = (winLen - seg) ~/ hop + 1`, so
  /// `hop ≈ (winLen - seg) / (columns - 1)`.
  static int autoSpectrogramOverlap(int winLen, int seg) {
    if (winLen <= 0 || seg <= 0 || winLen <= seg) return 0;
    final maxColumns = winLen - seg + 1; // hop = 1 ceiling
    final columns =
        maxColumns < kSpectrogramTargetColumns ? maxColumns : kSpectrogramTargetColumns;
    if (columns <= 1) return 0;
    var hop = (winLen - seg) ~/ (columns - 1);
    if (hop < 1) hop = 1;
    if (hop > seg) hop = seg; // guard huge windows from negative overlap
    // hop ∈ [1, seg] ⇒ noverlap = seg - hop ∈ [0, seg - 1].
    return seg - hop;
  }

  /// Returns a copy with the given fields replaced.
  ///
  /// Pass `yMin: null` or `yMax: null` to explicitly clear those fields.
  ChartSlot copyWith({
    String? slotId,
    ChartType? chartType,
    List<String>? channelIds,
    List<String>? mathChannelIds,
    YScaleMode? yScaleMode,
    Object? yMin = _unset,
    Object? yMax = _unset,
    double? heightFactor,
    Map<String, int>? channelColors,
    ChartScope? scope,
    SpectralParams? spectral,
    Averaging? fftAveraging,
    YScale? yScale,
    bool? showZeroLine,
    int? histogramBinCount,
    bool? histogramSymmetric,
    bool? histogramSmooth,
    List<String>? varianceChannelIds,
    VarianceMode? varianceMode,
    Object? gpsColorChannelId = _unset,
    Object? gpsColorMin = _unset,
    Object? gpsColorMax = _unset,
    Object? scatterXChannelId = _unset,
    Object? scatterYChannelId = _unset,
    ScatterMode? scatterMode,
    Object? scatterColorChannelId = _unset,
    Object? scatterColorMin = _unset,
    Object? scatterColorMax = _unset,
    bool? scatterEqualAspect,
    bool? scatterReferenceCircles,
    int? scatterBinCount,
    Object? title = _unset,
  }) =>
      ChartSlot(
        slotId: slotId ?? this.slotId,
        chartType: chartType ?? this.chartType,
        channelIds: channelIds ?? this.channelIds,
        mathChannelIds: mathChannelIds ?? this.mathChannelIds,
        yScaleMode: yScaleMode ?? this.yScaleMode,
        yMin: identical(yMin, _unset) ? this.yMin : yMin as double?,
        yMax: identical(yMax, _unset) ? this.yMax : yMax as double?,
        heightFactor: heightFactor ?? this.heightFactor,
        channelColors: channelColors ?? this.channelColors,
        scope: scope ?? this.scope,
        spectral: spectral ?? this.spectral,
        fftAveraging: fftAveraging ?? this.fftAveraging,
        yScale: yScale ?? this.yScale,
        showZeroLine: showZeroLine ?? this.showZeroLine,
        histogramBinCount: histogramBinCount ?? this.histogramBinCount,
        histogramSymmetric: histogramSymmetric ?? this.histogramSymmetric,
        histogramSmooth: histogramSmooth ?? this.histogramSmooth,
        varianceChannelIds: varianceChannelIds ?? this.varianceChannelIds,
        varianceMode: varianceMode ?? this.varianceMode,
        gpsColorChannelId: identical(gpsColorChannelId, _unset)
            ? this.gpsColorChannelId
            : gpsColorChannelId as String?,
        gpsColorMin: identical(gpsColorMin, _unset)
            ? this.gpsColorMin
            : gpsColorMin as double?,
        gpsColorMax: identical(gpsColorMax, _unset)
            ? this.gpsColorMax
            : gpsColorMax as double?,
        scatterXChannelId: identical(scatterXChannelId, _unset)
            ? this.scatterXChannelId
            : scatterXChannelId as String?,
        scatterYChannelId: identical(scatterYChannelId, _unset)
            ? this.scatterYChannelId
            : scatterYChannelId as String?,
        scatterMode: scatterMode ?? this.scatterMode,
        scatterColorChannelId: identical(scatterColorChannelId, _unset)
            ? this.scatterColorChannelId
            : scatterColorChannelId as String?,
        scatterColorMin: identical(scatterColorMin, _unset)
            ? this.scatterColorMin
            : scatterColorMin as double?,
        scatterColorMax: identical(scatterColorMax, _unset)
            ? this.scatterColorMax
            : scatterColorMax as double?,
        scatterEqualAspect: scatterEqualAspect ?? this.scatterEqualAspect,
        scatterReferenceCircles:
            scatterReferenceCircles ?? this.scatterReferenceCircles,
        scatterBinCount: scatterBinCount ?? this.scatterBinCount,
        title: identical(title, _unset) ? this.title : title as String?,
      );

  /// Serializes to a JSON-compatible map. See [WorkspaceNotifier._persistUiState].
  Map<String, dynamic> toJson() => {
        'slotId': slotId,
        'chartType': chartType.name,
        'channelIds': channelIds,
        'mathChannelIds': mathChannelIds,
        'yScaleMode': yScaleMode.name,
        if (yMin != null) 'yMin': yMin,
        if (yMax != null) 'yMax': yMax,
        'heightFactor': heightFactor,
        'channelColors': channelColors,
        'scope': scope.name,
        // Spectral params — emitted for FFT and spectrogram slots; other
        // chart types don't use them so keep other-type JSON lean.
        if (chartType == ChartType.fft || chartType == ChartType.spectrogram)
          'spectral': spectral.toJson(),
        // fftAveraging is FFT-only (spectrogram keeps every STFT frame).
        if (chartType == ChartType.fft) 'fftAveraging': fftAveraging.name,
        // Shared Y-axis scale (any chart type with a continuous Y axis); emit
        // only when non-default so other chart-type JSON stays lean.
        if (yScale != YScale.linear) 'yScale': yScale.name,
        if (showZeroLine) 'showZeroLine': showZeroLine,
        // Histogram-only fields; emit only for histogram slots so other
        // chart-type JSON stays untouched.
        if (chartType == ChartType.histogram)
          'histogramBinCount': histogramBinCount,
        if (chartType == ChartType.histogram && histogramSymmetric)
          'histogramSymmetric': histogramSymmetric,
        if (chartType == ChartType.histogram && histogramSmooth)
          'histogramSmooth': histogramSmooth,
        // Variance-trace-only fields; emit only for variance slots.
        if (chartType == ChartType.varianceTrace)
          'varianceChannelIds': varianceChannelIds,
        if (chartType == ChartType.varianceTrace)
          'varianceMode': varianceMode.name,
        // GPS colour-by fields; emit only for gps slots so other chart-type
        // JSON stays lean.
        if (chartType == ChartType.gpsMap && gpsColorChannelId != null)
          'gpsColorChannelId': gpsColorChannelId,
        if (chartType == ChartType.gpsMap && gpsColorMin != null)
          'gpsColorMin': gpsColorMin,
        if (chartType == ChartType.gpsMap && gpsColorMax != null)
          'gpsColorMax': gpsColorMax,
        // Scatter-only fields; emit only for scatter slots so other chart-type
        // JSON stays lean. Booleans/bins emit only when non-default.
        if (chartType == ChartType.scatter) ...{
          if (scatterXChannelId != null) 'scatterXChannelId': scatterXChannelId,
          if (scatterYChannelId != null) 'scatterYChannelId': scatterYChannelId,
          'scatterMode': scatterMode.name,
          if (scatterColorChannelId != null)
            'scatterColorChannelId': scatterColorChannelId,
          if (scatterColorMin != null) 'scatterColorMin': scatterColorMin,
          if (scatterColorMax != null) 'scatterColorMax': scatterColorMax,
          if (!scatterEqualAspect) 'scatterEqualAspect': scatterEqualAspect,
          if (!scatterReferenceCircles)
            'scatterReferenceCircles': scatterReferenceCircles,
          if (scatterBinCount != 64) 'scatterBinCount': scatterBinCount,
        },
        if (title != null) 'title': title,
      };

  /// Deserializes from a JSON map produced by [toJson]. Unknown values fall
  /// back to defaults so old JSON loads without crashing. Layouts whose
  /// `chartType` string is unknown to this build (older `ghostDelta` slots,
  /// or future chart types) fall back to [ChartType.timeSeries].
  factory ChartSlot.fromJson(Map<String, dynamic> json) => ChartSlot(
        slotId: json['slotId'] as String?,
        chartType: ChartType.values.firstWhere(
          (e) => e.name == json['chartType'],
          orElse: () => ChartType.timeSeries,
        ),
        channelIds: List<String>.from(json['channelIds'] as List? ?? []),
        mathChannelIds:
            List<String>.from(json['mathChannelIds'] as List? ?? []),
        yScaleMode: YScaleMode.values.firstWhere(
          (e) => e.name == json['yScaleMode'],
          orElse: () => YScaleMode.auto,
        ),
        yMin: (json['yMin'] as num?)?.toDouble(),
        yMax: (json['yMax'] as num?)?.toDouble(),
        heightFactor: (json['heightFactor'] as num?)?.toDouble() ?? 1.0,
        channelColors: (json['channelColors'] as Map<String, dynamic>? ?? {})
            .map((k, v) => MapEntry(k, (v as num).toInt())),
        scope: ChartScope.values.firstWhere(
          (e) => e.name == json['scope'],
          orElse: () => ChartScope.auto,
        ),
        // Prefer the new grouped `spectral` object; migrate legacy flat fft*
        // keys when it is absent so pre-refactor workbooks load without loss.
        spectral: json['spectral'] != null
            ? SpectralParams.fromJson(
                json['spectral'] as Map<String, dynamic>,
              )
            : SpectralParams.fromLegacyFftJson(json),
        fftAveraging: Averaging.values.firstWhere(
          (e) => e.name == json['fftAveraging'],
          orElse: () => Averaging.mean,
        ),
        // yScale unifies the old fftYScale / histogramLogCount. Prefer the new
        // key; migrate either legacy "log" form to YScale.log.
        yScale: YScale.values.firstWhere(
          (e) => e.name == json['yScale'],
          orElse: () =>
              (json['fftYScale'] == 'log' || json['histogramLogCount'] == true)
                  ? YScale.log
                  : YScale.linear,
        ),
        showZeroLine: json['showZeroLine'] as bool? ?? false,
        histogramBinCount: (json['histogramBinCount'] as num?)?.toInt() ?? 40,
        histogramSymmetric: json['histogramSymmetric'] as bool? ?? false,
        histogramSmooth: json['histogramSmooth'] as bool? ?? false,
        varianceChannelIds:
            List<String>.from(json['varianceChannelIds'] as List? ?? []),
        varianceMode: VarianceMode.values.firstWhere(
          (e) => e.name == json['varianceMode'],
          orElse: () => VarianceMode.distance,
        ),
        gpsColorChannelId: json['gpsColorChannelId'] as String?,
        gpsColorMin: (json['gpsColorMin'] as num?)?.toDouble(),
        gpsColorMax: (json['gpsColorMax'] as num?)?.toDouble(),
        scatterXChannelId: json['scatterXChannelId'] as String?,
        scatterYChannelId: json['scatterYChannelId'] as String?,
        scatterMode: ScatterMode.values.firstWhere(
          (e) => e.name == json['scatterMode'],
          orElse: () => ScatterMode.points,
        ),
        scatterColorChannelId: json['scatterColorChannelId'] as String?,
        scatterColorMin: (json['scatterColorMin'] as num?)?.toDouble(),
        scatterColorMax: (json['scatterColorMax'] as num?)?.toDouble(),
        scatterEqualAspect: json['scatterEqualAspect'] as bool? ?? true,
        scatterReferenceCircles:
            json['scatterReferenceCircles'] as bool? ?? true,
        scatterBinCount: (json['scatterBinCount'] as num?)?.toInt() ?? 64,
        title: json['title'] as String?,
      );
}

// ---------------------------------------------------------------------------
// Worksheet
// ---------------------------------------------------------------------------

/// One worksheet within a workbook. See §15.5.
class Worksheet {
  /// Stable UUID used to key the cursor provider and other worksheet-scoped
  /// state. Generated once at construction; preserved in [copyWith].
  final String id;

  /// Display name, e.g. `Sheet 1`.
  final String name;

  /// X axis mode last chosen for this worksheet.
  ///
  /// Defaults to [XAxisMode.time].
  final XAxisMode xAxisMode;

  /// Ordered worksheet blocks (charts and tables) in document order. Charts
  /// always precede tables in v1 — tables append below the charts (see
  /// [withChartSlots]). Replaces the old flat `charts` list; legacy `charts`
  /// JSON migrates to chart blocks on load. See design §6.
  final List<WorksheetBlock> blocks;

  /// Chart slots in block order — convenience for the many chart-index call
  /// sites that predate blocks. Because charts always precede tables, a
  /// chart-index into this list matches the chart's block position. Prefer
  /// iterating [blocks] in new code.
  List<ChartSlot> get charts => [
        for (final b in blocks)
          if (b.content is ChartContent) (b.content as ChartContent).slot,
      ];

  /// Table blocks in document order.
  List<WorksheetBlock> get tableBlocks =>
      [for (final b in blocks) if (b.content is TableContent) b];

  /// What kind of worksheet this is. Drives default chart slots, the pinned
  /// slot-removal guard, the worksheet-tab icon, and the Add-Chart filter.
  /// Defaults to [WorksheetKind.standard]; missing JSON key reads as
  /// `standard` for backward compatibility with workbooks written before
  /// Session Sheets shipped.
  final WorksheetKind kind;

  /// Creates a [Worksheet], generating a stable UUID if [id] is omitted.
  ///
  /// [blocks] defaults to a single fresh empty chart block when omitted; the
  /// constructor can't use a `const` list because [ChartSlot] generates a UUID
  /// at construction time.
  Worksheet({
    String? id,
    required this.name,
    this.xAxisMode = XAxisMode.time,
    List<WorksheetBlock>? blocks,
    this.kind = WorksheetKind.standard,
  })  : id = id ?? const Uuid().v4(),
        blocks = blocks ?? [WorksheetBlock.chart(ChartSlot())];

  /// Convenience constructor for a [WorksheetKind.sessionSheet] worksheet —
  /// pre-populates [blocks] with the three pinned chart slots in canonical
  /// order: GPS map at the top so the user is grounded in track location
  /// before scrolling into lap-time numbers.
  Worksheet.sessionSheet({
    String? id,
    required this.name,
    this.xAxisMode = XAxisMode.time,
  })  : id = id ?? const Uuid().v4(),
        kind = WorksheetKind.sessionSheet,
        blocks = [
          WorksheetBlock.chart(ChartSlot(chartType: ChartType.gpsMap)),
          WorksheetBlock.chart(ChartSlot(chartType: ChartType.lapTable)),
          WorksheetBlock.chart(ChartSlot(chartType: ChartType.lapProgression)),
        ];

  /// Returns a copy with the given fields replaced. [id] is always preserved.
  /// [kind] cannot change after construction (Session Sheets stay Session
  /// Sheets) — to convert, drop the worksheet and add a new one.
  Worksheet copyWith({
    String? name,
    XAxisMode? xAxisMode,
    List<WorksheetBlock>? blocks,
  }) =>
      Worksheet(
        id: id,
        name: name ?? this.name,
        xAxisMode: xAxisMode ?? this.xAxisMode,
        blocks: blocks ?? this.blocks,
        kind: kind,
      );

  /// Returns a copy whose chart blocks are replaced by [newCharts] (in order),
  /// preserving table blocks — which keep their identity and are placed after
  /// the charts (the charts-before-tables invariant). This is the bridge from
  /// the chart-index-based mutators to the block model: chart block ids are
  /// reused positionally so list keys stay stable across same-length edits.
  Worksheet withChartSlots(List<ChartSlot> newCharts) {
    final existingChartBlocks = [
      for (final b in blocks)
        if (b.content is ChartContent) b,
    ];
    final chartBlocks = <WorksheetBlock>[
      for (var i = 0; i < newCharts.length; i++)
        WorksheetBlock.chart(
          newCharts[i],
          id: i < existingChartBlocks.length ? existingChartBlocks[i].id : null,
        ),
    ];
    return copyWith(blocks: [...chartBlocks, ...tableBlocks]);
  }

  /// Serializes to a JSON-compatible map. The `kind` field is omitted when
  /// it equals the default ([WorksheetKind.standard]) so older app builds
  /// reading the file ignore the unknown field gracefully.
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'xAxisMode': xAxisMode.name,
        'blocks': blocks.map((b) => b.toJson()).toList(),
        if (kind != WorksheetKind.standard) 'kind': kind.name,
      };

  /// Deserializes from a JSON map produced by [toJson]. Missing `kind`
  /// defaults to [WorksheetKind.standard]; an unknown `kind` string also
  /// falls back so future kinds don't crash older app versions.
  ///
  /// Prefers a `blocks` array; falls back to migrating a legacy `charts` array
  /// (each chart slot becomes a chart block). When both are absent, defaults to
  /// one empty chart block.
  ///
  /// Backward-compat: session sheets created before the GPS map became a
  /// pinned slot are migrated by prepending a `gpsMap` chart block, but only
  /// when the sheet doesn't already contain one in any position — so a user who
  /// added their own map manually doesn't end up with two.
  factory Worksheet.fromJson(Map<String, dynamic> json) {
    final kind = WorksheetKind.values.firstWhere(
      (e) => e.name == json['kind'],
      orElse: () => WorksheetKind.standard,
    );
    final blocksJson = json['blocks'] as List?;
    final chartsJson = json['charts'] as List?;
    List<WorksheetBlock> blocks;
    if (blocksJson != null) {
      blocks = blocksJson
          .map((b) => WorksheetBlock.fromJson(b as Map<String, dynamic>))
          .toList();
    } else if (chartsJson != null) {
      // Legacy: a flat charts array becomes chart blocks in order.
      blocks = [
        for (final c in chartsJson)
          WorksheetBlock.chart(ChartSlot.fromJson(c as Map<String, dynamic>)),
      ];
    } else {
      blocks = [WorksheetBlock.chart(ChartSlot())];
    }
    final hasGpsMap = blocks.any(
      (b) =>
          b.content is ChartContent &&
          (b.content as ChartContent).slot.chartType == ChartType.gpsMap,
    );
    if (kind == WorksheetKind.sessionSheet && !hasGpsMap) {
      blocks = [
        WorksheetBlock.chart(ChartSlot(chartType: ChartType.gpsMap)),
        ...blocks,
      ];
    }
    return Worksheet(
      id: json['id'] as String?,
      name: json['name'] as String,
      xAxisMode: XAxisMode.values.firstWhere(
        (e) => e.name == json['xAxisMode'],
        orElse: () => XAxisMode.time,
      ),
      blocks: blocks,
      kind: kind,
    );
  }
}
