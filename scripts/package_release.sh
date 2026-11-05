#!/usr/bin/env bash
# Package VPXFixup.kext into a unified standalone distribution package
# supporting macOS Sonoma (14.0+ / Darwin 23), macOS Sequoia (15.0+ / Darwin 24) and macOS Tahoe (26.0+ / Darwin 25)
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build"
DIST_DIR="${ROOT_DIR}/dist"

cd "${ROOT_DIR}"

MIN_OS_VER="14.0"
PKG_NAME="VPXFixup-Release"
PKG_DIR="${DIST_DIR}/${PKG_NAME}"

echo "=========================================================="
echo " Packaging Unified ${PKG_NAME} (macOS Sonoma 14.0+, Sequoia 15.0+ & Tahoe 26.0+)"
echo "=========================================================="

# 1. Build VPXFixup.kext if compiler is accessible or use prebuilt
if [ ! -d "${BUILD_DIR}/VPXFixup.kext" ] || [ "${FORCE_REBUILD:-0}" = "1" ]; then
    echo "[*] Building unified VPXFixup.kext (Lilu Plugin, min macOS ${MIN_OS_VER})..."
    make -C kext/VPXFixup clean all MACOSX_MIN_VER="${MIN_OS_VER}"
    rm -f kext/VPXFixup/*.o
fi

# 2. Codesign ad-hoc
echo "[*] Applying ad-hoc codesign to VPXFixup.kext..."
codesign --force --deep --sign - "${BUILD_DIR}/VPXFixup.kext"

# 3. Clean and prepare dist directory
rm -rf "${DIST_DIR}"
mkdir -p "${PKG_DIR}"

# 4. Copy kext and verification script
echo "[*] Copying VPXFixup.kext and test_hw_decode.sh..."
cp -R "${BUILD_DIR}/VPXFixup.kext" "${PKG_DIR}/"
cp "${SCRIPT_DIR}/test_hw_decode.sh" "${PKG_DIR}/"
chmod +x "${PKG_DIR}/test_hw_decode.sh"

# 5. Create README.txt
cat << EOF > "${PKG_DIR}/README.txt"
========================================================================
 VPXFixup.kext - Lilu Plugin for VP9 & HEVC Hardware Decoding on Hackintosh
 Bundle ID: id.medkintos.VPXFixup (v1.0.1)
 Unified Build: macOS Sonoma (14.0+), macOS Sequoia (15.0+) & macOS Tahoe (26.0+)
 Companion Metal Driver Repo: https://github.com/medkintos/VP8MetalDecoder
========================================================================

Contents:
  1. VPXFixup.kext     : Unified Lilu kernel extension plugin (Sonoma, Sequoia & Tahoe)
  2. test_hw_decode.sh : Automated hardware decode verification script
                         (Safari, Chrome & Firefox — no browser downloads needed)

--- OpenCore EFI Installation Guide ---

1. Mount your EFI partition:
     sudo diskutil mount disk0s1   (or use MountEFI / OpenCore Configurator)
2. Copy \`VPXFixup.kext\` to:
     EFI/OC/Kexts/VPXFixup.kext
3. In OpenCore \`config.plist\`, add an entry under \`Kernel -> Add\`:
     Arch: Any
     BundlePath: VPXFixup.kext
     Comment: Redirect hwgva-id to board-id for WebKit/Firefox while preserving Apple Music DRM
     Enabled: True
     ExecutablePath: Contents/MacOS/VPXFixup
     PlistPath: Contents/Info.plist
   (Ensure it is listed after Lilu.kext and WhateverGreen.kext)
4. Keep \`unfairgva=4\` in your \`boot-args\` so Apple Music FairPlay DRM continues to work.
5. Reboot your Hackintosh.

--- Verification ---

- Run the automated verification suite:
     ./test_hw_decode.sh
     ./test_hw_decode.sh --open-safari
- Or verify kext is loaded manually:
     kmutil showloaded | grep -i vpxfixup
EOF

# 6. Archive into zip and tar.gz
echo "[*] Creating zip & tar.gz archives for ${PKG_NAME}..."
(
    cd "${DIST_DIR}"
    zip -r -q "${PKG_NAME}.zip" "${PKG_NAME}"
    tar -czf "${PKG_NAME}.tar.gz" "${PKG_NAME}"
)

echo ""
echo "[✓] Unified distribution packages ready in ${DIST_DIR}:"
ls -lh "${DIST_DIR}"
