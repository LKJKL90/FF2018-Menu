ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:14.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = FF2018Menu
FF2018Menu_FILES = Tweak.xm main.cpp
FF2018Menu_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-function
FF2018Menu_FRAMEWORKS = UIKit Foundation CoreGraphics
FF2018Menu_LIBRARIES = substrate
FF2018Menu_LDFLAGS = -undefined dynamic_lookup

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 freefireth"
