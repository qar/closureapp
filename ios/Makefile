# Commands for the iOS app. Run `make` in ios/ (or `make -C ios` from the repository
# root) to list them.
#
# Settings for this Mac only (device name, proxy) go in ios/local.mk, which git
# ignores. Example:
#   DEVICE := Entropy
#   export https_proxy := http://127.0.0.1:7897

PROJECT   := Closure.xcodeproj
SCHEME    := Closure
BUNDLE_ID := com.qar.closure
DEVICE    ?= Entropy
SIMULATOR ?= Closure iPhone 17
DERIVED   := build/device
APP       := $(DERIVED)/Build/Products/Release-iphoneos/Closure.app

-include local.mk
# App Store Connect API key ids (see fastlane/Fastfile). Optional.
-include fastlane/.env

ifneq ($(APP_STORE_CONNECT_API_KEY_ID),)
AUTH := -authenticationKeyPath $(HOME)/.appstoreconnect/private_keys/AuthKey_$(APP_STORE_CONNECT_API_KEY_ID).p8 \
        -authenticationKeyID $(APP_STORE_CONNECT_API_KEY_ID) \
        -authenticationKeyIssuerID $(APP_STORE_CONNECT_API_KEY_ISSUER_ID)
endif

SHELL := /bin/bash

.DEFAULT_GOAL := help
.PHONY: help project xcode test core-test check build device launch archive upload \
        metadata-push metadata-fetch release

help: ## 列出所有命令
	@grep -hE '^[a-z-]+:.*## ' $(firstword $(MAKEFILE_LIST)) | awk -F ':.*## ' '{printf "  make %-16s %s\n", $$1, $$2}'

project: ## 从 project.yml 生成工程，生成结果需要提交
	xcodegen generate

xcode: ## 在 Xcode 中打开工程
	xed .

test: ## 在模拟器运行单元测试，可设置 SIMULATOR="名称"
	@bash scripts/xcodebuild.sh build/test.log -project "$(PROJECT)" -scheme "$(SCHEME)" \
	  -destination 'platform=iOS Simulator,name=$(SIMULATOR)' test

core-test: ## 在 Mac 上编译并测试 C++ 播放内核
	cmake -S ../core -B ../core/build -DCMAKE_BUILD_TYPE=Release
	cmake --build ../core/build -j
	../core/build/closure_core_tests

check: ## 合并前检查：工程一致、iOS 测试和内核测试通过
	xcodegen generate
	@git diff --quiet -- $(PROJECT) || { echo "error: Closure.xcodeproj differs from project.yml. Commit the regenerated project."; exit 1; }
	@$(MAKE) --no-print-directory test
	@$(MAKE) --no-print-directory core-test

build: ## 编译真机 Release 包
	@bash scripts/xcodebuild.sh build/device.log -project "$(PROJECT)" -scheme "$(SCHEME)" -configuration Release \
	  -destination 'generic/platform=iOS' -derivedDataPath "$(DERIVED)" \
	  -allowProvisioningUpdates $(AUTH) build

device: build ## 编译 Release 包并安装到 iPhone，可设置 DEVICE="名称"
	xcrun devicectl device install app --device '$(DEVICE)' "$(APP)"

launch: ## 在 iPhone 上启动已安装的 App
	xcrun devicectl device process launch --device '$(DEVICE)' "$(BUNDLE_ID)"

archive: ## 为 App Store 归档到 build/Papermoon.xcarchive
	fastlane archive

upload: ## 签名并上传归档到 App Store Connect
	fastlane upload_build

metadata-push: ## 上传 fastlane/metadata 中的商店文案
	fastlane upload_metadata

metadata-fetch: ## 从 App Store Connect 下载商店文案
	fastlane fetch_metadata

release: ## 从 develop 创建发布分支并设置版本：make release VERSION=0.1.0
	@test -n "$(VERSION)" || { echo "usage: make release VERSION=0.1.0"; exit 1; }
	bash scripts/release-start.sh "$(VERSION)"
