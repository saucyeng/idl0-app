import 'dart:io' show Directory, Platform;

import 'package:path_provider/path_provider.dart';

/// Returns the base directory under which the `sessions/` folder lives.
///
/// On Android we use `getExternalStorageDirectory()` so files land at
/// `/storage/emulated/0/Android/data/<pkg>/files/sessions` and are
/// browseable from the system Files app (the documents directory is
/// app-private on Android 10+ and therefore invisible to the user).
/// On every other platform `getExternalStorageDirectory()` is not
/// implemented — it throws `UnsupportedError` on Windows/macOS/Linux
/// and returns null on iOS — so we fall back to
/// `getApplicationDocumentsDirectory()`, which is supported everywhere.
///
/// Callers always join `'sessions'` onto the returned path; this helper
/// returns the parent so the same shape works on every platform.
Future<Directory> getSessionsBaseDir() async {
  if (Platform.isAndroid) {
    final ext = await getExternalStorageDirectory();
    if (ext != null) return ext;
  }
  return getApplicationDocumentsDirectory();
}
