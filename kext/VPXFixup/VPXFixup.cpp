//
//  VPXFixup.cpp
//  VPXFixup - Lilu plugin to redirect hwgva-id -> board-id for non-Music processes
//  Preserves Apple Music DRM (unfairgva=4) while fixing WebKit/Safari/Yab hardware VP9
//
//  Copyright © 2026 Antigravity. All rights reserved.
//

#include <Headers/plugin_start.hpp>
#include <Headers/kern_api.hpp>
#include <Headers/kern_util.hpp>
#include <Headers/kern_patcher.hpp>
#include <IOKit/IORegistryEntry.h>
#include <IOKit/IOLib.h>
#include <sys/proc.h>
#include <mach/kmod.h>
#include "VPXFixup.hpp"

static VPXFixupPlugin vpxPlugin;

mach_vm_address_t VPXFixupPlugin::org_mac_iokit_check_get_property = 0;
mach_vm_address_t VPXFixupPlugin::org_is_io_registry_entry_get_property_bin_buf = 0;
mach_vm_address_t VPXFixupPlugin::org_is_io_registry_entry_get_property_bin = 0;
mach_vm_address_t VPXFixupPlugin::org_is_io_registry_entry_get_property_recursively = 0;
mach_vm_address_t VPXFixupPlugin::org_is_io_registry_entry_get_property = 0;
mach_vm_address_t VPXFixupPlugin::org_is_io_registry_entry_get_property_bytes = 0;

mach_vm_address_t VPXFixupPlugin::orgCopyProperty_char = 0;
mach_vm_address_t VPXFixupPlugin::orgCopyProperty_symbol = 0;
mach_vm_address_t VPXFixupPlugin::orgCopyPropertyPlane_char = 0;
mach_vm_address_t VPXFixupPlugin::orgCopyPropertyPlane_symbol = 0;

// Returns true ONLY for Apple Music / FairPlay DRM processes that need unfairgva=4 (hwgva-id = iMacPro1,1).
// All other processes (WebKit.GPU, Safari, yab, VTDecoderXPCService, etc.) receive the native board-id.
static inline bool isMusicProcess() {
    char name[64] = {0};
    proc_selfname(name, sizeof(name));
    if (strstr(name, "Music") != nullptr ||
        strstr(name, "fairplay") != nullptr ||
        strstr(name, "AMP") != nullptr ||
        strstr(name, "itunes") != nullptr) {
        return true;
    }
    return false;
}

static inline void redirectHwgvaIdInPlace(char *property_name) {
    if (property_name != nullptr && strcmp(property_name, "hwgva-id") == 0) {
        if (!isMusicProcess()) {
            // Both "hwgva-id" and "board-id" are exactly 8 characters + NUL
            memcpy(property_name, "board-id", 9);
        }
    }
}

int VPXFixupPlugin::wrap_mac_iokit_check_get_property(kauth_cred_t cred, io_object_t registry_entry, const char *property_name) {
    if (property_name != nullptr && strcmp(property_name, "hwgva-id") == 0) {
        if (!isMusicProcess()) {
            return FunctionCast(wrap_mac_iokit_check_get_property, org_mac_iokit_check_get_property)(cred, registry_entry, "board-id");
        }
    }
    return FunctionCast(wrap_mac_iokit_check_get_property, org_mac_iokit_check_get_property)(cred, registry_entry, property_name);
}

kern_return_t VPXFixupPlugin::wrap_is_io_registry_entry_get_property_bin_buf(
    io_object_t registry_entry, io_name_t plane, io_name_t property_name,
    uint32_t options, mach_vm_address_t buf, mach_vm_size_t *bufsize,
    io_buf_ptr_t *properties, mach_msg_type_number_t *propertiesCnt) {
    redirectHwgvaIdInPlace(property_name);
    return FunctionCast(wrap_is_io_registry_entry_get_property_bin_buf, org_is_io_registry_entry_get_property_bin_buf)(
        registry_entry, plane, property_name, options, buf, bufsize, properties, propertiesCnt);
}

kern_return_t VPXFixupPlugin::wrap_is_io_registry_entry_get_property_bin(
    io_object_t registry_entry, io_name_t plane, io_name_t property_name,
    uint32_t options, io_buf_ptr_t *properties, mach_msg_type_number_t *propertiesCnt) {
    redirectHwgvaIdInPlace(property_name);
    return FunctionCast(wrap_is_io_registry_entry_get_property_bin, org_is_io_registry_entry_get_property_bin)(
        registry_entry, plane, property_name, options, properties, propertiesCnt);
}

kern_return_t VPXFixupPlugin::wrap_is_io_registry_entry_get_property_recursively(
    io_object_t registry_entry, io_name_t plane, io_name_t property_name,
    uint32_t options, io_buf_ptr_t *properties, mach_msg_type_number_t *propertiesCnt) {
    redirectHwgvaIdInPlace(property_name);
    return FunctionCast(wrap_is_io_registry_entry_get_property_recursively, org_is_io_registry_entry_get_property_recursively)(
        registry_entry, plane, property_name, options, properties, propertiesCnt);
}

kern_return_t VPXFixupPlugin::wrap_is_io_registry_entry_get_property(
    io_object_t registry_entry, io_name_t property_name,
    io_buf_ptr_t *properties, mach_msg_type_number_t *propertiesCnt) {
    redirectHwgvaIdInPlace(property_name);
    return FunctionCast(wrap_is_io_registry_entry_get_property, org_is_io_registry_entry_get_property)(
        registry_entry, property_name, properties, propertiesCnt);
}

kern_return_t VPXFixupPlugin::wrap_is_io_registry_entry_get_property_bytes(
    io_object_t registry_entry, io_name_t property_name,
    io_struct_inband_t buf, mach_msg_type_number_t *dataCnt) {
    redirectHwgvaIdInPlace(property_name);
    return FunctionCast(wrap_is_io_registry_entry_get_property_bytes, org_is_io_registry_entry_get_property_bytes)(
        registry_entry, property_name, buf, dataCnt);
}

OSObject *VPXFixupPlugin::wrapCopyProperty_char(const IORegistryEntry *that, const char *aKey) {
    if (aKey != nullptr && strcmp(aKey, "hwgva-id") == 0) {
        if (!isMusicProcess()) {
            return FunctionCast(wrapCopyProperty_char, orgCopyProperty_char)(that, "board-id");
        }
    }
    return FunctionCast(wrapCopyProperty_char, orgCopyProperty_char)(that, aKey);
}

OSObject *VPXFixupPlugin::wrapCopyProperty_symbol(const IORegistryEntry *that, const OSSymbol *aKey) {
    if (aKey != nullptr && aKey->isEqualTo("hwgva-id")) {
        if (!isMusicProcess()) {
            const OSSymbol *boardSym = OSSymbol::withCStringNoCopy("board-id");
            if (boardSym != nullptr) {
                OSObject *res = FunctionCast(wrapCopyProperty_symbol, orgCopyProperty_symbol)(that, boardSym);
                boardSym->release();
                return res;
            }
        }
    }
    return FunctionCast(wrapCopyProperty_symbol, orgCopyProperty_symbol)(that, aKey);
}

OSObject *VPXFixupPlugin::wrapCopyPropertyPlane_char(const IORegistryEntry *that, const char *aKey, const IORegistryPlane *plane, IOOptionBits options) {
    if (aKey != nullptr && strcmp(aKey, "hwgva-id") == 0) {
        if (!isMusicProcess()) {
            return FunctionCast(wrapCopyPropertyPlane_char, orgCopyPropertyPlane_char)(that, "board-id", plane, options);
        }
    }
    return FunctionCast(wrapCopyPropertyPlane_char, orgCopyPropertyPlane_char)(that, aKey, plane, options);
}

OSObject *VPXFixupPlugin::wrapCopyPropertyPlane_symbol(const IORegistryEntry *that, const OSSymbol *aKey, const IORegistryPlane *plane, IOOptionBits options) {
    if (aKey != nullptr && aKey->isEqualTo("hwgva-id")) {
        if (!isMusicProcess()) {
            const OSSymbol *boardSym = OSSymbol::withCStringNoCopy("board-id");
            if (boardSym != nullptr) {
                OSObject *res = FunctionCast(wrapCopyPropertyPlane_symbol, orgCopyPropertyPlane_symbol)(that, boardSym, plane, options);
                boardSym->release();
                return res;
            }
        }
    }
    return FunctionCast(wrapCopyPropertyPlane_symbol, orgCopyPropertyPlane_symbol)(that, aKey, plane, options);
}

void VPXFixupPlugin::patchKernel(KernelPatcher &patcher) {
    IOLog("VPXFixup: routing IOKit registry property & MAC checks (hwgva-id -> board-id)\n");

    KernelPatcher::RouteRequest requests[] = {
        { "_mac_iokit_check_get_property", wrap_mac_iokit_check_get_property, org_mac_iokit_check_get_property },
        { "_is_io_registry_entry_get_property_bin_buf", wrap_is_io_registry_entry_get_property_bin_buf, org_is_io_registry_entry_get_property_bin_buf },
        { "_is_io_registry_entry_get_property_bin", wrap_is_io_registry_entry_get_property_bin, org_is_io_registry_entry_get_property_bin },
        { "_is_io_registry_entry_get_property_recursively", wrap_is_io_registry_entry_get_property_recursively, org_is_io_registry_entry_get_property_recursively },
        { "_is_io_registry_entry_get_property", wrap_is_io_registry_entry_get_property, org_is_io_registry_entry_get_property },
        { "_is_io_registry_entry_get_property_bytes", wrap_is_io_registry_entry_get_property_bytes, org_is_io_registry_entry_get_property_bytes },
        { "__ZNK15IORegistryEntry12copyPropertyEPKc", wrapCopyProperty_char, orgCopyProperty_char },
        { "__ZNK15IORegistryEntry12copyPropertyEPK8OSSymbol", wrapCopyProperty_symbol, orgCopyProperty_symbol },
        { "__ZNK15IORegistryEntry12copyPropertyEPKcPK15IORegistryPlanej", wrapCopyPropertyPlane_char, orgCopyPropertyPlane_char },
        { "__ZNK15IORegistryEntry12copyPropertyEPK8OSSymbolPK15IORegistryPlanej", wrapCopyPropertyPlane_symbol, orgCopyPropertyPlane_symbol }
    };

    patcher.routeMultiple(KernelPatcher::KernelID, requests, arrsize(requests), 0, 0, true, true);
    if (patcher.getError() != KernelPatcher::Error::NoError) {
        IOLog("VPXFixup: routeMultiple reported error %d\n", patcher.getError());
        patcher.clearError();
    } else {
        IOLog("VPXFixup: successfully routed all 10 IOKit registry property hooks\n");
    }
}

void VPXFixupPlugin::init() {
    IOLog("VPXFixup: init() called, registering kernel patcher callback\n");
    lilu.onPatcherLoadForce([](void *user, KernelPatcher &patcher) {
        static_cast<VPXFixupPlugin *>(user)->patchKernel(patcher);
    }, this);
}

void VPXFixupPlugin::deinit() {
}

static const char *bootargOff[] {
    "-vpxfixupoff"
};

static const char *bootargDebug[] {
    "-vpxfixupdbg"
};

static const char *bootargBeta[] {
    "-vpxfixupbeta"
};

// Explicit kmod declaration for OpenCore / xnu kernel loader
extern "C" kern_return_t ADDPR(kern_start)(kmod_info_t *, void *);
extern "C" kern_return_t ADDPR(kern_stop)(kmod_info_t *, void *);

KMOD_EXPLICIT_DECL(id.medkintos.VPXFixup, "1.0.0", ADDPR(kern_start), ADDPR(kern_stop))
__private_extern__ kmod_start_func_t *_realmain = 0;
__private_extern__ kmod_stop_func_t *_antimain = 0;
__private_extern__ int _kext_apple_cc = __APPLE_CC__;

PluginConfiguration ADDPR(config) {
    xStringify(PRODUCT_NAME),
    parseModuleVersion(xStringify(MODULE_VERSION)),
    LiluAPI::AllowNormal | LiluAPI::AllowInstallerRecovery | LiluAPI::AllowSafeMode,
    bootargOff,
    arrsize(bootargOff),
    bootargDebug,
    arrsize(bootargDebug),
    bootargBeta,
    arrsize(bootargBeta),
    KernelVersion::Sierra,
    KernelVersion::Tahoe,
    []() {
        vpxPlugin.init();
    }
};
