ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:14.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = FF2018Menu
FF2018Menu_FILES = Tweak.xm main.cpp substrate_shim.c
FF2018Menu_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-function
FF2018Menu_FRAMEWORKS = UIKit Foundation CoreGraphics QuartzCore
FF2018Menu_LDFLAGS = -undefined dynamic_lookup

# Le hook inline ecrit dans __TEXT d'un binaire deja signe. Sur un appareil
# non jailbreake (TXM, A12+) c'est refuse et le process est tue au premier
# appel. Par defaut on ne l'embarque donc pas. `make FFHOOK=1` le reactive.
ifneq ($(FFHOOK),1)
FF2018Menu_CFLAGS += -DFF_NO_HOOK
endif

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 freefireth"
