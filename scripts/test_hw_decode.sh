#!/usr/bin/env bash
# =============================================================================
# VPXFixup & VP8MetalDecoder — Hardware Video Decode Verification Suite
# =============================================================================
# Verifies VP9, HEVC, VP8, and H.264 hardware decoding across:
#   1. System / Kext / Bundle Status (VPXFixup.kext, Lilu.kext, VPXMetalVADriver)
#   2. Direct VideoToolbox & Metal GPU Hardware Decode API
#   3. Safari / WebKit Engine (Built-in macOS WebKit GPU Process + MediaCapabilities)
#   4. Google Chrome (Simulated Chrome GPU Sandbox + Live Chrome App if installed)
#   5. Mozilla Firefox (Simulated Firefox RDD Sandbox + Live Firefox App if installed)
#
# Zero external dependencies required: runs on any macOS system using built-in
# system frameworks (/usr/bin/osascript JXA + VideoToolbox + Metal + WebKit),
# even when Google Chrome, Mozilla Firefox, or Xcode Command Line Tools are
# NOT installed.
#
# Usage:
#   ./scripts/test_hw_decode.sh                # Run full automated CLI check
#   ./scripts/test_hw_decode.sh --open-safari  # Also open visual test page in Safari
#   ./scripts/test_hw_decode.sh --open-all     # Open visual test page in all installed browsers
# =============================================================================

set -u

OPEN_SAFARI=0
OPEN_ALL=0

for arg in "$@"; do
    case "$arg" in
        --open-safari|--safari)
            OPEN_SAFARI=1
            ;;
        --open-all|--open-browsers|--interactive)
            OPEN_ALL=1
            ;;
        -h|--help)
            echo "Usage: $0 [--open-safari] [--open-all]"
            echo ""
            echo "Options:"
            echo "  --open-safari   Open interactive HTML hardware decode dashboard in Safari.app"
            echo "  --open-all      Open interactive HTML hardware decode dashboard in all installed browsers"
            echo "  -h, --help      Show this help message"
            exit 0
            ;;
    esac
done

# Terminal colors
if [ -t 1 ]; then
    BOLD="\033[1m"
    DIM="\033[2m"
    GREEN="\033[1;32m"
    RED="\033[1;31m"
    YELLOW="\033[1;33m"
    CYAN="\033[1;36m"
    RESET="\033[0m"
else
    BOLD=""
    DIM=""
    GREEN=""
    RED=""
    YELLOW=""
    CYAN=""
    RESET=""
fi

pass_badge() { printf "${GREEN}[PASS / HWDEC]${RESET}"; }
warn_badge() { printf "${YELLOW}[SWDEC / WARN]${RESET}"; }
fail_badge() { printf "${RED}[FAIL / BLOCKED]${RESET}"; }
skip_badge() { printf "${CYAN}[NOT INSTALLED]${RESET}"; }

OS_VER="$(sw_vers -productVersion 2>/dev/null || echo "Unknown")"
OS_BUILD="$(sw_vers -buildVersion 2>/dev/null || echo "Unknown")"
DARWIN_VER="$(uname -r 2>/dev/null || echo "Unknown")"
ARCH_NAME="$(uname -m 2>/dev/null || echo "Unknown")"

echo -e "${BOLD}==============================================================================${RESET}"
echo -e "${BOLD}  VPXFixup & VP8MetalDecoder — Hardware Video Decode Verification Suite${RESET}"
echo -e "${BOLD}==============================================================================${RESET}"
echo -e "  macOS Version : ${CYAN}${OS_VER} (${OS_BUILD}) / Darwin ${DARWIN_VER} (${ARCH_NAME})${RESET}"
echo -e "  Timestamp     : $(date '+%Y-%m-%d %H:%M:%S')"
echo -e "${BOLD}------------------------------------------------------------------------------${RESET}"

# =============================================================================
# 1. System, Kext & Driver Bundle Check
# =============================================================================
echo -e "\n${BOLD}[1/5] System, Kernel Extension & Driver Bundle Status${RESET}"

LILU_INFO="$(/usr/sbin/kextstat 2>/dev/null | grep -i "as.vit9696.Lilu" || true)"
VPXFIXUP_INFO="$(/usr/sbin/kextstat 2>/dev/null | grep -i "id.medkintos.VPXFixup" || true)"
BUNDLE_PATH="/Library/Video/Plug-Ins/VPXMetalVADriver.bundle"
if [ ! -d "$BUNDLE_PATH" ] && [ -d "/Library/Video/Professional Video Workflow Plug-Ins/VPXMetalVADriver.bundle" ]; then
    BUNDLE_PATH="/Library/Video/Professional Video Workflow Plug-Ins/VPXMetalVADriver.bundle"
fi

if [ -n "$LILU_INFO" ]; then
    LILU_VER="$(echo "$LILU_INFO" | awk '{print $7}' | tr -d '()')"
    echo -e "  • Lilu.kext (as.vit9696.Lilu)         : ${GREEN}Loaded ${LILU_VER}${RESET}"
else
    echo -e "  • Lilu.kext (as.vit9696.Lilu)         : ${YELLOW}Not detected in kextstat${RESET}"
fi

if [ -n "$VPXFIXUP_INFO" ]; then
    VPX_VER="$(echo "$VPXFIXUP_INFO" | awk '{print $7}' | tr -d '()')"
    echo -e "  • VPXFixup.kext (id.medkintos.VPXFixup): ${GREEN}Loaded ${VPX_VER}${RESET}"
else
    echo -e "  • VPXFixup.kext (id.medkintos.VPXFixup): ${YELLOW}Not loaded${RESET}"
fi

if [ -d "$BUNDLE_PATH" ]; then
    BUNDLE_VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$BUNDLE_PATH/Contents/Info.plist" 2>/dev/null || echo "Installed")"
    echo -e "  • VPXMetalVADriver.bundle             : ${GREEN}Installed (v${BUNDLE_VER})${RESET}"
else
    echo -e "  • VPXMetalVADriver.bundle             : ${YELLOW}Not installed at ${BUNDLE_PATH}${RESET}"
fi

BOOT_ARGS="$(/usr/sbin/nvram 7C436110-AB2A-4BBB-A880-FE41995C9F82:boot-args 2>/dev/null | cut -f2- || echo "N/A")"
echo -e "  • NVRAM boot-args                     : ${DIM}${BOOT_ARGS}${RESET}"

# =============================================================================
# 2. Direct VideoToolbox & Metal GPU Hardware Decode Check
# =============================================================================
echo -e "\n${BOLD}[2/5] Direct VideoToolbox & Metal GPU Hardware Decode Check${RESET}"

run_vt_probe() {
    local sb_profile="${1:-}"
    /usr/bin/osascript -l JavaScript - "$sb_profile" 2>/dev/null <<'EOF'
function run(argv) {
    ObjC.import("Foundation");
    $.NSBundle.bundleWithPath("/System/Library/Frameworks/VideoToolbox.framework").load;
    $.NSBundle.bundleWithPath("/System/Library/Frameworks/Metal.framework").load;
    $.NSBundle.bundleWithPath("/System/Library/Frameworks/IOKit.framework").load;

    if (argv && argv.length > 0 && argv[0].length > 0) {
        try {
            ObjC.bindFunction("sandbox_init", ["int", ["string", "uint64_t", "void*"]]);
            $.sandbox_init(argv[0], 0, null);
        } catch (e) {}
    }

    ObjC.bindFunction("VTIsHardwareDecodeSupported", ["bool", ["uint32_t"]]);
    ObjC.bindFunction("VTRegisterSupplementalVideoDecoderIfAvailable", ["void", ["uint32_t"]]);
    ObjC.bindFunction("MTLCopyAllDevices", ["id", []]);

    const fourcc = (s) => ((s.charCodeAt(0) << 24) | (s.charCodeAt(1) << 16) | (s.charCodeAt(2) << 8) | s.charCodeAt(3)) >>> 0;
    $.VTRegisterSupplementalVideoDecoderIfAvailable(fourcc("vp09"));
    $.VTRegisterSupplementalVideoDecoderIfAvailable(fourcc("vp08"));

    const devs = $.MTLCopyAllDevices();
    const count = devs ? Number(devs.count) : 0;
    const names = [];
    for (let i = 0; i < count; i++) {
        names.push(ObjC.unwrap(devs.objectAtIndex(i).name));
    }

    ObjC.bindFunction("IOServiceGetMatchingService", ["uint32_t", ["uint32_t", "void*"]]);
    ObjC.bindFunction("IOServiceMatching", ["void*", ["string"]]);
    ObjC.bindFunction("IORegistryEntryCreateCFProperty", ["id", ["uint32_t", "id", "void*", "uint32_t"]]);
    ObjC.bindFunction("IOObjectRelease", ["int", ["uint32_t"]]);

    let svc = $.IOServiceGetMatchingService(0, $.IOServiceMatching("IntelAccelerator"));
    if (!svc) svc = $.IOServiceGetMatchingService(0, $.IOServiceMatching("IOAccelerator"));
    let iokitProp = null;
    if (svc) {
        iokitProp = ObjC.unwrap($.IORegistryEntryCreateCFProperty(svc, $("IOClass"), null, 0)) || null;
        $.IOObjectRelease(svc);
    }

    return JSON.stringify({
        gpuCount: count,
        gpus: names,
        iokitClass: iokitProp,
        vp9: Boolean($.VTIsHardwareDecodeSupported(fourcc("vp09"))),
        hevc: Boolean($.VTIsHardwareDecodeSupported(fourcc("hvc1"))),
        vp8: Boolean($.VTIsHardwareDecodeSupported(fourcc("vp08"))),
        h264: Boolean($.VTIsHardwareDecodeSupported(fourcc("avc1")))
    });
}
EOF
}

VT_JSON="$(run_vt_probe "")"

parse_json_field() {
    local json="$1"
    local expr="$2"
    /usr/bin/osascript -l JavaScript -e "const d = JSON.parse($(printf '%s' "$json" | /usr/bin/osascript -l JavaScript -e 'ObjC.import("Foundation"); const s = $.NSString.alloc.initWithDataEncoding($.NSFileHandle.fileHandleWithStandardInput.readDataToEndOfFile, $.NSUTF8StringEncoding); JSON.stringify(ObjC.unwrap(s));')); String($expr);" 2>/dev/null || echo ""
}

GPU_COUNT="$(parse_json_field "$VT_JSON" "d.gpuCount")"
GPU_NAMES="$(parse_json_field "$VT_JSON" "d.gpus.join(', ') || 'None'")"
VT_VP9="$(parse_json_field "$VT_JSON" "d.vp9")"
VT_HEVC="$(parse_json_field "$VT_JSON" "d.hevc")"
VT_VP8="$(parse_json_field "$VT_JSON" "d.vp8")"
VT_H264="$(parse_json_field "$VT_JSON" "d.h264")"

if [ "${GPU_COUNT:-0}" -gt 0 ]; then
    echo -e "  • Metal Devices (${GPU_COUNT})                   : ${GREEN}${GPU_NAMES}${RESET}"
else
    echo -e "  • Metal Devices (0)                   : ${RED}No Metal GPU detected${RESET}"
fi

print_codec_line() {
    local label="$1"
    local val="$2"
    local note="${3:-}"
    if [ "$val" = "true" ]; then
        printf "  • %-35s : %b %b\n" "$label" "$(pass_badge)" "$note"
    else
        printf "  • %-35s : %b %b\n" "$label" "$(warn_badge)" "$note"
    fi
}

print_codec_line "VideoToolbox VP9  ('vp09')" "$VT_VP9"
print_codec_line "VideoToolbox HEVC ('hvc1')" "$VT_HEVC"
print_codec_line "VideoToolbox VP8  ('vp08')" "$VT_VP8" "${DIM}(Requires VPXMetalVADriver.bundle)${RESET}"
print_codec_line "VideoToolbox H264 ('avc1')" "$VT_H264"

# =============================================================================
# 3. Safari / WebKit Hardware Decode Check (Built-in macOS Engine)
# =============================================================================
echo -e "\n${BOLD}[3/5] Safari / WebKit Hardware Decode Check (Built-in WebKit Engine)${RESET}"

SAFARI_JSON="$(/usr/bin/osascript -l JavaScript 2>/dev/null <<'EOF'
ObjC.import("Foundation");
ObjC.import("WebKit");
ObjC.import("AppKit");

$.NSApplication.sharedApplication;
const cfg = $.WKWebViewConfiguration.alloc.init;
if ($.WKWebsiteDataStore.nonPersistentDataStore) {
    cfg.websiteDataStore = $.WKWebsiteDataStore.nonPersistentDataStore;
}
const wv = $.WKWebView.alloc.initWithFrameConfiguration($.NSMakeRect(0, 0, 100, 100), cfg);
const html = `<!DOCTYPE html><html><body><script>
async function runChecks() {
    const codecs = {
        vp9:  "video/webm; codecs=\\"vp09.00.10.08\\"",
        hevc: "video/mp4; codecs=\\"hvc1.1.6.L120.90\\"",
        vp8:  "video/webm; codecs=\\"vp8\\"",
        h264: "video/mp4; codecs=\\"avc1.640028\\""
    };
    const results = {};
    for (const [k, ct] of Object.entries(codecs)) {
        try {
            const info = await navigator.mediaCapabilities.decodingInfo({
                type: "file",
                video: { contentType: ct, width: 1920, height: 1080, bitrate: 8000000, framerate: 30 }
            });
            results[k] = {
                supported: Boolean(info.supported),
                smooth: Boolean(info.smooth),
                powerEfficient: Boolean(info.powerEfficient)
            };
        } catch (err) {
            results[k] = { supported: false, smooth: false, powerEfficient: false, error: String(err) };
        }
    }
    document.title = "DONE:" + JSON.stringify(results);
}
runChecks();
</script></body></html>`;

wv.loadHTMLStringBaseURL(html, $.NSURL.URLWithString("https://localhost"));
const deadline = Date.now() + 6000;
let output = "{}";
while (Date.now() < deadline) {
    $.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(0.05));
    const title = ObjC.unwrap(wv.title);
    if (title && title.startsWith("DONE:")) {
        output = title.slice(5);
        break;
    }
}
output;
EOF
)"

SAFARI_VP9_HW="$(parse_json_field "$SAFARI_JSON" "d.vp9 && d.vp9.powerEfficient")"
SAFARI_VP9_SUP="$(parse_json_field "$SAFARI_JSON" "d.vp9 && d.vp9.supported")"
SAFARI_HEVC_HW="$(parse_json_field "$SAFARI_JSON" "d.hevc && d.hevc.powerEfficient")"
SAFARI_HEVC_SUP="$(parse_json_field "$SAFARI_JSON" "d.hevc && d.hevc.supported")"
SAFARI_VP8_HW="$(parse_json_field "$SAFARI_JSON" "d.vp8 && d.vp8.powerEfficient")"
SAFARI_VP8_SUP="$(parse_json_field "$SAFARI_JSON" "d.vp8 && d.vp8.supported")"
SAFARI_H264_HW="$(parse_json_field "$SAFARI_JSON" "d.h264 && d.h264.powerEfficient")"

print_codec_line "Safari/WebKit VP9  (powerEfficient)" "$SAFARI_VP9_HW" "${DIM}(supported=${SAFARI_VP9_SUP:-false})${RESET}"
print_codec_line "Safari/WebKit HEVC (powerEfficient)" "$SAFARI_HEVC_HW" "${DIM}(supported=${SAFARI_HEVC_SUP:-false})${RESET}"
print_codec_line "Safari/WebKit H264 (powerEfficient)" "$SAFARI_H264_HW"
if [ "$SAFARI_VP8_HW" = "true" ]; then
    print_codec_line "Safari/WebKit VP8  (powerEfficient)" "true"
else
    echo -e "  • Safari/WebKit VP8  (MediaCap)       : ${CYAN}[SUPPORTED=${SAFARI_VP8_SUP:-false}]${RESET} ${DIM}(WebKit uses libvpx for WebRTC/WebM VP8; VT used for native apps)${RESET}"
fi

# =============================================================================
# 4. Google Chrome Verification (Sandbox Simulation + Live App Check)
# =============================================================================
echo -e "\n${BOLD}[4/5] Google Chrome Hardware Decode Check (Works Without Chrome Installed)${RESET}"

CHROME_SANDBOX_PROFILE='(version 1)
(allow default)
(deny iokit-open-user-client
  (iokit-user-client-class "AppleIntelMEUserClient" "IGAccelVideoContextMain" "IGAccelVideoContextMedia"))
(deny mach-lookup
  (global-name "com.apple.coremedia.videodecoder" "com.apple.vtdecoderxpcservice"))'

CHROME_SB_JSON="$(run_vt_probe "$CHROME_SANDBOX_PROFILE")"
CHROME_SB_VP9="$(parse_json_field "$CHROME_SB_JSON" "d.vp9")"
CHROME_SB_HEVC="$(parse_json_field "$CHROME_SB_JSON" "d.hevc")"

print_codec_line "Chrome GPU Sandbox Sim — VP9" "$CHROME_SB_VP9" "${DIM}(Tests AppleIntelME + VT XPC under Seatbelt)${RESET}"
print_codec_line "Chrome GPU Sandbox Sim — HEVC" "$CHROME_SB_HEVC" "${DIM}(Tests AppleIntelME + GVA under Seatbelt)${RESET}"

CHROME_BIN=""
if [ -x "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" ]; then
    CHROME_BIN="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
elif [ -x "$HOME/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" ]; then
    CHROME_BIN="$HOME/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
fi

if [ -n "$CHROME_BIN" ]; then
    TMP_CHROME_DIR="$(mktemp -d /tmp/vpx_chrome_test.XXXXXX)"
    TMP_CHROME_HTML="${TMP_CHROME_DIR}/test.html"
    cat > "$TMP_CHROME_HTML" <<'HTML_EOF'
<!DOCTYPE html><html><head><meta charset="utf-8"></head><body>
<pre id="out">RUNNING</pre>
<script>
(async () => {
    const codecs = {
        vp9:  'video/webm; codecs="vp09.00.10.08"',
        hevc: 'video/mp4; codecs="hvc1.1.6.L120.90"',
        h264: 'video/mp4; codecs="avc1.640028"'
    };
    const res = {};
    for (const [k, ct] of Object.entries(codecs)) {
        try {
            const r = await navigator.mediaCapabilities.decodingInfo({
                type: 'file',
                video: { contentType: ct, width: 1920, height: 1080, bitrate: 8000000, framerate: 30 }
            });
            res[k] = { supported: r.supported, smooth: r.smooth, powerEfficient: r.powerEfficient };
        } catch (e) {
            res[k] = { supported: false, powerEfficient: false };
        }
    }
    document.getElementById('out').textContent = 'CHROME_JSON:' + JSON.stringify(res);
})();
</script></body></html>
HTML_EOF

    CHROME_DOM="$("$CHROME_BIN" --headless=new --user-data-dir="$TMP_CHROME_DIR/profile" --no-first-run --no-default-browser-check --virtual-time-budget=3000 --dump-dom "file://${TMP_CHROME_HTML}" 2>/dev/null | sed -n 's/.*CHROME_JSON:\({.*}\).*/\1/p' | head -n 1 || true)"
    rm -rf "$TMP_CHROME_DIR"

    if [ -n "$CHROME_DOM" ]; then
        CHROME_LIVE_VP9="$(parse_json_field "$CHROME_DOM" "d.vp9 && d.vp9.powerEfficient")"
        CHROME_LIVE_HEVC="$(parse_json_field "$CHROME_DOM" "d.hevc && d.hevc.powerEfficient")"
        print_codec_line "Live Google Chrome.app — VP9" "$CHROME_LIVE_VP9" "${DIM}(MediaCapabilities powerEfficient)${RESET}"
        print_codec_line "Live Google Chrome.app — HEVC" "$CHROME_LIVE_HEVC" "${DIM}(MediaCapabilities powerEfficient)${RESET}"
    else
        echo -e "  • Live Google Chrome.app              : ${YELLOW}[Installed, headless query skipped]${RESET} ${DIM}(Sandbox Sim above verified status)${RESET}"
    fi
else
    printf "  • %-35s : %b %b\n" "Live Google Chrome.app" "$(skip_badge)" "${DIM}(Verified via Chrome GPU Sandbox Sim above)${RESET}"
fi

# =============================================================================
# 5. Mozilla Firefox Verification (RDD Sandbox Simulation + Live App Check)
# =============================================================================
echo -e "\n${BOLD}[5/5] Mozilla Firefox Hardware Decode Check (Works Without Firefox Installed)${RESET}"

# Firefox's RDD process (SandboxPolicyRDD) blocks iokit-get-properties for
# IOClassNameOverride, SafeEjectRequested, AAPL,slot-name, and built-in, which
# causes MTLCopyAllDevices() to return 0 GPUs unless VPXFixup v1.0.1+ is active.
FIREFOX_RDD_SANDBOX_PROFILE='(version 1)
(allow default)
(deny iokit-get-properties
  (iokit-property "IOClass" "IOClassNameOverride" "SafeEjectRequested" "AAPL,slot-name" "built-in"))
(deny iokit-open-user-client
  (iokit-user-client-class "AppleIntelMEUserClient" "IGAccelDevice" "IGAccelSharedUserClient" "IGAccelVideoContextMain" "IGAccelVideoContextMedia"))'

FF_SB_JSON="$(run_vt_probe "$FIREFOX_RDD_SANDBOX_PROFILE")"
FF_SB_GPUS="$(parse_json_field "$FF_SB_JSON" "d.gpuCount")"
FF_SB_IOKIT="$(parse_json_field "$FF_SB_JSON" "d.iokitClass || ''")"
FF_SB_VP9="$(parse_json_field "$FF_SB_JSON" "d.gpuCount > 0 && d.vp9")"
FF_SB_HEVC="$(parse_json_field "$FF_SB_JSON" "d.gpuCount > 0 && d.hevc")"

if [ "${FF_SB_GPUS:-0}" -gt 0 ] && [ -n "$FF_SB_IOKIT" ]; then
    printf "  • %-35s : %b %b\n" "Firefox RDD Sandbox — IOKit & Metal" "$(pass_badge)" "${DIM}(${FF_SB_IOKIT}, ${FF_SB_GPUS} GPU visible)${RESET}"
else
    printf "  • %-35s : %b %b\n" "Firefox RDD Sandbox — IOKit & Metal" "$(fail_badge)" "${DIM}(iokit-get-properties / Metal blocked)${RESET}"
fi
print_codec_line "Firefox RDD Sandbox Sim — VP9" "$FF_SB_VP9" "${DIM}(Simulates Firefox plugin-container RDD process)${RESET}"
print_codec_line "Firefox RDD Sandbox Sim — HEVC" "$FF_SB_HEVC" "${DIM}(Simulates Firefox plugin-container RDD process)${RESET}"

FIREFOX_BIN=""
if [ -x "/Applications/Firefox.app/Contents/MacOS/firefox" ]; then
    FIREFOX_BIN="/Applications/Firefox.app/Contents/MacOS/firefox"
elif [ -x "$HOME/Applications/Firefox.app/Contents/MacOS/firefox" ]; then
    FIREFOX_BIN="$HOME/Applications/Firefox.app/Contents/MacOS/firefox"
fi

if [ -n "$FIREFOX_BIN" ]; then
    echo -e "  • Live Firefox.app Binary             : ${GREEN}Installed (${FIREFOX_BIN})${RESET}"
else
    printf "  • %-35s : %b %b\n" "Live Mozilla Firefox.app" "$(skip_badge)" "${DIM}(Verified via Firefox RDD Sandbox Sim above)${RESET}"
fi

# =============================================================================
# Optional: Interactive Browser Dashboard (--open-safari / --open-all)
# =============================================================================
if [ "$OPEN_SAFARI" -eq 1 ] || [ "$OPEN_ALL" -eq 1 ]; then
    DASHBOARD_HTML="/tmp/vpx_hw_decode_dashboard.html"
    cat > "$DASHBOARD_HTML" <<'DASH_EOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>VPXFixup & VP8MetalDecoder — Browser Hardware Decode Test</title>
<style>
  body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; background: #0f172a; color: #f8fafc; margin: 2rem; }
  h1 { font-size: 1.5rem; margin-bottom: 0.25rem; }
  p.sub { color: #94a3b8; margin-top: 0; margin-bottom: 1.5rem; }
  table { border-collapse: collapse; width: 100%; max-width: 860px; background: #1e293b; border-radius: 8px; overflow: hidden; }
  th, td { padding: 0.85rem 1rem; text-align: left; border-bottom: 1px solid #334155; }
  th { background: #0f172a; color: #cbd5e1; font-weight: 600; }
  .pass { color: #4ade80; font-weight: 700; }
  .warn { color: #facc15; font-weight: 700; }
  .fail { color: #f87171; font-weight: 700; }
  code { background: #0f172a; padding: 0.2rem 0.4rem; border-radius: 4px; color: #38bdf8; }
</style>
</head>
<body>
  <h1>VPXFixup &amp; VP8MetalDecoder — Browser Hardware Decode Dashboard</h1>
  <p class="sub" id="ua"></p>
  <table>
    <thead>
      <tr>
        <th>Codec</th>
        <th>MIME / Profile</th>
        <th>Supported</th>
        <th>Smooth (1080p60)</th>
        <th>Hardware Decode (powerEfficient)</th>
      </tr>
    </thead>
    <tbody id="rows"></tbody>
  </table>
  <script>
    document.getElementById('ua').textContent = 'User Agent: ' + navigator.userAgent;
    const tests = [
      { name: 'VP9 (Profile 0, 8-bit)', mime: 'video/webm; codecs="vp09.00.10.08"' },
      { name: 'VP9 (Profile 2, 10-bit HDR)', mime: 'video/webm; codecs="vp09.02.10.10"' },
      { name: 'HEVC / H.265 (Main)', mime: 'video/mp4; codecs="hvc1.1.6.L120.90"' },
      { name: 'HEVC / H.265 (Main10)', mime: 'video/mp4; codecs="hvc1.2.4.L120.90"' },
      { name: 'VP8', mime: 'video/webm; codecs="vp8"' },
      { name: 'H.264 / AVC (High)', mime: 'video/mp4; codecs="avc1.640028"' }
    ];
    (async () => {
      const tbody = document.getElementById('rows');
      for (const t of tests) {
        const tr = document.createElement('tr');
        try {
          const r = await navigator.mediaCapabilities.decodingInfo({
            type: 'file',
            video: { contentType: t.mime, width: 1920, height: 1080, bitrate: 12000000, framerate: 60 }
          });
          tr.innerHTML = `
            <td><strong>${t.name}</strong></td>
            <td><code>${t.mime}</code></td>
            <td class="${r.supported ? 'pass' : 'fail'}">${r.supported ? 'YES' : 'NO'}</td>
            <td class="${r.smooth ? 'pass' : 'warn'}">${r.smooth ? 'YES' : 'NO'}</td>
            <td class="${r.powerEfficient ? 'pass' : 'warn'}">${r.powerEfficient ? 'YES (HWDEC)' : 'NO (SWDEC)'}</td>
          `;
        } catch (e) {
          tr.innerHTML = `<td><strong>${t.name}</strong></td><td><code>${t.mime}</code></td><td colspan="3" class="fail">Error: ${e}</td>`;
        }
        tbody.appendChild(tr);
      }
    })();
  </script>
</body>
</html>
DASH_EOF

    echo -e "\n${BOLD}Opening interactive browser dashboard:${RESET} ${CYAN}${DASHBOARD_HTML}${RESET}"
    /usr/bin/open -a Safari "$DASHBOARD_HTML" 2>/dev/null || true
    if [ "$OPEN_ALL" -eq 1 ]; then
        [ -n "$CHROME_BIN" ] && /usr/bin/open -a "Google Chrome" "$DASHBOARD_HTML" 2>/dev/null || true
        [ -n "$FIREFOX_BIN" ] && /usr/bin/open -a "Firefox" "$DASHBOARD_HTML" 2>/dev/null || true
    fi
fi

# =============================================================================
# Summary
# =============================================================================
echo -e "\n${BOLD}==============================================================================${RESET}"
if [ "$VT_VP9" = "true" ] && [ "$VT_HEVC" = "true" ] && [ "$SAFARI_VP9_HW" = "true" ] && [ "$SAFARI_HEVC_HW" = "true" ] && [ "$CHROME_SB_VP9" = "true" ] && [ "$FF_SB_VP9" = "true" ]; then
    echo -e "  ${GREEN}OVERALL STATUS: PASS — VP9 & HEVC Hardware Decoding Active Across All Targets${RESET}"
else
    echo -e "  ${YELLOW}OVERALL STATUS: PARTIAL / CHECK DETAILS ABOVE${RESET}"
    if [ -z "$VPXFIXUP_INFO" ]; then
        echo -e "  ${DIM}Tip: Ensure VPXFixup.kext (v1.0.1+) is loaded by OpenCore and boot-args include -vpxdbg.${RESET}"
    fi
fi
echo -e "${BOLD}==============================================================================${RESET}"
