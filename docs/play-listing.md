# Google Play listing — copy-paste material

Assets live in `docs/play/`: five phone screenshots (1440×2880, 2:1),
`icon-512.png`, and `feature-graphic.png` (1024×500).

## App name (30 chars max)

```
BMS Dash
```

## Short description (80 chars max)

```
Live dashboard for JBD / Xiaoxiang smart BMS: SOC, cells, graphs, alerts.
```

## Full description (4000 chars max)

```
BMS Dash turns your phone into a live dashboard for JBD / Xiaoxiang smart
battery management systems over Bluetooth LE — the BMS boards used in many
DIY powerwalls, e-bikes, campers, and solar storage packs.

DASHBOARD
• State of charge at a glance on a radial gauge
• Pack voltage, current, remaining capacity, and temperatures
• Charged and discharged energy for the current session (Ah and Wh)
• Decoded protection warnings the moment the BMS raises them
• One hardened switch for the charge/discharge MOSFETs, with a
  confirmation prompt and command verification

CELLS
• Every cell voltage, live, with bars zoomed to the pack's min–max range
  so even a 20 mV drift is instantly visible
• Lowest / highest / delta / average, plus balancing indicators

MONITOR
• Smooth graphs of voltage, current, power, SOC, and temperature
• 1 minute to multi-hour history windows with touch tooltips

ALERTS
• Optional thresholds for low/high SOC, cell imbalance, and temperature
• A clear banner on the dashboard while a condition holds

MADE FOR YOUR PACK
• °C or °F, cell voltages in V or mV, custom pack name
• Adjustable poll rate and graph history window
• Keep-screen-awake option for bench monitoring
• Auto-reconnects to your last pack on launch
• Demo mode: explore the whole app with a simulated pack — no hardware
  needed

SAFE BY DESIGN
The app is read-mostly: the only command it ever writes is the volatile
MOSFET on/off switch. It never touches factory mode, EEPROM, or protection
settings, so your BMS configuration cannot be changed — or damaged — from
this app.

PRIVATE BY DESIGN
No accounts, no ads, no analytics. The app does not even request internet
access; your battery data never leaves your phone.

Works with BMS boards speaking the JBD / Xiaoxiang UART-over-BLE protocol
(GATT service 0xFF00), such as the JBD SP-series. Tested against a JBD
SP17S005 on a 10S pack.

BMS Dash is free. If it saves your pack, you can buy the developer a
coffee from the About screen.
```

## Release notes for the first upload (500 chars max)

```
First Play release of BMS Dash: live SOC/voltage/current dashboard,
per-cell voltages with drift zoom, telemetry graphs, alert thresholds,
session energy stats, MOSFET control with confirmation, °C/°F and V/mV
units, and a demo mode that works without hardware.
```

## Console form answers

- Category: **Tools** · Free · No ads
- Content rating questionnaire: utility app, no user-generated content,
  no violence/etc. → expect **Everyone / PEGI 3**
- Data safety: **No data collected, no data shared** (app has no INTERNET
  permission). Encryption/deletion questions become N/A.
- Target audience: **18+** (or 13+; not designed for children)
- Privacy policy URL: `https://invertium.github.io/bms-dash/privacy.html`
  (public GitHub Pages mirror of PRIVACY.md; works while this repo is
  private — keep both in sync when the policy changes)
- App access: all features available without credentials → "All
  functionality is available without special access"
- Bluetooth permission declaration (if asked): the app communicates with a
  physical battery management device via Bluetooth LE; `BLUETOOTH_SCAN`
  is declared `neverForLocation`.
