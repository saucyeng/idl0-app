import 'package:idl0/data/workbook.dart';
import 'package:idl0/transport/drive_service.dart';

/// No-op implementations of the [DriveService] Workbook operations, for test
/// fakes that `implements DriveService` but do not exercise the Workbook
/// surface (added when commit 89a8675 introduced the Workbook methods).
///
/// Mix in alongside `implements DriveService`:
///
/// ```dart
/// class _FakeDriveService with FakeDriveWorkbookOps implements DriveService {
///   // ... only the methods this test exercises ...
/// }
/// ```
///
/// A fake that *does* exercise Workbooks should override the relevant method
/// directly (the class member wins over the mixin's).
mixin FakeDriveWorkbookOps {
  /// No workbooks on Drive.
  Future<List<DriveWorkbookFile>> listWorkbooks() async => const [];

  /// Not exercised — throws if a test unexpectedly downloads a workbook.
  Future<Workbook> downloadWorkbook(String workbookId) =>
      throw UnimplementedError();

  /// Swallowed — Workbook uploads are not asserted by these fakes.
  Future<void> uploadWorkbook(Workbook workbook) async {}

  /// Swallowed — Workbook deletes are not asserted by these fakes.
  Future<void> deleteWorkbook(String workbookId) async {}
}
