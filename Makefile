# Common tasks. Run `make help`. See docs/ for the full explanation of each.
PY        ?= .venv/bin/python
SIM       ?= Apple Watch Series 12 (46mm)
DEST      ?= platform=watchOS Simulator,name=$(SIM)
# Stations used by the Swift tests (any two stations on the same line; never commit personal ones)
HOME_STN  ?= Central
WORK_STN  ?= Roma Street
SCRATCH   ?= /tmp/ntbuild

.PHONY: help venv desktop-run desktop-data desktop-mac timetable watch-config watch-data watch-project watch-test watch-build ios-build mac-build

help:
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-16s %s\n", $$1, $$2}'

venv: ## create .venv and install the desktop dependencies
	python3 -m venv .venv
	$(PY) -m pip install -r desktop/requirements.txt

desktop-run: ## run the macOS/Windows desktop app from source
	cd desktop && ../$(PY) app.py

desktop-data: ## force a timetable download/rebuild for the desktop app
	cd desktop && ../$(PY) build_data.py

desktop-mac: ## build desktop/dist/NextTrain.dmg (macOS only)
	./desktop/build_mac.sh

timetable: ## build the compressed timetable (rail.db.z) that CI publishes for the watch
	$(PY) tools/publish_timetable.py --build rail.db.z

watch-config: ## create watch/Shared/LocalConfig.swift from the example (edit your stations in it)
	@test -f watch/Shared/LocalConfig.swift || cp watch/LocalConfig.example.swift watch/Shared/LocalConfig.swift

watch-data: watch-config ## build the slim timetable and bundle it into the watch app
	cd desktop && ../$(PY) build_data.py
	$(PY) tools/export_watch_db.py watch/NextTrainWatch/watch.db

watch-project: ## generate watch/NextTrain.xcodeproj from watch/project.yml (needs: brew install xcodegen)
	cd watch && xcodegen generate && rm -rf NextTrain.xcodeproj/xcuserdata

watch-test: ## run the Swift package tests (DB-backed tests need NEXTTRAIN_DB, see docs/watch-app.md)
	cd watch/NextTrainCore && NEXTTRAIN_HOME="$(HOME_STN)" NEXTTRAIN_WORK="$(WORK_STN)" swift test --scratch-path $(SCRATCH)

ios-build: watch-project ## build the iPhone app + widget for the iOS simulator
	cd watch && xcodebuild -project NextTrain.xcodeproj -scheme NextTrainiOS \
	  -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/ntdd CODE_SIGNING_ALLOWED=NO build

mac-build: watch-project ## build the native Mac app + widget
	cd watch && xcodebuild -project NextTrain.xcodeproj -scheme NextTrainMac \
	  -destination 'generic/platform=macOS' -derivedDataPath /tmp/ntdd CODE_SIGNING_ALLOWED=NO build

watch-build: watch-project ## build the watch app for the simulator
	cd watch && xcodebuild -project NextTrain.xcodeproj -scheme NextTrainWatch \
	  -destination '$(DEST)' -derivedDataPath /tmp/ntdd CODE_SIGNING_ALLOWED=NO build
