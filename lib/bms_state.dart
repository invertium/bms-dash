import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ble.dart';
import 'demo_bms.dart';
import 'jbd_bms.dart';
import 'settings.dart';

const _lastDeviceIdKey = 'last_device_id';
const _lastDeviceNameKey = 'last_device_name';

/// Hard upper bound on retained telemetry samples regardless of the
/// configured time window (4 h at one basic-info frame per second).
const telemetryHistoryCap = 14400;

enum BmsPhase { disconnected, connecting, reconnecting, connected }

/// Returns [history] plus [sample], evicting entries older than [window]
/// (relative to the new sample) and anything beyond the [cap] safety bound.
@visibleForTesting
List<TelemetrySample> appendCapped(
  List<TelemetrySample> history,
  TelemetrySample sample, {
  int cap = telemetryHistoryCap,
  Duration? window,
}) {
  final cutoff = window == null ? null : sample.time.subtract(window);
  final result = [
    for (final s in history)
      if (cutoff == null || s.time.isAfter(cutoff)) s,
    sample,
  ];
  if (result.length > cap) {
    result.removeRange(0, result.length - cap);
  }
  return result;
}

/// Charge/discharge energy integrated over the current session.
@immutable
class SessionEnergy {
  const SessionEnergy({
    this.chargedAh = 0,
    this.chargedWh = 0,
    this.dischargedAh = 0,
    this.dischargedWh = 0,
  });

  final double chargedAh;
  final double chargedWh;
  final double dischargedAh;
  final double dischargedWh;

  bool get isEmpty =>
      chargedAh == 0 && chargedWh == 0 && dischargedAh == 0 &&
      dischargedWh == 0;
}

/// Integrates [current]'s readings over the time since [previous]. Gaps
/// longer than [maxGap] (reconnects, app suspends) are skipped rather than
/// integrated as if the last current had flowed the whole time.
@visibleForTesting
SessionEnergy accumulateEnergy(
  SessionEnergy energy,
  TelemetrySample previous,
  TelemetrySample current, {
  Duration maxGap = const Duration(seconds: 10),
}) {
  final dt = current.time.difference(previous.time);
  if (dt <= Duration.zero || dt > maxGap) {
    return energy;
  }
  final hours = dt.inMilliseconds / Duration.millisecondsPerHour;
  final ah = current.current * hours;
  final wh = current.power * hours;
  if (ah > 0) {
    return SessionEnergy(
      chargedAh: energy.chargedAh + ah,
      chargedWh: energy.chargedWh + wh,
      dischargedAh: energy.dischargedAh,
      dischargedWh: energy.dischargedWh,
    );
  }
  return SessionEnergy(
    chargedAh: energy.chargedAh,
    chargedWh: energy.chargedWh,
    dischargedAh: energy.dischargedAh - ah,
    dischargedWh: energy.dischargedWh - wh,
  );
}

@immutable
class TelemetrySample {
  const TelemetrySample({
    required this.time,
    required this.voltage,
    required this.current,
    required this.soc,
    required this.temperature,
  });

  factory TelemetrySample.fromBasicInfo(JbdBasicInfo info, DateTime time) {
    final temps = info.temperaturesCelsius;
    return TelemetrySample(
      time: time,
      voltage: info.totalVoltage,
      current: info.current,
      soc: info.socPercent,
      temperature: temps.isEmpty
          ? null
          : temps.reduce((a, b) => a + b) / temps.length,
    );
  }

  final DateTime time;
  final double voltage;
  final double current;
  final int soc;

  /// Mean of the NTC readings; null when the pack reports none.
  final double? temperature;

  double get power => voltage * current;
}

@immutable
class BmsState {
  const BmsState({
    this.phase = BmsPhase.disconnected,
    this.deviceName,
    this.statusMessage,
    this.telemetry,
    this.cellVoltages,
    this.history = const [],
    this.pendingMosfetToggle,
    this.hardwareVersion,
    this.isDemo = false,
    this.energy = const SessionEnergy(),
  });

  final BmsPhase phase;
  final String? deviceName;

  /// Transient status line for the connect screen (errors, progress).
  final String? statusMessage;
  final JbdBasicInfo? telemetry;
  final List<double>? cellVoltages;
  final List<TelemetrySample> history;
  final bool? pendingMosfetToggle;
  final String? hardwareVersion;
  final bool isDemo;
  final SessionEnergy energy;

  bool get isConnected => phase == BmsPhase.connected;

  static const Object _unset = Object();

  BmsState copyWith({
    BmsPhase? phase,
    Object? deviceName = _unset,
    Object? statusMessage = _unset,
    Object? telemetry = _unset,
    Object? cellVoltages = _unset,
    List<TelemetrySample>? history,
    Object? pendingMosfetToggle = _unset,
    Object? hardwareVersion = _unset,
    bool? isDemo,
    SessionEnergy? energy,
  }) {
    return BmsState(
      phase: phase ?? this.phase,
      deviceName: identical(deviceName, _unset)
          ? this.deviceName
          : deviceName as String?,
      statusMessage: identical(statusMessage, _unset)
          ? this.statusMessage
          : statusMessage as String?,
      telemetry: identical(telemetry, _unset)
          ? this.telemetry
          : telemetry as JbdBasicInfo?,
      cellVoltages: identical(cellVoltages, _unset)
          ? this.cellVoltages
          : cellVoltages as List<double>?,
      history: history ?? this.history,
      pendingMosfetToggle: identical(pendingMosfetToggle, _unset)
          ? this.pendingMosfetToggle
          : pendingMosfetToggle as bool?,
      hardwareVersion: identical(hardwareVersion, _unset)
          ? this.hardwareVersion
          : hardwareVersion as String?,
      isDemo: isDemo ?? this.isDemo,
      energy: energy ?? this.energy,
    );
  }
}

/// Alerts derived from live telemetry and the configured thresholds;
/// recomputes when either side changes.
final activeAlertsProvider = Provider<List<String>>((ref) {
  final settings = ref.watch(settingsProvider);
  final state = ref.watch(bmsControllerProvider);
  return evaluateAlerts(
    settings: settings,
    socPercent: state.telemetry?.socPercent,
    temperaturesCelsius: state.telemetry?.temperaturesCelsius ?? const [],
    cellVoltages: state.cellVoltages,
  );
});

final bmsControllerProvider =
    NotifierProvider<BmsController, BmsState>(BmsController.new);

/// Owns the BMS session and everything derived from it, shared by all tabs.
class BmsController extends Notifier<BmsState> {
  BmsSession? _session;
  StreamSubscription<JbdBasicInfo>? _telemetrySubscription;
  StreamSubscription<List<double>>? _cellsSubscription;

  /// Bumped on every connect/disconnect so a stale in-flight connection
  /// attempt can detect it was superseded or canceled.
  int _generation = 0;
  bool _autoReconnectAttempted = false;

  /// Previous telemetry sample of the live session, for energy integration.
  TelemetrySample? _lastSample;

  @override
  BmsState build() {
    ref.onDispose(() {
      final session = _session;
      _session = null;
      _telemetrySubscription?.cancel();
      _cellsSubscription?.cancel();
      unawaited(session?.disconnect());
    });
    return const BmsState();
  }

  Future<void> connectToDevice(
    BmsScanDevice device, {
    bool isReconnect = false,
  }) async {
    final generation = ++_generation;
    await _teardown();
    state = state.copyWith(
      phase: isReconnect ? BmsPhase.reconnecting : BmsPhase.connecting,
      deviceName: device.name,
      statusMessage: isReconnect
          ? 'Reconnecting to ${device.name}'
          : 'Connecting to ${device.name}',
    );

    final BmsConnection connection;
    try {
      connection = await ref.read(bluetoothScannerClientProvider).connectAndDiscover(
            device,
            pollInterval: Duration(
              seconds: ref.read(settingsProvider).pollIntervalSeconds,
            ),
          );
    } catch (error) {
      if (generation != _generation) {
        return; // Canceled or superseded while connecting.
      }
      state = state.copyWith(
        phase: BmsPhase.disconnected,
        statusMessage: isReconnect
            ? 'Could not reach ${device.name}'
            : 'Connection failed: $error',
      );
      return;
    }

    final session = connection.session;
    if (generation != _generation) {
      await session?.disconnect();
      return;
    }
    if (session == null) {
      state = state.copyWith(
        phase: BmsPhase.disconnected,
        statusMessage: '${device.name} has no JBD BMS service',
      );
      return;
    }

    _attach(session, device.name, isDemo: false);
    unawaited(_saveLastDevice(device));
  }

  /// Connects the synthetic battery; behaves like a real session everywhere
  /// downstream. Demo connections are not persisted for auto-reconnect.
  Future<void> connectDemo() async {
    _generation++;
    await _teardown();
    _attach(DemoBmsSession(), 'Demo battery', isDemo: true);
  }

  /// Attempts to reconnect to the last used BMS once per app launch.
  /// Returns immediately when there is nothing saved.
  Future<void> tryAutoReconnect() async {
    if (_autoReconnectAttempted || state.phase != BmsPhase.disconnected) {
      return;
    }
    _autoReconnectAttempted = true;
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getString(_lastDeviceIdKey);
    if (id == null) {
      return;
    }
    final name = prefs.getString(_lastDeviceNameKey) ?? 'saved BMS';
    await connectToDevice(
      BmsScanDevice(name: name, remoteId: id, rssi: 0, isLikelyBms: true),
      isReconnect: true,
    );
  }

  /// Disconnects; also cancels an in-flight connect/reconnect attempt.
  Future<void> disconnect({String message = 'Disconnected'}) async {
    _generation++;
    await _teardown();
    state = BmsState(statusMessage: message);
  }

  Future<void> setMosfets(bool enabled) async {
    final session = _session;
    if (session == null || state.pendingMosfetToggle != null) {
      return;
    }
    state = state.copyWith(pendingMosfetToggle: enabled);
    try {
      await session.setMosfets(chargeOn: enabled, dischargeOn: enabled);
      if (identical(_session, session)) {
        state = state.copyWith(pendingMosfetToggle: null);
      }
    } catch (error) {
      if (identical(_session, session)) {
        state = state.copyWith(
          pendingMosfetToggle: null,
          statusMessage: 'MOSFET command failed: $error',
        );
      }
    }
  }

  void _attach(BmsSession session, String name, {required bool isDemo}) {
    _session = session;
    _lastSample = null;
    state = BmsState(
      phase: BmsPhase.connected,
      deviceName: name,
      isDemo: isDemo,
      hardwareVersion: session.hardwareVersion,
    );

    _telemetrySubscription = session.basicInfo.listen(
      (info) {
        if (!identical(_session, session)) {
          return;
        }
        final sample = TelemetrySample.fromBasicInfo(info, DateTime.now());
        final history = appendCapped(
          state.history,
          sample,
          window: Duration(
            minutes: ref.read(settingsProvider).historyWindowMinutes,
          ),
        );
        final previous = _lastSample;
        _lastSample = sample;
        state = state.copyWith(
          telemetry: info,
          history: history,
          hardwareVersion: session.hardwareVersion,
          energy: previous == null
              ? state.energy
              : accumulateEnergy(state.energy, previous, sample),
        );
      },
      onDone: () {
        if (!identical(_session, session)) {
          return;
        }
        _session = null;
        _generation++;
        state = const BmsState(statusMessage: 'Device disconnected');
      },
    );

    _cellsSubscription = session.cellVoltages.listen((cells) {
      if (identical(_session, session)) {
        state = state.copyWith(cellVoltages: cells);
      }
    });
  }

  Future<void> _teardown() async {
    final session = _session;
    _session = null;
    await _telemetrySubscription?.cancel();
    await _cellsSubscription?.cancel();
    _telemetrySubscription = null;
    _cellsSubscription = null;
    await session?.disconnect();
  }

  Future<void> _saveLastDevice(BmsScanDevice device) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastDeviceIdKey, device.remoteId);
    await prefs.setString(_lastDeviceNameKey, device.name);
  }
}
