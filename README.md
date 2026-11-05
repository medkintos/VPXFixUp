# VPXFixup

**Enabling VP9 & HEVC Hardware Decoding on KBL/CFL/CML based Hackintosh with Lilu Kernel Extension (`VPXFixup.kext`) while Preserving Apple Music FairPlay DRM (`unfairgva=4`)**

<img width="1920" height="1080" alt="Screenshot 2026-11-04 at 16 35 42" src="https://github.com/user-attachments/assets/748d05b7-fae1-4272-bcc3-93db9df93fb6" />

> 📖 **Deep-Dive Architecture Guide:** See [**HOW_IT_WORKS.md**](./HOW_IT_WORKS.md) for a detailed explanation of the XNU kernel hooks, `unfairgva=4` (`hwgva-id`) vs. WebKit & Firefox GPU Sandbox mechanics, and per-process IORegistry property redirection.
>
> 🔗 **Companion Metal VideoToolbox Driver Bundle:** Looking for the standalone Metal compute shader VideoToolbox driver bundle (`VPXMetalVADriver.bundle`) for VP8/VP9? It has been moved to its own repository: [**medkintos/VP8MetalDecoder**](https://github.com/medkintos/VP8MetalDecoder).

---

## Development Notes & Hardware Compatibility

> [!NOTE]
> This project is written entirely with AI.
> 
> **Hardware Status:**
> * **Confirmed Working:** Intel Kaby Lake (KBL), Coffee Lake (CFL), and Comet Lake (CML) architectures (e.g. Intel HD 620 / UHD 620 / UHD 630).
> * Bug reports, hardware compatibility test results on other generations, and corrections to the data or implementation are very welcome!

---

## Technical Overview

On Intel-based macOS systems (including Kaby Lake, Coffee Lake, Comet Lake, and Ice Lake systems such as Intel HD 620 / UHD 620 / UHD 630), two competing requirements collide in Apple's media stack:

1. **The `unfairgva=4` + WebKit Sandbox Conflict (`hwgva-id`):**
   - Users commonly configure `unfairgva=4` in WhateverGreen (`boot-args`) to spoof an `iMacPro1,1` (`Mac-7BA5B2D9E42DDD94`) board identifier via the `hwgva-id` IORegistry property so that **Apple Music** (`Music.app` / `fairplayd`) can play FairPlay DRM-protected audio.
   - However, when `AppleGVA` runs inside the `com.apple.WebKit.GPU` process (Safari and WebKit-based browsers such as Yab), it attempts to read `hwgva-id` on `IOPlatformExpertDevice`.
   - Because `hwgva-id` is a non-standard WhateverGreen property not whitelisted in WebKit's Sandbox profile (`com.apple.WebKit.GPU.sb`), **`Sandbox.kext` denies `iokit-get-property: hwgva-id`**.
   - Additionally, if `iMacPro1,1` is seen by `AppleGVA` on an iGPU-only system without a T2 chip or discrete AMD GPU, `AVDCreateGPUAccelerator` fails after the first video session, causing Safari/Yab to permanently mark `vp09` as unsupported and fall back to laggy `avc1` software decoding on subsequent videos.
2. **The Firefox RDD Process (`plugin-container`) Sandbox Issue:**
   - Mozilla Firefox initializes hardware video decoders inside its **Remote Data Decoder (RDD)** process (`plugin-container`), which applies `SandboxPolicyRDD` with `(deny iokit-get-properties)` and a narrow 16-property whitelist.
   - On macOS Sonoma, Sequoia, and Tahoe, `Metal.framework` and `VideoToolbox` query `IOClassNameOverride`, `SafeEjectRequested`, and `AAPL,slot-name` on `IntelAccelerator` as well as `built-in` on `IOPCIDevice`. Because Firefox's RDD sandbox blocks those property reads, `MTLCopyAllDevicesWithObserver()` returns 0 Metal devices and both **VP9** and **HEVC** hardware decoding fail in Firefox (`about:support`).

---

## Solution: `VPXFixup.kext`

**`VPXFixup.kext`** is a lightweight **Lilu kernel extension plugin** targeting **macOS Sonoma (14.0+ / Darwin 23)**, **macOS Sequoia (15.0+ / Darwin 24)**, and **macOS Tahoe (26.0+ / Darwin 25)** that resolves the conflict between browser GPU sandboxes, `AppleGVA`, and Apple Music DRM:

* **Kernel MAC Policy & IORegistry Hook:** Hooks XNU's `_mac_iokit_check_get_property`, `_is_io_registry_entry_get_property_bin_buf` (and related Mach MIG traps), and `IORegistryEntry::copyProperty` in the kernel.
* **Per-Process `hwgva-id` ➔ `board-id` Redirection:**
  * **For Apple Music & FairPlay (`Music`, `fairplayd`, `AMP*`, `itunes`):** Preserves the `hwgva-id` lookup untouched so `unfairgva=4` returns the spoofed `iMacPro1,1` board ID (`Mac-7BA5B2D9E42DDD94`) and Apple Music lossless/DRM streaming works without interruption.
  * **For WebKit-based browsers (Safari, Yab), Chrome, and VideoToolbox processes:** Rewrites `"hwgva-id"` in-place to `"board-id"` before `IORegistryEntry` looks up the property. `AppleGVA` receives the native SMBIOS `board-id` (e.g. `Mac-0CFF9C7C2B63DF8D` / `MacBookAir9,1`), enabling native Intel GuC/GVA **VP9 (`vp09`)** hardware acceleration across unlimited consecutive videos without ever falling back to `avc1`.
  * **For Mozilla Firefox (`plugin-container` RDD Process):** Permits `iokit-get-properties` checks in `_mac_iokit_check_get_property` so `MTLCopyAllDevicesWithObserver()` and `VideoToolbox` can enumerate the Intel GPU inside Firefox's RDD sandbox, enabling **VP9 (`vp09`) and HEVC (`hvc1`) hardware decoding** in Firefox (`about:support`).

---

## Repository Structure

```text
├── external/
│   └── Lilu/                      # Lilu SDK headers & plugin entry wrappers for building VPXFixup.kext
├── kext/
│   └── VPXFixup/
│       ├── Info.plist             # Lilu plugin kext metadata (id.medkintos.VPXFixup)
│       ├── Makefile               # Kernel extension build rules
│       ├── VPXFixup.cpp           # XNU MAC policy & IORegistry property redirection implementation
│       └── VPXFixup.hpp           # Kernel patcher declarations
├── scripts/
│   ├── build.sh                   # Clean build script for VPXFixup.kext
│   ├── package_release.sh         # Builds and packages unified Sonoma, Sequoia & Tahoe release archives into dist/
│   └── test_hw_decode.sh          # Automated VP9 & HEVC hardware decode verification (Safari, Chrome, Firefox)
├── HOW_IT_WORKS.md                # Detailed technical documentation of the kernel hooks
└── Makefile                       # Top-level build system
```

---

## Building from Source

### Build `VPXFixup.kext`
```bash
./scripts/build.sh
```
This produces:
* `build/VPXFixup.kext` (`x86_64` Lilu kernel extension plugin, minimum OS macOS Sonoma 14.0+)

### Build Release Packages (`dist/`)
```bash
./scripts/package_release.sh
```
This builds and generates a **single unified release package** compatible with **macOS Sonoma (14.0+ / Darwin 23)**, **macOS Sequoia (15.0+ / Darwin 24)**, and **macOS Tahoe (26.0+ / Darwin 25)**:
* `dist/VPXFixup-Release.zip` / `dist/VPXFixup-Release.tar.gz` (Unified Sonoma, Sequoia & Tahoe build)

---

## Installation (OpenCore EFI)

1. Mount your OpenCore EFI partition.
2. Copy `VPXFixup.kext` to `EFI/OC/Kexts/VPXFixup.kext`.
3. Add `VPXFixup.kext` to your `EFI/OC/config.plist` under `Kernel -> Add` **after** `Lilu.kext` and `WhateverGreen.kext`.
4. Keep `unfairgva=4` in your `boot-args` so Apple Music DRM continues to work!
5. Reboot and run the automated hardware decode verification script:
   ```bash
   ./scripts/test_hw_decode.sh
   ```
   * **Zero External Browser Downloads Required:** The script tests `VPXFixup.kext`, direct `VideoToolbox` & `Metal` APIs, live **Safari / WebKit (`MediaCapabilities`)**, and simulated **Google Chrome GPU Sandbox** & **Mozilla Firefox RDD Sandbox** environments out of the box — even if Chrome or Firefox are not installed!
   * If Chrome or Firefox are installed, it automatically detects them as well.
   * Pass `--open-safari` or `--open-all` to launch an interactive visual hardware decode test dashboard in your browser(s):
     ```bash
     ./scripts/test_hw_decode.sh --open-safari
     ```
6. Open YouTube in **Safari**, **Yab**, **Firefox**, or **Google Chrome** and open **Stats for nerds** — consecutive 1080p60/4K videos will play smoothly using **`vp09`** hardware acceleration while **Apple Music** continues to play DRM songs without issue.

---

## Credits & Resources

### Credits
* **[Acidanthera](https://github.com/acidanthera)** — For [Lilu](https://github.com/acidanthera/Lilu), [WhateverGreen](https://github.com/acidanthera/WhateverGreen), [MacKernelSDK](https://github.com/acidanthera/MacKernelSDK), and [OpenCorePkg](https://github.com/acidanthera/OpenCorePkg), which provide the kernel patching infrastructure and Hackintosh bootloader ecosystem.
* **[Apple Inc.](https://opensource.apple.com/)** — For the open-source [XNU kernel](https://github.com/apple-oss-distributions/xnu), [WebKit](https://github.com/WebKit/WebKit), Metal framework, and VideoToolbox APIs.
* **[Mozilla](https://github.com/mozilla/gecko-dev)** — For Firefox's `AppleDecoderModule`, `AppleVTDecoder`, and macOS RDD sandbox architecture.
* **Google DeepMind Antigravity** — AI pair-programming agent used to research, author, debug, and package this project.

### Resources & Related Repositories
* [**How It Works (`HOW_IT_WORKS.md`)**](./HOW_IT_WORKS.md) — Internal architecture and XNU MAC policy / IORegistry redirection flow.
* [**VP8MetalDecoder (`medkintos/VP8MetalDecoder`)**](https://github.com/medkintos/VP8MetalDecoder) — Companion standalone Metal compute shader VideoToolbox driver bundle (`VPXMetalVADriver.bundle`) for VP8 and VP9.
* [Lilu Plugin Development Guide](https://github.com/acidanthera/Lilu) — Reference for `KernelPatcher` symbol routing and Lilu plugin lifecycle.
* [WhateverGreen DRM & `unfairgva` Documentation](https://github.com/acidanthera/WhateverGreen/blob/master/Manual/FAQ.Chart.md) — Background on `hwgva-id` board-id spoofing and FairPlay DRM on Intel Hackintosh systems.
