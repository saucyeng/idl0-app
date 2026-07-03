import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idl0/data/exceptions.dart';
import 'package:idl0/transport/wifi_network_binder.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const commands = MethodChannel('idl0/wifi_network');
  const events = EventChannel('idl0/wifi_network_events');

  late List<MethodCall> calls;
  late StreamController<Map<dynamic, dynamic>> plugin;

  setUp(() {
    calls = [];
    plugin = StreamController<Map<dynamic, dynamic>>.broadcast();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(commands, (call) async {
      calls.add(call);
      return null;
    });
    messenger.setMockStreamHandler(
      events,
      MockStreamHandler.inline(
        onListen: (args, sink) {
          plugin.stream.listen(sink.success, onDone: sink.endOfStream);
        },
      ),
    );
  });

  tearDown(() async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(commands, null);
    messenger.setMockStreamHandler(events, null);
    await plugin.close();
  });

  WifiNetworkBinder makeBinder({Duration? budget}) => WifiNetworkBinder(
        isAndroidPlatform: true,
        requestBudget: budget ?? const Duration(seconds: 45),
      );

  test('bind — available event with port — resolves and sets proxy base URL',
      () async {
    // Arrange
    final binder = makeBinder();
    addTearDown(binder.dispose);

    // Act
    final bound = binder.bind('IDL0-A3F2', 'pw');
    await Future<void>.delayed(Duration.zero); // let request reach the mock
    plugin.add({'event': 'available', 'ssid': 'IDL0-A3F2', 'port': 4242});
    await bound;

    // Assert
    expect(calls.single.method, equals('request'));
    expect(binder.deviceBaseUrl, equals('http://127.0.0.1:4242'));
  });

  test('bind — unavailable event — throws DeviceUnreachableException',
      () async {
    // Arrange
    final binder = makeBinder();
    addTearDown(binder.dispose);

    // Act
    final bound = binder.bind('IDL0-A3F2', 'pw');
    await Future<void>.delayed(Duration.zero);
    plugin.add({'event': 'unavailable', 'ssid': 'IDL0-A3F2'});

    // Assert
    await expectLater(bound, throwsA(isA<DeviceUnreachableException>()));
    expect(binder.deviceBaseUrl, equals('http://192.168.4.1'));
  });

  test('bind — no decisive event within budget — releases and throws',
      () async {
    // Arrange
    final binder = makeBinder(budget: const Duration(milliseconds: 50));
    addTearDown(binder.dispose);

    // Act / Assert
    await expectLater(
      binder.bind('IDL0-A3F2', 'pw'),
      throwsA(isA<DeviceUnreachableException>()),
    );
    expect(
      calls.map((c) => c.method),
      containsAllInOrder(['request', 'release']),
    );
  });

  test('bind — event for a different ssid — ignored, budget still applies',
      () async {
    // Arrange
    final binder = makeBinder(budget: const Duration(milliseconds: 50));
    addTearDown(binder.dispose);

    // Act
    final bound = binder.bind('IDL0-A3F2', 'pw');
    await Future<void>.delayed(Duration.zero);
    plugin.add({'event': 'available', 'ssid': 'IDL0-FE1B', 'port': 1111});

    // Assert — the foreign-device event must not satisfy the bind.
    await expectLater(bound, throwsA(isA<DeviceUnreachableException>()));
  });

  test('lost event after bind — clears the proxy base URL', () async {
    // Arrange
    final binder = makeBinder();
    addTearDown(binder.dispose);
    final bound = binder.bind('IDL0-A3F2', 'pw');
    await Future<void>.delayed(Duration.zero);
    plugin.add({'event': 'available', 'ssid': 'IDL0-A3F2', 'port': 4242});
    await bound;

    // Act
    plugin.add({'event': 'lost', 'ssid': 'IDL0-A3F2'});
    await Future<void>.delayed(Duration.zero);

    // Assert
    expect(binder.deviceBaseUrl, equals('http://192.168.4.1'));
  });
}
