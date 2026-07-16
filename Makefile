# docker-compose.yml runs containers as ${UID}:${GID}; shells do not export
# these reliably, so pass the invoking user's identity explicitly (otherwise
# compose silently falls back to 1000:1000 and generated files can end up
# owned by the wrong user on other hosts).
export UID := $(shell id -u)
export GID := $(shell id -g)

COMPOSE := docker compose
FLUTTER := $(COMPOSE) run --rm --build flutter
ADB := $(COMPOSE) run --rm --build adb

.PHONY: doctor deps analyze test apk clean devices install-debug shell emulator emulator-stop

emulator:
	$(COMPOSE) --profile emulator up -d emulator
	@echo "Wait for boot, then: adb connect localhost:5555"

emulator-stop:
	$(COMPOSE) --profile emulator down

doctor:
	$(FLUTTER) flutter doctor -v

deps:
	$(FLUTTER) flutter pub get

analyze:
	$(FLUTTER) flutter analyze

test:
	$(FLUTTER) flutter test

apk:
	$(FLUTTER) flutter build apk --debug

devices:
	$(ADB) adb devices

install-debug: apk
	$(ADB) adb install -r build/app/outputs/flutter-apk/app-debug.apk

clean:
	$(FLUTTER) flutter clean

shell:
	$(FLUTTER) bash
