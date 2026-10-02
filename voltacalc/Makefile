# Apps run as plain arm64; only code loaded into system processes needs arm64e.
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = VoltaCalc

VoltaCalc_FILES = CalcApp.m
VoltaCalc_CFLAGS = -fobjc-arc
VoltaCalc_FRAMEWORKS = UIKit CoreGraphics QuartzCore
VoltaCalc_CODESIGN_FLAGS = -Sentitlements.plist

include $(THEOS_MAKE_PATH)/application.mk
