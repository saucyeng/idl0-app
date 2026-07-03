import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/ui/tabs/analyze/per_lap_table.dart';

void main() {
  test('buildPerLapTable — one row per lap, metric templates, delta column', () {
    // Arrange / Act
    final t = buildPerLapTable(
      sessionId: 's1',
      lapCount: 3,
      metricChannels: ['Fork', 'Shock'],
    );

    // Assert
    expect(t.rows.length, 3);
    expect(t.rows.first.context, isNotNull);
    expect(t.rows.first.context!.sessionId, 's1');
    // A metric column carries a max([Fork]) template.
    expect(t.columns.any((c) => c.template == 'max([Fork])'), isTrue);
    // The delta column references the first metric's whole column.
    expect(
      t.columns.any((c) => c.template == '{fork_max} - min({fork_max[]})'),
      isTrue,
    );
    // Each row's first cell is the lap-number literal.
    expect(t.cells.first.first.literal, 1.0);
  });

  test('buildPerLapTable — no metrics yields just the lap label column', () {
    // Arrange / Act
    final t = buildPerLapTable(sessionId: 's', lapCount: 2, metricChannels: []);

    // Assert — only the "lap" label column, no delta column.
    expect(t.columns.length, 1);
    expect(t.columns.single.name, 'lap');
  });
}
