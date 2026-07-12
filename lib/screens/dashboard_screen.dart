import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../bms_state.dart';
import '../jbd_bms.dart';
import '../settings.dart';
import '../theme.dart';
import '../widgets.dart';

/// Battery overview tab: SOC gauge, stat tiles, MOSFET switch, device info.
class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(bmsControllerProvider);
    final telemetry = state.telemetry;
    final temperatureUnit =
        ref.watch(settingsProvider.select((s) => s.temperatureUnit));
    final alerts = ref.watch(activeAlertsProvider);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _BatteryPanel(
            telemetry: telemetry,
            temperatureUnit: temperatureUnit,
            alerts: alerts,
            energy: state.energy,
            mosfetsOn:
                state.pendingMosfetToggle ?? telemetry?.mosfetsOn ?? false,
            isTogglePending: state.pendingMosfetToggle != null,
            onMosfetsChanged: (enabled) =>
                _onMosfetsChanged(context, ref, enabled),
          ),
          const SizedBox(height: 16),
          _DeviceInfoCard(state: state),
        ],
      ),
    );
  }

  /// Switching the FETs off cuts the pack from charger and load, so it asks
  /// for confirmation; switching back on does not.
  Future<void> _onMosfetsChanged(
    BuildContext context,
    WidgetRef ref,
    bool enabled,
  ) async {
    if (!enabled) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: BmsColors.card,
          title: const Text('Turn MOSFETs off?'),
          content: const Text(
            'This disconnects the pack: charging stops and anything powered '
            'by the battery loses power until you switch back on.',
            style: TextStyle(color: BmsColors.textSecondary),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: BmsColors.warning,
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Turn off'),
            ),
          ],
        ),
      );
      if (confirmed != true) {
        return;
      }
    }
    await ref.read(bmsControllerProvider.notifier).setMosfets(enabled);
  }
}

class _BatteryPanel extends StatelessWidget {
  const _BatteryPanel({
    required this.telemetry,
    required this.temperatureUnit,
    required this.alerts,
    required this.energy,
    required this.mosfetsOn,
    required this.isTogglePending,
    required this.onMosfetsChanged,
  });

  final JbdBasicInfo? telemetry;
  final TemperatureUnit temperatureUnit;
  final List<String> alerts;
  final SessionEnergy energy;
  final bool mosfetsOn;
  final bool isTogglePending;
  final ValueChanged<bool> onMosfetsChanged;

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
            Center(child: _SocGauge(socPercent: telemetry.socPercent)),
            const SizedBox(height: 8),
            Center(
              child: Text(
                '${telemetry.cellCount}S pack  •  ${telemetry.cycleCount} '
                'cycles',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: BmsColors.textMuted),
              ),
            ),
            if (alerts.isNotEmpty) ...[
              const SizedBox(height: 12),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: BmsColors.pink.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.notifications_active_outlined,
                        color: BmsColors.pink, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        alerts.join('\n'),
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: BmsColors.pink),
                      ),
                    ),
                  ],
                ),
              ),
            ],
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
                  child: StatTile(
                    label: 'Voltage',
                    value: '${telemetry.totalVoltage.toStringAsFixed(2)} V',
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: StatTile(
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
                  child: StatTile(
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
                  child: StatTile(
                    label: 'Temperature',
                    value: telemetry.temperaturesCelsius.isEmpty
                        ? '—'
                        : temperatureUnit
                            .format(telemetry.temperaturesCelsius.first),
                    footnote: telemetry.temperaturesCelsius.length > 1
                        ? telemetry.temperaturesCelsius
                            .skip(1)
                            .map(temperatureUnit.format)
                            .join('  ')
                        : null,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: StatTile(
                    label: 'Charged',
                    value: '${energy.chargedAh.toStringAsFixed(2)} Ah',
                    footnote: '${energy.chargedWh.toStringAsFixed(0)} Wh '
                        'this session',
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: StatTile(
                    label: 'Discharged',
                    value: '${energy.dischargedAh.toStringAsFixed(2)} Ah',
                    footnote: '${energy.dischargedWh.toStringAsFixed(0)} Wh '
                        'this session',
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

class _DeviceInfoCard extends StatelessWidget {
  const _DeviceInfoCard({required this.state});

  final BmsState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final telemetry = state.telemetry;
    final productionDate = telemetry?.productionDate;

    final rows = <(String, String)>[
      ('Device', state.deviceName ?? '—'),
      if (state.hardwareVersion != null)
        ('Hardware', state.hardwareVersion!),
      if (telemetry != null) ...[
        ('Software', 'v${telemetry.softwareVersionLabel}'),
        if (productionDate != null)
          ('Produced', DateFormat.yMMMd().format(productionDate)),
        ('Cells', '${telemetry.cellCount}S'),
        (
          'Nominal capacity',
          '${telemetry.nominalCapacityAh.toStringAsFixed(1)} Ah'
        ),
        ('Cycles', '${telemetry.cycleCount}'),
      ],
    ];

    return Container(
      decoration: bmsCardDecoration(),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Device info',
            style: theme.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          for (final (label, value) in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      label,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: BmsColors.textSecondary),
                    ),
                  ),
                  Text(
                    value,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: BmsColors.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
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
