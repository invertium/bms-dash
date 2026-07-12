import 'package:bms_dash/bms_state.dart';
import 'package:bms_dash/settings.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Waits for an async condition driven by microtask-resolved futures.
Future<void> pumpUntil(bool Function() condition) async {
  for (var i = 0; i < 100 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(condition(), isTrue, reason: 'condition never became true');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SettingsController', () {
    test('starts with defaults', () {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final settings = container.read(settingsProvider);
      expect(settings.temperatureUnit, TemperatureUnit.celsius);
      expect(settings.cellVoltagesInMillivolts, isFalse);
      expect(settings.pollIntervalSeconds, 1);
      expect(settings.historyWindowMinutes, 60);
      expect(settings.packName, isEmpty);
      expect(settings.keepScreenAwake, isFalse);
      expect(settings.socLowAlertPercent, isNull);
      expect(settings.socHighAlertPercent, isNull);
      expect(settings.cellDeltaAlertMv, isNull);
      expect(settings.temperatureAlertCelsius, isNull);
    });

    test('persists changes across containers', () async {
      SharedPreferences.setMockInitialValues({});
      final first = ProviderContainer();
      final controller = first.read(settingsProvider.notifier);
      await controller.setTemperatureUnit(TemperatureUnit.fahrenheit);
      await controller.setPollIntervalSeconds(3);
      await controller.setHistoryWindowMinutes(240);
      await controller.setPackName('  Garage pack  ');
      await controller.setSocLowAlert(15);
      await controller.setTemperatureAlert(50);
      first.dispose();

      final second = ProviderContainer();
      addTearDown(second.dispose);
      await pumpUntil(
        () => second.read(settingsProvider).pollIntervalSeconds == 3,
      );
      final loaded = second.read(settingsProvider);
      expect(loaded.temperatureUnit, TemperatureUnit.fahrenheit);
      expect(loaded.historyWindowMinutes, 240);
      expect(loaded.packName, 'Garage pack');
      expect(loaded.socLowAlertPercent, 15);
      expect(loaded.temperatureAlertCelsius, 50);
      expect(loaded.socHighAlertPercent, isNull);
    });

    test('disabling an alert removes it', () async {
      SharedPreferences.setMockInitialValues({});
      final first = ProviderContainer();
      final controller = first.read(settingsProvider.notifier);
      await controller.setCellDeltaAlert(80);
      await controller.setCellDeltaAlert(null);
      first.dispose();

      final second = ProviderContainer();
      addTearDown(second.dispose);
      // Give the async load a chance to finish; the value must stay null.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(second.read(settingsProvider).cellDeltaAlertMv, isNull);
    });
  });

  group('unit formatting', () {
    test('temperature converts to Fahrenheit', () {
      expect(TemperatureUnit.celsius.format(25), '25.0 °C');
      expect(TemperatureUnit.fahrenheit.format(25), '77.0 °F');
      expect(TemperatureUnit.fahrenheit.fromCelsius(0), 32);
    });

    test('cell voltage formats as V or mV', () {
      expect(formatCellVoltage(3.341, millivolts: false), '3.341 V');
      expect(formatCellVoltage(3.3414, millivolts: true), '3341 mV');
    });
  });

  group('evaluateAlerts', () {
    const thresholds = AppSettings(
      socLowAlertPercent: 20,
      socHighAlertPercent: 95,
      cellDeltaAlertMv: 50,
      temperatureAlertCelsius: 45,
    );

    test('quiet when everything is within limits', () {
      final alerts = evaluateAlerts(
        settings: thresholds,
        socPercent: 60,
        temperaturesCelsius: [25, 26],
        cellVoltages: [3.30, 3.31, 3.32],
      );
      expect(alerts, isEmpty);
    });

    test('fires on each crossed threshold', () {
      final alerts = evaluateAlerts(
        settings: thresholds,
        socPercent: 15,
        temperaturesCelsius: [25, 47.5],
        cellVoltages: [3.30, 3.36],
      );
      expect(alerts, hasLength(3));
      expect(alerts[0], contains('SOC 15%'));
      expect(alerts[1], contains('60 mV'));
      expect(alerts[2], contains('47.5 °C'));
    });

    test('high SOC alert fires at the boundary', () {
      final alerts = evaluateAlerts(
        settings: thresholds,
        socPercent: 95,
        temperaturesCelsius: const [],
        cellVoltages: null,
      );
      expect(alerts.single, contains('at or above 95%'));
    });

    test('disabled thresholds never fire', () {
      final alerts = evaluateAlerts(
        settings: const AppSettings(),
        socPercent: 1,
        temperaturesCelsius: [99],
        cellVoltages: [2.5, 4.2],
      );
      expect(alerts, isEmpty);
    });
  });

  group('accumulateEnergy', () {
    final t0 = DateTime(2026, 7, 12, 12);

    TelemetrySample sample(DateTime time, double current) => TelemetrySample(
          time: time,
          voltage: 36,
          current: current,
          soc: 50,
          temperature: null,
        );

    test('integrates charge current over time', () {
      // 6 A at 36 V for 10 minutes = 1 Ah / 36 Wh.
      var energy = const SessionEnergy();
      final a = sample(t0, 6);
      final b = sample(t0.add(const Duration(minutes: 10)), 6);
      for (var t = a.time;
          t.isBefore(b.time);
          t = t.add(const Duration(seconds: 2))) {
        energy = accumulateEnergy(
          energy,
          sample(t, 6),
          sample(t.add(const Duration(seconds: 2)), 6),
        );
      }
      expect(energy.chargedAh, closeTo(1.0, 0.001));
      expect(energy.chargedWh, closeTo(36.0, 0.05));
      expect(energy.dischargedAh, 0);
    });

    test('negative current lands in the discharged bucket as positive', () {
      final energy = accumulateEnergy(
        const SessionEnergy(),
        sample(t0, -3.6),
        sample(t0.add(const Duration(seconds: 10)), -3.6),
      );
      expect(energy.dischargedAh, closeTo(0.01, 0.0001));
      expect(energy.dischargedWh, closeTo(0.36, 0.001));
      expect(energy.chargedAh, 0);
    });

    test('skips gaps longer than maxGap and non-positive intervals', () {
      final gap = accumulateEnergy(
        const SessionEnergy(),
        sample(t0, 5),
        sample(t0.add(const Duration(minutes: 5)), 5),
      );
      expect(gap.isEmpty, isTrue);

      final backwards = accumulateEnergy(
        const SessionEnergy(),
        sample(t0, 5),
        sample(t0.subtract(const Duration(seconds: 1)), 5),
      );
      expect(backwards.isEmpty, isTrue);
    });
  });

  group('appendCapped window', () {
    TelemetrySample at(DateTime time) => TelemetrySample(
          time: time,
          voltage: 36,
          current: 0,
          soc: 50,
          temperature: null,
        );

    test('evicts samples older than the window', () {
      final t0 = DateTime(2026, 7, 12, 12);
      var history = <TelemetrySample>[];
      for (var m = 0; m < 90; m++) {
        history = appendCapped(
          history,
          at(t0.add(Duration(minutes: m))),
          window: const Duration(minutes: 30),
        );
      }
      expect(history.length, 30);
      expect(
        history.first.time,
        t0.add(const Duration(minutes: 60)),
      );
    });
  });
}
