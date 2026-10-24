.PHONY: help setup bootstrap get format format-check analyze lint test test-bootstrap test-ios-simulator validate apk-debug apk-release build-apk ios-preview-build ios-release build-check devices doctor clean test-host test-host-runtime test-mobile-simulator test-local-app setup-claude test-claude test-claude-local-app

.DEFAULT_GOAL := help

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

test-bootstrap: ## Test native project configuration
	python3 scripts/test_bootstrap.py

test-ios-simulator: ## Run the onboarding integration test on a booted iOS Simulator
	flutter drive --driver=test_driver/integration_test.dart --target=integration_test/onboarding_test.dart

validate: format-check analyze test test-bootstrap ## Run formatting, analysis, and all tests

test-host: ## Check and test the restricted filesystem plugin against real local files
	python3 host/file-browser/test_filesystem.py
	node --check host/file-browser/index.js
	node --check host/file-browser/policy.js
	node --test host/file-browser/plugin.test.js

test-host-runtime: ## Verify authentication and plugin wiring in an isolated OpenCode v2 server
	python3 scripts/test_file_browser_runtime.py

test-mobile-simulator: ## Exercise file review, prompt recovery and QR confirmation on iOS Simulator
	flutter drive --no-pub --driver=test_driver/integration_test.dart --target=integration_test/mobile_workflows_test.dart

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
	flutter build apk --release

build-apk: apk-release ## Alias for building the Android release APK

ios-preview-build: ## Build the opt-in local HTTP preview for iOS Simulator
	flutter build ios --debug --simulator --dart-define=ALLOW_LOCAL_SERVER_HTTP=true --dart-define=USE_LOCAL_OPENCODE_SERVER=true

ios-release: ## Build the iOS Release app without code signing
	flutter build ios --release --no-codesign

build-check: apk-debug ios-release ## Build Android debug and unsigned iOS Release artifacts

devices: ## List Flutter devices
	flutter devices

doctor: ## Show Flutter toolchain diagnostics
	flutter doctor -v

clean: ## Remove Flutter build artifacts
	flutter clean
