import 'package:bms_dash/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('renders the BLE scan dashboard shell', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          bluetoothScannerClientProvider.overrideWithValue(
            const FakeBluetoothScannerClient(),
          ),
          sharedPreferencesProvider.overrideWithValue(prefs),
        ],
        child: const BmsApp(),
      ),
    );
    await tester.pump();

    expect(find.text('BMS Dash'), findsOneWidget);
    expect(find.text('Disconnected'), findsOneWidget);
    expect(find.text('BT on'), findsOneWidget);
    expect(find.text('Ready to scan'), findsOneWidget);
    expect(find.text('Scan'), findsOneWidget);
    expect(find.text('Show all devices'), findsOneWidget);
    expect(find.text('Try demo mode'), findsOneWidget);
    expect(find.byIcon(Icons.bluetooth_searching), findsOneWidget);
  });
}

class FakeBluetoothScannerClient implements BluetoothScannerClient {
  const FakeBluetoothScannerClient();

  @override
  Future<bool> get isSupported async => true;

  @override
  Stream<BluetoothAdapterState> get adapterState =>
      Stream.value(BluetoothAdapterState.on);

  @override
  Stream<List<BmsScanDevice>> get scanResults => Stream.value(const []);

  @override
  Stream<bool> get isScanning => Stream.value(false);

  @override
  bool get isScanningNow => false;

  @override
  Future<void> startScan({required bool androidUsesFineLocation}) async {}

  @override
  Future<void> stopScan() async {}

  @override
  Future<BmsConnection> connectAndDiscover(
    BmsScanDevice device, {
    Duration pollInterval = JbdBmsSession.defaultPollInterval,
  }) async {
    return BmsConnection(
      summary: DeviceConnectionSummary(
        name: device.name,
        remoteId: device.remoteId,
        serviceCount: 0,
        characteristicCount: 0,
      ),
      session: null,
    );
  }
}
