// stealth2.c — masque FFF_XZ uniquement pour libac_sdk.dylib.
//
// Pourquoi pas __DATA,__interpose (la version precedente) :
// la table d'interposition contient l'adresse de la fonction REMPLACEE.
// Ici ces fonctions viennent de dyld, non linkees a la compilation : le
// linker laissait 0 dans la case "replacee". Une entree d'interposition
// avec une adresse nulle est invalide -> dyld tuait le process au
// chargement. C'est exactement le crash de la v7.2.
//
// Ici on ne touche PAS au dyld global. On reecrit uniquement les slots
// d'import de libac_sdk (__got / __la_symbol_ptr). Seul l'anti-cheat voit
// une liste d'images filtree ; le reste du jeu, Unity et UIKit compris,
// continue d'appeler les vraies fonctions.
//
// Le scan de l'anti-cheat demarre dans un thread qui fait sleep(5) avant
// la premiere passe : notre constructeur a largement le temps de patcher.
//
// Si quoi que ce soit ne se passe pas comme prevu (image introuvable,
// section absente, vm_protect refuse), on ne patche rien et on rend la
// main : le jeu reste intact.

#include <stdint.h>
#include <string.h>
#include <dirent.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <mach/mach.h>
#include <mach/vm_map.h>

#ifndef VM_PROT_COPY
#define VM_PROT_COPY 0x10
#endif

static uint32_t (*real_count)(void);
static const char *(*real_name)(uint32_t);
static const struct mach_header *(*real_header)(uint32_t);
static intptr_t (*real_slide)(uint32_t);
static struct dirent *(*real_readdir)(DIR *);

static int g_my_index = -1;
static int g_patched = 0;
static int g_hdr_ok = 0;
static const char kSelfName[] = "FFF_XZ.dylib";

// ---- resolution paresseuse des fonctions d'origine -----------------------
static void resolve(void) {
    if (real_count) return;
    real_count  = (uint32_t (*)(void))dlsym(RTLD_DEFAULT, "dyld_image_count");
    real_name   = (const char *(*)(uint32_t))dlsym(RTLD_DEFAULT, "dyld_get_image_name");
    real_header = (const struct mach_header *(*)(uint32_t))dlsym(RTLD_DEFAULT, "dyld_get_image_header");
    real_slide  = (intptr_t (*)(uint32_t))dlsym(RTLD_DEFAULT, "dyld_get_image_vmaddr_slide");
    real_readdir = (struct dirent *(*)(DIR *))dlsym(RTLD_DEFAULT, "readdir");
}

static int is_self(const char *path) {
    if (!path) return 0;
    const char *slash = strrchr(path, '/');
    const char *base = slash ? slash + 1 : path;
    return strcmp(base, kSelfName) == 0;
}

static void find_self(void) {
    resolve();
    if (!real_count || !real_name) return;
    uint32_t n = real_count();
    for (uint32_t i = 0; i < n; i++) {
        if (is_self(real_name(i))) { g_my_index = (int)i; return; }
    }
}

// ---- vues filtrees ------------------------------------------------------
static uint32_t map_index(uint32_t i) {
    if (g_my_index >= 0 && i >= (uint32_t)g_my_index) return i + 1;
    return i;
}

static uint32_t s_count(void) {
    resolve();
    if (!real_count) return 0;
    uint32_t n = real_count();
    if (g_my_index >= 0 && n > (uint32_t)g_my_index) n--;
    return n;
}

static const char *s_name(uint32_t i) {
    resolve();
    if (!real_name || i >= s_count()) return NULL;
    return real_name(map_index(i));
}

static const struct mach_header *s_header(uint32_t i) {
    resolve();
    if (!real_header || i >= s_count()) return NULL;
    return real_header(map_index(i));
}

static intptr_t s_slide(uint32_t i) {
    resolve();
    if (!real_slide || i >= s_count()) return 0;
    return real_slide(map_index(i));
}

static struct dirent *s_readdir(DIR *d) {
    resolve();
    if (!real_readdir) return NULL;
    struct dirent *e;
    while ((e = real_readdir(d))) {
        if (strcmp(e->d_name, kSelfName) == 0) continue;
        return e;
    }
    return NULL;
}

// ---- patch d'un pointeur dans la memoire du process ---------------------
static int write_ptr(void **slot, void *value) {
    vm_address_t page = (vm_address_t)slot & ~(vm_address_t)(vm_page_size - 1);
    kern_return_t kr = vm_protect(mach_task_self(), page, vm_page_size, false,
                                  VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS) return 0;
    *slot = value;
    __builtin___clear_cache((char *)slot, (char *)slot + sizeof(void *));
    vm_protect(mach_task_self(), page, vm_page_size, false,
               VM_PROT_READ | VM_PROT_WRITE);
    return 1;
}

// ---- parcours du Mach-O de libac_sdk ------------------------------------
typedef struct {
    const char *name;
    void *shim;
} sym_map;

static int patch_image(const struct mach_header *mh, intptr_t slide) {
    if (!mh || mh->magic != MH_MAGIC_64) return 0;
    const struct mach_header_64 *h = (const struct mach_header_64 *)mh;

    const struct segment_command_64 *le = NULL;
    const struct dysymtab_command *dysym = NULL;
    const struct symtab_command *st = NULL;

    uint64_t addr_got = 0, size_got = 0; uint32_t res_got = 0;
    uint64_t addr_lazy = 0, size_lazy = 0; uint32_t res_lazy = 0;
    int have_got = 0, have_lazy = 0;

    const uint8_t *p = (const uint8_t *)h + sizeof(*h);
    for (uint32_t i = 0; i < h->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)p;
        if (lc->cmdsize < sizeof(*lc)) return 0;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *sg = (const struct segment_command_64 *)lc;
            if (strcmp(sg->segname, "__LINKEDIT") == 0) le = sg;
            const struct section_64 *sec = (const struct section_64 *)(sg + 1);
            uint32_t ns = (lc->cmdsize - sizeof(*sg)) / sizeof(*sec);
            for (uint32_t j = 0; j < ns; j++, sec++) {
                if (strcmp(sec->sectname, "__got") == 0) {
                    addr_got = sec->addr; size_got = sec->size;
                    res_got = sec->reserved1; have_got = 1;
                } else if (strcmp(sec->sectname, "__la_symbol_ptr") == 0) {
                    addr_lazy = sec->addr; size_lazy = sec->size;
                    res_lazy = sec->reserved1; have_lazy = 1;
                }
            }
        } else if (lc->cmd == LC_DYSYMTAB) {
            dysym = (const struct dysymtab_command *)lc;
        } else if (lc->cmd == LC_SYMTAB) {
            st = (const struct symtab_command *)lc;
        }
        p += lc->cmdsize;
    }

    if (!le || !dysym || !st) return 0;

    // Sans slide valide, le_base pointerait sur l'adresse 0 : on ne tente
    // rien plutot que de lire n'importe ou et tuer le process.
    if (!real_slide || slide == 0) return 0;

    // Tous les offsets de la table de symboles doivent tomber dans
    // __LINKEDIT. Un decalage foireux = lecture hors mapping = crash.
    const uint64_t le_lo = le->fileoff;
    const uint64_t le_hi = le->fileoff + le->filesize;
    if (st->symoff < le_lo || st->symoff + (uint64_t)st->nsyms * 16 > le_hi) return 0;
    if (st->stroff < le_lo || st->stroff + st->strsize > le_hi) return 0;
    if (dysym->indirectsymoff < le_lo ||
        dysym->indirectsymoff + (uint64_t)dysym->nindirectsyms * 4 > le_hi) return 0;

    const uint8_t *le_base = (const uint8_t *)(slide + (intptr_t)le->vmaddr);
    const struct nlist_64 *syms = (const struct nlist_64 *)(le_base + (st->symoff - le->fileoff));
    const char *strs = (const char *)(le_base + (st->stroff - le->fileoff));
    const uint32_t *indirect = (const uint32_t *)(le_base + (dysym->indirectsymoff - le->fileoff));

    sym_map table[] = {
        { "dyld_image_count",           (void *)s_count },
        { "dyld_get_image_name",        (void *)s_name },
        { "dyld_get_image_header",      (void *)s_header },
        { "dyld_get_image_vmaddr_slide",(void *)s_slide },
        { "readdir",                    (void *)s_readdir },
    };
    const int ntab = (int)(sizeof(table) / sizeof(table[0]));

    int count = 0;
    for (int pass = 0; pass < 2; pass++) {
        uint64_t addr = pass ? addr_lazy : addr_got;
        uint64_t size = pass ? size_lazy : size_got;
        uint32_t res  = pass ? res_lazy : res_got;
        int have      = pass ? have_lazy : have_got;
        if (!have || !addr || size < 8) continue;

        uint32_t nslots = (uint32_t)(size / 8);
        for (uint32_t i = 0; i < nslots; i++) {
            if (res + i >= dysym->nindirectsyms) break;
            uint32_t symidx = indirect[res + i];
            if (symidx == INDIRECT_SYMBOL_LOCAL || symidx == INDIRECT_SYMBOL_ABS) continue;
            if (symidx >= st->nsyms) continue;
            if (syms[symidx].n_un.n_strx >= st->strsize) continue;
            const char *nm = strs + syms[symidx].n_un.n_strx;
            if (!nm || !*nm) continue;
            for (int k = 0; k < ntab; k++) {
                // les noms Mach-O portent un underscore : on compare la fin
                size_t ln = strlen(table[k].name);
                size_t ls = strlen(nm);
                if (ls < ln || strcmp(nm + (ls - ln), table[k].name) != 0) continue;
                void **slot = (void **)(slide + (intptr_t)(addr + i * 8));
                if (*slot == table[k].shim) break;
                if (write_ptr(slot, table[k].shim)) count++;
                break;
            }
        }
    }
    return count;
}

__attribute__((constructor))
static void xz_stealth2_init(void) {
    if (g_patched) return;
    find_self();
    if (g_my_index < 0) return;
    resolve();
    if (!real_count || !real_name || !real_header) return;

    uint32_t n = real_count();
    for (uint32_t i = 0; i < n; i++) {
        if (i == (uint32_t)g_my_index) continue;
        const char *nm = real_name(i);
        if (!nm || !strstr(nm, "libac_sdk")) continue;
        int r = patch_image(real_header(i), real_slide ? real_slide(i) : 0);
        if (r > 0) g_patched = 1;
        break;
    }
}

// Appele depuis Tweak.xm une fois l'UI prete : si le constructeur a ete
// trop tot (image pas encore mappee sur un demarrage bizarre), on retente.
void xz_stealth2_retry(void) {
    if (!g_patched) xz_stealth2_init();
}

// 0 = pas patche, 1 = patche. Affiche par le menu (point d'etat).
int xz_stealth2_state(void) {
    return (g_patched ? 1 : 0) | (g_hdr_ok ? 2 : 0);
}

// ============================================================
// HEADER DU BINAIRE PRINCIPAL
// ============================================================
// L'injecteur ajoute LC_LOAD_WEAK_DYLIB a la fin des load commands.
// dyld l'a lu au demarrage : une fois toutes les images initialisees,
// on peut remettre le header en memoire a l'etat d'origine (ncmds -1,
// sizeofcmds reduit, commande zeroe). Le fichier sur disque garde sa
// signature valide ; seule la copie memoire redevient identique a
// l'originale. Un anti-cheat qui hash le header du jeu ne voit plus
// aucune trace de notre dylib.
//
// On ne le fait qu'apres coup (2 s), jamais pendant l'initialisation
// de dyld.
static void hdr_restore(void) {
    if (g_hdr_ok) return;
    const struct mach_header_64 *cmh =
        (const struct mach_header_64 *)_dyld_get_image_header(0);
    if (!cmh || cmh->magic != MH_MAGIC_64) return;

    uint8_t *base = (uint8_t *)cmh;
    uint32_t off = sizeof(struct mach_header_64);
    uint32_t total = cmh->sizeofcmds;

    for (uint32_t i = 0; i < cmh->ncmds; i++) {
        struct load_command *lc = (struct load_command *)(base + off);
        if (lc->cmdsize < sizeof(struct load_command)) return;
        if (lc->cmd == LC_LOAD_WEAK_DYLIB && lc->cmdsize >= 24) {
            uint32_t nameoff = *(uint32_t *)((uint8_t *)lc + 8);
            const char *nm = (const char *)lc + nameoff;
            int last = (i + 1 == cmh->ncmds);
            if (last && nameoff < lc->cmdsize &&
                strcmp(nm, "@rpath/FFF_XZ.dylib") == 0) {

                uintptr_t start = (uintptr_t)(base + off) & ~(uintptr_t)(vm_page_size - 1);
                uintptr_t end = (uintptr_t)(base + sizeof(struct mach_header_64) + total);
                size_t len = (size_t)(end - start);

                kern_return_t kr = vm_protect(mach_task_self(), (vm_address_t)start, len,
                                              false, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
                if (kr != KERN_SUCCESS) return;

                memset(base + off, 0, (sizeof(struct mach_header_64) + total) - off);
                ((struct mach_header_64 *)cmh)->ncmds = cmh->ncmds - 1;
                ((struct mach_header_64 *)cmh)->sizeofcmds = off - sizeof(struct mach_header_64);
                __builtin___clear_cache((char *)start, (char *)(start + len));

                vm_protect(mach_task_self(), (vm_address_t)start, len, false,
                           VM_PROT_READ | VM_PROT_EXECUTE);
                g_hdr_ok = 1;
                return;
            }
        }
        off += lc->cmdsize;
    }
}

void xz_hdr_restore_retry(void) {
    hdr_restore();
}
