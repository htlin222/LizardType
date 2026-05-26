# LizardType — swiftc build (no Xcode project). Run `make help` for targets.
APP_NAME  := LizardType
BUILD_DIR := build
APP       := $(BUILD_DIR)/$(APP_NAME).app
VERSION   := $(shell /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist 2>/dev/null)
DMG       := $(BUILD_DIR)/$(APP_NAME)-$(VERSION).dmg

.DEFAULT_GOAL := build
.PHONY: build dmg run cert icon clean help

build: ## Compile + sign LizardType.app
	@bash build.sh

dmg: build ## Build, then package a distributable .dmg
	@echo "▸ packaging $(DMG)"
	@rm -f "$(DMG)"
	@rm -rf "$(BUILD_DIR)/dmg"
	@mkdir -p "$(BUILD_DIR)/dmg"
	@cp -R "$(APP)" "$(BUILD_DIR)/dmg/"
	@ln -s /Applications "$(BUILD_DIR)/dmg/Applications"
	@hdiutil create -volname "$(APP_NAME)" -srcfolder "$(BUILD_DIR)/dmg" \
		-format UDZO -ov "$(DMG)" >/dev/null
	@rm -rf "$(BUILD_DIR)/dmg"
	@echo "✓ $(DMG)"

run: build ## Build, then launch the app
	@open "$(APP)"

cert: ## Create the stable self-signed signing identity (one-time)
	@bash setup-cert.sh

icon: ## Regenerate Resources/AppIcon.icns from AppIcon-source.png
	@rm -f Resources/AppIcon.icns
	@bash build.sh >/dev/null
	@echo "✓ Resources/AppIcon.icns"

clean: ## Remove build artifacts
	@rm -rf "$(BUILD_DIR)"
	@echo "✓ cleaned"

help: ## List available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-7s\033[0m %s\n", $$1, $$2}'
