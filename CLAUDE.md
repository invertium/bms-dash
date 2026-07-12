# BMS Dash — dev stack notes for Claude

Flutter Android app (JBD/Xiaoxiang BMS dashboard). **No Flutter/Android SDK
on the host** — everything runs in Docker. Only `adb` and `docker` exist
host-side.

## Everyday commands

```sh
make deps / analyze / test / apk    # flutter pub get / analyze / test / debug build
docker compose run --rm flutter <any flutter/dart/keytool cmd>
```

Run `analyze` + `test` in Docker before committing; never try `flutter` on
the host. After editing `pubspec.yaml`, run `make deps` before `analyze` or
you get stale-package-config errors.

## Installing on devices

- Physical phone: host `adb install -r build/app/outputs/flutter-apk/app-debug.apk`
  (or `make install-debug`).
- Debug keystore is persisted via the `./.android -> /home/ubuntu/.android`
  mount in docker-compose.yml. Gradle resolves it through Java's `user.home`
  (`/home/ubuntu` for uid 1000), **not** `$HOME`. Don't remove that mount or
  every rebuild changes signatures and installs fail with
  `INSTALL_FAILED_UPDATE_INCOMPATIBLE`.

## Emulator (UI verification without hardware)

```sh
make emulator            # KVM-accelerated Android 13 container
adb connect localhost:5555
make emulator-stop       # shut it down when done (it eats RAM)
```

Web VNC on http://localhost:6080. If adb stays `offline`, the container's
inner services wedged — recreate with
`docker compose --profile emulator up -d --force-recreate emulator`.

The emulator has no Bluetooth: use **"Try demo mode"** on the connect screen
(simulated 10S pack driving the exact same session code paths). Verify UI by
driving it with `adb shell input tap/swipe` + `adb exec-out screencap -p`;
screen is 1440x3040 — scale coordinates from the displayed screenshot size.

## Release builds

`docker compose run --rm flutter flutter build apk --release` — signs with
`android/key.properties` + `android/keystore/upload-keystore.jks` (both
gitignored, **irreplaceable — never delete**; back up before touching).
Without them it silently falls back to the debug key. R8 minify + resource
shrinking are on; new `-dontwarn`/keep rules go in
`android/app/proguard-rules.pro`.

## Safety rule

The app must only ever write BMS register 0xE1 (volatile MOSFET on/off).
Never add factory-mode or EEPROM writes — a wrong byte can brick a real
battery pack (see ROADMAP.md "out of scope").
