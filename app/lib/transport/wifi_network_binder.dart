import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';

import '../data/exceptions.dart';

/// Dart side of the `idl0/wifi_network` plugin (SPEC §6.2).
///
/// The plugin is a pure sensor/actuator: `request`/`release` commands plus
/// an event stream (`available` / `lost` / `unavailable`). This class keeps
/// the legacy `bind()`-future surface as a compatibility shim until the P3
/// reconciler consumes events directly: [bind] issues `request` and awaits
/// the first decisive event within a [requestBudget] budget. All timeout
/// policy lives HERE — the platform side holds no timers, so the system
/// approval dialog is never dismissed by our side.
///
/// On `available`, the plugin reports the loopback-proxy port and
/// [deviceBaseUrl] becomes `http://127.0.0.1:<port>` — only proxied sockets
/// route to the AP; the rest of the app keeps internet. On every other
/// platform (and Android < 29, where the event carries a null port)
/// [deviceBaseUrl] is the direct `http://192.168.4.1`.
class WifiNetworkBinder {
  static const _channel = MethodChannel('idl0/wifi_network');
  static const _events = EventChannel('idl0/wifi_network_events');

  /// How long [bind] waits for a decisive plugin event. Generous because
  /// the budget covers the user reading the system approval dialog on
  /// first connect; rejection fires `unavailable` promptly, so the full
  /// wait is only ever spent when nothing is answering.
  final Duration requestBudget;

  /// Platform gate; production default is `Platform.isAndroid`. Tests pass
  /// `true` to exercise the channel paths on the host.
  final bool isAndroidPlatform;

  /// Broadcast of plugin events; created on first use.
  Stream<Map<dynamic, dynamic>>? _eventStream;
  StreamSubscription<Map<dynamic, dynamic>>? _trackerSub;

  /// Loopback proxy port from the last `available` event, or null when
  /// unlinked / direct mode.
  int? _proxyPort;

  /// Creates a [WifiNetworkBinder]. [requestBudget] and [isAndroidPlatform]
  /// are injectable for tests.
  WifiNetworkBinder({
    this.requestBudget = const Duration(seconds: 45),
    bool? isAndroidPlatform,
  }) : isAndroidPlatform = isAndroidPlatform ?? Platform.isAndroid;

  /// Base URL for all device HTTP traffic. `http://127.0.0.1:<port>` while
  /// an Android proxy link is up, `http://192.168.4.1` otherwise.
  String get deviceBaseUrl {
    final port = _proxyPort;
    if (port == null) return 'http://192.168.4.1';
    return 'http://127.0.0.1:$port';
  }

  Stream<Map<dynamic, dynamic>> _ensureEvents() {
    final existing = _eventStream;
    if (existing != null) return existing;
    final stream =
        _events.receiveBroadcastStream().cast<Map<dynamic, dynamic>>();
    _eventStream = stream;
    // Persistent tracker: keeps [_proxyPort] honest across lost/available
    // events that arrive outside a bind() await (e.g. Android reaping the
    // network mid-session). P3 replaces this with the reconciler.
    _trackerSub = stream.listen((event) {
      switch (event['event']) {
        case 'available':
          _proxyPort = event['port'] as int?;
        case 'lost':
        case 'unavailable':
          _proxyPort = null;
      }
    });
    return stream;
  }

  /// Requests the device AP and waits for the link to come up.
  ///
  /// No-op on non-Android platforms (the user joins the AP manually and
  /// [deviceBaseUrl] is already direct).
  ///
  /// Throws [DeviceUnreachableException] if the plugin reports
  /// `unavailable` (user denied / system rejected) or nothing decisive
  /// arrives within [requestBudget].
  Future<void> bind(String ssid, String password) async {
    if (!isAndroidPlatform) return;
    final events = _ensureEvents();
    final decisive = events.firstWhere(
      (e) =>
          e['ssid'] == ssid &&
          (e['event'] == 'available' || e['event'] == 'unavailable'),
    );
    try {
      await _channel.invokeMethod<void>(
        'request',
        {'ssid': ssid, 'password': password},
      );
    } on PlatformException catch (e) {
      throw DeviceUnreachableException(
        'WiFi link request failed (${e.code}): ${e.message}',
      );
    }
    final Map<dynamic, dynamic> event;
    try {
      event = await decisive.timeout(requestBudget);
    } on TimeoutException {
      await release();
      throw DeviceUnreachableException(
        'WiFi link not established within ${requestBudget.inSeconds}s — '
        'is the device AP on?',
      );
    }
    if (event['event'] == 'unavailable') {
      throw const DeviceUnreachableException(
        'WiFi network unavailable — check that the device AP is on',
      );
    }
    _proxyPort = event['port'] as int?;
  }

  /// Releases the link request and proxy. Never throws; safe to call when
  /// [bind] was never invoked. No-op on non-Android platforms.
  Future<void> release() async {
    _proxyPort = null;
    if (!isAndroidPlatform) return;
    try {
      await _channel.invokeMethod<void>('release');
    } on PlatformException {
      // Release is best-effort.
    }
  }

  /// Tears down the persistent event tracker (tests only — production
  /// binders live for the app session).
  Future<void> dispose() async {
    await _trackerSub?.cancel();
    _trackerSub = null;
    _eventStream = null;
  }
}
