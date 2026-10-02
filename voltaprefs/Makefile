include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = VoltaPrefs

VoltaPrefs_FILES = $(wildcard *.m) VLTUnzip.c ../VLTScene.m ../VLTSlider.m
VoltaPrefs_LIBRARIES = z
VoltaPrefs_CFLAGS = -fobjc-arc -I..
VoltaPrefs_FRAMEWORKS = UIKit QuartzCore CoreGraphics PhotosUI UniformTypeIdentifiers AVFoundation CoreMedia ImageIO
VoltaPrefs_PRIVATE_FRAMEWORKS = Preferences
VoltaPrefs_INSTALL_PATH = /Library/PreferenceBundles

include $(THEOS_MAKE_PATH)/bundle.mk

internal-stage::
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences$(ECHO_END)
	$(ECHO_NOTHING)cp entry.plist $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/Volta.plist$(ECHO_END)
