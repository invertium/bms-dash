import 'package:bms_dash/bms_state.dart';
import 'package:bms_dash/demo_bms.dart';
import 'package:bms_dash/jbd_bms.dart';
import 'package:bms_dash/screens/monitor_screen.dart';
import 'package:flutter_test/flutter_test.dart';

TelemetrySample _sample(int second) => TelemetrySample(
      time: DateTime(2026, 1, 1, 0, 0, second),
      voltage: 40,
      current: -1,
      soc: 50,
      temperature: 22,
    );

void main() {
  group('appendCapped', () {
    test('evicts the oldest samples beyond the cap', () {
      var history = const <TelemetrySample>[];
      for (var i = 0; i < 5; i++) {
        history = appendCapped(history, _sample(i), cap: 3);
      }
      expect(history, hasLength(3));
      expect(history.first.time.second, 2);
      expect(history.last.time.second, 4);
    });
  });

  group('TelemetrySample', () {
    test('derives power and mean temperature from basic info', () {
      const info = JbdBasicInfo(
        totalVoltage: 40,
        current: -2.5,
        remainingCapacityAh: 20,
        nominalCapacityAh: 24,
        cycleCount: 1,
        protectionStatus: 0,
        socPercent: 80,
        chargeFetOn: true,
        dischargeFetOn: true,
        cellCount: 10,
        temperaturesCelsius: [20, 24],
      );
      final sample = TelemetrySample.fromBasicInfo(info, DateTime(2026));
      expect(sample.power, closeTo(-100, 0.001));
      expect(sample.temperature, closeTo(22, 0.001));
      expect(sample.soc, 80);
    });
  });

  group('energy gap tolerance', () {
    TelemetrySample at(Duration offset, double current) => TelemetrySample(
          time: DateTime(2026, 1, 1).add(offset),
          voltage: 36,
          current: current,
          soc: 50,
          temperature: null,
        );

    test('fast poll rates keep the 10 s floor', () {
      expect(
        energyMaxGapForPollInterval(const Duration(seconds: 1)),
        const Duration(seconds: 10),
      );
    });

    test('slow poll rates widen the accepted gap', () {
      expect(
        energyMaxGapForPollInterval(const Duration(seconds: 5)),
        const Duration(seconds: 22),
      );
    });

    test('a 5 s poll integrates a jittered 10-second-plus sample', () {
      // Basic info arrives every 2nd tick = nominally 10 s apart at the 5 s
      // setting; scheduling and BLE jitter push it just past 10 s, which the
      // old fixed maxGap = 10 s silently dropped.
      final maxGap = energyMaxGapForPollInterval(const Duration(seconds: 5));
      final energy = accumulateEnergy(
        const SessionEnergy(),
        at(Duration.zero, 3.6),
        at(const Duration(seconds: 10, milliseconds: 1), 3.6),
        maxGap: maxGap,
      );
      expect(energy.chargedAh, closeTo(0.01, 0.0001));
    });

    test('suspend/reconnect-sized gaps stay excluded', () {
      final maxGap = energyMaxGapForPollInterval(const Duration(seconds: 5));
      final energy = accumulateEnergy(
        const SessionEnergy(),
        at(Duration.zero, 3.6),
        at(const Duration(minutes: 2), 3.6),
        maxGap: maxGap,
      );
      expect(energy.isEmpty, isTrue);
    });
  });

  group('downsampleForChart', () {
    test('short lists pass through untouched', () {
      final samples = List.generate(600, (i) => i);
      expect(downsampleForChart(samples), samples);
    });

    test('always includes the newest sample after decimation', () {
      // 602 samples -> stride 2 selects 0, 2, ..., 600 and used to drop 601.
      for (final length in [601, 602, 1199, 1200, 1201]) {
        final samples = List.generate(length, (i) => i);
        final visible = downsampleForChart(samples);
        expect(visible.last, length - 1, reason: 'length $length');
        expect(visible.length, lessThanOrEqualTo(602));
      }
    });

    test('handles empty input', () {
      expect(downsampleForChart(const <int>[]), isEmpty);
    });
  });

  group('DemoBmsSession', () {
    test('emits telemetry and mirrors MOSFET state with software lock',
        () async {
      final session = DemoBmsSession();
      addTearDown(session.dispose);

      final first = await session.basicInfo.first
          .timeout(const Duration(seconds: 3));
      expect(first.cellCount, 10);
      expect(first.mosfetsOn, isTrue);
      expect(first.isSoftwareLocked, isFalse);

      final cells = await session.cellVoltages.first
          .timeout(const Duration(seconds: 3));
      expect(cells, hasLength(10));

      final confirmed = session.basicInfo
          .firstWhere((info) => !info.chargeFetOn && !info.dischargeFetOn)
          .timeout(const Duration(seconds: 3));
      await session.setMosfets(chargeOn: false, dischargeOn: false);
      final off = await confirmed;
      expect(off.isSoftwareLocked, isTrue);
      expect(off.hasProtectionFault, isFalse);
      expect(off.current, 0);
    });
  });
}
