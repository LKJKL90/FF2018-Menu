ARCHS = arm64
TARGET = iphone:clang:latest:13.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = FFF_XZ
FFF_XZ_FILES = Tweak.xm main.cpp patch_shim.c stealth.c
FFF_XZ_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-function
FFF_XZ_FRAMEWORKS = UIKit Foundation CoreGraphics QuartzCore
FFF_XZ_LDFLAGS = -undefined dynamic_lookup -Wl,-install_name,@rpath/FFF_XZ.dylib -Wl,-install_name,@rpath/FFF_XZ.dylib

include $(THEOS_MAKE_PATH)/tweak.mk
