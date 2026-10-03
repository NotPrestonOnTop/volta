# Apps run as plain arm64; only code loaded into system processes needs arm64e.
ARCHS = arm64
# The top-level Makefile exports the same target; this covers building here on its own.
TARGET ?= iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = VoltaMemos

VoltaMemos_FILES = MemosApp.m
VoltaMemos_CFLAGS = -fobjc-arc
VoltaMemos_FRAMEWORKS = UIKit CoreGraphics QuartzCore AVFoundation
VoltaMemos_CODESIGN_FLAGS = -Sentitlements.plist

include $(THEOS_MAKE_PATH)/application.mk
