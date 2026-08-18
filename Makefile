APP := build/AppleIIEmulator.app
BUILD_DIR := .build/arm64-apple-macosx/debug
RESOURCE_BUNDLE := AppleIIEmulator_AppleIIEmulator.bundle
CODESIGN_IDENTITY ?= -

.PHONY: package-app verify-app-bundle

## Build a conventional macOS app bundle with its SwiftPM resources in
## Contents/Resources.  The verification target is deliberately separate so
## release automation can assert the distributable layout before notarizing.
package-app:
	swift build
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp AppBundle/Info.plist $(APP)/Contents/Info.plist
	cp AppBundle/AppIcon.icns $(APP)/Contents/Resources/AppIcon.icns
	cp $(BUILD_DIR)/AppleIIEmulator $(APP)/Contents/MacOS/AppleIIEmulator
	ditto $(BUILD_DIR)/$(RESOURCE_BUNDLE) $(APP)/Contents/Resources/$(RESOURCE_BUNDLE)
	codesign --force --deep --sign "$(CODESIGN_IDENTITY)" $(APP)
	$(MAKE) verify-app-bundle

verify-app-bundle:
	test -x $(APP)/Contents/MacOS/AppleIIEmulator
	test -d $(APP)/Contents/Resources/$(RESOURCE_BUNDLE)
	test -f $(APP)/Contents/Resources/$(RESOURCE_BUNDLE)/AppleIIPlus-Applesoft-Autostart.rom
	test -f $(APP)/Contents/Resources/$(RESOURCE_BUNDLE)/VintagePlasticTexture.png
	codesign --verify --deep --strict $(APP)
