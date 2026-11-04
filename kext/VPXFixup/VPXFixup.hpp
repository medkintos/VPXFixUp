//
//  VPXFixup.hpp
//  VPXFixup - Lilu plugin to redirect hwgva-id -> board-id for non-Music processes
//  Preserves Apple Music DRM (unfairgva=4) while fixing WebKit/Safari/Yab hardware VP9
//
//  Copyright © 2026 Antigravity. All rights reserved.
//

#ifndef VPXFixup_hpp
#define VPXFixup_hpp

#include <Headers/kern_api.hpp>
#include <Headers/kern_patcher.hpp>
#include <IOKit/IORegistryEntry.h>

class VPXFixupPlugin {
public:
    void init();
    void deinit();
    void patchKernel(KernelPatcher &patcher);

private:
    static mach_vm_address_t org_mac_iokit_check_get_property;
    static mach_vm_address_t org_is_io_registry_entry_get_property_bin_buf;
    static mach_vm_address_t org_is_io_registry_entry_get_property_bin;
    static mach_vm_address_t org_is_io_registry_entry_get_property_recursively;
    static mach_vm_address_t org_is_io_registry_entry_get_property;
    static mach_vm_address_t org_is_io_registry_entry_get_property_bytes;

    static mach_vm_address_t orgCopyProperty_char;
    static mach_vm_address_t orgCopyProperty_symbol;
    static mach_vm_address_t orgCopyPropertyPlane_char;
    static mach_vm_address_t orgCopyPropertyPlane_symbol;

    static int wrap_mac_iokit_check_get_property(kauth_cred_t cred, io_object_t registry_entry, const char *property_name);
    static kern_return_t wrap_is_io_registry_entry_get_property_bin_buf(io_object_t registry_entry, io_name_t plane, io_name_t property_name, uint32_t options, mach_vm_address_t buf, mach_vm_size_t *bufsize, io_buf_ptr_t *properties, mach_msg_type_number_t *propertiesCnt);
    static kern_return_t wrap_is_io_registry_entry_get_property_bin(io_object_t registry_entry, io_name_t plane, io_name_t property_name, uint32_t options, io_buf_ptr_t *properties, mach_msg_type_number_t *propertiesCnt);
    static kern_return_t wrap_is_io_registry_entry_get_property_recursively(io_object_t registry_entry, io_name_t plane, io_name_t property_name, uint32_t options, io_buf_ptr_t *properties, mach_msg_type_number_t *propertiesCnt);
    static kern_return_t wrap_is_io_registry_entry_get_property(io_object_t registry_entry, io_name_t property_name, io_buf_ptr_t *properties, mach_msg_type_number_t *propertiesCnt);
    static kern_return_t wrap_is_io_registry_entry_get_property_bytes(io_object_t registry_entry, io_name_t property_name, io_struct_inband_t buf, mach_msg_type_number_t *dataCnt);

    static OSObject *wrapCopyProperty_char(const IORegistryEntry *that, const char *aKey);
    static OSObject *wrapCopyProperty_symbol(const IORegistryEntry *that, const OSSymbol *aKey);
    static OSObject *wrapCopyPropertyPlane_char(const IORegistryEntry *that, const char *aKey, const IORegistryPlane *plane, IOOptionBits options);
    static OSObject *wrapCopyPropertyPlane_symbol(const IORegistryEntry *that, const OSSymbol *aKey, const IORegistryPlane *plane, IOOptionBits options);
};

#endif /* VPXFixup_hpp */
