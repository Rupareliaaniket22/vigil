# Vigil — build, test and release.
#
# Everything here works with Command Line Tools alone. Full Xcode is optional.

APP_NAME          ?= Vigil
BUNDLE_ID         ?= dev.vigil.app
MARKETING_VERSION ?= 0.1.0
IDENTITY          ?= -

export APP_NAME BUNDLE_ID MARKETING_VERSION IDENTITY

.PHONY: help build test lint format bundle run smoke integration icon clean dmg release

help: ## Show this help
	@grep -E '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

build: ## Debug build
	swift build

test: ## Run the test suite
	swift test

lint: ## Check formatting (fails on drift)
	swift format lint --recursive --strict Sources Tests

format: ## Reformat in place
	swift format --in-place --recursive Sources Tests

bundle: ## Build a universal, signed .app
	@Scripts/build-universal.sh $(APP_NAME)
	@Scripts/bundle.sh

integration: bundle ## Drive a real app through its whole loop
	@Scripts/integration-test.sh

smoke: bundle ## Build the panel headlessly and check it lays out
	@VIGIL_SMOKE=1 ./dist/$(APP_NAME).app/Contents/MacOS/$(APP_NAME)

run: bundle ## Build and launch
	@pkill -x $(APP_NAME) 2>/dev/null || true
	open dist/$(APP_NAME).app

clean: ## Remove build artefacts
	rm -rf .build .build-arm64 .build-x86_64 dist
	rm -rf Resources/$(APP_NAME).iconset Resources/$(APP_NAME).icns

icon: ## Regenerate the app icon
	@swift Scripts/make-icon.swift
	@iconutil -c icns Resources/$(APP_NAME).iconset -o Resources/$(APP_NAME).icns
	@echo "wrote Resources/$(APP_NAME).icns"

dmg: bundle ## Package a DMG
	@rm -f dist/$(APP_NAME).dmg
	@hdiutil create -volname "$(APP_NAME)" -srcfolder dist/$(APP_NAME).app \
		-ov -format UDZO dist/$(APP_NAME).dmg
	@echo "built: dist/$(APP_NAME).dmg"

release: ## Signed + notarized release (needs IDENTITY and a notary profile)
	@test "$(IDENTITY)" != "-" || { echo "set IDENTITY to your Developer ID"; exit 1; }
	@Scripts/release.sh
