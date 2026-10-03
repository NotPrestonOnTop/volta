# Volta - rootless tweak for iOS 15 - 17
export TARGET := iphone:clang:latest:15.0
export ARCHS = arm64 arm64e
export THEOS_PACKAGE_SCHEME = rootless

INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

# Volta     -> every app: status bar battery, clock text, hidden items, fake notch (plus Control Center in SpringBoard)
# VoltaHome -> SpringBoard only: Home Screen, icons, dock, wallpapers, Lock Screen, notifications, fun
TWEAK_NAME = Volta VoltaHome

Volta_FILES = Tweak.x Status.x Keyboard.x Share.x
Volta_CFLAGS = -fobjc-arc
Volta_FRAMEWORKS = UIKit QuartzCore

VoltaHome_FILES = Home.x Layout.x Lock.x LockLook.x Icons.x Notify.x Switcher.x Popups.x Sounds.x Safety.x Fun.x VLTScene.m VLTSlider.m
VoltaHome_CFLAGS = -fobjc-arc
VoltaHome_FRAMEWORKS = UIKit QuartzCore AVFoundation CoreMedia CoreMotion AudioToolbox

# The Settings pane, the apps (Phone, Calculator, Voltweaks) and Voltweaks's root helper
SUBPROJECTS += voltaprefs voltaphone voltacalc voltaweather voltacompass voltamemos voltawallet voltasaved voltadrive voltweaks voltweakshelper

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/aggregate.mk
