import 'dart:async';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import 'jbd_bms.dart';

final bluetoothScannerClientProvider = Provider<BluetoothScannerClient>(
  (_) => FlutterBlueScannerClient(),
);

@immutable
class BmsScanDevice {
  const BmsScanDevice({
    required this.name,
    required this.remoteId,
    required this.rssi,
    required this.isLikelyBms,
  });

  factory BmsScanDevice.fromScanResult(ScanResult result) {
    final advertisedName = result.advertisementData.advName.trim();
    final platformName = result.device.platformName.trim();
    final name = advertisedName.isNotEmpty
        ? advertisedName
        : platformName.isNotEmpty
            ? platformName
            : 'Unnamed BLE device';

    return BmsScanDevice(
      name: name,
      remoteId: result.device.remoteId.str,
      rssi: result.rssi,
      // The advertised service is the strongest signal: whatever the module
      // is named, a device advertising the JBD UART service almost certainly
      // speaks its protocol. Not every firmware advertises it, so the name
      // heuristic stays as the fallback.
      isLikelyBms: isLikelyBmsName(name) ||
          result.advertisementData.serviceUuids
              .contains(JbdProtocol.serviceUuid),
    );
  }

  /// Name-based half of the likely-BMS heuristic. Vendor brandings (JBD,
  /// Xiaoxiang, LLT Power) and the bare module model codes some firmwares
  /// advertise (`SP04S034`, `AP21S002`, ...). A false positive only mislabels
  /// a row and sorts it higher, so this can afford to be generous.
  static bool isLikelyBmsName(String name) {
    final lowerName = name.toLowerCase();
    return lowerName.contains('jbd') ||
        lowerName.contains('xiaoxiang') ||
        lowerName.contains('bms') ||
        lowerName.contains('llt') ||
        lowerName.contains('sp17') ||
        RegExp(r'^(sp|ap)\d').hasMatch(lowerName);
  }

  final String name;
  final String remoteId;
  final int rssi;
  final bool isLikelyBms;

  /// Likely BMS first, then a stable alphabetical order. Deliberately not
  /// sorted by RSSI: signal strength jitters with every advertisement, and a
  /// list that reorders under the user's finger cannot be tapped. The RSSI
  /// readout still updates live, in place.
  static int compareForDisplay(BmsScanDevice a, BmsScanDevice b) {
    if (a.isLikelyBms != b.isLikelyBms) {
      return a.isLikelyBms ? -1 : 1;
    }
    final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
    if (byName != 0) {
      return byName;
    }
    return a.remoteId.compareTo(b.remoteId);
  }
}

/// Merges a scan snapshot into the devices already on screen, keyed by id.
/// A device missing from [update] stays listed with its last known state:
/// the scanner drops devices that go quiet for a few seconds (removeIfGone),
/// and rows vanishing and reappearing — shifting the list under the user's
/// finger — is worse than a briefly stale entry. The screen clears the list
/// when a new scan starts, so nothing outlives the scan window.
List<BmsScanDevice> mergeScanDevices(
  List<BmsScanDevice> known,
  List<BmsScanDevice> update,
) {
  final byId = {for (final device in known) device.remoteId: device};
  for (final device in update) {
    byId[device.remoteId] = device;
  }
  return byId.values.toList()..sort(BmsScanDevice.compareForDisplay);
}

class BluetoothPermissionService {
  Future<BluetoothPermissionResult> requestRequiredPermissions() async {
    if (kIsWeb || !Platform.isAndroid) {
      return const BluetoothPermissionResult.granted(usesFineLocation: false);
    }

    final androidInfo = await DeviceInfoPlugin().androidInfo;
    final sdkInt = androidInfo.version.sdkInt;

    if (sdkInt >= 31) {
      final statuses = await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
      ].request();

      final granted = statuses.values.every((status) => status.isGranted);
      return BluetoothPermissionResult(
        isGranted: granted,
        usesFineLocation: false,
        message: granted
            ? 'Bluetooth permissions granted'
            : 'Bluetooth scan/connect permission is required',
      );
    }

    final status = await Permission.locationWhenInUse.request();
    return BluetoothPermissionResult(
      isGranted: status.isGranted,
      usesFineLocation: true,
      message: status.isGranted
          ? 'Location permission granted for BLE scanning'
          : 'Location permission is required for BLE scanning on this Android version',
    );
  }
}

abstract class BluetoothScannerClient {
  Future<bool> get isSupported;

  Stream<BluetoothAdapterState> get adapterState;

  Stream<List<BmsScanDevice>> get scanResults;

  Stream<bool> get isScanning;

  bool get isScanningNow;

  Future<void> startScan({required bool androidUsesFineLocation});

  Future<void> stopScan();

  /// [password] unlocks a password-protected Bluetooth module; null for the
  /// usual unprotected one.
  Future<BmsConnection> connectAndDiscover(
    BmsScanDevice device, {
    Duration pollInterval,
    String? password,
  });
}

class FlutterBlueScannerClient implements BluetoothScannerClient {
  @override
  Future<bool> get isSupported => FlutterBluePlus.isSupported;

  @override
  Stream<BluetoothAdapterState> get adapterState => FlutterBluePlus.adapterState;

  @override
  Stream<List<BmsScanDevice>> get scanResults => FlutterBluePlus.scanResults.map(
        (results) => results.map(BmsScanDevice.fromScanResult).toList(),
      );

  @override
  Stream<bool> get isScanning => FlutterBluePlus.isScanning;

  @override
  bool get isScanningNow => FlutterBluePlus.isScanningNow;

  @override
  Future<void> startScan({required bool androidUsesFineLocation}) {
    return FlutterBluePlus.startScan(
      timeout: const Duration(seconds: 15),
      removeIfGone: const Duration(seconds: 5),
      continuousUpdates: true,
      androidUsesFineLocation: androidUsesFineLocation,
    );
  }

  @override
  Future<void> stopScan() {
    return FlutterBluePlus.stopScan();
  }

  @override
  Future<BmsConnection> connectAndDiscover(
    BmsScanDevice device, {
    Duration pollInterval = JbdBmsSession.defaultPollInterval,
    String? password,
  }) async {
    final bluetoothDevice = BluetoothDevice.fromId(device.remoteId);
    // connect() lives inside the cleanup try: it can throw after a partial
    // platform-side connection, which still needs the disconnect below.
    try {
      await bluetoothDevice.connect(
        license: License.nonprofit,
        timeout: const Duration(seconds: 15),
      );
      final services = await bluetoothDevice.discoverServices(timeout: 15);
      final session = await JbdBmsSession.start(
        bluetoothDevice,
        services,
        pollInterval: pollInterval,
        password: password,
      );
      if (session == null) {
        // Nothing useful to do with a non-JBD device; don't hold the link.
        unawaited(bluetoothDevice.disconnect());
      }
      return BmsConnection(
        summary: DeviceConnectionSummary(
          name: device.name,
          remoteId: device.remoteId,
          serviceCount: services.length,
          characteristicCount: services.fold<int>(
            0,
            (count, service) => count + service.characteristics.length,
          ),
        ),
        session: session,
      );
    } catch (_) {
      unawaited(bluetoothDevice.disconnect());
      rethrow;
    }
  }
}

/// Result of connecting to a device: GATT stats plus a live JBD session when
/// the device speaks the JBD protocol.
@immutable
class BmsConnection {
  const BmsConnection({required this.summary, required this.session});

  final DeviceConnectionSummary summary;
  final BmsSession? session;
}

@immutable
class DeviceConnectionSummary {
  const DeviceConnectionSummary({
    required this.name,
    required this.remoteId,
    required this.serviceCount,
    required this.characteristicCount,
  });

  final String name;
  final String remoteId;
  final int serviceCount;
  final int characteristicCount;
}

@immutable
class BluetoothPermissionResult {
  const BluetoothPermissionResult({
    required this.isGranted,
    required this.usesFineLocation,
    required this.message,
  });

  const BluetoothPermissionResult.granted({required this.usesFineLocation})
      : isGranted = true,
        message = 'Permissions granted';

  final bool isGranted;
  final bool usesFineLocation;
  final String message;
}

extension BluetoothAdapterStateLabel on BluetoothAdapterState {
  String get label {
    switch (this) {
      case BluetoothAdapterState.on:
        return 'on';
      case BluetoothAdapterState.off:
        return 'off';
      case BluetoothAdapterState.turningOn:
        return 'turning on';
      case BluetoothAdapterState.turningOff:
        return 'turning off';
      case BluetoothAdapterState.unauthorized:
        return 'unauthorized';
      case BluetoothAdapterState.unavailable:
        return 'unavailable';
      case BluetoothAdapterState.unknown:
        return 'unknown';
    }
  }
}
