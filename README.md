# VPXMetalDecoder & VPXFixup

**Enabling VP8 and VP9 Hardware Decoding on CFL/CML based Hackintosh with Metal-Accelerated VideoToolbox Driver Bundle (`VPXMetalVADriver.bundle`) & Lilu Kernel Extension (`VPXFixup.kext`)**

<img width="1920" height="1080" alt="Screenshot 2026-11-04 at 16 35 42" src="https://github.com/user-attachments/assets/748d05b7-fae1-4272-bcc3-93db9df93fb6" />


> 📖 **Deep-Dive Architecture Guide:** See [**HOW_IT_WORKS.md**](./HOW_IT_WORKS.md) for a detailed explanation of the kernel hooks, `unfairgva=4` vs. WebKit GPU Sandbox mechanics, and the Metal compute decoding pipeline.

---

## Development Notes & Disclaimer

> [!NOTE]
> This project is written entirely with AI. The tool has not yet been verified on a wide range of real hardware. Bug reports, hardware compatibility test results, and corrections to the data or implementation are very welcome!

---

## Technical Overview

On Intel-based macOS systems (including Coffee Lake, Comet Lake, and Ice Lake systems such as Intel UHD 620 / UHD 630):

1. **Missing Native VP8/VP9 Hardware Path on Intel iGPU:** Apple's native VideoToolbox stack for Intel integrated graphics only provides hardware decoding support for **H.264** (`avc1`) and **HEVC** (`hvc1`). Native VP9 (`vp09`) hardware decoding on Intel Macs is gated behind the Apple T2 Security Chip (`AppleVP9`, `AppleGen10.bundle`) or restricted by board-id whitelists in `AppleGVA.framework`.
2. **The `unfairgva=4` + WebKit Sandbox Conflict (`hwgva-id`):**
   - Users commonly configure `unfairgva=4` in WhateverGreen (`boot-args`) to spoof an `iMacPro1,1` (`Mac-7BA5B2D9E42DDD94`) board identifier via the `hwgva-id` IORegistry property so that **Apple Music** (`Music.app` / `fairplayd`) can play FairPlay DRM-protected audio.
   - However, when `AppleGVA` runs inside the `com.apple.WebKit.GPU` process (Safari and WebKit-based browsers such as Yab), it attempts to read `hwgva-id` on `IOPlatformExpertDevice`.
   - Because `hwgva-id` is a non-standard WhateverGreen property not whitelisted in WebKit's Sandbox profile (`com.apple.WebKit.GPU.sb`), **`Sandbox.kext` denies `iokit-get-property: hwgva-id`**.
   - Additionally, if `iMacPro1,1` is seen by `AppleGVA` on an iGPU-only system without a T2 chip or discrete AMD GPU, `AVDCreateGPUAccelerator` fails after the first video session, causing Safari/Yab to permanently mark `vp09` as unsupported and fall back to laggy `avc1` software decoding on subsequent videos.

---

## Solution Architecture

This repository provides a complete two-part solution:

### 1. `VPXFixup.kext`
A lightweight **Lilu kernel extension plugin** targeting macOS Sequoia (Darwin 24) and macOS Tahoe (Darwin 25) that resolves the conflict between WebKit's GPU Sandbox, `AppleGVA`, and Apple Music DRM:
* **Kernel MAC Policy & IORegistry Hook:** Hooks XNU's `_mac_iokit_check_get_property`, `_is_io_registry_entry_get_property_bin_buf` (and related Mach MIG traps), and `IORegistryEntry::copyProperty` in the kernel.
* **Per-Process `hwgva-id` ➔ `board-id` Redirection:**
  * **For Apple Music & FairPlay (`Music`, `fairplayd`, `AMP*`):** Preserves the `hwgva-id` lookup untouched so `unfairgva=4` returns the spoofed `iMacPro1,1` board ID (`Mac-7BA5B2D9E42DDD94`) and Apple Music lossless/DRM streaming works without interruption.
  * **For WebKit based browsers (such as Safari and Yab), and VideoToolbox processes:** Rewrites `"hwgva-id"` in-place to `"board-id"` before `Sandbox.kext` evaluates the MAC policy check and before `IORegistryEntry` looks up the property. `Sandbox.kext` permits `"board-id"`, and `AppleGVA` receives the native SMBIOS `board-id` (e.g. `Mac-0CFF9C7C2B63DF8D` / `MacBookAir9,1`), enabling native Intel GuC/GVA VP9 (`vp09`) hardware acceleration across unlimited consecutive videos without ever falling back to `avc1`.
  * **For Firefox (`plugin-container` RDD Process):** Permits `iokit-get-properties` checks (`IOClassNameOverride`, `SafeEjectRequested`, `AAPL,slot-name` on `IntelAccelerator` and `built-in` on `IOPCIDevice`) in `_mac_iokit_check_get_property` so `MTLCopyAllDevicesWithObserver()` and `VideoToolbox` can enumerate the Intel GPU inside Firefox's RDD sandbox, enabling **VP9 (`vp09`) and HEVC (`hvc1`) hardware decoding** in Firefox (`about:support`).
* **Kernel Flag Enforcement:** Forces `AppleVTD_force_enable = 1` if present in the kernel.

### 2. `VPXMetalVADriver.bundle`
A standalone VideoToolbox plugin driver bundle and macOS MediaExtension (`MEVideoDecoder`) that provides Metal compute shader acceleration for VP8 (`vp08`) and VP9 (`vp09`, `qvp9`):
* **GPU Compute IDCT / IADST:** Parallel 2D Inverse Discrete Cosine & Sine Transforms (`4x4`, `8x8`, `16x16`, `32x32`) executing on Metal compute pipelines.
* **GPU Motion Compensation & In-Loop Deblocking:** 8-tap subpixel interpolation filtering and concurrent horizontal/vertical edge loop filters.
* **Zero-Copy `IOSurface` / `CVPixelBuffer` Output:** Outputs hardware-backed `NV12` (`420v` / `420f`) and `32BGRA` surfaces directly consumable by `CAMetalLayer` and WindowServer.
* **Seamless Dynamic Resolution Switching:** Handles MSE resolution changes and consecutive video playback without dropping sessions.

---

## Repository Structure

```text
├── bundle/
│   ├── Info.plist                 # VideoToolbox bundle metadata (id.medkintos.videodecoder.vpx.metal)
│   └── MediaExtension-Info.plist  # ExtensionKit attributes dictionary
├── dist/                          # Packaged release archives & prebuilt bundles/kexts
├── external/
│   └── Lilu/                      # Lilu SDK headers & plugin entry wrappers for building VPXFixup.kext
├── include/
│   ├── VPXBitstreamParser.h       # VP8/VP9 frame header & superframe parser
│   ├── VPXMediaExtension.h        # macOS MediaExtension protocol interfaces
│   ├── VPXMetalCommon.h           # Shared FourCC definitions, types, logging (id.medkintos.*)
│   ├── VPXMetalDecoder.h          # Core decoding coordinator
│   ├── VPXMetalEngine.h           # Metal compute pipelines, buffers, texture cache
│   └── VPXMetalVADriver.h         # VideoToolbox bundle C-vtable ABI entry points
├── kext/
│   └── VPXFixup/
│       ├── Info.plist             # Lilu plugin kext metadata (id.medkintos.VPXFixup)
│       ├── Makefile               # Kernel extension build rules
│       ├── VPXFixup.cpp           # XNU MAC policy & IORegistry property redirection implementation
│       └── VPXFixup.hpp           # Kernel patcher declarations
├── scripts/
│   ├── build.sh                   # Clean build script for VPXMetalVADriver.bundle & VPXFixup.kext
│   ├── install.sh                 # Installs VPXMetalVADriver.bundle to /Library/Video/Plug-Ins/
│   └── package_release.sh         # Builds and packages release archives into dist/
├── src/
│   ├── VPXBitstreamParser.c       # Fast VP8/VP9 bitstream header parser
│   ├── VPXInjector.m              # System-wide VideoToolbox hook shim
│   ├── VPXMediaExtension.m        # MEVideoDecoderExtension implementation
│   ├── VPXMetalCommon.m           # OS logging subsystem
│   ├── VPXMetalDecoder.m          # Decode loop & IOSurface frame emission
│   ├── VPXMetalEngine.m           # GPU device selection & Metal compute dispatch
│   ├── VPXMetalShaders.metal      # MSL compute kernels (IDCT, motion comp, loop filter, NV12)
│   └── VPXMetalVADriver.m         # VideoToolbox bundle registration
├── test/
│   ├── test_vpx_metal.m           # Automated verification & benchmark suite
│   └── vpx_test_samples.h         # Test bitstream headers (VP8 720p & VP9 1080p)
├── HOW_IT_WORKS.md                # Detailed technical documentation of the kext & Metal driver
└── Makefile                       # Multi-architecture bundle & test suite build system
```

---

## Building from Source

### Build Everything (`VPXMetalVADriver.bundle` + `VPXFixup.kext`)
```bash
./scripts/build.sh
```
This produces:
* `build/VPXMetalVADriver.bundle` (Universal Mach-O bundle: `x86_64` + `arm64`)
* `build/VPXFixup.kext` (`x86_64` Lilu kernel extension plugin)
* `build/vpx_metal_test` (Universal verification & benchmark binary)

### Build Release Packages (`dist/`)
```bash
./scripts/package_release.sh
```
This clean-builds all targets and generates standalone release packages for both **macOS Sequoia** and **macOS Tahoe**:
* `dist/VPXMetalVADriver-Sequoia-Release.zip` / `dist/VPXMetalVADriver-Sequoia-Release.tar.gz` (macOS 15.0+ / Darwin 24)
* `dist/VPXMetalVADriver-Tahoe-Release.zip` / `dist/VPXMetalVADriver-Tahoe-Release.tar.gz` (macOS 26.0+ / Darwin 25)

---

## Installation

### 1. Install `VPXFixup.kext` (OpenCore EFI)
1. Mount your OpenCore EFI partition.
2. Copy `build/VPXFixup.kext` to `EFI/OC/Kexts/VPXFixup.kext`.
3. Add `VPXFixup.kext` to your `EFI/OC/config.plist` under `Kernel -> Add` **after** `Lilu.kext` and `WhateverGreen.kext`.
4. You can keep `unfairgva=4` in your `boot-args` so Apple Music DRM continues to work!

### 2. Install `VPXMetalVADriver.bundle` (macOS System)
```bash
sudo ./scripts/install.sh
```
Or manually:
```bash
sudo mkdir -p /Library/Video/Plug-Ins
sudo cp -R build/VPXMetalVADriver.bundle /Library/Video/Plug-Ins/
sudo chown -R root:wheel /Library/Video/Plug-Ins/VPXMetalVADriver.bundle
sudo chmod -R 755 /Library/Video/Plug-Ins/VPXMetalVADriver.bundle
sudo killall -9 com.apple.WebKit.GPU VTDecoderXPCService 2>/dev/null || true
```

### 3. Reboot and Verify
After rebooting:
* Check that `VPXFixup` is loaded:
  ```bash
  kmutil showloaded | grep -i vpxfixup
  ```
* Run the test suite:
  ```bash
  ./build/vpx_metal_test
  ```
* Open YouTube in any WebKit based browsers (such as **Safari** or **Yab**) and open **Stats for nerds** — consecutive 1080p60/4K videos will play smoothly using **`vp09`** hardware acceleration while **Apple Music** continues to play DRM songs without issue.

---

## Credits & Resources

### Credits
* **[Acidanthera](https://github.com/acidanthera)** — For [Lilu](https://github.com/acidanthera/Lilu), [WhateverGreen](https://github.com/acidanthera/WhateverGreen), [MacKernelSDK](https://github.com/acidanthera/MacKernelSDK), and [OpenCorePkg](https://github.com/acidanthera/OpenCorePkg), which provide the kernel patching infrastructure and Hackintosh bootloader ecosystem.
* **[Apple Inc.](https://opensource.apple.com/)** — For the open-source [XNU kernel](https://github.com/apple-oss-distributions/xnu), [WebKit](https://github.com/WebKit/WebKit), Metal framework, VideoToolbox, and MediaExtension APIs.
* **[The WebM Project](https://www.webmproject.org/)** — For the VP8 and VP9 bitstream and codec specifications.
* **Google DeepMind Antigravity** — AI pair-programming agent used to research, author, debug, and package this project.

### Resources & Documentation
* [**How It Works (`HOW_IT_WORKS.md`)**](./HOW_IT_WORKS.md) — Internal architecture, XNU MAC policy / IORegistry redirection flow, and Metal compute pipeline documentation.
* [Lilu Plugin Development Guide](https://github.com/acidanthera/Lilu) — Reference for `KernelPatcher` symbol routing and Lilu plugin lifecycle.
* [WhateverGreen DRM & `unfairgva` Documentation](https://github.com/acidanthera/WhateverGreen/blob/master/Manual/FAQ.Chart.md) — Background on `hwgva-id` board-id spoofing and FairPlay DRM on Intel Hackintosh systems.
* [Apple MediaExtension & VideoToolbox Documentation](https://developer.apple.com/documentation/mediaextension) — Official Apple developer documentation for custom video decoders on macOS.
* [VP9 Bitstream & Decoding Process Specification](https://storage.googleapis.com/downloads.webmproject.org/docs/vp9/vp9-bitstream-specification-v0.6-20160331-draft.pdf) — Reference specification for VP9 frame headers, superframes, 8-tap motion compensation, and loop filtering.
