SWIFT_FORMAT = $(shell xcrun --find swift-format 2>/dev/null)
SWIFTLINT_VERSION = $(shell cat .swiftlint-version 2>/dev/null)
IMPORT_CHECK = --explicit-target-dependency-import-check error
MEMBER_IMPORT_CHECK = -Xswiftc -enable-upcoming-feature -Xswiftc MemberImportVisibility
ARCHITECTURE_PATH = Tools/ArchitectureRules
FORMAT_PATHS = Sources Tests $(ARCHITECTURE_PATH)/Tests $(ARCHITECTURE_PATH)/Package.swift

VERSION ?= 0.1.0
BUILD ?= 1

.PHONY: setup build build-strict test test-strict architecture-test lint format format-check app dist zip run clean

setup:
	@command -v swift >/dev/null 2>&1 || (echo "missing: swift (install Xcode 26.5+ from the App Store)" && exit 1)
	@xcrun --find swift-format >/dev/null 2>&1 || (echo "missing: swift-format (install Xcode 26.5+ command line tools: xcode-select --install)" && exit 1)
	@command -v swiftlint >/dev/null 2>&1 || (echo "missing: swiftlint (install pinned version $$(cat .swiftlint-version): see .github/workflows/ci.yml)" >&2; exit 1)
	@echo "setup ok"

build:
	swift build

build-strict:
	swift build --build-tests $(IMPORT_CHECK) $(MEMBER_IMPORT_CHECK) -Xswiftc -warnings-as-errors

test:
	swift test

test-strict:
	swift test $(IMPORT_CHECK) $(MEMBER_IMPORT_CHECK) -Xswiftc -warnings-as-errors

architecture-test:
	swift test --package-path $(ARCHITECTURE_PATH) --disable-keychain --disable-netrc $(IMPORT_CHECK) -Xswiftc -warnings-as-errors

lint:
	@if [ -z "$$(command -v swiftlint)" ]; then \
		echo "missing: swiftlint (install pinned version $$(cat .swiftlint-version): see .github/workflows/ci.yml)" >&2; \
		exit 1; \
	fi
	@if [ -n "$(SWIFTLINT_VERSION)" ]; then \
		installed="$$(swiftlint version)"; \
		if [ "$$installed" != "$(SWIFTLINT_VERSION)" ]; then \
			echo "error: swiftlint $$installed installed, want $(SWIFTLINT_VERSION) (see .swiftlint-version)" >&2; \
			exit 1; \
		fi; \
	fi
	swiftlint --strict

format:
	@if [ -z "$(SWIFT_FORMAT)" ]; then echo "missing: swift-format (install Xcode 26.5+ command line tools: xcode-select --install)" >&2; exit 1; fi
	"$(SWIFT_FORMAT)" format -i --recursive $(FORMAT_PATHS)

format-check:
	@if [ -z "$(SWIFT_FORMAT)" ]; then echo "missing: swift-format (install Xcode 26.5+ command line tools: xcode-select --install)" >&2; exit 1; fi
	"$(SWIFT_FORMAT)" lint --strict --recursive $(FORMAT_PATHS)

app:
	Scripts/build_app.sh debug

dist:
	VERSION="$(VERSION)" BUILD="$(BUILD)" Scripts/build_app.sh release
	$(MAKE) zip VERSION="$(VERSION)"

# Package the existing Iris.app (e.g. after stapling a notarization ticket).
zip:
	@if [ ! -f Iris.app/Contents/Info.plist ]; then \
		echo "error: missing Iris.app or Iris.app/Contents/Info.plist; build the app before running make zip" >&2; \
		exit 1; \
	fi
	@plist="Iris.app/Contents/Info.plist"; \
	bundle_version="$$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$$plist" 2>/dev/null)" || { \
		echo "error: could not read CFBundleShortVersionString from $$plist" >&2; \
		exit 1; \
	}; \
	if [ "$$bundle_version" != "$(VERSION)" ]; then \
		echo "error: Iris.app version $$bundle_version does not match VERSION=$(VERSION); rebuild or set VERSION to the bundle version" >&2; \
		exit 1; \
	fi
	mkdir -p dist
	ditto -c -k --keepParent --norsrc --noextattr Iris.app dist/Iris-$(VERSION)-macos.zip
	cd dist && shasum -a 256 "Iris-$(VERSION)-macos.zip" > "Iris-$(VERSION)-macos.zip.sha256"
	@echo "Wrote dist/Iris-$(VERSION)-macos.zip"

run: app
	open Iris.app

clean:
	@if [ -d "Iris.app" ] && ! swift Scripts/assert_app_stopped.swift "$(CURDIR)/Iris.app"; then \
		echo "clean aborted: Iris.app is running (quit it, then run make clean again)" >&2; \
		exit 1; \
	fi
	rm -rf .build dist Iris.app
