APP_NAME := Fluorescent
BUILD_DIR := build
SDK := $(shell xcrun --sdk macosx --show-sdk-path)
SWIFTC := xcrun --sdk macosx swiftc
PLISTBUDDY := /usr/libexec/PlistBuddy
VERSION := $(shell $(PLISTBUDDY) -c "Print :CFBundleShortVersionString" Info.plist 2>/dev/null || echo 0.0)

SRC := main.swift overlay.swift
FLAGS := -O -parse-as-library -sdk $(SDK) -target arm64-apple-macos13 \
    -framework AppKit -framework SwiftUI -framework CoreGraphics -framework Carbon \
    -framework IOKit -framework ApplicationServices -framework ServiceManagement

APP_BUNDLE := $(BUILD_DIR)/$(APP_NAME).app
DMG_DIR := $(BUILD_DIR)/dmgroot
VOLNAME := $(APP_NAME) $(VERSION)
DMG := $(BUILD_DIR)/$(APP_NAME)-$(VERSION).dmg

.PHONY: all build bundle dmg release run clean reset

all: build

build: $(BUILD_DIR)/$(APP_NAME)

$(BUILD_DIR)/$(APP_NAME): $(SRC)
	mkdir -p $(BUILD_DIR)
	$(SWIFTC) $(FLAGS) -o $@ $(SRC)

bundle: build
	mkdir -p $(APP_BUNDLE)/Contents/MacOS
	cp Info.plist $(APP_BUNDLE)/Contents/Info.plist
	cp $(BUILD_DIR)/$(APP_NAME) $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)
	printf "APPL????" > $(APP_BUNDLE)/Contents/PkgInfo
	codesign --force --deep -s - $(APP_BUNDLE)

dmg: bundle
	rm -rf $(DMG_DIR) $(DMG)
	mkdir -p $(DMG_DIR)
	cp -R $(APP_BUNDLE) $(DMG_DIR)/
	ln -sf /Applications $(DMG_DIR)/Applications
	hdiutil create -fs HFS+ -volname "$(VOLNAME)" -srcfolder "$(DMG_DIR)" -ov -format UDZO "$(DMG)"
	@echo "Created $(DMG)"

release: dmg

run: bundle
	open $(APP_BUNDLE)

clean:
	rm -rf $(BUILD_DIR)

reset:
	tccutil reset All org.kestell.fluorescent
