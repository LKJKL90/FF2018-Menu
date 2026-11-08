ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:14.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = FFF_XZ
FFF_XZ_FILES = Tweak.xm main.cpp patch_shim.c
FFF_XZ_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-function -fvisibility=hidden
FFF_XZ_FRAMEWORKS = UIKit Foundation CoreGraphics QuartzCore
FFF_XZ_LDFLAGS = -undefined dynamic_lookup -Wl,-S,-x

include $(THEOS_MAKE_PATH)/tweak.mk
