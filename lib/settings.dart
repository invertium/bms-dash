import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The already-loaded preferences store. Overridden in `main()` (and in
/// tests) before the first widget builds, so settings are available
/// synchronously from the first frame — no async-load race where the first
/// connection sees default values.
final sharedPreferencesProvider = Provider<SharedPreferences>(
  (_) => throw StateError(
    'sharedPreferencesProvider must be overridden with a loaded instance',
  ),
);

enum TemperatureUnit { celsius, fahrenheit }

extension TemperatureUnitFormat on TemperatureUnit {
  double fromCelsius(double celsius) =>
      this == TemperatureUnit.fahrenheit ? celsius * 9 / 5 + 32 : celsius;

  String get suffix => this == TemperatureUnit.fahrenheit ? '°F' : '°C';

  String format(double celsius, {int decimals = 1}) =>
      '${fromCelsius(celsius).toStringAsFixed(decimals)} $suffix';
}

/// Formats a cell voltage per the display-unit setting.
String formatCellVoltage(double volts, {required bool millivolts}) =>
    millivolts ? '${(volts * 1000).round()} mV' : '${volts.toStringAsFixed(3)} V';

/// User preferences, persisted via [SettingsController]. Alert thresholds are
/// null when that alert is disabled.
@immutable
class AppSettings {
  const AppSettings({
    this.temperatureUnit = TemperatureUnit.celsius,
    this.cellVoltagesInMillivolts = false,
    this.pollIntervalSeconds = 1,
    this.historyWindowMinutes = 60,
    this.packName = '',
    this.keepScreenAwake = false,
    this.socLowAlertPercent,
    this.socHighAlertPercent,
    this.cellDeltaAlertMv,
    this.temperatureAlertCelsius,
  });

  final TemperatureUnit temperatureUnit;
  final bool cellVoltagesInMillivolts;

  /// Seconds between poll ticks (basic info and cell voltages alternate on
  /// the tick). Applies from the next connection.
  final int pollIntervalSeconds;

  /// How much telemetry history the monitor keeps.
  final int historyWindowMinutes;

  /// Custom display name for the pack; empty means "use the BLE name".
  final String packName;

  final bool keepScreenAwake;

  final int? socLowAlertPercent;
  final int? socHighAlertPercent;
  final int? cellDeltaAlertMv;
  final double? temperatureAlertCelsius;

  static const Object _unset = Object();

  AppSettings copyWith({
    TemperatureUnit? temperatureUnit,
    bool? cellVoltagesInMillivolts,
    int? pollIntervalSeconds,
    int? historyWindowMinutes,
    String? packName,
    bool? keepScreenAwake,
    Object? socLowAlertPercent = _unset,
    Object? socHighAlertPercent = _unset,
    Object? cellDeltaAlertMv = _unset,
    Object? temperatureAlertCelsius = _unset,
  }) {
    return AppSettings(
      temperatureUnit: temperatureUnit ?? this.temperatureUnit,
      cellVoltagesInMillivolts:
          cellVoltagesInMillivolts ?? this.cellVoltagesInMillivolts,
      pollIntervalSeconds: pollIntervalSeconds ?? this.pollIntervalSeconds,
      historyWindowMinutes: historyWindowMinutes ?? this.historyWindowMinutes,
      packName: packName ?? this.packName,
      keepScreenAwake: keepScreenAwake ?? this.keepScreenAwake,
      socLowAlertPercent: identical(socLowAlertPercent, _unset)
          ? this.socLowAlertPercent
          : socLowAlertPercent as int?,
      socHighAlertPercent: identical(socHighAlertPercent, _unset)
          ? this.socHighAlertPercent
          : socHighAlertPercent as int?,
      cellDeltaAlertMv: identical(cellDeltaAlertMv, _unset)
          ? this.cellDeltaAlertMv
          : cellDeltaAlertMv as int?,
      temperatureAlertCelsius: identical(temperatureAlertCelsius, _unset)
          ? this.temperatureAlertCelsius
          : temperatureAlertCelsius as double?,
    );
  }
}

final settingsProvider =
    NotifierProvider<SettingsController, AppSettings>(SettingsController.new);

/// Loads settings once on startup and persists every change.
class SettingsController extends Notifier<AppSettings> {
  static const _tempUnitKey = 'settings_temp_fahrenheit';
  static const _cellMvKey = 'settings_cell_millivolts';
  static const _pollIntervalKey = 'settings_poll_interval_s';
  static const _historyWindowKey = 'settings_history_window_min';
  static const _packNameKey = 'settings_pack_name';
  static const _keepAwakeKey = 'settings_keep_awake';
  static const _socLowKey = 'settings_alert_soc_low';
  static const _socHighKey = 'settings_alert_soc_high';
  static const _cellDeltaKey = 'settings_alert_cell_delta_mv';
  static const _tempAlertKey = 'settings_alert_temp_c';

  /// Selectable values in the settings UI; loaded values outside these are
  /// treated as corrupt and sanitized rather than trusted.
  static const pollIntervalChoices = [1, 2, 3, 5];
  static const historyWindowChoices = [30, 60, 120, 240];

  SharedPreferences get _prefs => ref.read(sharedPreferencesProvider);

  @override
  AppSettings build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    return AppSettings(
      temperatureUnit: (prefs.getBool(_tempUnitKey) ?? false)
          ? TemperatureUnit.fahrenheit
          : TemperatureUnit.celsius,
      cellVoltagesInMillivolts: prefs.getBool(_cellMvKey) ?? false,
      pollIntervalSeconds:
          _choice(prefs.getInt(_pollIntervalKey), pollIntervalChoices, 1),
      historyWindowMinutes:
          _choice(prefs.getInt(_historyWindowKey), historyWindowChoices, 60),
      packName: prefs.getString(_packNameKey) ?? '',
      keepScreenAwake: prefs.getBool(_keepAwakeKey) ?? false,
      socLowAlertPercent: prefs.getInt(_socLowKey)?.clamp(1, 99),
      socHighAlertPercent: prefs.getInt(_socHighKey)?.clamp(1, 100),
      cellDeltaAlertMv: prefs.getInt(_cellDeltaKey)?.clamp(1, 1000),
      temperatureAlertCelsius: prefs.getDouble(_tempAlertKey)?.clamp(0, 100),
    );
  }

  static int _choice(int? stored, List<int> allowed, int fallback) =>
      stored != null && allowed.contains(stored) ? stored : fallback;

  Future<void> setTemperatureUnit(TemperatureUnit unit) async {
    state = state.copyWith(temperatureUnit: unit);
    await _setBool(_tempUnitKey, unit == TemperatureUnit.fahrenheit);
  }

  Future<void> setCellVoltagesInMillivolts(bool enabled) async {
    state = state.copyWith(cellVoltagesInMillivolts: enabled);
    await _setBool(_cellMvKey, enabled);
  }

  Future<void> setPollIntervalSeconds(int seconds) async {
    state = state.copyWith(pollIntervalSeconds: seconds.clamp(1, 5));
    await _setInt(_pollIntervalKey, state.pollIntervalSeconds);
  }

  Future<void> setHistoryWindowMinutes(int minutes) async {
    state = state.copyWith(historyWindowMinutes: minutes);
    await _setInt(_historyWindowKey, minutes);
  }

  Future<void> setPackName(String name) async {
    state = state.copyWith(packName: name.trim());
    await _prefs.setString(_packNameKey, state.packName);
  }

  Future<void> setKeepScreenAwake(bool enabled) async {
    state = state.copyWith(keepScreenAwake: enabled);
    await _setBool(_keepAwakeKey, enabled);
  }

  Future<void> setSocLowAlert(int? percent) async {
    state = state.copyWith(socLowAlertPercent: percent);
    await _setIntOrRemove(_socLowKey, percent);
  }

  Future<void> setSocHighAlert(int? percent) async {
    state = state.copyWith(socHighAlertPercent: percent);
    await _setIntOrRemove(_socHighKey, percent);
  }

  Future<void> setCellDeltaAlert(int? millivolts) async {
    state = state.copyWith(cellDeltaAlertMv: millivolts);
    await _setIntOrRemove(_cellDeltaKey, millivolts);
  }

  Future<void> setTemperatureAlert(double? celsius) async {
    state = state.copyWith(temperatureAlertCelsius: celsius);
    if (celsius == null) {
      await _prefs.remove(_tempAlertKey);
    } else {
      await _prefs.setDouble(_tempAlertKey, celsius);
    }
  }

  Future<void> _setBool(String key, bool value) async {
    await _prefs.setBool(key, value);
  }

  Future<void> _setInt(String key, int value) async {
    await _prefs.setInt(key, value);
  }

  Future<void> _setIntOrRemove(String key, int? value) async {
    if (value == null) {
      await _prefs.remove(key);
    } else {
      await _prefs.setInt(key, value);
    }
  }
}

/// Active alert messages for the current telemetry, given the configured
/// thresholds. Pure so it is easy to test.
List<String> evaluateAlerts({
  required AppSettings settings,
  required int? socPercent,
  required List<double> temperaturesCelsius,
  required List<double>? cellVoltages,
}) {
  final alerts = <String>[];

  final socLow = settings.socLowAlertPercent;
  if (socLow != null && socPercent != null && socPercent <= socLow) {
    alerts.add('SOC $socPercent% at or below $socLow%');
  }

  final socHigh = settings.socHighAlertPercent;
  if (socHigh != null && socPercent != null && socPercent >= socHigh) {
    alerts.add('SOC $socPercent% at or above $socHigh%');
  }

  final deltaLimit = settings.cellDeltaAlertMv;
  if (deltaLimit != null && cellVoltages != null && cellVoltages.length > 1) {
    var minV = cellVoltages.first;
    var maxV = cellVoltages.first;
    for (final v in cellVoltages) {
      if (v < minV) minV = v;
      if (v > maxV) maxV = v;
    }
    final deltaMv = ((maxV - minV) * 1000).round();
    if (deltaMv >= deltaLimit) {
      alerts.add('Cell delta $deltaMv mV at or above $deltaLimit mV');
    }
  }

  final tempLimit = settings.temperatureAlertCelsius;
  if (tempLimit != null && temperaturesCelsius.isNotEmpty) {
    final hottest = temperaturesCelsius.reduce((a, b) => a > b ? a : b);
    if (hottest >= tempLimit) {
      alerts.add(
        'Temperature ${settings.temperatureUnit.format(hottest)} at or above '
        '${settings.temperatureUnit.format(tempLimit, decimals: 0)}',
      );
    }
  }

  return alerts;
}
