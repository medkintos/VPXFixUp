#!/usr/bin/env bash
# Package VPXFixup.kext into standalone distribution packages
# for both macOS Sequoia (15.x / Darwin 24) and macOS Tahoe (26.x / Darwin 25)
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build"
DIST_DIR="${ROOT_DIR}/dist"

cd "${ROOT_DIR}"

package_target() {
    local TARGET_NAME="$1"
    local MIN_OS_VER="$2"
    local PKG_NAME="VPXFixup-${TARGET_NAME}-Release"
    local PKG_DIR="${DIST_DIR}/${PKG_NAME}"

    echo "=========================================================="
    echo " Packaging ${PKG_NAME} (min macOS ${MIN_OS_VER})"
    echo "=========================================================="

    # 1. Build VPXFixup.kext
    echo "[*] Building VPXFixup.kext (Lilu Plugin) for macOS ${TARGET_NAME} (${MIN_OS_VER})..."
    make -C kext/VPXFixup clean all MACOSX_MIN_VER="${MIN_OS_VER}"
    rm -f kext/VPXFixup/*.o

    # 2. Codesign ad-hoc
    echo "[*] Applying ad-hoc codesign to VPXFixup.kext..."
    codesign --force --deep --sign - "${BUILD_DIR}/VPXFixup.kext"

    # 3. Clean and prepare dist directory for this target
    rm -rf "${PKG_DIR}" "${DIST_DIR}/${PKG_NAME}.zip" "${DIST_DIR}/${PKG_NAME}.tar.gz" "${DIST_DIR}/.DS_Store"
    mkdir -p "${PKG_DIR}"

    # 4. Copy kext
    echo "[*] Copying VPXFixup.kext..."
    cp -R "${BUILD_DIR}/VPXFixup.kext" "${PKG_DIR}/"

    # 5. Create README.txt
    cat << EOF > "${PKG_DIR}/README.txt"
========================================================================
 VPXFixup.kext - Lilu Plugin for VP9 & HEVC Hardware Decoding on Hackintosh
 Bundle ID: id.medkintos.VPXFixup (v1.0.1)
 Target: macOS ${TARGET_NAME} (${MIN_OS_VER}+) / Intel Coffee Lake & Comet Lake
 Companion Metal Driver Repo: https://github.com/medkintos/VP8MetalDecoder
========================================================================

Contents:
  1. VPXFixup.kext : Lilu kernel extension plugin (id.medkintos.VPXFixup)

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

- Verify kext is loaded:
     kmutil showloaded | grep -i vpxfixup
- Open Safari, Yab, Firefox (about:support), or Chrome (chrome://gpu) and play 1080p60/4K YouTube videos:
     Codec will remain on hardware-accelerated "vp09" across consecutive videos while Apple Music DRM continues to work!
EOF

    # 6. Archive into zip and tar.gz
    echo "[*] Creating zip & tar.gz archives for ${PKG_NAME}..."
    (
        cd "${DIST_DIR}"
        zip -r -q "${PKG_NAME}.zip" "${PKG_NAME}"
        tar -czf "${PKG_NAME}.tar.gz" "${PKG_NAME}"
    )
}

# Build Tahoe Release (macOS 26.0 / Darwin 25)
package_target "Tahoe" "26.0"

# Build Sequoia Release (macOS 15.0 / Darwin 24)
package_target "Sequoia" "15.0"

echo ""
echo "[✓] Distribution packages ready in ${DIST_DIR}:"
ls -lh "${DIST_DIR}"
