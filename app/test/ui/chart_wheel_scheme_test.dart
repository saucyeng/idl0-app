import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/ui/widgets/chart_action.dart';

void main() {
  group('wheelModeFor — desktop chart wheel scheme', () {
    test('Ctrl held — zoom', () {
      // Arrange / Act
      final mode = wheelModeFor(ctrl: true, shift: false);

      // Assert
      expect(mode, equals(WheelMode.zoom));
    });

    test('Shift held — pan', () {
      // Arrange / Act
      final mode = wheelModeFor(ctrl: false, shift: true);

      // Assert
      expect(mode, equals(WheelMode.pan));
    });

    test('no modifier — none, so the wheel scrolls the worksheet list', () {
      // Arrange / Act
      final mode = wheelModeFor(ctrl: false, shift: false);

      // Assert
      expect(mode, equals(WheelMode.none));
    });

    test('Ctrl+Shift both held — Ctrl wins (zoom)', () {
      // Arrange / Act
      final mode = wheelModeFor(ctrl: true, shift: true);

      // Assert
      expect(mode, equals(WheelMode.zoom));
    });
  });
}
