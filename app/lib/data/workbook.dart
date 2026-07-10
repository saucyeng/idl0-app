import 'package:uuid/uuid.dart';

import 'exceptions.dart';
import 'math_channel.dart' show MathChannel, MathConstant, kBuiltinMathChannels;
import 'overlay_layout.dart' show OverlayLayout;
import 'worksheet.dart' show Worksheet;

/// Highest workbook_version this build can read.
///
/// - v2: adds `overlay_layouts` (SPEC §33.1); additive — v1 files load with
///   an empty list.
const int _kSupportedWorkbookVersion = 2;

/// A portable analysis workbook — worksheets, charts, math channels, axes,
/// layout — independent of any specific session.
///
/// **Storage model — Drive-as-database.** Canonical store is a JSON file at
/// `IDL0/workbooks/<workbookId>.idl0wb` in the user's Google Drive. A local
/// SQLite cache ([WorkbookIndex]) and a local file mirror at
/// `<sessions-base>/workbooks/<workbookId>.idl0wb` are kept in sync by
/// [WorkbookNotifier]. Conflict policy is last-write-wins by [updatedAtMs].
///
/// **Session binding.** Charts inside a workbook do not store session IDs;
/// they render against the runtime [WorkbookViewContext] (primary + optional
/// overlay session). Math channels travel with the workbook so a shared
/// workbook brings its derived channels with it.
class Workbook {
  /// Highest schema version this build supports.
  static const int supportedVersion = _kSupportedWorkbookVersion;

  /// Stable UUIDv4 assigned at creation; preserved across rename and sync.
  final String workbookId;

  /// User-facing display name.
  final String name;

  /// Ordered list of worksheets.
  final List<Worksheet> worksheets;

  /// Derived channels visible across every worksheet in this workbook.
  final List<MathChannel> mathChannels;

  /// Named numeric constants usable in this workbook's math expressions.
  /// Travels with the `.idl0wb` so a shared workbook brings its constants too.
  final List<MathConstant> constants;

  /// Video/chart overlay layouts owned by this workbook (SPEC §33.1). The
  /// engine consumes their JSON directly (`idl-rs overlay --workbook`).
  /// Added in workbook_version 2.
  final List<OverlayLayout> overlayLayouts;

  /// Creation timestamp, UTC milliseconds since Unix epoch.
  final int createdAtMs;

  /// Last-modified timestamp, UTC milliseconds since Unix epoch. Drives
  /// last-write-wins conflict resolution during Drive sync.
  final int updatedAtMs;

  /// Schema version of this in-memory instance; `<= supportedVersion`.
  final int workbookVersion;

  /// Creates a [Workbook] with explicit field values.
  const Workbook({
    required this.workbookId,
    required this.name,
    required this.worksheets,
    required this.mathChannels,
    required this.createdAtMs,
    required this.updatedAtMs,
    required this.workbookVersion,
    this.constants = const [],
    this.overlayLayouts = const [],
  });

  /// Creates a fresh [Workbook] with a generated UUID and matched timestamps.
  ///
  /// Pass [now] to override the wall-clock for tests; defaults to
  /// `DateTime.now().toUtc()`. Pass [workbookId] to supply a pre-generated
  /// UUID (useful in tests that assert on a known ID).
  factory Workbook.create({
    required String name,
    List<Worksheet> worksheets = const [],
    List<MathChannel> mathChannels = const [],
    List<MathConstant> constants = const [],
    List<OverlayLayout> overlayLayouts = const [],
    DateTime? now,
    String? workbookId,
  }) {
    final ts = (now ?? DateTime.now().toUtc()).millisecondsSinceEpoch;
    return Workbook(
      workbookId: workbookId ?? const Uuid().v4(),
      name: name,
      worksheets: worksheets,
      mathChannels: mathChannels,
      constants: constants,
      overlayLayouts: overlayLayouts,
      createdAtMs: ts,
      updatedAtMs: ts,
      workbookVersion: _kSupportedWorkbookVersion,
    );
  }

  /// The **default** workbook seeded into an empty library: a Session sheet
  /// (pinned GPS map + lap table + lap progression) plus a blank Charts sheet —
  /// the same content as the Analyze tab's first-run layout. Gives every install
  /// a real, persisted workbook to open and curate.
  factory Workbook.createDefault({
    String name = 'Workbook 1',
    DateTime? now,
    String? workbookId,
  }) =>
      Workbook.create(
        name: name,
        worksheets: [
          Worksheet.sessionSheet(name: 'Session'),
          Worksheet(name: 'Charts'),
        ],
        // Seed the lap tutorial channels so a fresh install has LapNumber /
        // LapTime / LapDistance / lap-delta available to chart immediately.
        mathChannels: kBuiltinMathChannels,
        now: now,
        workbookId: workbookId,
      );

  /// A fresh **blank** workbook — one empty standard worksheet, no charts. Used
  /// for the user-initiated "New workbook" action; a prefilled start comes from
  /// a template or by duplicating the default. (A zero-worksheet workbook is
  /// invalid — the UI always needs at least one sheet to display.)
  factory Workbook.createBlank({
    String name = 'Untitled',
    DateTime? now,
    String? workbookId,
  }) =>
      Workbook.create(
        name: name,
        worksheets: [Worksheet(name: 'Sheet 1')],
        now: now,
        workbookId: workbookId,
      );

  /// Returns a copy with the given fields replaced. [updatedAtMs] is auto-
  /// bumped when any content field is replaced; pass [updatedAtMs] explicitly
  /// to override (e.g. when downloading from Drive and using the remote
  /// timestamp verbatim).
  Workbook copyWith({
    String? name,
    List<Worksheet>? worksheets,
    List<MathChannel>? mathChannels,
    List<MathConstant>? constants,
    List<OverlayLayout>? overlayLayouts,
    int? updatedAtMs,
    DateTime? now,
  }) {
    final mutated = name != null ||
        worksheets != null ||
        mathChannels != null ||
        constants != null ||
        overlayLayouts != null;
    final newUpdated = updatedAtMs ??
        (mutated
            ? (now ?? DateTime.now().toUtc()).millisecondsSinceEpoch
            : this.updatedAtMs);
    return Workbook(
      workbookId: workbookId,
      name: name ?? this.name,
      worksheets: worksheets ?? this.worksheets,
      mathChannels: mathChannels ?? this.mathChannels,
      constants: constants ?? this.constants,
      overlayLayouts: overlayLayouts ?? this.overlayLayouts,
      createdAtMs: createdAtMs,
      updatedAtMs: newUpdated,
      workbookVersion: workbookVersion,
    );
  }

  /// Serializes to a JSON-compatible map for Drive upload and local cache.
  Map<String, dynamic> toJson() => {
        'workbook_id': workbookId,
        'name': name,
        'worksheets': worksheets.map((w) => w.toJson()).toList(),
        'math_channels': mathChannels.map((c) => c.toJson()).toList(),
        'constants': constants.map((c) => c.toJson()).toList(),
        if (overlayLayouts.isNotEmpty)
          'overlay_layouts': overlayLayouts.map((l) => l.toJson()).toList(),
        'created_at_ms': createdAtMs,
        'updated_at_ms': updatedAtMs,
        'workbook_version': workbookVersion,
      };

  /// Deserializes from a JSON map. Throws [UnsupportedWorkbookVersionException]
  /// when `workbook_version` exceeds [supportedVersion]. Missing optional
  /// fields fall back to sensible defaults so older files load cleanly.
  factory Workbook.fromJson(Map<String, dynamic> json) {
    final version = (json['workbook_version'] as int?) ?? 1;
    if (version > _kSupportedWorkbookVersion) {
      throw UnsupportedWorkbookVersionException(
        found: version,
        supported: _kSupportedWorkbookVersion,
      );
    }
    try {
      return Workbook(
        workbookId: json['workbook_id'] as String,
        name: json['name'] as String,
        worksheets: (json['worksheets'] as List<dynamic>? ?? [])
            .map((w) => Worksheet.fromJson(w as Map<String, dynamic>))
            .toList(),
        mathChannels: (json['math_channels'] as List<dynamic>? ?? [])
            .map((c) => MathChannel.fromJson(c as Map<String, dynamic>))
            .toList(),
        constants: (json['constants'] as List<dynamic>? ?? [])
            .map((c) => MathConstant.fromJson(c as Map<String, dynamic>))
            .toList(),
        overlayLayouts: (json['overlay_layouts'] as List<dynamic>? ?? [])
            .map((l) => OverlayLayout.fromJson(l as Map<String, dynamic>))
            .toList(),
        createdAtMs: json['created_at_ms'] as int,
        updatedAtMs: json['updated_at_ms'] as int,
        workbookVersion: version,
      );
    } on UnsupportedWorkbookVersionException {
      rethrow;
    } catch (e) {
      throw WorkbookParseException('Malformed workbook JSON: $e');
    }
  }
}
