# Apps run as plain arm64; only code loaded into system processes needs arm64e.
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = Voltweaks

Voltweaks_FILES = TweaksApp.m
Voltweaks_CFLAGS = -fobjc-arc
Voltweaks_FRAMEWORKS = UIKit CoreGraphics QuartzCore
Voltweaks_CODESIGN_FLAGS = -Sentitlements.plist

include $(THEOS_MAKE_PATH)/application.mk
