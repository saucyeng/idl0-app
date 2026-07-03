import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../../brand/brand.dart';
import 'source_dialogs/dialog_chrome.dart';

/// Live BLE scan dialog for Heart Rate Monitors.
///
/// Scans for advertisers exposing the standard Heart Rate Service
/// (`0x180D`), sorts results by RSSI descending (nearest first — usually
/// the user's own strap), and returns the picked `(address, name)` pair
/// via `Navigator.pop`. The phone NEVER connects to the strap — it only
/// listens for advertisements. The ESP32 firmware does the GATT connection
/// after the address is pushed to it via `idl0_config.json`.
///
/// Result shape:
///   `null` → cancelled / no selection
///   `({String address, String name})` → user tapped a row
class HrmPairDialog extends StatefulWidget {
  /// Creates an [HrmPairDialog].
  const HrmPairDialog({super.key});

  @override
  State<HrmPairDialog> createState() => _HrmPairDialogState();
}

class _HrmPairDialogState extends State<HrmPairDialog> {
  /// Standard BLE Heart Rate Service UUID (§7.5 / Bluetooth assigned numbers).
  static final Guid _hrServiceGuid =
      Guid('0000180d-0000-1000-8000-00805f9b34fb');

  /// 30-second scan budget — long enough to find a strap that's just
  /// been woken up by chest contact, short enough to bail if nothing's
  /// in range.
  static const _scanTimeout = Duration(seconds: 30);

  StreamSubscription<List<ScanResult>>? _sub;

  /// Latest advertisement per device (keyed by remoteId). flutter_blue_plus
  /// re-emits the same device as RSSI updates, so we replace in place.
  final Map<String, ScanResult> _found = {};

  bool _scanning = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _startScan();
  }

  Future<void> _startScan() async {
    if (!mounted) return;
    setState(() {
      _scanning = true;
      _error = null;
      _found.clear();
    });

    // Cancel any leftover listener from a previous scan.
    await _sub?.cancel();

    try {
      await FlutterBluePlus.startScan(
        withServices: [_hrServiceGuid],
        timeout: _scanTimeout,
      );
      _sub = FlutterBluePlus.scanResults.listen((results) {
        if (!mounted) return;
        setState(() {
          for (final r in results) {
            // Re-check the service uuid — some platforms filter loosely.
            final matches = r.advertisementData.serviceUuids
                .any((u) => u == _hrServiceGuid);
            if (matches) {
              _found[r.device.remoteId.str] = r;
            }
          }
        });
      });
      // Stop the "scanning" indicator when flutter_blue_plus auto-stops.
      Future.delayed(_scanTimeout, () {
        if (mounted) setState(() => _scanning = false);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _scanning = false;
      });
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    // Best-effort stop; if the platform side is already idle, this is a no-op.
    FlutterBluePlus.stopScan();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sorted = _found.values.toList()
      ..sort((a, b) => b.rssi.compareTo(a.rssi));

    return AlertDialog(
      title: sourceDialogTitle('Pair heart rate monitor'),
      content: SizedBox(
        width: 380,
        height: 380,
        child: Column(
          children: [
            if (_scanning)
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: LinearProgressIndicator(),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'Scan error: $_error',
                  style: plexMono(fontSize: 12, color: brandAccent),
                ),
              ),
            Expanded(child: _buildBody(sorted)),
          ],
        ),
      ),
      actions: [
        QuietButton(
          label: 'Cancel',
          onPressed: () => Navigator.pop(context),
        ),
        QuietButton(
          label: 'Rescan',
          emphasis: ButtonEmphasis.info,
          onPressed: _scanning ? null : _startScan,
        ),
      ],
    );
  }

  Widget _buildBody(List<ScanResult> sorted) {
    if (sorted.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            _scanning
                ? 'Scanning…  Hold the strap to your chest to wake it up.'
                : 'No heart rate monitors found in the last 30 seconds.\n'
                    'Tap Rescan to try again.',
            textAlign: TextAlign.center,
            style: plexSans(fontSize: 13, color: brandFgDim),
          ),
        ),
      );
    }
    return ListView.builder(
      itemCount: sorted.length,
      itemBuilder: (context, i) {
        final r = sorted[i];
        final name = r.device.platformName.trim();
        return ListTile(
          dense: true,
          title: Text(name.isEmpty ? '(unnamed)' : name),
          subtitle: Text(r.device.remoteId.str),
          trailing: Text('${r.rssi} dBm'),
          onTap: () => _select(r),
        );
      },
    );
  }

  void _select(ScanResult r) {
    // Stop the scan immediately — we have what we need.
    FlutterBluePlus.stopScan();
    final name = r.device.platformName.trim();
    Navigator.pop<({String address, String name})>(
      context,
      (
        address: r.device.remoteId.str.toUpperCase(),
        name: name.isEmpty ? 'HRM ${r.device.remoteId.str}' : name,
      ),
    );
  }
}
