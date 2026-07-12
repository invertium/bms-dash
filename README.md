# ⚡ BMS Dash

A modern Android dashboard for **JBD / Xiaoxiang smart BMS** (battery
management systems) over Bluetooth LE — state of charge, per-cell voltages,
live graphs, and MOSFET control in a dark, glanceable UI.

Free and open source (MIT). If it saves your pack, consider
[buying me a coffee](https://buymeacoffee.com/invertium). ☕

## Features

- **Dashboard** — radial SOC gauge, pack voltage/current/capacity/temperature
  tiles, decoded protection warnings, device info (hardware/software version,
  production date, cycles), and a single hardened toggle for the charge +
  discharge MOSFETs (confirm-and-retry against telemetry, confirmation prompt
  before cutting power).
- **Cells** — one bar per cell with relative zoom so a 20 mV drift is
  obvious, min/max/delta/average stats, and live balancing indicators.
- **Monitor** — smooth gradient time-series graphs for voltage, current,
  power, SOC, and temperature with 1 m / 5 m / 15 m / All windows and touch
  tooltips (~1 h of history).
- **Connectivity** — BMS-first device filtering, auto-reconnect to the last
  pack on launch, and a stale-data watchdog that tears the session down
  instead of showing frozen values.
- **Demo mode** — a built-in simulated 10S pack, so you can explore every
  screen without hardware (it drives the exact same code paths).

Tested against a JBD **SP17S005P17S80A** (10S LiFePO₄/Li-ion configurations).
Any BMS speaking the JBD/Xiaoxiang UART-over-BLE protocol (GATT service
`0xFF00`) should work.

## Safety

The app is read-mostly by design: the **only** write it ever sends is the
volatile MOSFET on/off command (register `0xE1`). It never enters factory
mode and never touches EEPROM/protection settings, and the BMS's hardware
protections stay active regardless of what the app does. Still: this software
comes **without any warranty** (see [LICENSE](LICENSE)) — you are working
with hardware that manages a battery; keep the pack's limits in mind.

## Building

Everything runs in Docker — no local Flutter/Android SDK needed:

```sh
make deps      # flutter pub get
make analyze   # static analysis
make test      # unit + widget tests
make apk       # debug APK -> build/app/outputs/flutter-apk/app-debug.apk
```

Install on a USB-connected phone with `make install-debug`, or use the
containerized Android emulator (`make emulator`, then
`adb connect localhost:5555`) together with demo mode. See
[docs/host-tools.md](docs/host-tools.md) for host-side adb notes.

### Release builds

Release builds are signed with the keystore referenced by
`android/key.properties` (not in version control); without it they fall back
to the debug key so the project still builds from a fresh clone:

```sh
docker compose run --rm flutter flutter build apk --release
```

## Protocol

The JBD frame codec lives in [`lib/jbd_bms.dart`](lib/jbd_bms.dart) with
golden-frame tests in [`test/jbd_bms_test.dart`](test/jbd_bms_test.dart):
basic info (`0x03`), cell voltages (`0x04`), hardware version (`0x05`), and
MOSFET control (`0xE1`), including balance bits, protection-status decoding,
and the software-FET-lock quirk (bit 12 is set by the off command and is not
a fault).

## Roadmap

See [ROADMAP.md](ROADMAP.md) for planned features.

## License

[MIT](LICENSE) — bundled dependency licenses are viewable in-app under
*About → Open-source licenses*.
