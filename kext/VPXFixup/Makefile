# Makefile for VPXFixup Lilu Plugin
# Target: macOS Sequoia (Darwin 24) & macOS Tahoe (Darwin 25) x86_64

CLANG = /Library/Developer/CommandLineTools/usr/bin/clang++
SDK = /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk
LILU_ROOT = ../../external/Lilu/Lilu.kext/Contents/Resources
MACOSX_MIN_VER ?= 15.0

CFLAGS = -arch x86_64 -isysroot $(SDK) -mmacosx-version-min=$(MACOSX_MIN_VER) \
         -mkernel -nostdinc -fno-builtin -fno-rtti -fno-exceptions \
         -D__ACIDANTHERA_MAC_SDK -DLILU_KEXTPATCH_SUPPORT \
         -DPRODUCT_NAME=VPXFixup -DMODULE_VERSION=1.0.1 \
         -I$(SDK)/System/Library/Frameworks/Kernel.framework/Headers \
         -I$(LILU_ROOT) \
         -I. -std=c++14 -O2 -Wall -Wno-sign-conversion -Wno-shadow

LDFLAGS = -arch x86_64 -isysroot $(SDK) -mmacosx-version-min=$(MACOSX_MIN_VER) \
          -Xlinker -kext -nostdlib \
          -Xlinker -undefined -Xlinker dynamic_lookup

BUILD_KEXT = ../../build/VPXFixup.kext
MACOS_DIR = $(BUILD_KEXT)/Contents/MacOS

all: $(MACOS_DIR)/VPXFixup $(BUILD_KEXT)/Contents/Info.plist

$(MACOS_DIR)/VPXFixup: VPXFixup.o plugin_start.o
	@mkdir -p $(MACOS_DIR)
	$(CLANG) $(LDFLAGS) -o $@ $^
	@codesign --force --deep --sign - $(BUILD_KEXT)
	@echo "[+] Built and signed VPXFixup.kext"

VPXFixup.o: VPXFixup.cpp VPXFixup.hpp
	$(CLANG) $(CFLAGS) -c $< -o $@

plugin_start.o: $(LILU_ROOT)/Library/plugin_start.cpp
	$(CLANG) $(CFLAGS) -c $< -o $@

$(BUILD_KEXT)/Contents/Info.plist: Info.plist
	@mkdir -p $(BUILD_KEXT)/Contents
	cp $< $@

clean:
	rm -rf *.o $(BUILD_KEXT)

.PHONY: all clean
