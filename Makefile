# Makefile for VPXMetalDecoder
# Target: macOS Sequoia & Tahoe / Intel Coffee Lake & Comet Lake (x86_64 & Universal)

CC = clang
MACOSX_MIN_VER ?= 15.0
ARCHS = -arch x86_64 -arch arm64
CFLAGS = -O3 -fPIC -Wall -Wextra -Wno-unused-parameter \
         -mmacosx-version-min=$(MACOSX_MIN_VER) \
         -Iinclude -fobjc-arc $(ARCHS)

LDFLAGS = -framework Foundation \
          -framework CoreMedia \
          -framework CoreVideo \
          -framework VideoToolbox \
          -framework Metal \
          -framework IOKit

BUNDLE_DIR = build/VPXMetalVADriver.bundle
BUNDLE_MACOS = $(BUNDLE_DIR)/Contents/MacOS
BUNDLE_PLIST = $(BUNDLE_DIR)/Contents/Info.plist

SRCS = src/VPXMetalCommon.m \
       src/VPXMetalEngine.m \
       src/VPXBitstreamParser.c \
       src/VPXMetalDecoder.m \
       src/VPXMetalVADriver.m \
       src/VPXMediaExtension.m \
       src/VPXInjector.m

TEST_SRCS = test/test_vpx_metal.m $(SRCS)

all: bundle test_app

bundle: $(BUNDLE_MACOS)/VPXMetalVADriver $(BUNDLE_PLIST)

$(BUNDLE_MACOS)/VPXMetalVADriver: $(SRCS)
	@mkdir -p $(BUNDLE_MACOS)
	$(CC) $(CFLAGS) -bundle $(LDFLAGS) -o $@ $(SRCS)
	@echo "[+] Built Universal VideoToolbox bundle binary (x86_64 + arm64): $@"

$(BUNDLE_PLIST): bundle/Info.plist
	@mkdir -p $(BUNDLE_DIR)/Contents
	cp bundle/Info.plist $(BUNDLE_PLIST)
	@echo "[+] Copied bundle Info.plist"

test_app: build/vpx_metal_test build/vpx_metal_test_x86_64

build/vpx_metal_test: $(TEST_SRCS)
	@mkdir -p build
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $(TEST_SRCS)
	@echo "[+] Built Universal test suite binary: $@"

build/vpx_metal_test_x86_64: $(TEST_SRCS)
	@mkdir -p build
	$(CC) -arch x86_64 -mmacosx-version-min=$(MACOSX_MIN_VER) -O3 -fobjc-arc -Iinclude $(LDFLAGS) -o $@ $(TEST_SRCS)
	@echo "[+] Built pure x86_64 test suite binary: $@"

clean:
	rm -rf build

.PHONY: all bundle test_app clean
