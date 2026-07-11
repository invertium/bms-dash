import 'dart:math';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../bms_state.dart';
import '../theme.dart';
import '../widgets.dart';

enum _Metric {
  voltage('Voltage', 'V', 2),
  current('Current', 'A', 2),
  power('Power', 'W', 0),
  soc('SOC', '%', 0),
  temperature('Temp', '°C', 1);

  const _Metric(this.label, this.unit, this.decimals);

  final String label;
  final String unit;
  final int decimals;

  double? valueOf(TelemetrySample sample) {
    switch (this) {
      case _Metric.voltage:
        return sample.voltage;
      case _Metric.current:
        return sample.current;
      case _Metric.power:
        return sample.power;
      case _Metric.soc:
        return sample.soc.toDouble();
      case _Metric.temperature:
        return sample.temperature;
    }
  }

  String format(double value) => '${value.toStringAsFixed(decimals)} $unit';
}

enum _Window {
  m1('1 m', Duration(minutes: 1)),
  m5('5 m', Duration(minutes: 5)),
  m15('15 m', Duration(minutes: 15)),
  all('All', null);

  const _Window(this.label, this.duration);

  final String label;
  final Duration? duration;
}

/// Live time-series monitor over the telemetry history.
class MonitorScreen extends ConsumerStatefulWidget {
  const MonitorScreen({super.key});

  @override
  ConsumerState<MonitorScreen> createState() => _MonitorScreenState();
}

class _MonitorScreenState extends ConsumerState<MonitorScreen> {
  _Metric _metric = _Metric.voltage;
  _Window _window = _Window.m5;

  @override
  Widget build(BuildContext context) {
    final history = ref.watch(bmsControllerProvider.select((s) => s.history));

    final cutoff = _window.duration == null
        ? null
        : DateTime.now().subtract(_window.duration!);
    final samples = [
      for (final sample in history)
        if (cutoff == null || sample.time.isAfter(cutoff))
          if (_metric.valueOf(sample) != null) sample,
    ];

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _chipRow<_Metric>(
            values: _Metric.values,
            selected: _metric,
            labelOf: (m) => m.label,
            onSelected: (m) => setState(() => _metric = m),
          ),
          const SizedBox(height: 10),
          _chipRow<_Window>(
            values: _Window.values,
            selected: _window,
            labelOf: (w) => w.label,
            onSelected: (w) => setState(() => _window = w),
          ),
          const SizedBox(height: 16),
          Container(
            decoration: bmsCardDecoration(),
            padding: const EdgeInsets.fromLTRB(12, 20, 20, 12),
            height: 320,
            child: samples.length < 2
                ? const Center(
                    child: Text(
                      'Collecting data...',
                      style: TextStyle(color: BmsColors.textSecondary),
                    ),
                  )
                : _MetricChart(metric: _metric, samples: samples),
          ),
          const SizedBox(height: 16),
          if (samples.isNotEmpty) _StatsRow(metric: _metric, samples: samples),
        ],
      ),
    );
  }

  Widget _chipRow<T>({
    required List<T> values,
    required T selected,
    required String Function(T) labelOf,
    required ValueChanged<T> onSelected,
  }) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final value in values)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(labelOf(value)),
                selected: value == selected,
                showCheckmark: false,
                onSelected: (_) => onSelected(value),
              ),
            ),
        ],
      ),
    );
  }
}

class _StatsRow extends StatelessWidget {
  const _StatsRow({required this.metric, required this.samples});

  final _Metric metric;
  final List<TelemetrySample> samples;

  @override
  Widget build(BuildContext context) {
    final values = [for (final s in samples) metric.valueOf(s)!];
    final minValue = values.reduce(min);
    final maxValue = values.reduce(max);
    final avg = values.reduce((a, b) => a + b) / values.length;

    return Row(
      children: [
        Expanded(
          child: StatTile(label: 'Min', value: metric.format(minValue)),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: StatTile(label: 'Avg', value: metric.format(avg)),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: StatTile(label: 'Max', value: metric.format(maxValue)),
        ),
      ],
    );
  }
}

class _MetricChart extends StatelessWidget {
  const _MetricChart({required this.metric, required this.samples});

  final _Metric metric;
  final List<TelemetrySample> samples;

  static final _timeFormat = DateFormat.Hms();

  @override
  Widget build(BuildContext context) {
    // Cap the point count so long windows stay smooth to render.
    const maxPoints = 600;
    final stride = (samples.length / maxPoints).ceil().clamp(1, 1 << 30);
    final visible = [
      for (var i = 0; i < samples.length; i += stride) samples[i],
    ];

    final spots = [
      for (final sample in visible)
        FlSpot(
          sample.time.millisecondsSinceEpoch / 1000,
          metric.valueOf(sample)!,
        ),
    ];

    final values = [for (final spot in spots) spot.y];
    var minY = values.reduce(min);
    var maxY = values.reduce(max);
    final span = maxY - minY;
    final margin = span == 0 ? max(minY.abs() * 0.02, 0.5) : span * 0.12;
    minY -= margin;
    maxY += margin;

    final minX = spots.first.x;
    final maxX = spots.last.x;

    return LineChart(
      duration: Duration.zero,
      LineChartData(
        minY: minY,
        maxY: maxY,
        gridData: FlGridData(
          drawVerticalLine: false,
          horizontalInterval: _niceInterval((maxY - minY) / 4),
          getDrawingHorizontalLine: (_) => const FlLine(
            color: BmsColors.hairline,
            strokeWidth: 1,
          ),
        ),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(),
          rightTitles: const AxisTitles(),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 46,
              interval: _niceInterval((maxY - minY) / 4),
              getTitlesWidget: (value, meta) {
                // Edge labels collide with the nearest interval tick.
                if (value <= minY || value >= maxY) {
                  return const SizedBox.shrink();
                }
                return Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Text(
                    value.toStringAsFixed(metric.decimals),
                    style: const TextStyle(
                      color: BmsColors.textMuted,
                      fontSize: 11,
                    ),
                    textAlign: TextAlign.right,
                  ),
                );
              },
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 28,
              interval: max((maxX - minX) / 3, 1),
              getTitlesWidget: (value, meta) {
                // Skip the edge labels so they never clip at the card edge.
                if (value <= minX || value >= maxX) {
                  return const SizedBox.shrink();
                }
                final time = DateTime.fromMillisecondsSinceEpoch(
                  (value * 1000).round(),
                );
                return Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _timeFormat.format(time),
                    style: const TextStyle(
                      color: BmsColors.textMuted,
                      fontSize: 11,
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        lineTouchData: LineTouchData(
          touchTooltipData: LineTouchTooltipData(
            getTooltipColor: (_) => BmsColors.cardInner,
            tooltipBorderRadius: BorderRadius.circular(10),
            getTooltipItems: (spots) => [
              for (final spot in spots)
                LineTooltipItem(
                  '${metric.format(spot.y)}\n',
                  const TextStyle(
                    color: BmsColors.textPrimary,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                  children: [
                    TextSpan(
                      text: _timeFormat.format(
                        DateTime.fromMillisecondsSinceEpoch(
                          (spot.x * 1000).round(),
                        ),
                      ),
                      style: const TextStyle(
                        color: BmsColors.textSecondary,
                        fontWeight: FontWeight.w400,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
            ],
          ),
          getTouchedSpotIndicator: (barData, indexes) => [
            for (final _ in indexes)
              TouchedSpotIndicatorData(
                const FlLine(color: BmsColors.hairline, strokeWidth: 1),
                FlDotData(
                  getDotPainter: (spot, percent, bar, index) =>
                      FlDotCirclePainter(
                    radius: 5,
                    color: BmsColors.pink,
                    strokeWidth: 2,
                    strokeColor: BmsColors.card,
                  ),
                ),
              ),
          ],
        ),
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: true,
            curveSmoothness: 0.25,
            preventCurveOverShooting: true,
            barWidth: 2,
            isStrokeCapRound: true,
            gradient: BmsColors.accent,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(
              show: true,
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  BmsColors.purple.withValues(alpha: 0.14),
                  BmsColors.purple.withValues(alpha: 0.0),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Rounds a raw tick step to a clean 1/2/5 multiple.
  static double _niceInterval(double raw) {
    if (raw <= 0 || !raw.isFinite) {
      return 1;
    }
    final magnitude = pow(10, (log(raw) / ln10).floor()).toDouble();
    final residual = raw / magnitude;
    final nice = residual >= 5
        ? 10.0
        : residual >= 2
            ? 5.0
            : residual >= 1
                ? 2.0
                : 1.0;
    return nice * magnitude;
  }
}
