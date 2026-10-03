# Apps run as plain arm64; only code loaded into system processes needs arm64e.
ARCHS = arm64
# The main Volta Makefile exports TARGET; this is for building this folder on its own.
TARGET ?= iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = VoltaWeather

VoltaWeather_FILES = WeatherApp.m
VoltaWeather_CFLAGS = -fobjc-arc
VoltaWeather_FRAMEWORKS = UIKit CoreGraphics QuartzCore Foundation
VoltaWeather_CODESIGN_FLAGS = -Sentitlements.plist

include $(THEOS_MAKE_PATH)/application.mk
