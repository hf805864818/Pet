DA = 0
FINALPACKAGE = 1
DEBUG = 0

ARCHS = arm64 arm64e
# 允许 CI 用命令行覆盖（CI 按实际存在的 SDK 目录名传入）
TARGET ?= iphone:clang:16.5:15.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = PetDFY

# 纯 Objective-C（无 Logos）。src/Entry.m 提供 MobileSubstrate 构造入口。
PetDFY_FILES = $(wildcard src/Core/*.m) $(wildcard src/Sources/*.m) src/Entry.m

PetDFY_CFLAGS = -fobjc-arc -Wno-everything \
	-I src -I src/Core -I src/Sources

PetDFY_FRAMEWORKS = Foundation UIKit Metal MetalKit MetalPerformanceShaders \
	QuartzCore AVFoundation CoreMotion AudioToolbox CoreGraphics Security ImageIO

# substrate: MobileSubstrate 注入；z: PDZipExtract 的进程内 ZIP 解压
PetDFY_LIBRARIES = substrate z

PetDFY_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/tweak.mk
