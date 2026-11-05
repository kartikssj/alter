PROJECT := alter.xcodeproj
TARGET := Alter
CONFIG ?= Debug
DERIVED := build

APP := $(DERIVED)/Build/Products/$(CONFIG)/Alter.app

.PHONY: build run clean

build:
	xcodebuild -project $(PROJECT) -scheme $(TARGET) -configuration $(CONFIG) -derivedDataPath $(DERIVED) build

run: build
	open $(APP)

clean:
	rm -rf $(DERIVED)
