# TickBar Makefile
#
# 本地开发:     make run
# 在 Xcode 打开: make open
# 出包:         make release-build VERSION=0.1.0
# 签名+公证:    make notarize VERSION=0.1.0
# 打 DMG:       make dmg VERSION=0.1.0

SHELL := /bin/bash
PROJECT := TickBar.xcodeproj
SCHEME := TickBar
DERIVED := build/dd
APP_NAME := TickBar
DEV_APP_NAME := TickBar-Dev
DEV_BUNDLE_ID := app.tickbar.TickBar.debug
DEV_APP_PATH := $(DERIVED)/Build/Products/Debug/$(DEV_APP_NAME).app
VERSION ?= 0.1.0
BUILD_DIR := build/Release
APP_PATH := $(BUILD_DIR)/$(APP_NAME).app
DMG_PATH := build/$(APP_NAME)-$(VERSION).dmg
ZIP_PATH := build/$(APP_NAME)-$(VERSION).zip

# 尝试自动读取本机钥匙串中的可用证书
AUTO_DEV_ID := $(shell security find-identity -v -p codesigning 2>/dev/null | grep -E "Developer ID Application|Apple Distribution|Apple Development" | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/')
DEV_ID ?= $(AUTO_DEV_ID)

# 签名 / 公证凭据(放 .env,不入库)
-include .env
export

.PHONY: help
help:
	@echo "TickBar build targets:"
	@echo "  make gen              # 重新生成 Xcode 项目"
	@echo "  make build            # Debug 构建(TickBar-Dev.app)"
	@echo "  make run              # 构建并(重新)启动 TickBar-Dev"
	@echo "  make kill             # 关掉正在跑的 TickBar-Dev"
	@echo "  make open             # 在 Xcode 中打开"
	@echo "  make release-build    # Release 构建"
	@echo "  make sign             # 签名"
	@echo "  make dmg              # 打包成 DMG"
	@echo "  make zip              # 打包成 ZIP"
	@echo "  make clean            # 清理产物"

.PHONY: gen
gen:
	xcodegen generate

.PHONY: build
build: gen
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug -derivedDataPath $(DERIVED) \
		CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="-" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=YES \
		build

.PHONY: run
run: build
	@pkill -f "$(DEV_APP_NAME).app/Contents/MacOS" 2>/dev/null; true
	@pkill -f "PanBar-Dev.app/Contents/MacOS" 2>/dev/null; true
	open $(DEV_APP_PATH)
	@echo "✓ Launched $(DEV_APP_NAME) ($(DEV_BUNDLE_ID))"

.PHONY: open
open: gen
	open $(PROJECT)

.PHONY: kill
kill:
	@pkill -f "$(DEV_APP_NAME).app/Contents/MacOS" && echo "✓ Killed $(DEV_APP_NAME)" || echo "(not running)"

.PHONY: release-build
release-build: gen
	mkdir -p $(BUILD_DIR)
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration Release \
		-derivedDataPath $(DERIVED) \
		-archivePath build/$(APP_NAME).xcarchive \
		MARKETING_VERSION=$(VERSION) \
		CURRENT_PROJECT_VERSION=$(shell date +%s) \
		CODE_SIGNING_ALLOWED=NO \
		archive
	rm -rf $(APP_PATH)
	cp -R build/$(APP_NAME).xcarchive/Products/Applications/$(APP_NAME).app $(BUILD_DIR)/
	@if [ -n "$(DEV_ID)" ]; then \
		echo "Signing $(APP_PATH) with $(DEV_ID)..."; \
		codesign --force --options=runtime --timestamp --sign "$(DEV_ID)" --entitlements TickBar/Resources/TickBar.entitlements --deep $(APP_PATH); \
	else \
		echo "Signing $(APP_PATH) with ad-hoc signature..."; \
		codesign --force --deep --sign - $(APP_PATH); \
	fi
	codesign -dvvv $(APP_PATH)
	@echo "✓ Built and signed $(APP_PATH)"

.PHONY: sign
sign:
	@test -d "$(APP_PATH)" || (echo "✗ $(APP_PATH) not found — run 'make release-build' first" && exit 1)
	@if [ -n "$(DEV_ID)" ]; then \
		echo "Signing with $(DEV_ID)..."; \
		codesign --force --options=runtime --timestamp --sign "$(DEV_ID)" --entitlements TickBar/Resources/TickBar.entitlements --deep $(APP_PATH); \
	else \
		echo "Signing with ad-hoc..."; \
		codesign --force --deep --sign - $(APP_PATH); \
	fi
	codesign --verify --deep --strict --verbose=2 $(APP_PATH)
	@echo "✓ Signed"

.PHONY: zip
zip:
	@test -d "$(APP_PATH)" || (echo "✗ $(APP_PATH) not found — run 'make release-build' first" && exit 1)
	cd $(BUILD_DIR) && ditto -c -k --keepParent --sequesterRsrc $(APP_NAME).app ../$(APP_NAME)-$(VERSION).zip
	@echo "✓ ZIP at $(ZIP_PATH)"

.PHONY: dmg
dmg:
	@test -d "$(APP_PATH)" || (echo "✗ $(APP_PATH) not found — run 'make release-build' first" && exit 1)
	rm -f $(DMG_PATH)
	@if command -v create-dmg >/dev/null; then \
		create-dmg \
			--volname "$(APP_NAME) $(VERSION)" \
			--window-pos 200 120 \
			--window-size 540 380 \
			--icon-size 100 \
			--icon "$(APP_NAME).app" 140 190 \
			--app-drop-link 400 190 \
			--no-internet-enable \
			$(DMG_PATH) \
			$(APP_PATH); \
	else \
		echo "create-dmg not found, generating DMG via hdiutil..."; \
		hdiutil create -volname "$(APP_NAME) $(VERSION)" -srcfolder $(APP_PATH) -ov -format UDZO $(DMG_PATH); \
	fi
	@echo "✓ DMG at $(DMG_PATH)"

.PHONY: clean
clean:
	rm -rf build/ DerivedData/ $(DERIVED)
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) clean 2>/dev/null || true
