PROJECT := alter.xcodeproj
TARGET := Alter
CONFIG ?= Debug
DERIVED := build

APP := $(DERIVED)/Build/Products/$(CONFIG)/Alter.app
RELEASE_APP := $(DERIVED)/Build/Products/Release/Alter.app

.PHONY: build run clean release cask

build:
	xcodebuild -project $(PROJECT) -scheme $(TARGET) -configuration $(CONFIG) -derivedDataPath $(DERIVED) build

run: build
	open $(APP)

clean:
	rm -rf $(DERIVED)

# ---------------------------------------------------------------------------
# Release (unsigned/ad-hoc for now — see README install notes).
#
# When a personal Developer ID certificate becomes available:
#   1. alter.xcodeproj Release config:
#        CODE_SIGN_IDENTITY = "Developer ID Application"
#        DEVELOPMENT_TEAM = <personal team id>
#        CODE_SIGN_STYLE = Automatic
#        ENABLE_HARDENED_RUNTIME = YES
#   2. Store notarization credentials once:
#        xcrun notarytool store-credentials "alter-notary" \
#          --apple-id <apple id> --team-id <team id> --password <app-specific pw>
#   3. After `make release`:
#        xcrun notarytool submit dist/Alter-<version>.zip \
#          --keychain-profile alter-notary --wait
#        xcrun stapler staple $(RELEASE_APP)
#      then re-zip (the stapled ticket must ship inside the zip).
# ---------------------------------------------------------------------------
release:
	xcodebuild -project $(PROJECT) -scheme $(TARGET) -configuration Release -destination 'generic/platform=macOS' -derivedDataPath $(DERIVED) build
	lipo -info "$(RELEASE_APP)/Contents/MacOS/Alter"
	@mkdir -p dist
	@VERSION=$$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$(RELEASE_APP)/Contents/Info.plist"); \
	rm -f "dist/Alter-$$VERSION.zip"; \
	ditto -c -k --keepParent "$(RELEASE_APP)" "dist/Alter-$$VERSION.zip"; \
	echo "==> dist/Alter-$$VERSION.zip"; \
	shasum -a 256 "dist/Alter-$$VERSION.zip"

# Prints the Homebrew cask stanza for the tap repo (kartikssj/homebrew-tap),
# with version and sha256 filled in from the artifact in dist/.
cask:
	@Scripts/print-cask.sh
