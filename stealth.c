// stealth.c — masque le dylib des scans de l'anti-cheat.
//
// L'anti-cheat du jeu (libac_sdk.dylib) énumère les images dyld
// (_dyld_image_count / _dyld_get_image_name / _dyld_get_image_header /
// _dyld_get_image_vmaddr_slide) et parcourt des répertoires pour repérer
// substrate/frida/cycript. Un dylib inconnu dans `Frameworks/` est donc
// visible en deux coups d'œil.
//
// On interpose ces fonctions : notre image disparaît de l'énumération, et
// notre nom de fichier disparaît des readdir(). Tout le reste est laissé
// intact, l'API se comporte comme si le dylib n'existait pas.

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
static char xz_name[192];

static void xz_resolve(void) {
    if (real_image_count) return;
    real_image_count  = (uint32_t (*)(void))dlsym(RTLD_DEFAULT, "dyld_image_count");
    real_image_name   = (const char *(*)(uint32_t))dlsym(RTLD_DEFAULT, "dyld_get_image_name");
    real_image_header = (const struct mach_header *(*)(uint32_t))dlsym(RTLD_DEFAULT, "dyld_get_image_header");
    real_image_slide  = (intptr_t (*)(uint32_t))dlsym(RTLD_DEFAULT, "dyld_get_image_vmaddr_slide");
    real_readdir      = (struct dirent *(*)(DIR *))dlsym(RTLD_DEFAULT, "readdir");
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

void xz_stealth_init(void) {
    xz_resolve();
    xz_self_name();
    if (!real_image_count || !real_image_header) return;

    Dl_info info;
    if (!dladdr((void *)(uintptr_t)&xz_stealth_init, &info) || !info.dli_fbase)
        return;

    uint32_t n = real_image_count();
    for (uint32_t i = 0; i < n; i++) {
        if ((const void *)real_image_header(i) == info.dli_fbase) {
            xz_hidden_index = (int)i;
            return;
        }
    }
}

static uint32_t xz_map_index(uint32_t i) {
    if (xz_hidden_index >= 0 && i >= (uint32_t)xz_hidden_index) return i + 1;
    return i;
}

// ---- remplacements -------------------------------------------------------
static uint32_t xz_image_count(void) {
    xz_resolve();
    if (!real_image_count) return 0;
    uint32_t n = real_image_count();
    if (xz_hidden_index >= 0 && n > (uint32_t)xz_hidden_index) n -= 1;
    return n;
}

static const char *xz_image_name(uint32_t i) {
    xz_resolve();
    if (!real_image_name) return NULL;
    return real_image_name(xz_map_index(i));
}

static const struct mach_header *xz_image_header(uint32_t i) {
    xz_resolve();
    if (!real_image_header) return NULL;
    return real_image_header(xz_map_index(i));
}

static intptr_t xz_image_slide(uint32_t i) {
    xz_resolve();
    if (!real_image_slide) return 0;
    return real_image_slide(xz_map_index(i));
}

static struct dirent *xz_readdir(DIR *d) {
    xz_resolve();
    if (!real_readdir) return NULL;
    const char *me = xz_self_name();
    struct dirent *e;
    while ((e = real_readdir(d))) {
        if (me[0] && strcmp(e->d_name, me) == 0) continue;
        return e;
    }
    return NULL;
}

DYLD_INTERPOSE(xz_image_count, dyld_image_count);
DYLD_INTERPOSE(xz_image_name, dyld_get_image_name);
DYLD_INTERPOSE(xz_image_header, dyld_get_image_header);
DYLD_INTERPOSE(xz_image_slide, dyld_get_image_vmaddr_slide);
DYLD_INTERPOSE(xz_readdir, readdir);
