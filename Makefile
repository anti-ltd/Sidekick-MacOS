APP_NAME       := Sidekick
BUNDLE_ID      := ltd.anti.Sidekick
CONFIG         := release
BUILD_DIR      := build
APP_BUNDLE     := $(BUILD_DIR)/$(APP_NAME).app
EXEC_NAME      := $(APP_NAME)
INFO_PLIST     := Resources/Info.plist
ENTITLEMENTS   := Resources/Sidekick.entitlements
ICONSET        := $(BUILD_DIR)/AppIcon.iconset
ICNS           := Resources/AppIcon.icns

SWIFT          := swift
CODESIGN       := codesign
STRIP          := strip

# Stable signing identity so macOS keeps the Accessibility/Screen Recording
# grants across rebuilds — without this every `make run` would re-prompt for
# permissions and the user would lose their granted state. Falls back to
# ad-hoc ("-") on machines without the self-signed "Sidekick Dev" cert.
# Create one via Keychain Access → Certificate Assistant → Create a
# Certificate → type "Code Signing", name "Sidekick Dev".
SIGN_ID        := $(shell security find-certificate -c "Sidekick Dev" >/dev/null 2>&1 && echo "Sidekick Dev" || echo -)

# Size-optimised release flags (same recipe as fileden / clonk).
RELEASE_FLAGS  := -Xswiftc -Osize -Xswiftc -wmo -Xlinker -dead_strip

BIN_PATH       = $(shell $(SWIFT) build -c $(CONFIG) --show-bin-path)

# Optional helper for screenshots — see clonk/fileden for the same pattern.
APPBIN ?= ../app-arently/.build/release/app-arently

.PHONY: all build bundle run debug stop clean test help icon release webrtc-patch dev-cert

all: build

help:
	@echo "Targets:"
	@echo "  make build    — swift build -c release"
	@echo "  make bundle   — assemble Sidekick.app under build/"
	@echo "  make run      — bundle + relaunch app"
	@echo "  make release  — size-optimised bundle, stripped + signed"
	@echo "  make debug    — debug build + run in foreground"
	@echo "  make stop     — kill running Sidekick"
	@echo "  make test     — swift test"
	@echo "  make clean    — swift package clean + remove build/"
	@echo "  make icon     — render AppIcon.icns (requires AppIconRenderer)"
	@echo ""
	@echo "One-time setup:"
	@echo "  make dev-cert  — create the 'Sidekick Dev' self-signed cert so"
	@echo "                   Accessibility / Screen Recording / Local Network"
	@echo "                   grants stick across rebuilds"
	@echo ""
	@echo "Internal:"
	@echo "  make webrtc-patch — fix the broken macOS slice of stasel/WebRTC"

# Create the stable signing identity once per machine. Future `make run`
# / `make bundle` picks it up automatically — the SIGN_ID detection at
# the top of this file flips from "-" (ad-hoc) to "Sidekick Dev".
dev-cert:
	@./scripts/make-dev-cert.sh

# stasel/WebRTC's macOS slice ships only the umbrella header. The patch
# script copies the real headers in and rewrites the umbrella so the
# module imports cleanly. Idempotent; cheap to run every build.
webrtc-patch:
	@./scripts/patch-webrtc-macos.sh

build: webrtc-patch
	$(SWIFT) build -c $(CONFIG) --product $(APP_NAME) $(RELEASE_FLAGS)

test: webrtc-patch
	$(SWIFT) test

bundle: build
	@rm -rf "$(APP_BUNDLE)"
	@mkdir -p "$(APP_BUNDLE)/Contents/MacOS"
	@mkdir -p "$(APP_BUNDLE)/Contents/Resources"
	@mkdir -p "$(APP_BUNDLE)/Contents/Frameworks"
	@cp "$(BIN_PATH)/$(APP_NAME)" "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)"
	@cp "$(INFO_PLIST)" "$(APP_BUNDLE)/Contents/Info.plist"
	@if [ -f "$(ICNS)" ]; then cp "$(ICNS)" "$(APP_BUNDLE)/Contents/Resources/AppIcon.icns"; fi
	@# Embed WebRTC.framework. swift build already staged the right slice
	@# next to the binary; we copy it into Contents/Frameworks/ and patch
	@# the executable's rpath so dyld looks there. SwiftPM doesn't add
	@# the conventional @executable_path/../Frameworks rpath for
	@# binary-target deps, so without this the app launches into a
	@# "Library not loaded: @rpath/WebRTC.framework/WebRTC" crash.
	@cp -R "$(BIN_PATH)/WebRTC.framework" "$(APP_BUNDLE)/Contents/Frameworks/"
	@install_name_tool -add_rpath @executable_path/../Frameworks \
		"$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)" 2>/dev/null || true
	@$(CODESIGN) --force --deep --sign "$(SIGN_ID)" --entitlements "$(ENTITLEMENTS)" "$(APP_BUNDLE)"
	@echo "Built $(APP_BUNDLE) (signed: $(SIGN_ID))"

run: stop bundle
	@open "$(APP_BUNDLE)"
	@echo "Launched $(APP_NAME)"

debug:
	$(SWIFT) run $(APP_NAME)

stop:
	@pkill -x "$(APP_NAME)" 2>/dev/null || true

release: build
	@rm -rf "$(APP_BUNDLE)"
	@mkdir -p "$(APP_BUNDLE)/Contents/MacOS"
	@mkdir -p "$(APP_BUNDLE)/Contents/Resources"
	@mkdir -p "$(APP_BUNDLE)/Contents/Frameworks"
	@cp "$(BIN_PATH)/$(APP_NAME)" "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)"
	@$(STRIP) "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)"
	@cp "$(INFO_PLIST)" "$(APP_BUNDLE)/Contents/Info.plist"
	@if [ -f "$(ICNS)" ]; then cp "$(ICNS)" "$(APP_BUNDLE)/Contents/Resources/AppIcon.icns"; fi
	@cp -R "$(BIN_PATH)/WebRTC.framework" "$(APP_BUNDLE)/Contents/Frameworks/"
	@install_name_tool -add_rpath @executable_path/../Frameworks \
		"$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)" 2>/dev/null || true
	@$(CODESIGN) --force --deep --sign "$(SIGN_ID)" --entitlements "$(ENTITLEMENTS)" "$(APP_BUNDLE)"
	@echo "Built $(APP_BUNDLE) (stripped, signed: $(SIGN_ID))"

icon: build
	@rm -rf "$(ICONSET)"
	@"$(BIN_PATH)/$(APP_NAME)" --icon "$(ICONSET)"
	@if command -v pngquant >/dev/null 2>&1; then \
		echo "Quantizing icon PNGs..."; \
		for f in "$(ICONSET)"/*.png "$(BUILD_DIR)"/icon-*.png; do \
			pngquant --quality=90-100 --speed 1 --force --output "$$f" "$$f" || true; \
		done; \
	fi
	@iconutil -c icns "$(ICONSET)" -o "$(ICNS)"
	@mkdir -p Resources/screenshots
	@cp "$(BUILD_DIR)/icon-512.png"  Resources/screenshots/app-icon.png
	@cp "$(BUILD_DIR)/icon-1024.png" "../sidekick-ios/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
	@cp "$(BUILD_DIR)/icon-512.png"  "../appstage/assets/icons/sidekick-mac.png"
	@cp "$(BUILD_DIR)/icon-512.png"  "../appstage/assets/icons/sidekick-ios.png"
	@echo "Icon -> $(ICNS)"

clean:
	$(SWIFT) package clean
	rm -rf $(BUILD_DIR)
