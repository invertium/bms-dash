import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../about.dart';
import '../ble.dart';
import '../bms_state.dart';
import '../theme.dart';
import '../widgets.dart';
import 'settings_screen.dart';

/// Scan/connect flow shown while no BMS session is live, including the
/// launch-time auto-reconnect state and the demo-mode entry point.
class ConnectScreen extends ConsumerStatefulWidget {
  const ConnectScreen({super.key});

  @override
  ConsumerState<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends ConsumerState<ConnectScreen> {
  final List<BmsScanDevice> _devices = [];
  final _permissions = BluetoothPermissionService();
  late final BluetoothScannerClient _bluetooth;

  StreamSubscription<BluetoothAdapterState>? _adapterStateSubscription;
  StreamSubscription<List<BmsScanDevice>>? _scanResultsSubscription;
  StreamSubscription<bool>? _isScanningSubscription;

  BluetoothAdapterState _adapterState = BluetoothAdapterState.unknown;
  bool _isBluetoothSupported = true;
  bool _isScanning = false;
  bool _showAllDevices = false;
  String _status = 'Ready to scan';

  @override
  void initState() {
    super.initState();
    _bluetooth = ref.read(bluetoothScannerClientProvider);
    _initBluetooth();
  }

  Future<void> _initBluetooth() async {
    final isSupported = await _bluetooth.isSupported;
    if (!mounted) {
      return;
    }

    setState(() {
      _isBluetoothSupported = isSupported;
      if (!isSupported) {
        _status = 'Bluetooth LE is not supported on this device';
      }
    });

    if (!isSupported) {
      return;
    }

    _adapterStateSubscription = _bluetooth.adapterState.listen((state) {
      if (!mounted) {
        return;
      }
      setState(() {
        _adapterState = state;
        if (state != BluetoothAdapterState.on) {
          _status = 'Bluetooth is ${state.label}';
        } else if (_status.startsWith('Bluetooth is ')) {
          // Coming back on: clear the stale adapter message, but never
          // clobber an active scan/connect status.
          _status = 'Ready to scan';
        }
      });
      if (state == BluetoothAdapterState.on) {
        unawaited(ref.read(bmsControllerProvider.notifier).tryAutoReconnect());
      }
    });

    _scanResultsSubscription = _bluetooth.scanResults.listen(
      (devices) {
        if (!mounted) {
          return;
        }
        setState(() {
          _devices
            ..clear()
            ..addAll(devices);
          _devices.sort(BmsScanDevice.compareForDisplay);
        });
      },
      onError: (Object error) {
        if (!mounted) {
          return;
        }
        setState(() {
          _status = 'Scan failed: $error';
        });
      },
    );

    _isScanningSubscription = _bluetooth.isScanning.listen((isScanning) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isScanning = isScanning;
        if (!isScanning && _status == 'Scanning for BLE devices') {
          _status = _devices.isEmpty
              ? 'No BLE devices found'
              : 'Found ${_devices.length} BLE device(s)';
        }
      });
    });
  }

  @override
  void dispose() {
    _adapterStateSubscription?.cancel();
    _scanResultsSubscription?.cancel();
    _isScanningSubscription?.cancel();
    if (_bluetooth.isScanningNow) {
      unawaited(_bluetooth.stopScan());
    }
    super.dispose();
  }

  Future<void> _startScan() async {
    if (!_isBluetoothSupported) {
      return;
    }

    setState(() {
      _status = 'Checking Bluetooth permissions';
    });

    final permissionResult = await _permissions.requestRequiredPermissions();
    if (!mounted) {
      return;
    }
    if (!permissionResult.isGranted) {
      setState(() {
        _status = permissionResult.message;
      });
      return;
    }

    if (_adapterState != BluetoothAdapterState.on) {
      setState(() {
        _status = 'Turn Bluetooth on before scanning';
      });
      return;
    }

    setState(() {
      _devices.clear();
      _status = 'Scanning for BLE devices';
    });

    try {
      await _bluetooth.startScan(
        androidUsesFineLocation: permissionResult.usesFineLocation,
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = 'Could not start scan: $error';
      });
    }
  }

  Future<void> _stopScan() async {
    await _bluetooth.stopScan();
  }

  Future<void> _connectToDevice(BmsScanDevice device) async {
    if (_isScanning) {
      await _bluetooth.stopScan();
    }
    await ref.read(bmsControllerProvider.notifier).connectToDevice(device);
  }

  @override
  Widget build(BuildContext context) {
    final bmsState = ref.watch(bmsControllerProvider);
    final isBusy = bmsState.phase == BmsPhase.connecting ||
        bmsState.phase == BmsPhase.reconnecting;

    // Connection results land in the controller's status message; show the
    // freshest of the two sources.
    final status = bmsState.phase == BmsPhase.disconnected
        ? (bmsState.statusMessage ?? _status)
        : (bmsState.statusMessage ?? _status);

    return Scaffold(
      appBar: AppBar(
        title: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            GradientBoltMark(),
            SizedBox(width: 6),
            Text('BMS Dash'),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Settings',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const SettingsScreen(),
              ),
            ),
            icon: const Icon(Icons.settings_outlined),
          ),
          IconButton(
            tooltip: 'About & support',
            onPressed: () => showAboutBmsDialog(context),
            icon: const Icon(Icons.info_outline),
          ),
          IconButton(
            tooltip: 'Refresh scan',
            onPressed: _isScanning || isBusy ? null : _startScan,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _StatusPanel(
                adapterState: _adapterState,
                phase: bmsState.phase,
                isScanning: _isScanning,
                status: status,
              ),
              const SizedBox(height: 16),
              if (bmsState.phase == BmsPhase.reconnecting)
                Expanded(child: _ReconnectingView(state: bmsState))
              else ...[
                Row(
                  children: [
                    Expanded(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient:
                              _isScanning || isBusy ? null : BmsColors.accent,
                          color: _isScanning || isBusy
                              ? BmsColors.cardInner
                              : null,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor: Colors.transparent,
                            disabledBackgroundColor: Colors.transparent,
                            foregroundColor: Colors.white,
                            disabledForegroundColor: BmsColors.textMuted,
                            shadowColor: Colors.transparent,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          onPressed: _isScanning || isBusy ? null : _startScan,
                          icon: const Icon(Icons.bluetooth_searching),
                          label: const Text(
                            'Scan',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    IconButton.filled(
                      style: IconButton.styleFrom(
                        backgroundColor: BmsColors.cardInner,
                        disabledBackgroundColor:
                            BmsColors.cardInner.withValues(alpha: 0.5),
                        foregroundColor: BmsColors.textPrimary,
                        disabledForegroundColor: BmsColors.textMuted,
                      ),
                      tooltip: 'Stop scan',
                      onPressed: _isScanning ? _stopScan : null,
                      icon: const Icon(Icons.stop),
                    ),
                  ],
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text(
                    'Show all devices',
                    style: TextStyle(color: BmsColors.textSecondary),
                  ),
                  value: _showAllDevices,
                  onChanged: (value) {
                    setState(() {
                      _showAllDevices = value;
                    });
                  },
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: _DeviceList(
                    devices: _showAllDevices
                        ? _devices
                        : _devices
                            .where((device) => device.isLikelyBms)
                            .toList(),
                    hiddenDeviceCount: _showAllDevices
                        ? 0
                        : _devices
                            .where((device) => !device.isLikelyBms)
                            .length,
                    isConnecting: isBusy,
                    isScanning: _isScanning,
                    onDeviceSelected: _connectToDevice,
                  ),
                ),
                Center(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextButton(
                        onPressed: isBusy
                            ? null
                            : () => ref
                                .read(bmsControllerProvider.notifier)
                                .connectDemo(),
                        child: const Text(
                          'Try demo mode',
                          style: TextStyle(color: BmsColors.textMuted),
                        ),
                      ),
                      const Text(
                        '•',
                        style: TextStyle(color: BmsColors.textMuted),
                      ),
                      TextButton.icon(
                        onPressed: () => showAboutBmsDialog(context),
                        icon: const Icon(
                          Icons.coffee,
                          size: 16,
                          color: BmsColors.textMuted,
                        ),
                        label: const Text(
                          'Support',
                          style: TextStyle(color: BmsColors.textMuted),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ReconnectingView extends ConsumerWidget {
  const _ReconnectingView({required this.state});

  final BmsState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 32,
            height: 32,
            child: CircularProgressIndicator(strokeWidth: 3),
          ),
          const SizedBox(height: 20),
          Text(
            'Reconnecting to ${state.deviceName ?? 'saved BMS'}',
            style: const TextStyle(color: BmsColors.textSecondary),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: () => ref
                .read(bmsControllerProvider.notifier)
                .disconnect(message: 'Reconnect canceled'),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }
}

class _StatusPanel extends StatelessWidget {
  const _StatusPanel({
    required this.adapterState,
    required this.phase,
    required this.isScanning,
    required this.status,
  });

  final BluetoothAdapterState adapterState;
  final BmsPhase phase;
  final bool isScanning;
  final String status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isBusy =
        phase == BmsPhase.connecting || phase == BmsPhase.reconnecting;
    final isActive = isBusy || isScanning;

    return Container(
      decoration: bmsCardDecoration(),
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              gradient: isActive ? BmsColors.accent : null,
              color: isActive ? null : BmsColors.cardInner,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(
              isBusy
                  ? Icons.bluetooth_connected
                  : isScanning
                      ? Icons.radar
                      : Icons.bluetooth,
              color: isActive ? Colors.white : BmsColors.textSecondary,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  switch (phase) {
                    BmsPhase.connecting => 'Connecting',
                    BmsPhase.reconnecting => 'Reconnecting',
                    _ => isScanning ? 'Scanning' : 'Disconnected',
                  },
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  status,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: BmsColors.textSecondary),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: BmsColors.cardInner,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: adapterState == BluetoothAdapterState.on
                        ? BmsColors.good
                        : BmsColors.warning,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  'BT ${adapterState.label}',
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: BmsColors.textSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DeviceList extends StatelessWidget {
  const _DeviceList({
    required this.devices,
    required this.hiddenDeviceCount,
    required this.isConnecting,
    required this.isScanning,
    required this.onDeviceSelected,
  });

  final List<BmsScanDevice> devices;
  final int hiddenDeviceCount;
  final bool isConnecting;
  final bool isScanning;
  final ValueChanged<BmsScanDevice> onDeviceSelected;

  @override
  Widget build(BuildContext context) {
    if (devices.isEmpty) {
      final String message;
      if (hiddenDeviceCount > 0) {
        message = 'No likely BMS found, but $hiddenDeviceCount other BLE '
            'device(s) are hidden. Turn on "Show all devices" to list them.';
      } else if (isScanning) {
        message = 'Listening for BLE advertisements...';
      } else {
        message = 'No devices yet. Start a scan with the BMS powered on.';
      }
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: BmsColors.textSecondary),
          ),
        ),
      );
    }

    final theme = Theme.of(context);
    return ListView.builder(
      itemCount: devices.length,
      itemBuilder: (context, index) {
        final device = devices[index];
        return Container(
          margin: const EdgeInsets.only(bottom: 10),
          decoration: bmsCardDecoration(),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: isConnecting ? null : () => onDeviceSelected(device),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  children: [
                    Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        gradient:
                            device.isLikelyBms ? BmsColors.accent : null,
                        color:
                            device.isLikelyBms ? null : BmsColors.cardInner,
                        borderRadius: BorderRadius.circular(13),
                      ),
                      child: Icon(
                        device.isLikelyBms
                            ? Icons.battery_charging_full
                            : Icons.bluetooth,
                        size: 22,
                        color: device.isLikelyBms
                            ? Colors.white
                            : BmsColors.textSecondary,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            device.name,
                            style: theme.textTheme.bodyLarge
                                ?.copyWith(fontWeight: FontWeight.w600),
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            device.remoteId,
                            style: theme.textTheme.labelSmall
                                ?.copyWith(color: BmsColors.textMuted),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          '${device.rssi} dBm',
                          style: theme.textTheme.labelMedium
                              ?.copyWith(color: BmsColors.textSecondary),
                        ),
                        if (device.isLikelyBms) ...[
                          const SizedBox(height: 4),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: BmsColors.pink.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              'likely BMS',
                              style: theme.textTheme.labelSmall
                                  ?.copyWith(color: BmsColors.pink),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
