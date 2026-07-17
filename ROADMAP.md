# BMS Dash — Roadmap

Rough priority order within each horizon. Nothing here is a promise; it's a
map of what fits the app's design (read-mostly, safety first, everything
testable against demo mode).

## Next — settings & quality of life

- ~~**Settings screen**~~ *(shipped in 1.1.0: units, poll rate, history
  window, pack name, keep-awake)*
- ~~**Alert thresholds with in-app banners**~~ *(shipped in 1.1.0: SOC
  low/high, cell delta, temperature)*
- ~~**Charge/discharge session stats**~~ *(shipped in 1.1.0: Ah/Wh per
  session on the dashboard)*
- **Graph polish**: pinch-zoom + pan on the monitor chart, long-press to
  compare two points, optional min/max band per pixel when downsampling.
- **"Advanced mode" settings switch** gating the riskier features below
  (separate FET toggles, config viewer).

## Then — background & data

- **Background monitoring** (Android foreground service): keep polling with
  the app minimized and fire system notifications for alert thresholds and
  protection trips. Biggest single feature; needs a persistent notification
  and battery-optimization exemption UX.
- **Protection & event log**: timestamped history of protection trips, FET
  changes, connect/disconnect events; persisted with `sqflite`, exportable.
- **CSV / JSON export**: share telemetry history and the event log via the
  system share sheet.
- **Long-term history**: persist downsampled telemetry across sessions
  (per-day retention policy) so the monitor can show days, not minutes.
- **Multi-pack support**: remember several BMSes, quick-switch from the app
  bar, per-pack settings and history.

## Later — advanced & platform

- **Separate charge/discharge FET switches** behind advanced mode (the BMS
  supports them independently; the combined toggle stays the default).
- **Read-only configuration viewer**: read EEPROM parameters (protection
  voltages/currents, capacity, cell count) via factory-mode *reads* only —
  needs very careful handling since it uses the same mode that allows writes;
  strictly display, never write.
- **Home-screen widget**: SOC + current at a glance (Glance/App Widget),
  fed by the background service.
- **Light theme** and dynamic-color variant of the palette.
- **Localization**: extract strings, ship German first.
- **iOS build**: `flutter_blue_plus` already supports iOS; needs signing,
  permission plists, and a TestFlight pipeline.
- **Distribution**: Play Store (in progress). F-Droid is out — it requires
  an OSI-approved license and the project moved to the PolyForm
  Noncommercial license after 1.0.0.

## Explicitly out of scope

- Writing protection/EEPROM settings. One byte wrong bricks packs; other
  apps exist for that and the risk/benefit is bad for a monitoring app.
- Cloud accounts/telemetry upload. Local-first stays the rule; export covers
  the rest.
