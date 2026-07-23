import 'package:bms_dash/ble.dart';
import 'package:bms_dash/jbd_bms.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';

BmsScanDevice device(
  String id, {
  String name = 'Unnamed BLE device',
  int rssi = -60,
  bool isLikelyBms = false,
}) =>
    BmsScanDevice(
      name: name,
      remoteId: id,
      rssi: rssi,
      isLikelyBms: isLikelyBms,
    );

void main() {
  group('isLikelyBmsName', () {
    test('accepts vendor brandings and module model codes', () {
      for (final name in [
        'JBD-SP04S034',
        'xiaoxiangBMS',
        'MyBattery BMS',
        'LLT-12V100Ah', // The tester report: LLT Power packs missed the old list.
        'SP17S005',
        'SP04S034',
        'AP21S002',
        'sp25s003',
      ]) {
        expect(BmsScanDevice.isLikelyBmsName(name), isTrue, reason: name);
      }
    });

    test('rejects nondescript names', () {
      for (final name in [
        'Unnamed BLE device',
        'MX Master 3',
        'Spark', // "sp" not followed by a digit
        'APartyLight',
      ]) {
        expect(BmsScanDevice.isLikelyBmsName(name), isFalse, reason: name);
      }
    });
  });

  group('fromScanResult', () {
    test('an advertised JBD service marks any name as likely BMS', () {
      final result = ScanResult(
        device: BluetoothDevice.fromId('A4:C1:37:04:2D:BE'),
        advertisementData: AdvertisementData(
          advName: 'DL-46001',
          txPowerLevel: null,
          appearance: null,
          connectable: true,
          manufacturerData: const {},
          serviceData: const {},
          serviceUuids: [JbdProtocol.serviceUuid],
        ),
        rssi: -60,
        timeStamp: DateTime(2026),
      );
      expect(BmsScanDevice.fromScanResult(result).isLikelyBms, isTrue);
    });
  });

  group('compareForDisplay', () {
    test('does not reorder when only RSSI changes', () {
      // The tester report: RSSI jitters with every advertisement, and a
      // list sorted by it reorders under the user's finger.
      final before = [
        device('AA', name: 'Alpha', rssi: -80),
        device('BB', name: 'Beta', rssi: -40),
      ]..sort(BmsScanDevice.compareForDisplay);
      final after = [
        device('AA', name: 'Alpha', rssi: -30),
        device('BB', name: 'Beta', rssi: -90),
      ]..sort(BmsScanDevice.compareForDisplay);

      expect(
        before.map((d) => d.remoteId),
        after.map((d) => d.remoteId),
      );
    });

    test('groups likely BMS first, then name, then id', () {
      final sorted = [
        device('CC', name: 'Zeta'),
        device('BB', name: 'same', isLikelyBms: true),
        device('AA', name: 'same', isLikelyBms: true),
      ]..sort(BmsScanDevice.compareForDisplay);

      expect(sorted.map((d) => d.remoteId), ['AA', 'BB', 'CC']);
    });
  });

  group('mergeScanDevices', () {
    test('keeps a device the scanner has dropped', () {
      final merged = mergeScanDevices(
        [device('AA', name: 'Alpha'), device('BB', name: 'Beta')],
        [device('BB', name: 'Beta', rssi: -50)],
      );

      expect(merged.map((d) => d.remoteId), ['AA', 'BB']);
    });

    test('updates a known device in place', () {
      final merged = mergeScanDevices(
        [device('AA', name: 'Alpha', rssi: -80)],
        [device('AA', name: 'Alpha', rssi: -42)],
      );

      expect(merged.single.rssi, -42);
    });
  });
}
