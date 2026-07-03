import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/worksheet.dart';

void main() {
  test('ChartSlot — gps colour fields round-trip through JSON', () {
    // Arrange
    final slot = ChartSlot(
      chartType: ChartType.gpsMap,
      gpsColorChannelId: 'IMU0_AccelZ',
      gpsColorMin: -2.0,
      gpsColorMax: 8.5,
    );

    // Act
    final restored = ChartSlot.fromJson(slot.toJson());

    // Assert
    expect(restored.gpsColorChannelId, equals('IMU0_AccelZ'));
    expect(restored.gpsColorMin, equals(-2.0));
    expect(restored.gpsColorMax, equals(8.5));
  });

  test('ChartSlot — gps colour fields absent on a solid-mode gps slot', () {
    // Arrange
    final slot = ChartSlot(chartType: ChartType.gpsMap);

    // Act
    final json = slot.toJson();

    // Assert — not emitted when null, defaults round-trip to null.
    expect(json.containsKey('gpsColorChannelId'), isFalse);
    expect(ChartSlot.fromJson(json).gpsColorChannelId, isNull);
  });

  test('ChartSlot — gps colour fields not emitted for non-gps slots', () {
    // Arrange — channelId set but type is time-series; must not serialise.
    final slot = ChartSlot(
      chartType: ChartType.timeSeries,
      gpsColorChannelId: 'IMU0_AccelZ',
    );

    // Act
    final json = slot.toJson();

    // Assert
    expect(json.containsKey('gpsColorChannelId'), isFalse);
  });

  test('ChartSlot — copyWith clears gpsColorChannelId via explicit null', () {
    // Arrange
    final slot = ChartSlot(
      chartType: ChartType.gpsMap,
      gpsColorChannelId: 'Speed',
    );

    // Act
    final cleared = slot.copyWith(gpsColorChannelId: null);

    // Assert
    expect(cleared.gpsColorChannelId, isNull);
  });
}
