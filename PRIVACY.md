# BMS Dash — Privacy Policy

*Last updated: July 16, 2026*

> Public copy (linked from the Play listing):
> https://invertium.github.io/bms-dash/privacy.html — mirror of this file
> from the [invertium.github.io](https://github.com/invertium/invertium.github.io)
> repo; update both together.

BMS Dash is a dashboard for JBD / Xiaoxiang battery management systems. It
is built to work entirely on your device.

## What the app collects

**Nothing.** BMS Dash does not collect, store on remote servers, transmit,
or share any personal data or telemetry. The app does not even request the
Android `INTERNET` permission, so it is technically incapable of sending
data anywhere.

## Bluetooth

The app uses Bluetooth Low Energy for exactly one purpose: talking to the
battery management system you connect it to. On Android 12 and newer it
declares the `BLUETOOTH_SCAN` permission with the `neverForLocation` flag,
meaning scan results are never used to derive your location. On Android 11
and older, the operating system requires the location permission for BLE
scanning; the app still does not access, record, or use your location.

## What stays on your device

Settings (units, alert thresholds, pack name) and the identifier of the
last-connected BMS are stored locally on your device so the app can restore
them, and nothing else. Battery telemetry shown in the app is held in
memory for the current session only. Uninstalling the app removes all of
it. The app also opts out of Android's cloud backup (`allowBackup=false`),
so the operating system does not upload these local settings to Google
Drive either.

## External links

The About screen contains links (source code, donations) that open in your
browser. Those websites have their own privacy policies; nothing is sent to
them by the app itself.

## Children

The app does not target children and, since it collects no data, processes
no data about anyone.

## Changes and contact

Changes to this policy will appear in this file, with the date above
updated. Questions: open an issue at
https://github.com/invertium/bms_app/issues.
