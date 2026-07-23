import 'dart:typed_data';

import 'package:bms_dash/jbd_auth.dart';
import 'package:bms_dash/jbd_bms.dart';
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

  group('cell voltages (register 0x04)', () {
    /// 4 cells: 3.341, 3.352, 3.298, 3.348 V.
    final cellFrame = Uint8List.fromList([
      0xdd, 0x04, 0x00, 0x08,
      0x0d, 0x0d, 0x0d, 0x18, 0x0c, 0xe2, 0x0d, 0x14,
      0xfe, 0xaa, // checksum
      0x77,
    ]);

    test('builds the read command with a valid checksum', () {
      expect(
        JbdProtocol.readCommand(JbdProtocol.cellVoltagesRegister),
        [0xdd, 0xa5, 0x04, 0x00, 0xff, 0xfc, 0x77],
      );
    });

    test('decodes a response into volts', () {
      final payload = JbdProtocol.parseResponse(
        cellFrame,
        JbdProtocol.cellVoltagesRegister,
      );
      expect(payload, isNotNull);
      expect(
        JbdProtocol.parseCellVoltages(payload!),
        [3.341, 3.352, 3.298, 3.348],
      );
    });
  });

  group('extended basic-info fields', () {
    test('balance bits cover both words (cells 1, 2 and 17)', () {
      const info = JbdBasicInfo(
        totalVoltage: 40,
        current: 0,
        remainingCapacityAh: 20,
        nominalCapacityAh: 24,
        cycleCount: 1,
        protectionStatus: 0,
        socPercent: 80,
        chargeFetOn: true,
        dischargeFetOn: true,
        cellCount: 17,
        temperaturesCelsius: [],
        balanceStatus: (0x0001 << 16) | 0x0003,
      );
      expect(info.isCellBalancing(0), isTrue);
      expect(info.isCellBalancing(1), isTrue);
      expect(info.isCellBalancing(2), isFalse);
      expect(info.isCellBalancing(16), isTrue);
    });

    test('software version and production date decode', () {
      const info = JbdBasicInfo(
        totalVoltage: 40,
        current: 0,
        remainingCapacityAh: 20,
        nominalCapacityAh: 24,
        cycleCount: 1,
        protectionStatus: 0,
        socPercent: 80,
        chargeFetOn: true,
        dischargeFetOn: true,
        cellCount: 10,
        temperaturesCelsius: [],
        softwareVersion: 0x20,
        // 2023-06-15: (23 << 9) | (6 << 5) | 15
        productionDateRaw: 11983,
      );
      expect(info.softwareVersionLabel, '2.0');
      expect(info.productionDate, DateTime(2023, 6, 15));

      const blank = JbdBasicInfo(
        totalVoltage: 40,
        current: 0,
        remainingCapacityAh: 20,
        nominalCapacityAh: 24,
        cycleCount: 1,
        protectionStatus: 0,
        socPercent: 80,
        chargeFetOn: true,
        dischargeFetOn: true,
        cellCount: 10,
        temperaturesCelsius: [],
      );
      expect(blank.productionDate, isNull);
    });
  });

  group('malformed payload rejection', () {
    Uint8List basicPayload() => Uint8List.fromList(
          JbdProtocol.parseResponse(
            sampleBasicInfoFrame,
            JbdProtocol.basicInfoRegister,
          )!,
        );

    test('odd-length cell payload is a different layout, not a cell list',
        () {
      expect(
        JbdProtocol.parseCellVoltages(
          Uint8List.fromList([0x0d, 0x0d, 0x0d]),
        ),
        isEmpty,
      );
    });

    test('basic info missing its declared NTC readings is rejected', () {
      // The sample declares 1 NTC; chop off its two bytes.
      final short = Uint8List.fromList(basicPayload().sublist(0, 23));
      expect(JbdBasicInfo.fromPayload(short), isNull);
    });

    test('out-of-range SOC is rejected', () {
      final payload = basicPayload();
      payload[19] = 101;
      expect(JbdBasicInfo.fromPayload(payload), isNull);
    });

    test('impossible cell counts are rejected', () {
      final payload = basicPayload();
      payload[21] = 0;
      expect(JbdBasicInfo.fromPayload(payload), isNull);
      payload[21] = 33;
      expect(JbdBasicInfo.fromPayload(payload), isNull);
    });

    JbdBasicInfo dated(int raw) => JbdBasicInfo(
          totalVoltage: 40,
          current: 0,
          remainingCapacityAh: 20,
          nominalCapacityAh: 24,
          cycleCount: 1,
          protectionStatus: 0,
          socPercent: 80,
          chargeFetOn: true,
          dischargeFetOn: true,
          cellCount: 10,
          temperaturesCelsius: const [],
          productionDateRaw: raw,
        );

    test('impossible packed dates are rejected instead of normalized', () {
      // 2024-02-31 must not become 2024-03-02.
      expect(dated((24 << 9) | (2 << 5) | 31).productionDate, isNull);
      // 2023-02-29: not a leap year.
      expect(dated((23 << 9) | (2 << 5) | 29).productionDate, isNull);
      // 2024-04-31: April has 30 days.
      expect(dated((24 << 9) | (4 << 5) | 31).productionDate, isNull);
      // 2024-02-29 is real and must survive.
      expect(
        dated((24 << 9) | (2 << 5) | 29).productionDate,
        DateTime(2024, 2, 29),
      );
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

  group('authenticateJbdModule', () {
    const remoteId = 'A4:C1:37:04:2D:BE';
    const probeTimeout = Duration(seconds: 2);
    const stepTimeout = Duration(seconds: 4);

    /// Answers each command from [responses]; commands not listed throw the
    /// timeout a real silent module would produce. Records every exchange.
    JbdAuthExchange scripted(
      Map<int, int> responses,
      List<(Uint8List, int, Duration)> log,
    ) {
      return (frame, expectedCommand, timeout) async {
        log.add((frame, expectedCommand, timeout));
        final value = responses[expectedCommand];
        if (value == null) {
          throw const JbdAuthException(
            JbdAuthFailure.timeout,
            'The BMS did not answer the unlock request',
          );
        }
        return JbdAuthResponse(command: expectedCommand, value: value);
      };
    }

    Future<void> run(JbdAuthExchange exchange, {String? password}) {
      return authenticateJbdModule(
        exchange: exchange,
        remoteId: remoteId,
        password: password,
        probeTimeout: probeTimeout,
        stepTimeout: stepTimeout,
      );
    }

    test('a silent module and no password proceeds unauthenticated', () async {
      // The common case: a module that predates the auth protocol never
      // answers the probe, and that must not fail the connection.
      final log = <(Uint8List, int, Duration)>[];
      await run(scripted(const {}, log));

      expect(log, hasLength(1));
      expect(log.single.$1, JbdAuthProtocol.appKeyFrame());
      // The probe uses the short budget so legacy modules don't stall
      // every connect for the full handshake timeout.
      expect(log.single.$3, probeTimeout);
    });

    test('a module reporting no password set proceeds', () async {
      final log = <(Uint8List, int, Duration)>[];
      await run(
        scripted(
          const {
            JbdAuthProtocol.appKeyCommand: JbdAuthProtocol.statusNoPasswordSet,
          },
          log,
        ),
      );
      expect(log, hasLength(1));
    });

    test('a locked module with no password asks for one', () async {
      // The 1.2.0 bug: without this, a locked pack just looked dead and the
      // password prompt could never appear for a first-time connection.
      final log = <(Uint8List, int, Duration)>[];
      await expectLater(
        run(
          scripted(
            const {JbdAuthProtocol.appKeyCommand: JbdAuthProtocol.statusOk},
            log,
          ),
        ),
        throwsA(
          isA<JbdAuthException>().having(
            (e) => e.failure,
            'failure',
            JbdAuthFailure.passwordRequired,
          ),
        ),
      );
      // No challenge/password traffic without a password to send.
      expect(log, hasLength(1));
    });

    test('a password runs the full handshake with pinned bytes', () async {
      final log = <(Uint8List, int, Duration)>[];
      await run(
        scripted(
          const {
            JbdAuthProtocol.appKeyCommand: JbdAuthProtocol.statusOk,
            JbdAuthProtocol.randomByteCommand: 0x62,
            JbdAuthProtocol.passwordCommand: JbdAuthProtocol.statusOk,
          },
          log,
        ),
        password: '123456',
      );

      expect(log, hasLength(3));
      expect(log[0].$3, stepTimeout);
      expect(log[1].$1, JbdAuthProtocol.randomByteRequestFrame());
      expect(
        log[2].$1,
        JbdAuthProtocol.passwordFrame(
          password: '123456',
          macAddress: const [0xa4, 0xc1, 0x37, 0x04, 0x2d, 0xbe],
          randomByte: 0x62,
        ),
      );
    });

    test('a rejected password fails with wrongPassword', () async {
      await expectLater(
        run(
          scripted(const {
            JbdAuthProtocol.appKeyCommand: JbdAuthProtocol.statusOk,
            JbdAuthProtocol.randomByteCommand: 0x62,
            JbdAuthProtocol.passwordCommand: JbdAuthProtocol.statusRejected,
          }, []),
          password: '123456',
        ),
        throwsA(
          isA<JbdAuthException>().having(
            (e) => e.failure,
            'failure',
            JbdAuthFailure.wrongPassword,
          ),
        ),
      );
    });

    test('a silent module with a saved password still fails loudly', () async {
      // That module spoke the protocol when the password was saved, so
      // silence now is a real fault, not a legacy module.
      await expectLater(
        run(scripted(const {}, []), password: '123456'),
        throwsA(
          isA<JbdAuthException>().having(
            (e) => e.failure,
            'failure',
            JbdAuthFailure.timeout,
          ),
        ),
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
