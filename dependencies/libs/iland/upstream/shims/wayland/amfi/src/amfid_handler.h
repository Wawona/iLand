#pragma once

/* task_t, mach_vm_address_t and the rest of the Mach VM types used below are
 * declared in these headers. Include them here so the header is self-contained
 * regardless of include order in the translation unit. */
#include <mach/mach.h>
#include <mach/mach_vm.h>

int  install_hook(task_t task, mach_vm_address_t fn_addr);
void amfid_patch(void);
void amfid_unpatch(void);
