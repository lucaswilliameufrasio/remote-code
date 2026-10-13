.PHONY: help setup bootstrap get format format-check analyze lint test test-bootstrap validate apk-debug ios-preview-build ios-release build-check devices doctor clean

.DEFAULT_GOAL := help

help: ## Show common development commands
	@awk 'BEGIN {FS = ":.*## "}; /^[a-zA-Z_-]+:.*## / {printf "%-24s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

setup: bootstrap ## Generate native projects and install Flutter dependencies

bootstrap: ## Configure Android and iOS native projects
	python3 scripts/bootstrap.py

get: ## Install Flutter dependencies
	flutter pub get

format: ## Format Dart source and tests
	dart format lib test

format-check: ## Check Dart formatting without changing files
	dart format --output=none --set-exit-if-changed lib test

analyze: ## Run Flutter static analysis
	flutter analyze --no-fatal-infos

lint: analyze ## Alias for Flutter static analysis

test: ## Run all Flutter tests
	flutter test

test-bootstrap: ## Test native project configuration
	python3 scripts/test_bootstrap.py

validate: format-check analyze test test-bootstrap ## Run formatting, analysis, and all tests

apk-debug: ## Build the Android debug APK
	flutter build apk --debug

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
