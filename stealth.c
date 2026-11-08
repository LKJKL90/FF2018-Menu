// stealth.c — masque le dylib des scans de l'anti-cheat.
//
// L'anti-cheat du jeu (libac_sdk.dylib) énumère les images dyld
// (_dyld_image_count / _dyld_get_image_name / _dyld_get_image_header /
// _dyld_get_image_vmaddr_slide) et parcourt des répertoires (opendir /
// readdir) pour repérer substrate, frida, cycript, etc. Un dylib inconnu
// dans Frameworks/ est donc visible en deux coups d'œil.
//
// On interpose ces fonctions : notre image disparaît de l'énumération et
// notre nom de fichier disparaît des readdir(). Le reste de l'API se
// comporte exactement comme avant.
//
// Tout est résolu à la première utilisation. Si une résolution échoue,
// les wrappers retombent sur un comportement neutre au lieu de casser
// l'énumération : mieux vaut être visible que planter le jeu.

#include <stdint.h>
#include <string.h>
#include <dirent.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>

#define DYLD_INTERPOSE(_replacement, _replacee)                              \
    __attribute__((used)) static struct {                                    \
        const void *replacement;                                             \
        const void *replacee;                                                \
    } _interpose_##_replacee __attribute__((section("__DATA,__interpose"))) = \
        { (const void *)(unsigned long)&_replacement,                        \
          (const void *)(unsigned long)&_replacee }

static uint32_t (*real_image_count)(void);
static const char *(*real_image_name)(uint32_t);
static const struct mach_header *(*real_image_header)(uint32_t);
static intptr_t (*real_image_slide)(uint32_t);
static struct dirent *(*real_readdir)(DIR *);

static int xz_hidden_index = -1;
static int xz_busy = 0;
static char xz_name[192];

// Pointeurs vers les fonctions d'origine. On interroge libSystem par
// handle : RTLD_DEFAULT pourrait renvoyer notre propre wrapper.
static void *xz_sym(const char *a, const char *b) {
    static void *h;
    if (!h) {
        h = dlopen("/usr/lib/libSystem.B.dylib", RTLD_LAZY | RTLD_NOLOAD);
        if (!h) h = dlopen("/usr/lib/libSystem.B.dylib", RTLD_LAZY);
    }
    void *p = h ? dlsym(h, a) : NULL;
    if (!p) p = dlsym(RTLD_DEFAULT, a);
    if (!p && b) {
        p = h ? dlsym(h, b) : NULL;
        if (!p) p = dlsym(RTLD_DEFAULT, b);
    }
    return p;
}

static void xz_ensure(void) {
    if (real_image_count && xz_hidden_index >= 0) return;
    if (xz_busy) return;                 // réentrance (dlsym -> dyld_image_count)
    xz_busy = 1;

    if (!real_image_count) {
        void *p;
        p = xz_sym("_dyld_image_count", "dyld_image_count");
        if (p && p != (void *)(uintptr_t)&real_image_count) real_image_count = (uint32_t (*)(void))p;
        p = xz_sym("_dyld_get_image_name", "dyld_get_image_name");
        if (p) real_image_name = (const char *(*)(uint32_t))p;
        p = xz_sym("_dyld_get_image_header", "dyld_get_image_header");
        if (p) real_image_header = (const struct mach_header *(*)(uint32_t))p;
        p = xz_sym("_dyld_get_image_vmaddr_slide", "dyld_get_image_vmaddr_slide");
        if (p) real_image_slide = (intptr_t (*)(uint32_t))p;
        p = xz_sym("readdir", NULL);
        if (p) real_readdir = (struct dirent *(*)(DIR *))p;
    }

    if (real_image_count && real_image_header && xz_hidden_index < 0) {
        Dl_info info;
        if (dladdr((void *)(uintptr_t)&xz_ensure, &info) && info.dli_fbase) {
            uint32_t n = real_image_count();
            for (uint32_t i = 0; i < n; i++) {
                if ((const void *)real_image_header(i) == info.dli_fbase) {
                    xz_hidden_index = (int)i;
                    break;
                }
            }
        }
    }
    xz_busy = 0;
}

void xz_stealth_init(void) {
    xz_ensure();
}

static const char *xz_self_name(void) {
    if (xz_name[0]) return xz_name;
    Dl_info info;
    if (dladdr((void *)(uintptr_t)&xz_self_name, &info) && info.dli_fname) {
        const char *slash = strrchr(info.dli_fname, '/');
        const char *base = slash ? slash + 1 : info.dli_fname;
        size_t n = strlen(base);
        if (n >= sizeof(xz_name)) n = sizeof(xz_name) - 1;
        memcpy(xz_name, base, n);
        xz_name[n] = 0;
    }
    return xz_name;
}

static uint32_t xz_map_index(uint32_t i) {
    if (xz_hidden_index >= 0 && i >= (uint32_t)xz_hidden_index) return i + 1;
    return i;
}

// ---- remplacements -------------------------------------------------------
static uint32_t xz_image_count(void) {
    xz_ensure();
    if (!real_image_count) return 0;
    uint32_t n = real_image_count();
    if (xz_hidden_index >= 0 && n > (uint32_t)xz_hidden_index) n -= 1;
    return n;
}

static const char *xz_image_name(uint32_t i) {
    xz_ensure();
    if (!real_image_name) return NULL;
    return real_image_name(xz_map_index(i));
}

static const struct mach_header *xz_image_header(uint32_t i) {
    xz_ensure();
    if (!real_image_header) return NULL;
    return real_image_header(xz_map_index(i));
}

static intptr_t xz_image_slide(uint32_t i) {
    xz_ensure();
    if (!real_image_slide) return 0;
    return real_image_slide(xz_map_index(i));
}

static struct dirent *xz_readdir(DIR *d) {
    xz_ensure();
    if (!real_readdir) return NULL;
    const char *me = xz_self_name();
    struct dirent *e;
    while ((e = real_readdir(d))) {
        if (me[0] && strcmp(e->d_name, me) == 0) continue;
        return e;
    }
    return NULL;
}

DYLD_INTERPOSE(xz_image_count, _dyld_image_count);
DYLD_INTERPOSE(xz_image_name, _dyld_get_image_name);
DYLD_INTERPOSE(xz_image_header, _dyld_get_image_header);
DYLD_INTERPOSE(xz_image_slide, _dyld_get_image_vmaddr_slide);
DYLD_INTERPOSE(xz_readdir, readdir);
