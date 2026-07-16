import 'package:bms_dash/screens/settings_screen.dart';
import 'package:bms_dash/settings.dart';
import 'package:bms_dash/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('renders with saved values and no framework exceptions', (
    WidgetTester tester,
  ) async {
    // Populated prefs exercise the slider rows and the pack-name field;
    // the SwitchListTiles inside the decorated section cards used to trip
    // "ink may be hidden" assertions on every build.
    SharedPreferences.setMockInitialValues({
      'settings_pack_name': 'Garage pack',
      'settings_alert_soc_low': 20,
    });
    final prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
        child: MaterialApp(
          theme: buildBmsTheme(),
          home: const SettingsScreen(),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);

    // The persisted pack name must show in the field on a cold open.
    expect(find.text('Garage pack'), findsOneWidget);

    // Interact with a chip and a switch; still no assertions.
    await tester.tap(find.text('°F'));
    await tester.pump();
    await tester.tap(find.text('Keep screen awake'));
    await tester.pump();
    expect(tester.takeException(), isNull);

    // The Alerts card sits below the fold; scrolling it into view also
    // builds its SwitchListTile + Slider rows. The TextField brings its own
    // Scrollable, so target the outer ListView explicitly.
    await tester.scrollUntilVisible(
      find.text('Threshold: 20%'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Threshold: 20%'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
