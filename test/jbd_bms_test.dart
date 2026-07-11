import 'dart:typed_data';

import 'package:bms_app/jbd_bms.dart';
import 'package:flutter_test/flutter_test.dart';

/// Basic-info response frame for a 13S pack: 48.10 V, -1.50 A, 45.00 of
/// 100.00 Ah, 12 cycles, SOC 45%, both FETs on, one NTC at 25.0 °C.
final sampleBasicInfoFrame = Uint8List.fromList([
  0xdd, 0x03, 0x00, 0x19, // start, register, status OK, length 25
  0x12, 0xca, // total voltage 4810 * 10 mV
  0xff, 0x6a, // current -150 * 10 mA
  0x11, 0x94, // remaining capacity 4500 * 10 mAh
  0x27, 0x10, // nominal capacity 10000 * 10 mAh
  0x00, 0x0c, // 12 cycles
  0x00, 0x00, // production date
  0x00, 0x00, 0x00, 0x00, // balance status
  0x00, 0x00, // protection status
  0x20, // software version
  0x2d, // SOC 45%
  0x03, // FET status: charge + discharge on
  0x0d, // 13 cells
  0x01, // 1 NTC
  0x0b, 0xa5, // 2981 = 25.0 degC
  0xfb, 0xac, // checksum
  0x77, // end
]);

void main() {
  group('JbdProtocol', () {
    test('builds the canonical basic-info read command', () {
      expect(
        JbdProtocol.readCommand(JbdProtocol.basicInfoRegister),
        [0xdd, 0xa5, 0x03, 0x00, 0xff, 0xfd, 0x77],
      );
    });

    test('builds MOSFET commands with inverted disable bits', () {
      expect(
        JbdProtocol.mosfetCommand(chargeOn: true, dischargeOn: true),
        [0xdd, 0x5a, 0xe1, 0x02, 0x00, 0x00, 0xff, 0x1d, 0x77],
      );
      expect(
        JbdProtocol.mosfetCommand(chargeOn: false, dischargeOn: false),
        [0xdd, 0x5a, 0xe1, 0x02, 0x00, 0x03, 0xff, 0x1a, 0x77],
      );
      expect(
        JbdProtocol.mosfetCommand(chargeOn: false, dischargeOn: true),
        [0xdd, 0x5a, 0xe1, 0x02, 0x00, 0x01, 0xff, 0x1c, 0x77],
      );
    });

    test('accepts a valid response and rejects a corrupted one', () {
      expect(
        JbdProtocol.parseResponse(
          sampleBasicInfoFrame,
          JbdProtocol.basicInfoRegister,
        ),
        isNotNull,
      );

      final corrupted = Uint8List.fromList(sampleBasicInfoFrame);
      corrupted[5] += 1;
      expect(
        JbdProtocol.parseResponse(corrupted, JbdProtocol.basicInfoRegister),
        isNull,
      );
    });
  });

  group('JbdBasicInfo', () {
    test('decodes the sample frame', () {
      final payload = JbdProtocol.parseResponse(
        sampleBasicInfoFrame,
        JbdProtocol.basicInfoRegister,
      )!;
      final info = JbdBasicInfo.fromPayload(payload)!;

      expect(info.totalVoltage, closeTo(48.10, 0.001));
      expect(info.current, closeTo(-1.50, 0.001));
      expect(info.remainingCapacityAh, closeTo(45.0, 0.001));
      expect(info.nominalCapacityAh, closeTo(100.0, 0.001));
      expect(info.cycleCount, 12);
      expect(info.socPercent, 45);
      expect(info.chargeFetOn, isTrue);
      expect(info.dischargeFetOn, isTrue);
      expect(info.mosfetsOn, isTrue);
      expect(info.hasProtectionFault, isFalse);
      expect(info.cellCount, 13);
      expect(info.temperaturesCelsius, hasLength(1));
      expect(info.temperaturesCelsius.first, closeTo(25.0, 0.001));
    });
  });

  group('protection status decoding', () {
    JbdBasicInfo infoWithProtection(int status) => JbdBasicInfo(
          totalVoltage: 40,
          current: 0,
          remainingCapacityAh: 20,
          nominalCapacityAh: 24,
          cycleCount: 1,
          protectionStatus: status,
          socPercent: 80,
          chargeFetOn: true,
          dischargeFetOn: true,
          cellCount: 10,
          temperaturesCelsius: const [],
        );

    test('software FET lock alone is not a fault', () {
      final info = infoWithProtection(JbdBasicInfo.softwareLockBit);
      expect(info.hasProtectionFault, isFalse);
      expect(info.isSoftwareLocked, isTrue);
      expect(info.activeProtections, isEmpty);
    });

    test('real trips are named, unknown bits fall back to hex', () {
      final info = infoWithProtection(0x0401);
      expect(info.hasProtectionFault, isTrue);
      expect(info.activeProtections, ['Cell overvoltage', 'Short circuit']);

      expect(
        infoWithProtection(0x8000).activeProtections,
        ['Unknown (0x8000)'],
      );
    });
  });

  group('JbdFrameAssembler', () {
    test('reassembles a frame split across BLE notification chunks', () {
      final assembler = JbdFrameAssembler();

      expect(assembler.addChunk(sampleBasicInfoFrame.sublist(0, 20)), isEmpty);
      final frames = assembler.addChunk(sampleBasicInfoFrame.sublist(20));

      expect(frames, hasLength(1));
      expect(frames.single, sampleBasicInfoFrame);
    });

    test('skips garbage before a frame start', () {
      final assembler = JbdFrameAssembler();
      final frames = assembler.addChunk([
        0x00,
        0x42,
        ...sampleBasicInfoFrame,
      ]);

      expect(frames, hasLength(1));
      expect(frames.single, sampleBasicInfoFrame);
    });
  });
}
