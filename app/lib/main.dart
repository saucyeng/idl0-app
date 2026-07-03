import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'data/database_paths.dart';
import 'src/rust/frb_generated.dart';
import 'ui/app.dart';

/// Application entry point.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Quiet flutter_blue_plus's native Android logging, which emits a
  // D/[FBP-Android] onCharacteristicChanged line on every status notify
  // (~1 Hz) and clogs the monitor. `error` keeps genuine BLE failures
  // visible; raise to LogLevel.verbose when actively debugging BLE.
  //
  // Android-only: this is a platform-channel call and flutter_blue_plus has no
  // native implementation of it on desktop (Windows/Linux), where it throws
  // UnsupportedError. The D/[FBP-Android] noise it suppresses is Android-only
  // regardless.
  if (Platform.isAndroid) {
    await FlutterBluePlus.setLogLevel(LogLevel.error);
  }
  await RustLib.init();
  // sqflite uses FFI on desktop — mobile uses the platform plugin directly.
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
  // Park SQLite databases under the OS app-support directory instead of
  // the ffi default `<cwd>/.dart_tool/sqflite_common_ffi/databases/`,
  // which `flutter clean` wipes along with the build tree. Also migrates
  // any legacy DBs that already sit in the old location.
  await installStableDatabasePath();
  runApp(const ProviderScope(child: IDL0App()));
}
