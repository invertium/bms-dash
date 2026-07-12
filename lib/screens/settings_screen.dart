import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../settings.dart';
import '../theme.dart';

/// User preferences: display units, pack identity, connection tuning, and
/// alert thresholds.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  late final TextEditingController _packNameController;

  @override
  void initState() {
    super.initState();
    _packNameController =
        TextEditingController(text: ref.read(settingsProvider).packName);
  }

  @override
  void dispose() {
    _packNameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final controller = ref.read(settingsProvider.notifier);
    final unit = settings.temperatureUnit;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _SectionCard(
              title: 'Display',
              children: [
                _ChoiceRow<TemperatureUnit>(
                  label: 'Temperature',
                  values: TemperatureUnit.values,
                  selected: unit,
                  labelOf: (u) => u.suffix,
                  onSelected: controller.setTemperatureUnit,
                ),
                const SizedBox(height: 10),
                _ChoiceRow<bool>(
                  label: 'Cell voltages',
                  values: const [false, true],
                  selected: settings.cellVoltagesInMillivolts,
                  labelOf: (mv) => mv ? 'mV' : 'V',
                  onSelected: controller.setCellVoltagesInMillivolts,
                ),
              ],
            ),
            const SizedBox(height: 14),
            _SectionCard(
              title: 'Pack',
              children: [
                TextField(
                  controller: _packNameController,
                  onChanged: controller.setPackName,
                  style: const TextStyle(color: BmsColors.textPrimary),
                  decoration: InputDecoration(
                    labelText: 'Pack name',
                    hintText: 'Uses the Bluetooth name when empty',
                    labelStyle:
                        const TextStyle(color: BmsColors.textSecondary),
                    hintStyle: const TextStyle(color: BmsColors.textMuted),
                    filled: true,
                    fillColor: BmsColors.cardInner,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text(
                    'Keep screen awake',
                    style: TextStyle(fontSize: 15),
                  ),
                  subtitle: const Text(
                    'While connected to a pack',
                    style: TextStyle(
                      color: BmsColors.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                  value: settings.keepScreenAwake,
                  onChanged: controller.setKeepScreenAwake,
                ),
              ],
            ),
            const SizedBox(height: 14),
            _SectionCard(
              title: 'Connection',
              children: [
                _ChoiceRow<int>(
                  label: 'Poll rate',
                  values: const [1, 2, 3, 5],
                  selected: settings.pollIntervalSeconds,
                  labelOf: (s) => '$s s',
                  onSelected: controller.setPollIntervalSeconds,
                ),
                const SizedBox(height: 4),
                const Text(
                  'Applies from the next connection.',
                  style:
                      TextStyle(color: BmsColors.textMuted, fontSize: 11),
                ),
                const SizedBox(height: 10),
                _ChoiceRow<int>(
                  label: 'Graph history',
                  values: const [30, 60, 120, 240],
                  selected: settings.historyWindowMinutes,
                  labelOf: (m) => m < 60 ? '$m m' : '${m ~/ 60} h',
                  onSelected: controller.setHistoryWindowMinutes,
                ),
              ],
            ),
            const SizedBox(height: 14),
            _SectionCard(
              title: 'Alerts',
              children: [
                const Text(
                  'Shown as a banner on the dashboard while the condition '
                  'holds.',
                  style:
                      TextStyle(color: BmsColors.textMuted, fontSize: 11),
                ),
                _AlertTile(
                  title: 'Low state of charge',
                  value: settings.socLowAlertPercent?.toDouble(),
                  defaultValue: 20,
                  min: 5,
                  max: 50,
                  step: 5,
                  format: (v) => '${v.round()}%',
                  onChanged: (v) =>
                      controller.setSocLowAlert(v?.round()),
                ),
                _AlertTile(
                  title: 'High state of charge',
                  value: settings.socHighAlertPercent?.toDouble(),
                  defaultValue: 95,
                  min: 50,
                  max: 100,
                  step: 5,
                  format: (v) => '${v.round()}%',
                  onChanged: (v) =>
                      controller.setSocHighAlert(v?.round()),
                ),
                _AlertTile(
                  title: 'Cell imbalance',
                  value: settings.cellDeltaAlertMv?.toDouble(),
                  defaultValue: 50,
                  min: 10,
                  max: 200,
                  step: 10,
                  format: (v) => '${v.round()} mV',
                  onChanged: (v) =>
                      controller.setCellDeltaAlert(v?.round()),
                ),
                _AlertTile(
                  title: 'High temperature',
                  value: settings.temperatureAlertCelsius,
                  defaultValue: 45,
                  min: 30,
                  max: 70,
                  step: 5,
                  format: (v) => unit.format(v, decimals: 0),
                  onChanged: controller.setTemperatureAlert,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: bmsCardDecoration(),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    );
  }
}

class _ChoiceRow<T> extends StatelessWidget {
  const _ChoiceRow({
    required this.label,
    required this.values,
    required this.selected,
    required this.labelOf,
    required this.onSelected,
  });

  final String label;
  final List<T> values;
  final T selected;
  final String Function(T) labelOf;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: const TextStyle(color: BmsColors.textSecondary),
          ),
        ),
        for (final value in values)
          Padding(
            padding: const EdgeInsets.only(left: 6),
            child: ChoiceChip(
              label: Text(labelOf(value)),
              selected: value == selected,
              showCheckmark: false,
              visualDensity: VisualDensity.compact,
              onSelected: (_) => onSelected(value),
            ),
          ),
      ],
    );
  }
}

/// Threshold alert row: a switch enables it, a slider tunes it.
class _AlertTile extends StatelessWidget {
  const _AlertTile({
    required this.title,
    required this.value,
    required this.defaultValue,
    required this.min,
    required this.max,
    required this.step,
    required this.format,
    required this.onChanged,
  });

  final String title;

  /// Current threshold; null while the alert is disabled.
  final double? value;
  final double defaultValue;
  final double min;
  final double max;
  final double step;
  final String Function(double) format;
  final ValueChanged<double?> onChanged;

  @override
  Widget build(BuildContext context) {
    final value = this.value;

    return Column(
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(title, style: const TextStyle(fontSize: 15)),
          subtitle: value == null
              ? null
              : Text(
                  'Threshold: ${format(value)}',
                  style: const TextStyle(
                    color: BmsColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
          value: value != null,
          onChanged: (enabled) =>
              onChanged(enabled ? defaultValue : null),
        ),
        if (value != null)
          Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: ((max - min) / step).round(),
            onChanged: onChanged,
          ),
      ],
    );
  }
}
