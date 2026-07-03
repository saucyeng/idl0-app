import 'dart:async';

import 'package:google_fonts/google_fonts.dart';

/// Suite-wide test setup.
///
/// Disables runtime font fetching so [GoogleFonts] resolves to local fallbacks
/// in offline test environments instead of dispatching HTTP requests that fail
/// the test harness with unhandled async exceptions.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  GoogleFonts.config.allowRuntimeFetching = false;
  await testMain();
}
