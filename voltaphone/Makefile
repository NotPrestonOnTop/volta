# Apps run as plain arm64; only code loaded into system processes needs arm64e.
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = VoltaPhone

VoltaPhone_FILES = PhoneApp.m
VoltaPhone_CFLAGS = -fobjc-arc
VoltaPhone_FRAMEWORKS = UIKit CoreGraphics QuartzCore AudioToolbox
VoltaPhone_CODESIGN_FLAGS = -Sentitlements.plist

include $(THEOS_MAKE_PATH)/application.mk
