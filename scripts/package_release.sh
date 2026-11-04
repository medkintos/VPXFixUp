#!/usr/bin/env bash
# Package VPXMetalVADriver and VPXFixup.kext into standalone distribution packages
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
    local PKG_NAME="VPXMetalVADriver-${TARGET_NAME}-Release"
    local PKG_DIR="${DIST_DIR}/${PKG_NAME}"

    echo "=========================================================="
    echo " Packaging ${PKG_NAME} (min macOS ${MIN_OS_VER})"
    echo "=========================================================="

    # 1. Clean and build bundle & test app with target MACOSX_MIN_VER
    echo "[*] Compiling VPXMetalVADriver.bundle & test app for macOS ${TARGET_NAME} (${MIN_OS_VER})..."
    make clean
    make all MACOSX_MIN_VER="${MIN_OS_VER}"

    # 2. Build VPXFixup.kext
    echo "[*] Building VPXFixup.kext (Lilu Plugin) for macOS ${TARGET_NAME}..."
    make -C kext/VPXFixup clean all MACOSX_MIN_VER="${MIN_OS_VER}"
    rm -f kext/VPXFixup/*.o

    # 3. Codesign ad-hoc
    echo "[*] Applying ad-hoc codesign to bundle, kext, and binaries..."
    codesign --force --deep --sign - "${BUILD_DIR}/VPXMetalVADriver.bundle"
    codesign --force --deep --sign - "${BUILD_DIR}/VPXFixup.kext"
    codesign --force --sign - "${BUILD_DIR}/vpx_metal_test"

    # 4. Clean and prepare dist directory for this target
    rm -rf "${PKG_DIR}" "${DIST_DIR}/${PKG_NAME}.zip" "${DIST_DIR}/${PKG_NAME}.tar.gz" "${DIST_DIR}/.DS_Store"
    mkdir -p "${PKG_DIR}"

    # 5. Copy bundle, kext, and test tool
    echo "[*] Copying bundle, kext, and test tool..."
    cp -R "${BUILD_DIR}/VPXMetalVADriver.bundle" "${PKG_DIR}/"
    cp -R "${BUILD_DIR}/VPXFixup.kext" "${PKG_DIR}/"
    cp "${BUILD_DIR}/vpx_metal_test" "${PKG_DIR}/"

    # 6. Create standalone install.sh
    cat << 'EOF' > "${PKG_DIR}/install.sh"
#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_PATH="${SCRIPT_DIR}/VPXMetalVADriver.bundle"
PLUGIN_DIR="/Library/Video/Plug-Ins"

if [ "$EUID" -ne 0 ]; then
    echo "[!] Please run with sudo: sudo ./install.sh"
    exit 1
fi

if [ ! -d "${BUNDLE_PATH}" ]; then
    echo "[-] Error: ${BUNDLE_PATH} not found!"
    exit 1
fi

echo "[*] Installing VPXMetalVADriver.bundle into ${PLUGIN_DIR}..."
mkdir -p "${PLUGIN_DIR}"
rm -rf "${PLUGIN_DIR}/VPXMetalVADriver.bundle"
cp -R "${BUNDLE_PATH}" "${PLUGIN_DIR}/"

# Clear quarantine attributes (prevents Gatekeeper block if downloaded via browser/cloud)
xattr -cr "${PLUGIN_DIR}/VPXMetalVADriver.bundle" 2>/dev/null || true

# Set appropriate root permissions
chown -R root:wheel "${PLUGIN_DIR}/VPXMetalVADriver.bundle"
chmod -R 755 "${PLUGIN_DIR}/VPXMetalVADriver.bundle"

echo "[*] Restarting WebKit and GPU processes..."
killall Safari 2>/dev/null || true
killall "com.apple.WebKit.GPU" 2>/dev/null || true
killall "com.apple.WebKit.WebContent" 2>/dev/null || true

echo ""
echo "================================================================"
echo "[+] VPXMetalVADriver installed successfully to ${PLUGIN_DIR}!"
echo "[+] VideoToolbox VP8 and VP9 hardware acceleration is now active."
echo "================================================================"
echo ""
echo "[i] REMINDER FOR OC EFI:"
echo "    Copy VPXFixup.kext from this folder to your EFI/OC/Kexts/"
echo "    and add it to config.plist under Kernel -> Add (after Lilu & WhateverGreen)."
echo ""

if [ -f "${SCRIPT_DIR}/vpx_metal_test" ]; then
    echo "[*] Running diagnostic verification test..."
    "${SCRIPT_DIR}/vpx_metal_test" || true
fi
EOF
    chmod +x "${PKG_DIR}/install.sh"

    # 7. Create standalone uninstall.sh
    cat << 'EOF' > "${PKG_DIR}/uninstall.sh"
#!/usr/bin/env bash
set -e

PLUGIN_PATH="/Library/Video/Plug-Ins/VPXMetalVADriver.bundle"

if [ "$EUID" -ne 0 ]; then
    echo "[!] Please run with sudo: sudo ./uninstall.sh"
    exit 1
fi

if [ -d "${PLUGIN_PATH}" ]; then
    echo "[*] Removing ${PLUGIN_PATH}..."
    rm -rf "${PLUGIN_PATH}"
    echo "[+] VPXMetalVADriver has been uninstalled."
    killall Safari 2>/dev/null || true
    killall "com.apple.WebKit.GPU" 2>/dev/null || true
    killall "com.apple.WebKit.WebContent" 2>/dev/null || true
else
    echo "[-] VPXMetalVADriver was not found in /Library/Video/Plug-Ins."
fi
EOF
    chmod +x "${PKG_DIR}/uninstall.sh"

    # 8. Create README.txt
    cat << EOF > "${PKG_DIR}/README.txt"
========================================================================
 VPXMetalDecoder Suite - VP8/VP9 Hardware Acceleration on Hackintosh
 Bundle ID Namespace: id.medkintos
 Target: macOS ${TARGET_NAME} (${MIN_OS_VER}+) / Intel Coffee Lake & Comet Lake
========================================================================

Contents:
  1. VPXFixup.kext           : Lilu plugin kext (id.medkintos.VPXFixup)
  2. VPXMetalVADriver.bundle : Metal VideoToolbox driver bundle (id.medkintos.videodecoder.vpx.metal)
  3. vpx_metal_test          : Metal GPU decode diagnostic & benchmark utility
  4. install.sh              : 1-step installer for userland driver bundle
  5. uninstall.sh            : Clean uninstaller script

--- Complete Installation Guide ---

STEP 1: Install the Lilu Plugin Kext (VPXFixup.kext)
---------------------------------------------------
1. Mount your EFI partition:
     sudo diskutil mount disk0s1   (or use MountEFI / OpenCore Configurator)
2. Copy \`VPXFixup.kext\` to:
     EFI/OC/Kexts/VPXFixup.kext
3. In OpenCore \`config.plist\`, add an entry under \`Kernel -> Add\`:
     Arch: Any
     BundlePath: VPXFixup.kext
     Comment: Redirect hwgva-id to board-id for WebKit while preserving Apple Music DRM
     Enabled: True
     ExecutablePath: Contents/MacOS/VPXFixup
     PlistPath: Contents/Info.plist
   (Ensure it is listed after Lilu.kext and WhateverGreen.kext)
4. Reboot your Hackintosh.

STEP 2: Install the VideoToolbox Driver Bundle
---------------------------------------------
1. In Terminal, navigate to this extracted folder:
     cd /path/to/${PKG_NAME}
2. Run the installer:
     sudo ./install.sh

STEP 3: Verify Playback in Safari / WebKit & Apple Music
--------------------------------------------------------
1. Open Safari (or Yab / any WebKit browser) and navigate to YouTube.
2. Play any 1080p60 or 4K VP9 video.
3. Right-click video -> "Stats for nerds" -> Verify Codec shows "vp09".
4. Switch between multiple videos back-to-back:
   -> Subsequent videos maintain hardware "vp09" without falling back to avc1.
5. Apple Music Lossless/DRM playback remains active with \`unfairgva=4\`.

--- Diagnostics & Troubleshooting ---

- Benchmark Metal GPU decoding:
     ./vpx_metal_test

- Live-stream decoder log messages in Terminal:
     /usr/bin/log stream --predicate 'process == "com.apple.WebKit.GPU" or subsystem == "id.medkintos.vpxmetal" or eventMessage CONTAINS "VPXFixup"'

- Optional Boot Arguments:
     -vpxfixupoff : Disable VPXFixup
     -vpxfixupdbg : Enable verbose debug logging in system log
EOF

    # 9. Archive into zip and tar.gz
    echo "[*] Creating zip & tar.gz archives for ${PKG_NAME}..."
    (
        cd "${DIST_DIR}"
        zip -r -q "${PKG_NAME}.zip" "${PKG_NAME}"
        tar -czf "${PKG_NAME}.tar.gz" "${PKG_NAME}"
    )
}

# Build Tahoe Release (macOS 26.0 / Darwin 25)
package_target "Tahoe" "26.0"

# Build Sequoia Release (macOS 15.0 / Darwin 24) - also leaves build/ compatible with both Sequoia & Tahoe
package_target "Sequoia" "15.0"

echo ""
echo "[✓] Distribution packages ready in ${DIST_DIR}:"
ls -lh "${DIST_DIR}"
