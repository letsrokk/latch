SHELL := /bin/zsh
.DEFAULT_GOAL := help

CONFIG ?= debug
OUTPUT ?= $(CURDIR)/dist
APP ?= $(OUTPUT)/LATCH.app

PROJECT := $(CURDIR)/LATCH.xcodeproj
SCHEME := LATCH
DERIVED_DATA := $(CURDIR)/.build/xcode-derived-data
XCODEBUILD := xcodebuild -project "$(PROJECT)" -scheme "$(SCHEME)" -derivedDataPath "$(DERIVED_DATA)"
XCODE_CONFIG := $(if $(filter release,$(CONFIG)),Release,Debug)
BUILT_APP := $(DERIVED_DATA)/Build/Products/$(XCODE_CONFIG)/LATCH.app
SCRIPT_TESTS := \
	Tests/BuildScripts/atomic-app-replacement-test.sh \
	Tests/BuildScripts/app-icon-packaging-test.sh \
	Tests/BuildScripts/stage-xcode-app-test.sh \
	Tests/BuildScripts/stop-running-app-test.sh \
	Tests/BuildScripts/prepare-app-for-replacement-test.sh

.PHONY: help validate-config script-tests test build app release check notarize clean module-names-check branding-check system-test

help:
	@printf '%s\n' \
		'LATCH development tasks' \
		'' \
		'  make test [FILTER=BrandingContractTests]   Run Xcode tests or a filtered selection.' \
		'  make module-names-check                     Verify Swift module names use LATCH.' \
		'  make branding-check                         Verify active product branding uses LATCH.' \
		'  make build [CONFIG=debug|release]           Build the LATCH Xcode scheme.' \
		'  make app [CONFIG=debug|release]             Stage the signed Xcode product.' \
		'  make release SIGNING_IDENTITY="..." TEAM_ID="..."' \
		'                                                Build and stage a release-signed app.' \
		'  make check                                  Run project, script, unit, and bundle checks.' \
		'  make notarize NOTARY_PROFILE="..."          Submit the release-signed app.' \
		'  make system-test STEP=... SYSTEM_TEST_ACK=YES' \
		'                                                Run one explicit installed-system test step.' \
		'  make clean                                  Clean Xcode derived data products.' \
		'' \
		'Variables:' \
		'  CONFIG=debug                                Build configuration.' \
		'  OUTPUT=./dist                               App output directory.' \
		'  APP=./dist/LATCH.app                       Existing app for release/notarize.'

validate-config:
	@[[ "$(CONFIG)" == debug || "$(CONFIG)" == release ]] || { print -u2 'CONFIG must be debug or release.'; exit 64; }

module-names-check:
	./scripts/check-latch-module-names.sh

branding-check:
	./scripts/check-latch-branding.sh

script-tests:
	@for script in $(SCRIPT_TESTS); do /bin/zsh "$$script" || exit $$?; done

test: validate-config script-tests
	@if [[ -n "$(FILTER)" ]]; then \
		$(XCODEBUILD) -configuration "$(XCODE_CONFIG)" -destination 'platform=macOS' -only-testing:"LATCHTests/$(FILTER)" test; \
	else \
		$(XCODEBUILD) -configuration "$(XCODE_CONFIG)" -destination 'platform=macOS' test; \
	fi

build: validate-config
	$(XCODEBUILD) -configuration "$(XCODE_CONFIG)" -destination 'platform=macOS' build

app: build
	/bin/zsh ./scripts/stage-xcode-app.sh "$(BUILT_APP)" "$(OUTPUT)"

release:
	@[[ -n "$(SIGNING_IDENTITY)" ]] || { print -u2 'SIGNING_IDENTITY is required.'; exit 64; }
	@[[ -n "$(TEAM_ID)" ]] || { print -u2 'TEAM_ID is required.'; exit 64; }
	$(XCODEBUILD) -configuration Release -destination 'platform=macOS' CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$(SIGNING_IDENTITY)" DEVELOPMENT_TEAM="$(TEAM_ID)" build
	/bin/zsh ./scripts/stage-xcode-app.sh "$(DERIVED_DATA)/Build/Products/Release/LATCH.app" "$(dir $(APP))"

check: validate-config
	./Tests/BuildScripts/xcode-project-contract-test.sh
	$(MAKE) script-tests
	./scripts/check-latch-module-names.sh
	./scripts/check-latch-branding.sh
	$(XCODEBUILD) -configuration Debug -destination 'platform=macOS' test
	$(MAKE) app CONFIG=debug OUTPUT="$(OUTPUT)"
	./Tests/BuildScripts/xcode-bundle-contract-test.sh "$(OUTPUT)/LATCH.app"

notarize:
	@[[ -n "$(NOTARY_PROFILE)" ]] || { print -u2 'NOTARY_PROFILE is required.'; exit 64; }
	./scripts/notarize-app.sh "$(APP)" "$(NOTARY_PROFILE)"

system-test:
	@STEP="$(STEP)" SIGNING_IDENTITY="$(SIGNING_IDENTITY)" TEAM_ID="$(TEAM_ID)" SYSTEM_TEST_ACK="$(SYSTEM_TEST_ACK)" SYSTEM_TEST_RUN_ID="$(SYSTEM_TEST_RUN_ID)" /bin/zsh ./scripts/system-test.sh

clean:
	$(XCODEBUILD) -configuration "$(XCODE_CONFIG)" clean
