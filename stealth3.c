// stealth3.c — neutralise le compteur de soupcons de libac_sdk.
//
// Ce que fait l'anti-cheat (desassemble depuis libac_sdk.dylib) :
//
//   AcSDK_tick / AcSDK_report :
//       6 detecteurs -> bits 1,2,4,8,16,32,64
//       OR dans un global 32 bits a l'adresse 0xcaa0
//       le rapport envoye au serveur contient ce global
//
//   AcSDK_flags : return [0xcaa0]
//
// Autrement dit : un dylib inconnu, une trace de jailbreak, un debogueur...
// allument un bit. Le bit part dans le rapport, et le serveur refuse la
// session (c'est exactement le "plateforme d'authentification non valide").
//
// Cacher notre image ne suffit pas : le rapport recalcule les 6 detecteurs
// a chaque envoi. En revanche les quatre seules instructions qui ecrivent
// le global sont connues et verifiables. On les remplace par NOP, et on
// remet le global a zero. Le rapport lit alors 0 et se declare propre.
//
// Securite : on lit les 4 octets de chaque instruction et on ne patche que
// s'ils correspondent exactement a ceux du binaire analyse. Si la moindre
// difference apparait (autre build du jeu), on ne touche a rien.
//
// Aucune table d'interposition, aucun detour de dyld, aucun thread.

#include <stdint.h>
#include <string.h>
#include <mach-o/dyld.h>
#include <mach/mach.h>
#include <mach/vm_map.h>

#ifndef VM_PROT_COPY
#define VM_PROT_COPY 0x10
#endif

#define AC_FLAGS_RVA 0xcaa0u
#define INS_NOP      0xD503201Fu

typedef struct {
    uint32_t rva;      // adresse dans libac_sdk (vmaddr __TEXT = 0)
    uint32_t expect;   // encodage exact de l'instruction d'origine
} ac_site;

// str w8, [x9, #0xaa0]   x2
// str w8, [x19, #0xaa0]  x1
static const ac_site kSites[] = {
    { 0x4c80u, 0xB90AA128u },
    { 0x4d58u, 0xB90AA268u },
    { 0x4de8u, 0xB90AA128u },
    { 0x4ef0u, 0xB90AA128u },
};
#define NSITES (sizeof(kSites) / sizeof(kSites[0]))

static int g_ac_ok = 0;

static int make_writable(void *addr) {
    uintptr_t page = (uintptr_t)addr & ~(uintptr_t)(vm_page_size - 1);
    return vm_protect(mach_task_self(), (vm_address_t)page, vm_page_size, false,
                      VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) == KERN_SUCCESS;
}

static void make_executable(void *addr) {
    uintptr_t page = (uintptr_t)addr & ~(uintptr_t)(vm_page_size - 1);
    vm_protect(mach_task_self(), (vm_address_t)page, vm_page_size, false,
               VM_PROT_READ | VM_PROT_EXECUTE);
}

// Retourne 1 si le patch a ete pose (ou etait deja en place).
static int patch_site(intptr_t slide, const ac_site *s) {
    volatile uint32_t *p = (volatile uint32_t *)(slide + (intptr_t)s->rva);
    uint32_t cur = *p;
    if (cur == INS_NOP) return 1;
    if (cur != s->expect) return 0;
    if (!make_writable((void *)p)) return 0;
    *p = INS_NOP;
    __builtin___clear_cache((char *)p, (char *)p + 4);
    make_executable((void *)p);
    return (*p == INS_NOP) ? 1 : 0;
}

int xz_ac_patch(void) {
    if (g_ac_ok) return 1;

    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *nm = _dyld_get_image_name(i);
        if (!nm || !strstr(nm, "libac_sdk")) continue;

        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        if (!slide) return 0;

        // Verification integrale avant la moindre ecriture.
        for (unsigned k = 0; k < NSITES; k++) {
            volatile uint32_t *p = (volatile uint32_t *)(slide + (intptr_t)kSites[k].rva);
            if (*p != kSites[k].expect && *p != INS_NOP) return 0;
        }

        for (unsigned k = 0; k < NSITES; k++) {
            if (!patch_site(slide, &kSites[k])) return 0;
        }

        *(volatile uint32_t *)(slide + (intptr_t)AC_FLAGS_RVA) = 0;
        g_ac_ok = 1;
        return 1;
    }
    return 0;
}

int xz_ac_state(void) {
    return g_ac_ok;
}
