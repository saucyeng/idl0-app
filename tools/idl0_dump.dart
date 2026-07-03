/// IDL0 binary log inspector.
///
/// Usage: dart run tools/idl0_dump.dart [options] <file>
///
/// Options:
///   --all           Print all records (default: first 20)
///   --records N     Print first N matching records
///   --type TYPE     Filter by type: imu, gps, channel, end
///   --summary       Print summary statistics only, no records
///
/// Supports both v1 (ESPL) and v2 (IDL0) log formats.
/// Unknown record types are skipped via payload_len — forward compatible.
/// Exits with code 1 on invalid magic or file truncation.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

// ── entry point ───────────────────────────────────────────────────────────────

void main(List<String> argv) {
  final args = _parseArgs(argv);

  final file = File(args.path);
  if (!file.existsSync()) {
    stderr.writeln('Error: file not found: ${args.path}');
    exit(1);
  }

  final bytes = file.readAsBytesSync();
  if (bytes.length < 4) {
    stderr.writeln('Error: file too short (${bytes.length} bytes)');
    exit(1);
  }

  final magic = ascii.decode(bytes.sublist(0, 4), allowInvalid: true);
  switch (magic) {
    case 'ESPL':
      _dumpV1(bytes, args);
    case 'IDL0':
      _dumpV2(bytes, args);
    default:
      stderr.writeln('Error: invalid magic bytes "$magic" — expected ESPL or IDL0');
      exit(1);
  }
}

// ── v1 (ESPL) ────────────────────────────────────────────────────────────────

void _dumpV1(Uint8List bytes, _Args args) {
  if (bytes.length < 128) {
    stderr.writeln('Error: v1 header truncated (need 128 bytes, have ${bytes.length})');
    exit(1);
  }

  if (!args.summaryOnly) {
    print('Format: v1 (ESPL)');
    print('File:   ${args.path}');
    print('Size:   ${_fmtSize(bytes.length)}');
    print('---');
  }

  final reader = _ByteReader(bytes);
  reader.skip(128);

  int imuCount = 0, gpsCount = 0, endCount = 0, unknownCount = 0;
  int printed = 0;
  bool truncated = false;
  bool cleanEnd = false;

  while (reader.hasMore) {
    final offset = reader.position;
    try {
      final type = reader.u8();
      final payloadLen = reader.u16();

      final isImu = type == 0x01 || type == 0x03 || type == 0x04;
      final isGps = type == 0x02;
      final isEnd = type == 0xFF;

      if (isImu) {
        imuCount++;
      } else if (isGps) {
        gpsCount++;
      } else if (isEnd) {
        endCount++;
      } else {
        unknownCount++;
      }

      final category = isImu ? 'imu' : isGps ? 'gps' : isEnd ? 'end' : 'unknown';
      final canPrint = _shouldShow(args, category, printed);

      if (isImu) {
        final label = type == 0x01 ? '1' : type == 0x03 ? '2' : '3';
        if (payloadLen < 32) {
          reader.skip(payloadLen);
          if (canPrint) {
            print('[+0x${_hex8(offset)}] IMU$label  (undersized payload $payloadLen — skipped)');
            printed++;
          }
          continue;
        }
        final tsUs = reader.i64();
        final ax = reader.f32(), ay = reader.f32(), az = reader.f32();
        final gx = reader.f32(), gy = reader.f32(), gz = reader.f32();
        if (payloadLen > 32) reader.skip(payloadLen - 32);
        if (canPrint) {
          print('[+0x${_hex8(offset)}] IMU$label  ts=${tsUs}µs  '
              'ax=${_f3(ax)}g ay=${_f3(ay)}g az=${_f3(az)}g  '
              'gx=${_f3(gx)}°/s gy=${_f3(gy)}°/s gz=${_f3(gz)}°/s');
          printed++;
        }
      } else if (isGps) {
        if (payloadLen < 8) {
          reader.skip(payloadLen);
          if (canPrint) {
            print('[+0x${_hex8(offset)}] GPS  (undersized payload $payloadLen — skipped)');
            printed++;
          }
          continue;
        }
        final tsMs = reader.i64();
        final nmeaBytes = reader.bytes(payloadLen - 8);
        final nmea = ascii
            .decode(nmeaBytes, allowInvalid: true)
            .replaceAll('\r', '')
            .replaceAll('\n', ' | ');
        if (canPrint) {
          print('[+0x${_hex8(offset)}] GPS   ts=${tsMs}ms  $nmea');
          printed++;
        }
      } else if (isEnd) {
        reader.skip(payloadLen);
        cleanEnd = true;
        if (canPrint) {
          print('[+0x${_hex8(offset)}] END');
          printed++;
        }
        break;
      } else {
        stderr.writeln('Warning: [+0x${_hex8(offset)}] unknown type 0x${type.toRadixString(16).padLeft(2, '0')} '
            'payload_len=$payloadLen — skipping');
        reader.skip(payloadLen);
      }
    } on _TruncatedException catch (e) {
      stderr.writeln('Warning: $e');
      truncated = true;
      break;
    }
  }

  final total = imuCount + gpsCount + endCount + unknownCount;

  if (args.summaryOnly) {
    print('Format:  v1 (ESPL)');
    print('File:    ${args.path}');
    print('Size:    ${_fmtSize(bytes.length)}');
    print('IMU:     ${_comma(imuCount)}');
    print('GPS:     ${_comma(gpsCount)}');
    print('END:     $endCount${cleanEnd ? '' : ' (no SESSION_END — may be incomplete)'}');
    if (unknownCount > 0) print('Unknown: ${_comma(unknownCount)} (skipped)');
    if (truncated) print('WARNING: file truncated — counts are partial');
  } else if (!args.showAll && args.maxRecords != null && printed >= args.maxRecords!) {
    print('--- showing first ${args.maxRecords} of $total records (use --all to see all) ---');
  }

  if (truncated) exit(1);
}

// ── v2 (IDL0) ────────────────────────────────────────────────────────────────

class _RegEntry {
  final int id, dataType, rateHz;
  final String name, units;
  const _RegEntry(this.id, this.dataType, this.rateHz, this.name, this.units);
}

void _dumpV2(Uint8List bytes, _Args args) {
  final reader = _ByteReader(bytes);

  // Parse header.
  late String sessionId, deviceId, configCrc;
  late int sessionStartMs, imuMask, imuRateHz, gpsRateHz;
  late List<_RegEntry> registry;

  try {
    reader.skip(4); // magic
    final schemaVersion = reader.u8();
    if (schemaVersion > 2) {
      stderr.writeln('Error: unsupported schema version $schemaVersion (max supported: 2)');
      exit(1);
    }
    final uuidBytes = reader.bytes(16);
    sessionId = uuidBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final devBytes = reader.bytes(8);
    deviceId = devBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    sessionStartMs = reader.i64();
    configCrc = reader.u32().toRadixString(16).padLeft(8, '0');
    imuMask = reader.u32();
    reader.u8(); // imu_count (informational)
    imuRateHz = reader.u16();
    gpsRateHz = reader.u8();
    final regCount = reader.u8();
    registry = [];
    for (int i = 0; i < regCount; i++) {
      final id = reader.u8();
      final dt = reader.u8();
      final rate = reader.u16();
      final name = _nullStr(reader.bytes(20));
      final units = _nullStr(reader.bytes(8));
      registry.add(_RegEntry(id, dt, rate, name, units));
    }
    final markerBytes = reader.bytes(4);
    final marker = ByteData.sublistView(markerBytes).getUint32(0, Endian.little);
    if (marker != 0xDEADBEEF) {
      stderr.writeln('Error: v2 header end marker corrupt (got 0x${marker.toRadixString(16)})');
      exit(1);
    }
  } on _TruncatedException catch (e) {
    stderr.writeln('Error: v2 header truncated — $e');
    exit(1);
  }

  if (!args.summaryOnly) {
    print('Format:   v2 (IDL0)');
    print('File:     ${args.path}');
    print('Size:     ${_fmtSize(bytes.length)}');
    print('Session:  $sessionId');
    print('Device:   $deviceId');
    print('Start:    ${_fmtUtc(sessionStartMs)}');
    print('Config:   $configCrc (CRC32)');
    print('IMU mask: 0x${imuMask.toRadixString(16).padLeft(8, '0')}');
    print('IMU rate: ${imuRateHz}Hz   GPS rate: ${gpsRateHz}Hz');
    if (registry.isEmpty) {
      print('Registry: (empty)');
    } else {
      print('Registry: ${registry.length} channel${registry.length == 1 ? '' : 's'}');
      for (final e in registry) {
        final rate = e.rateHz == 0 ? 'event' : '${e.rateHz}Hz';
        print('  [${e.id}] ${e.name.padRight(20)} ${_dtName(e.dataType).padRight(4)}  '
            '${rate.padRight(8)}  ${e.units}');
      }
    }
    print('---');
  }

  final regById = {for (final e in registry) e.id: e};

  // Pre-compute which axes are enabled per IMU index.
  final axisEnabled = List.generate(
      3, (i) => List.generate(6, (a) => (imuMask >> (i * 6 + a)) & 1 == 1));
  const axisNames = ['AccelX', 'AccelY', 'AccelZ', 'GyroX', 'GyroY', 'GyroZ'];

  int imuCount = 0, gpsCount = 0, chCount = 0, endCount = 0, unknownCount = 0;
  int printed = 0;
  bool truncated = false;
  bool cleanEnd = false;

  while (reader.hasMore) {
    final offset = reader.position;
    try {
      final type = reader.u8();
      final payloadLen = reader.u16();

      final isImu = type == 0x01;
      final isGps = type == 0x02;
      final isCh = type == 0x03;
      final isEnd = type == 0xFF;

      if (isImu) {
        imuCount++;
      } else if (isGps) {
        gpsCount++;
      } else if (isCh) {
        chCount++;
      } else if (isEnd) {
        endCount++;
      } else {
        unknownCount++;
      }

      final category =
          isImu ? 'imu' : isGps ? 'gps' : isCh ? 'channel' : isEnd ? 'end' : 'unknown';
      final canPrint = _shouldShow(args, category, printed);

      if (isImu) {
        final payloadStart = reader.position;
        final imuIndex = reader.u8();
        final sampleCounter = reader.u32();
        final parts = <String>[];
        if (imuIndex < 3) {
          for (int axis = 0; axis < 6; axis++) {
            if (axisEnabled[imuIndex][axis]) {
              parts.add('${axisNames[axis]}=${reader.i16()}');
            }
          }
        }
        final consumed = reader.position - payloadStart;
        if (consumed < payloadLen) reader.skip(payloadLen - consumed);
        if (canPrint) {
          print('[+0x${_hex8(offset)}] IMU   idx=$imuIndex  cnt=$sampleCounter  '
              '${parts.join('  ')}');
          printed++;
        }
      } else if (isGps) {
        final payloadStart = reader.position;
        final epochMs = reader.i64();
        reader.u32(); // sample_counter
        final lat = reader.i32();
        final lon = reader.i32();
        final alt = reader.i16();
        final spd = reader.u16();
        final hdg = reader.u16();
        final fix = reader.u8();
        final sats = reader.u8();
        final consumed = reader.position - payloadStart;
        if (consumed < payloadLen) reader.skip(payloadLen - consumed);
        if (canPrint) {
          print('[+0x${_hex8(offset)}] GPS   epoch=${epochMs}ms  '
              'lat=${(lat / 1e7).toStringAsFixed(7)}°  '
              'lon=${(lon / 1e7).toStringAsFixed(7)}°  '
              'alt=${(alt / 10.0).toStringAsFixed(1)}m  '
              'spd=${(spd / 100.0).toStringAsFixed(2)}km/h  '
              'hdg=${(hdg / 100.0).toStringAsFixed(2)}°  '
              'fix=$fix  sats=$sats');
          printed++;
        }
      } else if (isCh) {
        final payloadStart = reader.position;
        final channelId = reader.u8();
        final tsUs = reader.i64();
        final entry = regById[channelId];
        double? value;
        if (entry != null && entry.dataType < 8) {
          value = _readTyped(reader, entry.dataType);
        }
        final consumed = reader.position - payloadStart;
        if (consumed < payloadLen) reader.skip(payloadLen - consumed);
        if (canPrint) {
          final name = entry?.name ?? '?';
          final units = entry?.units ?? '';
          final valStr = value == null
              ? '(unknown data type ${entry?.dataType})'
              : entry!.dataType >= 6
                  ? value.toStringAsFixed(4)
                  : value.toStringAsFixed(0);
          print('[+0x${_hex8(offset)}] CH    id=$channelId ($name)  ts=${tsUs}µs  '
              'val=$valStr${units.isNotEmpty ? ' $units' : ''}');
          printed++;
        }
      } else if (isEnd) {
        reader.skip(payloadLen);
        cleanEnd = true;
        if (canPrint) {
          print('[+0x${_hex8(offset)}] END');
          printed++;
        }
        break;
      } else {
        stderr.writeln('Warning: [+0x${_hex8(offset)}] unknown type 0x${type.toRadixString(16).padLeft(2, '0')} '
            'payload_len=$payloadLen — skipping');
        reader.skip(payloadLen);
      }
    } on _TruncatedException catch (e) {
      stderr.writeln('Warning: $e');
      truncated = true;
      break;
    }
  }

  final total = imuCount + gpsCount + chCount + endCount + unknownCount;

  if (args.summaryOnly) {
    print('Format:   v2 (IDL0)');
    print('File:     ${args.path}');
    print('Size:     ${_fmtSize(bytes.length)}');
    print('Session:  $sessionId');
    print('Device:   $deviceId');
    print('Start:    ${_fmtUtc(sessionStartMs)}');
    print('---');
    print('IMU:     ${_comma(imuCount)}');
    print('GPS:     ${_comma(gpsCount)}');
    print('CHANNEL: ${_comma(chCount)}');
    print('END:     $endCount${cleanEnd ? '' : ' (no SESSION_END — may be incomplete)'}');
    if (unknownCount > 0) print('Unknown: ${_comma(unknownCount)} (skipped)');
    if (truncated) print('WARNING: file truncated — counts are partial');
  } else if (!args.showAll && args.maxRecords != null && printed >= args.maxRecords!) {
    print('--- showing first ${args.maxRecords} of $total records (use --all to see all) ---');
  }

  if (truncated) exit(1);
}

// ── helpers ───────────────────────────────────────────────────────────────────

bool _shouldShow(_Args args, String category, int printed) {
  if (args.summaryOnly) return false;
  if (args.typeFilter != null && args.typeFilter != category) return false;
  if (args.showAll) return true;
  return printed < (args.maxRecords ?? 20);
}

String _nullStr(Uint8List bytes) {
  final end = bytes.indexOf(0);
  return ascii.decode(end >= 0 ? bytes.sublist(0, end) : bytes, allowInvalid: true);
}

String _dtName(int dt) {
  const n = ['u8', 'u16', 'u32', 'i8', 'i16', 'i32', 'f32', 'f64'];
  return dt < n.length ? n[dt] : 'dt$dt';
}

double _readTyped(_ByteReader r, int dataType) => switch (dataType) {
      0 => r.u8().toDouble(),
      1 => r.u16().toDouble(),
      2 => r.u32().toDouble(),
      3 => r.i8().toDouble(),
      4 => r.i16().toDouble(),
      5 => r.i32().toDouble(),
      6 => r.f32(),
      7 => r.f64(),
      _ => throw StateError('Unreachable: unknown data type $dataType'),
    };

String _hex8(int v) => v.toRadixString(16).padLeft(8, '0');
String _f3(double v) => v.toStringAsFixed(3);

String _fmtSize(int n) {
  if (n < 1024) return '$n B';
  if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
  return '${(n / (1024 * 1024)).toStringAsFixed(2)} MB';
}

String _comma(int n) {
  final s = n.toString();
  if (s.length <= 3) return s;
  final buf = StringBuffer();
  for (int i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
    buf.write(s[i]);
  }
  return buf.toString();
}

String _fmtUtc(int ms) {
  final dt = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
  return '${dt.year.toString().padLeft(4, '0')}-'
      '${dt.month.toString().padLeft(2, '0')}-'
      '${dt.day.toString().padLeft(2, '0')} '
      '${dt.hour.toString().padLeft(2, '0')}:'
      '${dt.minute.toString().padLeft(2, '0')}:'
      '${dt.second.toString().padLeft(2, '0')} UTC';
}

// ── args ──────────────────────────────────────────────────────────────────────

class _Args {
  final String path;
  final bool showAll;
  final int? maxRecords;
  final String? typeFilter;
  final bool summaryOnly;

  const _Args({
    required this.path,
    required this.showAll,
    this.maxRecords,
    this.typeFilter,
    required this.summaryOnly,
  });
}

_Args _parseArgs(List<String> argv) {
  bool showAll = false;
  int? maxRecords;
  String? typeFilter;
  bool summaryOnly = false;
  String? path;

  for (int i = 0; i < argv.length; i++) {
    switch (argv[i]) {
      case '--all':
        showAll = true;
      case '--records':
        if (i + 1 >= argv.length) _usage('--records requires a value');
        final n = int.tryParse(argv[++i]);
        if (n == null || n < 0) _usage('--records requires a non-negative integer');
        maxRecords = n;
      case '--type':
        if (i + 1 >= argv.length) _usage('--type requires a value');
        typeFilter = argv[++i].toLowerCase();
        if (!{'imu', 'gps', 'channel', 'end'}.contains(typeFilter)) {
          _usage('--type must be one of: imu, gps, channel, end');
        }
      case '--summary':
        summaryOnly = true;
      default:
        if (argv[i].startsWith('--')) _usage('Unknown flag: ${argv[i]}');
        if (path != null) _usage('Unexpected argument: ${argv[i]}');
        path = argv[i];
    }
  }

  if (path == null) _usage('No file specified');
  return _Args(
    path: path,
    showAll: showAll,
    maxRecords: maxRecords,
    typeFilter: typeFilter,
    summaryOnly: summaryOnly,
  );
}

Never _usage(String msg) {
  stderr.writeln('Error: $msg');
  stderr.writeln(
      'Usage: dart run tools/idl0_dump.dart [--all] [--records N] [--type imu|gps|channel|end] [--summary] <file>');
  exit(1);
}

// ── byte reader ───────────────────────────────────────────────────────────────

class _ByteReader {
  final ByteData _data;
  int _pos = 0;

  _ByteReader(Uint8List bytes)
      : _data =
            ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.lengthInBytes);

  int get position => _pos;
  int get remaining => _data.lengthInBytes - _pos;
  bool get hasMore => _pos < _data.lengthInBytes;

  void _require(int n) {
    if (remaining < n) throw _TruncatedException(_pos, n, remaining);
  }

  int u8() {
    _require(1);
    return _data.getUint8(_pos++);
  }

  int u16() {
    _require(2);
    final v = _data.getUint16(_pos, Endian.little);
    _pos += 2;
    return v;
  }

  int u32() {
    _require(4);
    final v = _data.getUint32(_pos, Endian.little);
    _pos += 4;
    return v;
  }

  int i8() {
    _require(1);
    return _data.getInt8(_pos++);
  }

  int i16() {
    _require(2);
    final v = _data.getInt16(_pos, Endian.little);
    _pos += 2;
    return v;
  }

  int i32() {
    _require(4);
    final v = _data.getInt32(_pos, Endian.little);
    _pos += 4;
    return v;
  }

  int i64() {
    _require(8);
    final v = _data.getInt64(_pos, Endian.little);
    _pos += 8;
    return v;
  }

  double f32() {
    _require(4);
    final v = _data.getFloat32(_pos, Endian.little);
    _pos += 4;
    return v;
  }

  double f64() {
    _require(8);
    final v = _data.getFloat64(_pos, Endian.little);
    _pos += 8;
    return v;
  }

  Uint8List bytes(int n) {
    _require(n);
    final v = Uint8List.view(_data.buffer, _data.offsetInBytes + _pos, n);
    _pos += n;
    return v;
  }

  void skip(int n) {
    _require(n);
    _pos += n;
  }
}

class _TruncatedException implements Exception {
  final String _msg;

  _TruncatedException(int offset, int need, int have)
      : _msg = 'Unexpected end at +0x${offset.toRadixString(16).padLeft(8, '0')} '
            '(need $need bytes, have $have)';

  @override
  String toString() => _msg;
}
