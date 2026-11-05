# Makefile for VPXFixup (Lilu Kernel Extension Plugin)
# Target: macOS Sequoia (Darwin 24) & macOS Tahoe (Darwin 25) x86_64

MACOSX_MIN_VER ?= 15.0

all:
	$(MAKE) -C kext/VPXFixup all MACOSX_MIN_VER=$(MACOSX_MIN_VER)
	@rm -f kext/VPXFixup/*.o

clean:
	$(MAKE) -C kext/VPXFixup clean
	rm -rf build

.PHONY: all clean
