import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import 'jbd_bms.dart';

final bluetoothScannerClientProvider = Provider<BluetoothScannerClient>(
  (_) => FlutterBlueScannerClient(),
);

void main() {
  runApp(const ProviderScope(child: BmsApp()));
}

/// Dashboard palette: pink/purple accents on deep navy. The four accent
/// colors are validated for contrast and color-vision-deficiency separation
/// against [card].
abstract final class BmsColors {
  static const Color background = Color(0xFF1C1B2E);
  static const Color card = Color(0xFF2A2942);
  static const Color cardInner = Color(0xFF343357);
  static const Color hairline = Color(0xFF3D3C5E);

  static const Color pink = Color(0xFFF1437E);
  static const Color purple = Color(0xFF8B5CF6);
  static const Color good = Color(0xFF1F9D5F);
  static const Color warning = Color(0xFFD97706);

  static const Color textPrimary = Color(0xFFF2F1FA);
  static const Color textSecondary = Color(0xFFA9A7C7);
  static const Color textMuted = Color(0xFF6F6D91);

  /// Unfilled gauge track: a dim step of the purple ramp so the meter reads
  /// as one piece.
  static const Color gaugeTrack = Color(0xFF3A3763);

  static const Gradient accent = LinearGradient(
    colors: [pink, purple],
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
  );
}

class BmsApp extends StatelessWidget {
  const BmsApp({super.key});

  @override
  Widget build(BuildContext context) {
    const scheme = ColorScheme.dark(
      primary: BmsColors.pink,
      onPrimary: Colors.white,
      secondary: BmsColors.purple,
      onSecondary: Colors.white,
      surface: BmsColors.background,
      onSurface: BmsColors.textPrimary,
      surfaceContainerHighest: BmsColors.cardInner,
      outlineVariant: BmsColors.hairline,
      error: BmsColors.warning,
    );

    return MaterialApp(
      title: 'JBD BMS',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: scheme,
        useMaterial3: true,
        scaffoldBackgroundColor: BmsColors.background,
        appBarTheme: const AppBarTheme(
          backgroundColor: BmsColors.background,
          foregroundColor: BmsColors.textPrimary,
          elevation: 0,
          centerTitle: false,
          titleTextStyle: TextStyle(
            color: BmsColors.textPrimary,
            fontSize: 20,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.2,
          ),
        ),
        switchTheme: SwitchThemeData(
          thumbColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? Colors.white
                : BmsColors.textMuted,
          ),
          trackColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? BmsColors.pink
                : BmsColors.cardInner,
          ),
          trackOutlineColor:
              const WidgetStatePropertyAll(Colors.transparent),
        ),
        listTileTheme: const ListTileThemeData(
          textColor: BmsColors.textPrimary,
          iconColor: BmsColors.textSecondary,
        ),
        dividerTheme: const DividerThemeData(
          color: BmsColors.hairline,
          thickness: 1,
        ),
        progressIndicatorTheme: const ProgressIndicatorThemeData(
          color: BmsColors.pink,
          linearTrackColor: BmsColors.gaugeTrack,
        ),
      ),
      home: const DashboardScreen(),
    );
  }
}

/// Shared rounded-card look for the dashboard panels.
BoxDecoration bmsCardDecoration({Color color = BmsColors.card}) {
  return BoxDecoration(
    color: color,
    borderRadius: BorderRadius.circular(20),
    border: Border.all(color: BmsColors.hairline),
  );
}

class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  final List<BmsScanDevice> _devices = [];
  final _permissions = BluetoothPermissionService();
  late final BluetoothScannerClient _bluetooth;

  StreamSubscription<BluetoothAdapterState>? _adapterStateSubscription;
  StreamSubscription<List<BmsScanDevice>>? _scanResultsSubscription;
  StreamSubscription<bool>? _isScanningSubscription;

  BluetoothAdapterState _adapterState = BluetoothAdapterState.unknown;
  bool _isBluetoothSupported = true;
  bool _isConnecting = false;
  bool _isScanning = false;
  DeviceConnectionSummary? _connectionSummary;
  JbdBmsSession? _session;
  JbdBasicInfo? _telemetry;
  bool? _pendingMosfetToggle;
  bool _showAllDevices = false;
  StreamSubscription<JbdBasicInfo>? _telemetrySubscription;
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
        }
      });
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
    _telemetrySubscription?.cancel();
    final session = _session;
    if (session != null) {
      unawaited(session.disconnect());
    }
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
    if (_isConnecting) {
      return;
    }

    setState(() {
      _isConnecting = true;
      _connectionSummary = null;
      _status = 'Connecting to ${device.name}';
    });

    try {
      if (_isScanning) {
        await _bluetooth.stopScan();
      }
      await _teardownSession();
      final connection = await _bluetooth.connectAndDiscover(device);
      final session = connection.session;
      if (!mounted) {
        await session?.disconnect();
        return;
      }
      setState(() {
        _connectionSummary = connection.summary;
        _session = session;
        _telemetry = null;
        _pendingMosfetToggle = null;
        _status = session == null
            ? 'Connected to ${connection.summary.name}, '
                'but it has no JBD BMS service'
            : 'Connected to ${connection.summary.name}';
      });
      _telemetrySubscription = session?.basicInfo.listen(
        (info) {
          if (!mounted) {
            return;
          }
          setState(() {
            _telemetry = info;
          });
        },
        onDone: () {
          if (!mounted || !identical(_session, session)) {
            return;
          }
          setState(() {
            _session = null;
            _telemetry = null;
            _pendingMosfetToggle = null;
            _connectionSummary = null;
            _status = 'Device disconnected';
          });
        },
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = 'Connection failed: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isConnecting = false;
        });
      }
    }
  }

  Future<void> _teardownSession() async {
    final session = _session;
    _session = null;
    await _telemetrySubscription?.cancel();
    _telemetrySubscription = null;
    await session?.disconnect();
  }

  Future<void> _disconnect() async {
    await _teardownSession();
    if (!mounted) {
      return;
    }
    setState(() {
      _connectionSummary = null;
      _telemetry = null;
      _pendingMosfetToggle = null;
      _status = 'Disconnected';
    });
  }

  Future<void> _setMosfets(bool enabled) async {
    final session = _session;
    if (session == null || _pendingMosfetToggle != null) {
      return;
    }
    setState(() {
      _pendingMosfetToggle = enabled;
      _status = enabled
          ? 'Turning charge & discharge MOSFETs on'
          : 'Turning charge & discharge MOSFETs off';
    });
    try {
      await session.setMosfets(chargeOn: enabled, dischargeOn: enabled);
      if (!mounted) {
        return;
      }
      setState(() {
        _pendingMosfetToggle = null;
        _status = enabled
            ? 'Charge & discharge MOSFETs are on'
            : 'Charge & discharge MOSFETs are off';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _pendingMosfetToggle = null;
        _status = 'MOSFET command failed: $error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ShaderMask(
              shaderCallback: (bounds) =>
                  BmsColors.accent.createShader(bounds),
              child: const Icon(Icons.bolt, color: Colors.white, size: 26),
            ),
            const SizedBox(width: 6),
            const Text('JBD BMS'),
          ],
        ),
        actions: [
          if (_session == null)
            IconButton(
              tooltip: 'Refresh scan',
              onPressed: _isScanning ? null : _startScan,
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
              if (_session == null)
                _StatusPanel(
                  adapterState: _adapterState,
                  connectionSummary: _connectionSummary,
                  isConnecting: _isConnecting,
                  isScanning: _isScanning,
                  status: _status,
                ),
              if (_session != null)
                // The connected view can be taller than small screens, so it
                // scrolls as a whole.
                Expanded(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _StatusPanel(
                          adapterState: _adapterState,
                          connectionSummary: _connectionSummary,
                          isConnecting: _isConnecting,
                          isScanning: _isScanning,
                          status: _status,
                        ),
                        const SizedBox(height: 16),
                        _BmsPanel(
                          telemetry: _telemetry,
                          mosfetsOn: _pendingMosfetToggle ??
                              _telemetry?.mosfetsOn ??
                              false,
                          isTogglePending: _pendingMosfetToggle != null,
                          onMosfetsChanged: _setMosfets,
                          onDisconnect: _disconnect,
                        ),
                      ],
                    ),
                  ),
                )
              else ...[
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: _isScanning ? null : BmsColors.accent,
                          color: _isScanning ? BmsColors.cardInner : null,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor: Colors.transparent,
                            disabledBackgroundColor: Colors.transparent,
                            foregroundColor: Colors.white,
                            disabledForegroundColor: BmsColors.textMuted,
                            shadowColor: Colors.transparent,
                            padding:
                                const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          onPressed: _isScanning ? null : _startScan,
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
                    isConnecting: _isConnecting,
                    isScanning: _isScanning,
                    onDeviceSelected: _connectToDevice,
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

class _StatusPanel extends StatelessWidget {
  const _StatusPanel({
    required this.adapterState,
    required this.connectionSummary,
    required this.isConnecting,
    required this.isScanning,
    required this.status,
  });

  final BluetoothAdapterState adapterState;
  final DeviceConnectionSummary? connectionSummary;
  final bool isConnecting;
  final bool isScanning;
  final String status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isActive = isConnecting || isScanning || connectionSummary != null;

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
              isConnecting
                  ? Icons.bluetooth_connected
                  : isScanning
                      ? Icons.radar
                      : connectionSummary != null
                          ? Icons.link
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
                  isConnecting
                      ? 'Connecting'
                      : connectionSummary == null
                          ? isScanning
                              ? 'Scanning'
                              : 'Disconnected'
                          : 'Connected',
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

class _BmsPanel extends StatelessWidget {
  const _BmsPanel({
    required this.telemetry,
    required this.mosfetsOn,
    required this.isTogglePending,
    required this.onMosfetsChanged,
    required this.onDisconnect,
  });

  final JbdBasicInfo? telemetry;
  final bool mosfetsOn;
  final bool isTogglePending;
  final ValueChanged<bool> onMosfetsChanged;
  final VoidCallback onDisconnect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final telemetry = this.telemetry;

    return Container(
      decoration: bmsCardDecoration(),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                'Battery',
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              IconButton(
                tooltip: 'Disconnect',
                onPressed: onDisconnect,
                icon: const Icon(Icons.link_off,
                    color: BmsColors.textSecondary),
              ),
            ],
          ),
          if (telemetry == null)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 40),
              child: Column(
                children: [
                  SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(strokeWidth: 3),
                  ),
                  SizedBox(height: 16),
                  Text(
                    'Waiting for battery data...',
                    style: TextStyle(color: BmsColors.textSecondary),
                  ),
                ],
              ),
            )
          else ...[
            Center(
              child: _SocGauge(socPercent: telemetry.socPercent),
            ),
            const SizedBox(height: 8),
            Center(
              child: Text(
                '${telemetry.cellCount}S pack  •  ${telemetry.cycleCount} '
                'cycles',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: BmsColors.textMuted),
              ),
            ),
            if (telemetry.hasProtectionFault) ...[
              const SizedBox(height: 12),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: BmsColors.warning.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.warning_amber_rounded,
                        color: BmsColors.warning, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Protection: '
                        '${telemetry.activeProtections.join(', ')}',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: BmsColors.warning),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: _StatTile(
                    label: 'Voltage',
                    value:
                        '${telemetry.totalVoltage.toStringAsFixed(2)} V',
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _StatTile(
                    label: 'Current',
                    value: '${telemetry.current.toStringAsFixed(2)} A',
                    footnote: telemetry.current > 0.01
                        ? 'charging'
                        : telemetry.current < -0.01
                            ? 'discharging'
                            : 'idle',
                    footnoteDotColor: telemetry.current > 0.01
                        ? BmsColors.good
                        : telemetry.current < -0.01
                            ? BmsColors.pink
                            : BmsColors.textMuted,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: _StatTile(
                    label: 'Capacity',
                    value:
                        '${telemetry.remainingCapacityAh.toStringAsFixed(1)}'
                        ' Ah',
                    footnote: 'of '
                        '${telemetry.nominalCapacityAh.toStringAsFixed(1)}'
                        ' Ah',
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _StatTile(
                    label: 'Temperature',
                    value: telemetry.temperaturesCelsius.isEmpty
                        ? '—'
                        : '${telemetry.temperaturesCelsius.first.toStringAsFixed(1)} °C',
                    footnote: telemetry.temperaturesCelsius.length > 1
                        ? telemetry.temperaturesCelsius
                            .skip(1)
                            .map((t) => '${t.toStringAsFixed(1)} °C')
                            .join('  ')
                        : null,
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 16),
          Container(
            decoration: BoxDecoration(
              color: BmsColors.cardInner,
              borderRadius: BorderRadius.circular(14),
            ),
            child: SwitchListTile(
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              title: const Text(
                'Charge & discharge MOSFETs',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
              ),
              subtitle: Text(
                telemetry == null
                    ? 'Waiting for FET status'
                    : 'Charge FET ${telemetry.chargeFetOn ? 'on' : 'off'}, '
                        'discharge FET '
                        '${telemetry.dischargeFetOn ? 'on' : 'off'}',
                style: const TextStyle(
                  color: BmsColors.textSecondary,
                  fontSize: 12,
                ),
              ),
              value: mosfetsOn,
              onChanged: telemetry == null || isTogglePending
                  ? null
                  : onMosfetsChanged,
            ),
          ),
        ],
      ),
    );
  }
}

/// Radial state-of-charge meter: 270° arc, accent-gradient fill over a dim
/// track of the same ramp, hero number in the middle. The fill switches to
/// the warning color when the pack is nearly empty.
class _SocGauge extends StatelessWidget {
  const _SocGauge({required this.socPercent});

  final int socPercent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fraction = socPercent.clamp(0, 100) / 100;

    return SizedBox(
      width: 190,
      height: 190,
      child: CustomPaint(
        painter: _SocGaugePainter(fraction: fraction),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$socPercent%',
                style: theme.textTheme.displayMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: BmsColors.textPrimary,
                ),
              ),
              Text(
                'state of charge',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: BmsColors.textMuted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SocGaugePainter extends CustomPainter {
  const _SocGaugePainter({required this.fraction});

  final double fraction;

  static const double _startAngle = 3 * pi / 4;
  static const double _sweepAngle = 3 * pi / 2;

  @override
  void paint(Canvas canvas, Size size) {
    const strokeWidth = 16.0;
    final rect = Offset.zero & size;
    final arcRect = rect.deflate(strokeWidth / 2 + 2);

    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..color = BmsColors.gaugeTrack;
    canvas.drawArc(arcRect, _startAngle, _sweepAngle, false, track);

    if (fraction <= 0) {
      return;
    }
    final fill = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;
    if (fraction < 0.2) {
      fill.color = BmsColors.warning;
    } else {
      fill.shader = BmsColors.accent.createShader(rect);
    }
    canvas.drawArc(arcRect, _startAngle, _sweepAngle * fraction, false, fill);
  }

  @override
  bool shouldRepaint(_SocGaugePainter oldDelegate) =>
      oldDelegate.fraction != fraction;
}

/// Dashboard stat tile: muted label over a semibold value, with an optional
/// footnote and state dot.
class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.label,
    required this.value,
    this.footnote,
    this.footnoteDotColor,
  });

  final String label;
  final String value;
  final String? footnote;
  final Color? footnoteDotColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: BmsColors.cardInner,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: BmsColors.textSecondary),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w600,
              color: BmsColors.textPrimary,
            ),
          ),
          if (footnote != null) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                if (footnoteDotColor != null) ...[
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: footnoteDotColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 5),
                ],
                Flexible(
                  child: Text(
                    footnote!,
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: BmsColors.textMuted),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ],
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
                              color:
                                  BmsColors.pink.withValues(alpha: 0.15),
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
    final lowerName = name.toLowerCase();

    return BmsScanDevice(
      name: name,
      remoteId: result.device.remoteId.str,
      rssi: result.rssi,
      isLikelyBms: lowerName.contains('jbd') ||
          lowerName.contains('xiaoxiang') ||
          lowerName.contains('bms') ||
          lowerName.contains('sp17'),
    );
  }

  final String name;
  final String remoteId;
  final int rssi;
  final bool isLikelyBms;

  static int compareForDisplay(BmsScanDevice a, BmsScanDevice b) {
    if (a.isLikelyBms != b.isLikelyBms) {
      return a.isLikelyBms ? -1 : 1;
    }
    return b.rssi.compareTo(a.rssi);
  }
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

  Future<BmsConnection> connectAndDiscover(BmsScanDevice device);
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
  Future<BmsConnection> connectAndDiscover(BmsScanDevice device) async {
    final bluetoothDevice = BluetoothDevice.fromId(device.remoteId);
    await bluetoothDevice.connect(
      license: License.nonprofit,
      timeout: const Duration(seconds: 15),
    );
    try {
      final services = await bluetoothDevice.discoverServices(timeout: 15);
      final session = await JbdBmsSession.start(bluetoothDevice, services);
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
  final JbdBmsSession? session;
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

extension on BluetoothAdapterState {
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
