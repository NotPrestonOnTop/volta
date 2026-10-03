# Apps run as plain arm64; only code loaded into system processes needs arm64e.
ARCHS = arm64

# The top-level Makefile exports these; the defaults are for building this folder on its own.
TARGET ?= iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME ?= rootless

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = VoltaDrive

VoltaDrive_FILES = DriveApp.m
VoltaDrive_CFLAGS = -fobjc-arc
VoltaDrive_FRAMEWORKS = UIKit CoreGraphics QuartzCore MapKit CoreLocation MediaPlayer
VoltaDrive_CODESIGN_FLAGS = -Sentitlements.plist

include $(THEOS_MAKE_PATH)/application.mk
