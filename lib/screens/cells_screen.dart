import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../bms_state.dart';
import '../settings.dart';
import '../theme.dart';
import '../widgets.dart';

/// Per-cell voltages with relative-zoom bars so small imbalances are
/// visible, plus min/max/delta/average stats and balancing indicators.
class CellsScreen extends ConsumerWidget {
  const CellsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(bmsControllerProvider);
    final cells = state.cellVoltages;
    final millivolts = ref
        .watch(settingsProvider.select((s) => s.cellVoltagesInMillivolts));

    if (cells == null || cells.isEmpty) {
      return const Center(
        child: Text(
          'Waiting for cell data...',
          style: TextStyle(color: BmsColors.textSecondary),
        ),
      );
    }

    final minV = cells.reduce((a, b) => a < b ? a : b);
    final maxV = cells.reduce((a, b) => a > b ? a : b);
    final avgV = cells.reduce((a, b) => a + b) / cells.length;
    final deltaMv = (maxV - minV) * 1000;
    final minIndex = cells.indexOf(minV);
    final maxIndex = cells.indexOf(maxV);

    // Relative zoom: bars span [min - pad, max + pad] so drift is visible
    // even when the absolute spread is a few millivolts.
    const pad = 0.015;
    final rangeLow = minV - pad;
    final rangeSpan = (maxV + pad) - rangeLow;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: StatTile(
                  label: 'Lowest',
                  value: formatCellVoltage(minV, millivolts: millivolts),
                  footnote: 'cell ${minIndex + 1}',
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: StatTile(
                  label: 'Highest',
                  value: formatCellVoltage(maxV, millivolts: millivolts),
                  footnote: 'cell ${maxIndex + 1}',
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: StatTile(
                  label: 'Delta',
                  value: '${deltaMv.toStringAsFixed(0)} mV',
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: StatTile(
                  label: 'Average',
                  value: formatCellVoltage(avgV, millivolts: millivolts),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Container(
            decoration: bmsCardDecoration(),
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                for (var i = 0; i < cells.length; i++)
                  Padding(
                    padding: EdgeInsets.only(
                      bottom: i == cells.length - 1 ? 0 : 12,
                    ),
                    child: _CellRow(
                      index: i,
                      voltageLabel: millivolts
                          ? '${(cells[i] * 1000).round()}'
                          : cells[i].toStringAsFixed(3),
                      fraction:
                          ((cells[i] - rangeLow) / rangeSpan).clamp(0.0, 1.0),
                      isMin: i == minIndex,
                      isMax: i == maxIndex,
                      isBalancing:
                          state.telemetry?.isCellBalancing(i) ?? false,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Bars are zoomed to the pack’s min–max range to make drift '
            'visible; use the delta above for the absolute spread.',
            style: Theme.of(context)
                .textTheme
                .labelSmall
                ?.copyWith(color: BmsColors.textMuted),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _CellRow extends StatelessWidget {
  const _CellRow({
    required this.index,
    required this.voltageLabel,
    required this.fraction,
    required this.isMin,
    required this.isMax,
    required this.isBalancing,
  });

  final int index;
  final String voltageLabel;
  final double fraction;
  final bool isMin;
  final bool isMax;
  final bool isBalancing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      children: [
        SizedBox(
          width: 28,
          child: Text(
            '${index + 1}',
            style: theme.textTheme.labelMedium
                ?.copyWith(color: BmsColors.textSecondary),
          ),
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(5),
            child: SizedBox(
              height: 10,
              child: Stack(
                children: [
                  const Positioned.fill(
                    child: ColoredBox(color: BmsColors.gaugeTrack),
                  ),
                  Positioned.fill(
                    child: FractionallySizedBox(
                      alignment: Alignment.centerLeft,
                      widthFactor: fraction,
                      child: const DecoratedBox(
                        decoration: BoxDecoration(gradient: BmsColors.accent),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        SizedBox(
          width: 64,
          child: Text(
            voltageLabel,
            textAlign: TextAlign.right,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: BmsColors.textPrimary,
              fontWeight: FontWeight.w600,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
        SizedBox(
          width: 46,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (isBalancing)
                const Padding(
                  padding: EdgeInsets.only(right: 2),
                  child: Icon(
                    Icons.swap_vert,
                    size: 15,
                    color: BmsColors.good,
                  ),
                ),
              if (isMax)
                const Icon(
                  Icons.arrow_drop_up,
                  size: 20,
                  color: BmsColors.textSecondary,
                )
              else if (isMin)
                const Icon(
                  Icons.arrow_drop_down,
                  size: 20,
                  color: BmsColors.textSecondary,
                ),
            ],
          ),
        ),
      ],
    );
  }
}
