import 'dart:async';
import 'dart:typed_data';

import 'package:idl0/data/exceptions.dart';
import 'package:idl0/transport/wifi_service.dart';

/// Configurable fake [WifiService] for provider tests.
class FakeWifiService implements WifiService {
  /// Files returned by [getFileList].
  List<FileInfo> files = [];

  /// When set, [getFileList] throws this instead of returning [files].
  Object? listError;

  /// Names passed to [downloadFile], in call order.
  final List<String> downloadLog = [];

  /// Per-file progress sequences to emit; defaults to `[0.5, 1.0]`.
  Map<String, List<double>> progressByName = {};

  /// Names that should throw mid-download.
  Set<String> failDownloads = {};

  /// Number of times [bind] has been called.
  int bindCalls = 0;

  /// Number of times [release] has been called.
  int releaseCalls = 0;

  /// When set, [bind] throws this (e.g. a [DummyTransportException]).
  Object? bindError;

  /// When set, [bind] does not complete until this completer does —
  /// lets tests hold the link in the `binding` phase.
  Completer<void>? bindGate;

  @override
  Future<void> bind() async {
    bindCalls++;
    if (bindGate != null) await bindGate!.future;
    if (bindError != null) throw bindError!;
  }

  @override
  Future<void> release() async {
    releaseCalls++;
  }

  /// Number of times [getFileList] has been called.
  int listCalls = 0;

  @override
  Future<List<FileInfo>> getFileList() async {
    listCalls++;
    if (listError != null) throw listError!;
    return files;
  }

  @override
  Stream<double> downloadFile(String name, int size) async* {
    downloadLog.add(name);
    if (failDownloads.contains(name)) {
      throw const DummyTransportException('boom');
    }
    for (final p in progressByName[name] ?? const [0.5, 1.0]) {
      yield p;
    }
  }

  @override
  PushFirmwareHandle pushFirmware(
    Uint8List bin, {
    void Function(int sent, int total)? onProgress,
  }) =>
      throw UnimplementedError();

  @override
  Future<void> pushConfig(String configJson) async {}
}

/// Minimal concrete [TransportException] for tests.
class DummyTransportException extends TransportException {
  /// Creates a [DummyTransportException].
  const DummyTransportException(super.message);
}
