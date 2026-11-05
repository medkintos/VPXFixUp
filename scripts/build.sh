#!/usr/bin/env bash
set -e

echo "=========================================================="
echo " Building VPXFixup.kext (id.medkintos.VPXFixup)"
echo "=========================================================="

cd "$(dirname "$0")/.."

mkdir -p build
make -C kext/VPXFixup clean
make -C kext/VPXFixup all
rm -f kext/VPXFixup/*.o

echo ""
echo "[✓] Build complete!"
echo "    - Kext: build/VPXFixup.kext"
