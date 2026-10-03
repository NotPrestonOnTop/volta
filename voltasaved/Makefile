# Apps run as plain arm64; only code loaded into system processes needs arm64e.
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = VoltaSaved

VoltaSaved_FILES = SavedApp.m
VoltaSaved_CFLAGS = -fobjc-arc
VoltaSaved_FRAMEWORKS = UIKit CoreGraphics QuartzCore
VoltaSaved_CODESIGN_FLAGS = -Sentitlements.plist

include $(THEOS_MAKE_PATH)/application.mk
