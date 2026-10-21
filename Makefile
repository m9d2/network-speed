ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0

THEOS_PACKAGE_SCHEME = roothide

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = NetSpeedStatus

NetSpeedStatus_FILES = Tweak.xm
NetSpeedStatus_FRAMEWORKS = UIKit
NetSpeedStatus_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk

BUNDLE_NAME = NetSpeedStatusPrefs
NetSpeedStatusPrefs_FILES = Preferences/NSRootListController.m
NetSpeedStatusPrefs_FRAMEWORKS = UIKit
NetSpeedStatusPrefs_LDFLAGS = -undefined dynamic_lookup
NetSpeedStatusPrefs_INSTALL_PATH = /Library/PreferenceBundles
NetSpeedStatusPrefs_RESOURCE_FILES = Root.plist
NetSpeedStatusPrefs_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/bundle.mk

after-install::
	install.exec "killall -9 SpringBoard"
