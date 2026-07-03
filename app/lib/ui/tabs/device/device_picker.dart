import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/exceptions.dart';
import '../../../providers/device_provider.dart';
import '../../brand/brand.dart';

/// Opens the device-source picker sheet — the single surface for choosing,
/// switching, and disconnecting the recording device.
///
/// Scope (mobile UI redesign, "proper picker, switch wired later"): today this
/// manages one IDL0 connection — **Scan for new devices** runs the real
/// scan-and-connect-nearest, and **Disconnect** drops it. "This phone" (GPS
/// recording) is shown as a forthcoming source. True multi-unit switching and a
/// persisted paired-device list (§23.8) land in the BLE integration pass.
// TODO(idl0): when multi-unit + phone-GPS land, back this with a
// `deviceController` source model (knownDevices + selected source) and wire
// per-row switch + the phone source.
void showDevicePicker(BuildContext context) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => const BrandSheet(
      title: 'Select device',
      child: _DevicePickerBody(),
    ),
  );
}

class _DevicePickerBody extends ConsumerStatefulWidget {
  const _DevicePickerBody();

  @override
  ConsumerState<_DevicePickerBody> createState() => _DevicePickerBodyState();
}

class _DevicePickerBodyState extends ConsumerState<_DevicePickerBody> {
  bool _busy = false;

  Future<void> _scan() async {
    setState(() => _busy = true);
    try {
      await ref.read(deviceProvider.notifier).connect();
      if (mounted) Navigator.of(context).maybePop();
    } on Object catch (e) {
      _snack(
        e is TransportException
            ? e.message
            : 'Could not connect — check Bluetooth and try again.',
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disconnect() async {
    setState(() => _busy = true);
    try {
      await ref.read(deviceProvider.notifier).disconnect();
    } on Object catch (e) {
      _snack(e is TransportException ? e.message : 'Disconnect failed.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final device = ref.watch(deviceProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const MinimalSectionHead(label: 'idl0 devices'),
        if (device.isConnected)
          _DeviceRow(
            name: device.deviceName ?? 'IDL0',
            batteryPercent: device.batteryPercent,
            onDisconnect: _busy ? null : _disconnect,
          )
        else
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text(
              'No IDL0 connected — scan to find one nearby.',
              style: plexSans(fontSize: 13, color: brandFgDim),
            ),
          ),
        const MinimalSectionHead(label: 'no hardware'),
        const _PhoneRow(),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          child: QuietButton(
            label: _busy ? 'Scanning…' : 'Scan for new devices',
            filled: true,
            large: true,
            emphasis: ButtonEmphasis.info,
            icon: Icons.bluetooth_searching,
            onPressed: _busy ? null : _scan,
          ),
        ),
      ],
    );
  }
}

/// A connected IDL0 row: bluetooth icon · name + CONNECTED · battery · a green
/// active bar · Disconnect.
class _DeviceRow extends StatelessWidget {
  const _DeviceRow({
    required this.name,
    required this.batteryPercent,
    required this.onDisconnect,
  });

  final String name;
  final int? batteryPercent;
  final VoidCallback? onDisconnect;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: brandControlFill,
        border: Border(left: BorderSide(color: brandGood, width: 3)),
      ),
      padding: const EdgeInsets.fromLTRB(13, 10, 16, 10),
      child: Row(
        children: [
          const Icon(Icons.bluetooth, size: 18, color: brandGood),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  overflow: TextOverflow.ellipsis,
                  style: plexMono(fontSize: 13, fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 2),
                Text(
                  'CONNECTED',
                  style: plexMono(
                    fontSize: 10,
                    fontWeight: FontWeight.w500,
                    color: brandGood,
                    letterSpacing: brandKickerTracking,
                  ),
                ),
              ],
            ),
          ),
          if (batteryPercent != null) ...[
            Text('$batteryPercent%', style: plexMono(fontSize: 12)),
            const SizedBox(width: 10),
          ],
          QuietButton(label: 'Disconnect', onPressed: onDisconnect),
        ],
      ),
    );
  }
}

/// The "This phone" source — GPS lap timing only, forthcoming.
class _PhoneRow extends StatelessWidget {
  const _PhoneRow();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(
        children: [
          const Icon(Icons.smartphone, size: 18, color: brandFgDim),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'This phone',
                  style: plexMono(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: brandFgDim,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'GPS lap timing only — no suspension data',
                  style: plexSans(fontSize: 12, color: brandFgFaint),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              border: Border.all(color: brandRule, width: brandHairlineWidth),
              borderRadius: const BorderRadius.all(
                  Radius.circular(brandControlRadiusSoft),),
            ),
            child: Text(
              'SOON',
              style: plexMono(
                fontSize: 10,
                fontWeight: FontWeight.w500,
                color: brandFgFaint,
                letterSpacing: brandKickerTracking,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
