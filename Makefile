APP_NAME := Fluorescent
BUILD_DIR := build
SDK := $(shell xcrun --sdk macosx --show-sdk-path)
SWIFTC := xcrun --sdk macosx swiftc

SRC := main.swift overlay.swift
FLAGS := -O -parse-as-library -sdk $(SDK) -target arm64-apple-macos13 \
    -framework AppKit -framework SwiftUI -framework CoreGraphics -framework Carbon -framework IOKit

.PHONY: all build bundle run clean

all: bundle

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

run: bundle
	open $(APP_NAME).app

clean:
	rm -rf $(BUILD_DIR) $(APP_NAME).app
	tccutil reset All org.kestell.fluorescent

