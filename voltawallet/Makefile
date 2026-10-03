# Apps run as plain arm64; only code loaded into system processes needs arm64e.
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = VoltaWallet

VoltaWallet_FILES = WalletApp.m
VoltaWallet_CFLAGS = -fobjc-arc
VoltaWallet_FRAMEWORKS = UIKit CoreGraphics QuartzCore CoreImage
VoltaWallet_CODESIGN_FLAGS = -Sentitlements.plist

include $(THEOS_MAKE_PATH)/application.mk
