#!/usr/bin/env bash
set -e

echo "=========================================================="
echo " Building VPXMetalDecoder & VPXFixup (id.medkintos)"
echo "=========================================================="

cd "$(dirname "$0")/.."

mkdir -p build
make clean
make all
make -C kext/VPXFixup clean
make -C kext/VPXFixup all
rm -f kext/VPXFixup/*.o

echo ""
echo "[✓] Build complete!"
echo "    - Bundle: build/VPXMetalVADriver.bundle"
echo "    - Kext:   build/VPXFixup.kext"
echo "    - Test App (Universal): build/vpx_metal_test"
echo "    - Test App (x86_64):    build/vpx_metal_test_x86_64"
