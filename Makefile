# Vigil — build, test and release.
#
# Everything here works with Command Line Tools alone. Full Xcode is optional.

APP_NAME          ?= Vigil
# Reverse-DNS of a domain this project actually controls. It used to be
# `dev.vigil.app`, which reverses to `app.vigil.dev` — a domain nobody here
# owns and anyone could register. Apple does not check, so it would have
# notarized; the cost is squatting on someone else's name and a collision
# later. `rupareliaaniket22.github.io` is real, is where the project's pages
# are served from, and GitHub reserves it to this account.
#
# This has to be settled before the first release and cannot be revisited
# after one. UserDefaults, the SMAppService login item and every per-app
# permission macOS grants are all keyed on this string. `agentsVigilHasSetUp`
# is the worst of them: it is the record that makes a removal stick, so an
# identifier change reads to a *later* version as "nobody ever set these up"
# and silently reinstalls hooks the user deliberately took out.
BUNDLE_ID         ?= io.github.rupareliaaniket22.vigil
# Single source of truth. Scripts/bundle.sh and Scripts/release.sh read the
# same file when they are run directly, so there is one place to change and no
# way for a release to disagree with itself about what it is.
MARKETING_VERSION ?= $(shell cat VERSION)
IDENTITY          ?= -

NOTARY_PROFILE    ?=

export APP_NAME BUNDLE_ID MARKETING_VERSION IDENTITY NOTARY_PROFILE

.PHONY: help build test hooktest lint format bundle run smoke integration icon clean dmg release uninstall

help: ## Show this help
	@grep -E '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

build: ## Debug build
	swift build

test: ## Run the test suite
	swift test

hooktest: ## Hook script stays bounded
	@Tests/HookScript/run.sh

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

# Not a build target. It is here so `make help` lists it, because the people
# most likely to want it are the ones who just discovered Vigil edits their
# agents' config files. It prompts before removing anything.
uninstall: ## Remove everything Vigil put on this Mac
	@Scripts/uninstall.sh

clean: ## Remove build artefacts
	rm -rf .build .build-arm64 .build-x86_64 dist
	rm -rf Resources/$(APP_NAME).iconset Resources/$(APP_NAME).icns

icon: ## Regenerate the app icon
	@swift Scripts/make-icon.swift
	@iconutil -c icns Resources/$(APP_NAME).iconset -o Resources/$(APP_NAME).icns
	@echo "wrote Resources/$(APP_NAME).icns"

# `-unsigned` in the name, and not by accident: this target and Scripts/release.sh
# were both writing dist/Vigil-<version>.dmg, so the ad-hoc image built to check
# the layout was byte-for-byte indistinguishable by name from the notarized one,
# sitting in the same directory, ready to be attached to a GitHub release. The
# shape is the same on purpose; what it is signed with is not.
dmg: bundle ## Package a DMG to check its shape (ad-hoc signed, never shippable)
	@rm -rf dist/dmg-root dist/$(APP_NAME)-$(MARKETING_VERSION)-unsigned.dmg
	@mkdir -p dist/dmg-root
	@ditto dist/$(APP_NAME).app dist/dmg-root/$(APP_NAME).app
	@ln -s /Applications dist/dmg-root/Applications
	@hdiutil create -volname "$(APP_NAME) $(MARKETING_VERSION)" \
		-srcfolder dist/dmg-root -ov -format UDZO \
		dist/$(APP_NAME)-$(MARKETING_VERSION)-unsigned.dmg
	@rm -rf dist/dmg-root
	@echo "built: dist/$(APP_NAME)-$(MARKETING_VERSION)-unsigned.dmg"

release: ## Signed + notarized release (needs IDENTITY and a notary profile)
	@test "$(IDENTITY)" != "-" || { echo "set IDENTITY to your Developer ID"; exit 1; }
	@test -n "$(NOTARY_PROFILE)" || { echo "set NOTARY_PROFILE to a stored notarytool profile"; exit 1; }
	@Scripts/release.sh
