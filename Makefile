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

DMG_DIR := $(BUILD_DIR)/dmgroot
VOLNAME := $(APP_NAME) $(VERSION)
DMG := $(BUILD_DIR)/$(APP_NAME)-$(VERSION).dmg

.PHONY: all build bundle dmg release run clean

all: dmg

build: $(BUILD_DIR)/$(APP_NAME)

$(BUILD_DIR)/$(APP_NAME): $(SRC)
	mkdir -p $(BUILD_DIR)
	$(SWIFTC) $(FLAGS) -o $@ $(SRC)

bundle: build
	mkdir -p $(APP_NAME).app/Contents/MacOS
	cp Info.plist $(APP_NAME).app/Contents/Info.plist
	cp $(BUILD_DIR)/$(APP_NAME) $(APP_NAME).app/Contents/MacOS/$(APP_NAME)
	printf "APPL????" > $(APP_NAME).app/Contents/PkgInfo
	codesign --force --deep -s - $(APP_NAME).app

dmg: bundle
	rm -rf $(DMG_DIR) $(DMG)
	mkdir -p $(DMG_DIR)
	cp -R $(APP_NAME).app $(DMG_DIR)/
	ln -sf /Applications $(DMG_DIR)/Applications
	hdiutil create -fs HFS+ -volname "$(VOLNAME)" -srcfolder "$(DMG_DIR)" -ov -format UDZO "$(DMG)"
	@echo "Created $(DMG)"

release: dmg

run: bundle
	open $(APP_NAME).app

clean:
	rm -rf $(BUILD_DIR) $(APP_NAME).app "$(DMG_DIR)" "$(DMG)"
	
reset:
	ccutil reset All org.kestell.fluorescent
