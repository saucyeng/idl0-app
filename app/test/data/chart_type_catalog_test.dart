import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/worksheet.dart';
import 'package:idl0/ui/tabs/analyze/chart_type_catalog.dart';

void main() {
  test('kChartTypeCatalog — every addable type — has an info entry', () {
    // Arrange / Act / Assert
    for (final type in kAddableChartTypes) {
      expect(
        kChartTypeCatalog.containsKey(type),
        isTrue,
        reason: 'no catalog entry for $type',
      );
    }
  });

  test('kAddableChartTypes — includes scatter', () {
    // Arrange / Act / Assert
    expect(kAddableChartTypes, contains(ChartType.scatter));
  });
}
