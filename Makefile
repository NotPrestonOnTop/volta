# Volta - rootless tweak for iOS 15 - 17
export TARGET := iphone:clang:latest:15.0
export ARCHS = arm64 arm64e
export THEOS_PACKAGE_SCHEME = rootless

INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

# Volta     -> every app: status bar battery (plus Control Center in SpringBoard)
# VoltaHome -> SpringBoard only: dock and animated wallpapers
TWEAK_NAME = Volta VoltaHome

Volta_FILES = Tweak.x
Volta_CFLAGS = -fobjc-arc
Volta_FRAMEWORKS = UIKit QuartzCore

VoltaHome_FILES = Home.x Layout.x Lock.x Fun.x VLTScene.m VLTSlider.m
VoltaHome_CFLAGS = -fobjc-arc
VoltaHome_FRAMEWORKS = UIKit QuartzCore AVFoundation CoreMedia CoreMotion AudioToolbox

# The Settings pane, and two small iPad apps (Phone, Calculator)
SUBPROJECTS += voltaprefs voltaphone voltacalc

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/aggregate.mk
