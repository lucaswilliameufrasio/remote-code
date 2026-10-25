.PHONY: help setup bootstrap get format format-check analyze lint test test-bootstrap test-ios-simulator validate apk-debug apk-release build-apk ios-preview-build ios-release build-check devices doctor clean test-host test-host-runtime test-mobile-simulator test-local-app setup-claude test-claude test-claude-local-app

.DEFAULT_GOAL := help

.PHONY: build-aab build-ipa build-ios apk-unsigned aab-unsigned test-ci test-release lint-native-android android-signing-report precommit run

help: ## Show common development commands
	@awk 'BEGIN {FS = ":.*## "}; /^[a-zA-Z_-]+:.*## / {printf "%-24s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

setup: bootstrap ## Generate native projects and install Flutter dependencies

bootstrap: ## Configure Android and iOS native projects
	python3 scripts/bootstrap.py

get: ## Install Flutter dependencies
	flutter pub get

format: ## Format Dart source and tests
	dart format lib test integration_test test_driver

format-check: ## Check Dart formatting without changing files
	dart format --output=none --set-exit-if-changed lib test integration_test test_driver

analyze: ## Run Flutter static analysis
	flutter analyze --no-fatal-infos

lint: analyze ## Alias for Flutter static analysis

test: test-host test-host-runtime test-claude ## Run Flutter and host tests, including isolated agent integration
	flutter test

test-ci: test-host test-host-runtime test-claude ## Run all tests and produce Flutter coverage
	flutter test --coverage

test-release: ## Check release signing guards without using real credentials
	python3 scripts/test_release.py

test-bootstrap: ## Test native project configuration
	python3 scripts/test_bootstrap.py

test-ios-simulator: ## Run the onboarding integration test on a booted iOS Simulator
	flutter drive $(if $(DEVICE),-d "$(DEVICE)") --driver=test_driver/integration_test.dart --target=integration_test/onboarding_test.dart

validate: format-check analyze test test-bootstrap test-release ## Run formatting, analysis, and all tests

precommit: ## Run validation, native Android lint, and both platform builds in sequence
	$(MAKE) validate
	$(MAKE) lint-native-android
	$(MAKE) build-check

test-host: ## Check and test the restricted filesystem plugin against real local files
	python3 host/file-browser/test_filesystem.py
	node --check host/file-browser/index.js
	node --check host/file-browser/policy.js
	node --test host/file-browser/plugin.test.js

test-host-runtime: ## Verify authentication and plugin wiring in an isolated OpenCode v2 server
	python3 scripts/test_file_browser_runtime.py

test-mobile-simulator: ## Exercise file review, prompt recovery and QR confirmation on iOS Simulator
	flutter drive $(if $(DEVICE),-d "$(DEVICE)") --no-pub --driver=test_driver/integration_test.dart --target=integration_test/mobile_workflows_test.dart

test-local-app: ## Exercise real OpenCode, restricted files, prompt recovery and snapshots over local HTTPS
	python3 scripts/test_local_app.py $(if $(DEVICE),--device $(DEVICE))

setup-claude: ## Install the optional Claude adapter into its isolated virtual environment
	python3 -m venv host/claude-code/.venv
	host/claude-code/.venv/bin/python -m pip install -r host/claude-code/requirements.txt

test-claude: ## Test real HTTP/SQLite and the official Claude SDK against a local model fixture
	host/claude-code/.venv/bin/python host/claude-code/test_server.py
	host/claude-code/.venv/bin/python host/claude-code/test_sdk_runtime.py

test-claude-local-app: ## Exercise the mobile Claude client with the real SDK over local HTTPS
	host/claude-code/.venv/bin/python scripts/test_claude_local_app.py --device $(DEVICE)

apk-debug: ## Build the Android debug APK
	flutter build apk --debug

apk-release: ## Build the Android release APK
	python3 scripts/build_release.py apk

build-apk: apk-release ## Alias for building the Android release APK

build-aab: ## Build a signed Android App Bundle for Google Play
	python3 scripts/build_release.py appbundle

apk-unsigned: ## Build an unsigned release APK for verification, not installation
	python3 scripts/build_release.py apk --unsigned

aab-unsigned: ## Build an unsigned App Bundle for verification, not publication
	python3 scripts/build_release.py appbundle --unsigned

build-ipa: ## Build a signed IPA using your locally configured Apple provisioning
	flutter build ipa --release

build-ios: ios-release ## Alias for the unsigned iOS verification build

lint-native-android: ## Check native Android release lint
	flutter build apk --release --config-only
	cd android && ./gradlew :app:lintRelease

android-signing-report: ## Show Android signing certificate metadata, never private keys
	cd android && ./gradlew signingReport

run: ## Run the app (optionally DEVICE=<id> from make devices)
	flutter run $(if $(DEVICE),-d "$(DEVICE)")

ios-preview-build: ## Build the opt-in local HTTP preview for iOS Simulator
	flutter build ios --debug --simulator --dart-define=ALLOW_LOCAL_SERVER_HTTP=true --dart-define=USE_LOCAL_OPENCODE_SERVER=true

ios-release: ## Build the iOS Release app without code signing
	flutter build ios --release --no-codesign

build-check: apk-debug apk-unsigned ios-release ## Build debug Android and unsigned release Android/iOS artifacts

devices: ## List Flutter devices
	flutter devices

doctor: ## Show Flutter toolchain diagnostics
	flutter doctor -v

clean: ## Remove Flutter build artifacts
	flutter clean
