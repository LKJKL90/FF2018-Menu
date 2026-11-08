// substrate_shim.c — MSHookFunction minimal pour arm64 iOS, sans substrate.
//
// Un IPA sideloadé n'a pas /usr/lib/libsubstrate.dylib : le symbole
// _MSHookFunction reste non résolu et dyld tue le process au premier appel.
// Ce fichier fournit une implémentation autonome, suffisante pour un hook
// de fonction unique (Player.LateUpdate).
//
// Principe :
//   1. on vole les 4 premières instructions de la cible (16 octets)
//   2. on les recopie dans un trampoline suivi de  ldr x16,#8 / br x16 / <cible+16>
//   3. on remplace la cible par            ldr x16,#8 / br x16 / <replacement>
//   4. l'appelant reçoit l'adresse du trampoline, qui rejoue le prologue puis
//      repart dans la fonction d'origine.
//
// L'écriture dans __TEXT passe par vm_protect(VM_PROT_COPY) : la page est
// copiée en COW, modifiée, puis remise en R-X. Aucune allocation exécutable
// n'est demandée, donc pas besoin de l'entitlement dynamic-codesigning.

#include <stdint.h>
#include <string.h>
#include <mach/mach.h>
#include <mach/vm_map.h>
#include <mach/vm_prot.h>
#include <libkern/OSCacheControl.h>

#define HOOK_SLOTS      8
#define SLOT_BYTES      32
#define STOLEN_BYTES    16

// Pool de trampolines : 8 slots de 32 octets, placés dans __TEXT du dylib.
// Le contenu est écrit à l'exécution, l'espace est réservé à la compilation.
__attribute__((naked, used, aligned(16)))
static void _ff_hook_slots(void) {
    __asm__ __volatile__(".space 256, 0\n");
}

static int _ff_next_slot = 0;

// Rend [addr, addr+n) accessible en écriture, écrit, puis remet en R-X.
// Gère le cas où la zone chevauche deux pages.
static int _ff_write_code(void *addr, const void *src, size_t n) {
    uintptr_t start = (uintptr_t)addr;
    uintptr_t page  = start & ~(uintptr_t)(vm_page_size - 1);
    vm_size_t span  = (vm_size_t)((start + n) - page);
    kern_return_t kr;

    // On arrondit au multiple de page pour que la remise en R-X couvre tout.
    span = (vm_size_t)(((span + vm_page_size - 1) / vm_page_size) * vm_page_size);

    kr = vm_protect(mach_task_self(), (vm_address_t)page, span, FALSE,
                    VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS) return -1;

    memcpy(addr, src, n);
    sys_icache_invalidate(addr, n);

    kr = vm_protect(mach_task_self(), (vm_address_t)page, span, FALSE,
                    VM_PROT_READ | VM_PROT_EXECUTE);
    if (kr != KERN_SUCCESS) return -2;

    return 0;
}

void MSHookFunction(void *symbol, void *replace, void **result) {
    if (!symbol || !replace) return;
    if (_ff_next_slot >= HOOK_SLOTS) return;

    uintptr_t slot = (uintptr_t)_ff_hook_slots + (uintptr_t)(_ff_next_slot * SLOT_BYTES);
    _ff_next_slot++;

    uint32_t tramp[8];
    memcpy(tramp, symbol, STOLEN_BYTES);        // prologue d'origine
    tramp[4] = 0x58000050;                      // ldr x16, #8
    tramp[5] = 0xd61f0200;                      // br  x16
    uint64_t back = (uint64_t)((uintptr_t)symbol + STOLEN_BYTES);
    memcpy(&tramp[6], &back, sizeof(back));     // littéral de ldr

    if (_ff_write_code((void *)slot, tramp, sizeof(tramp)) != 0) return;

    uint32_t patch[4];
    patch[0] = 0x58000050;                      // ldr x16, #8
    patch[1] = 0xd61f0200;                      // br  x16
    uint64_t dest = (uint64_t)(uintptr_t)replace;
    memcpy(&patch[2], &dest, sizeof(dest));

    if (_ff_write_code(symbol, patch, sizeof(patch)) != 0) return;

    if (result) *result = (void *)slot;
}
