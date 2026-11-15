ARCHS = arm64 arm64e
TARGET := iphone:clang:latest:14.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = PiliProbe
PiliProbe_FILES = Tweak.m
PiliProbe_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
PiliProbe_FRAMEWORKS = UIKit Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
