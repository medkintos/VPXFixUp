#!/usr/bin/env bash
# Installation script for VPXMetalVADriver bundle
set -e

PLUGIN_DIR="/Library/Video/Plug-Ins"
BUNDLE_NAME="VPXMetalVADriver.bundle"
SOURCE_BUNDLE="build/${BUNDLE_NAME}"

if [ ! -d "${SOURCE_BUNDLE}" ]; then
    echo "[-] Error: ${SOURCE_BUNDLE} does not exist. Please run ./scripts/build.sh first."
    exit 1
fi

echo "[*] Installing ${BUNDLE_NAME} into ${PLUGIN_DIR}..."

if [ "$EUID" -ne 0 ]; then
    echo "[-] Please run as root (sudo ./scripts/install.sh)"
    exit 1
fi

mkdir -p "${PLUGIN_DIR}"
rm -rf "${PLUGIN_DIR}/${BUNDLE_NAME}"
cp -R "${SOURCE_BUNDLE}" "${PLUGIN_DIR}/"
chown -R root:wheel "${PLUGIN_DIR}/${BUNDLE_NAME}"
chmod -R 755 "${PLUGIN_DIR}/${BUNDLE_NAME}"

echo "[+] Successfully installed ${BUNDLE_NAME} to ${PLUGIN_DIR}."
echo "[+] VideoToolbox will now recognize VP8/VP9 hardware acceleration."
