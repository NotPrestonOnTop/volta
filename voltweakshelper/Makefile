# The small root tool Voltweaks uses to switch a tweak on or off.
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

TOOL_NAME = voltweaks-helper

voltweaks-helper_FILES = main.c
voltweaks-helper_CFLAGS = -Wall -Wextra
voltweaks-helper_CODESIGN_FLAGS = -Sentitlements.plist
voltweaks-helper_INSTALL_PATH = /usr/libexec

include $(THEOS_MAKE_PATH)/tool.mk
