#!/usr/bin/env python3
"""Génère xz_strings.h : chaînes UI encodées XOR pour éviter les scans
de chaînes en clair dans le binaire (signatures de mod menu)."""
import sys

KEY = 0x5A
STRINGS = [
    "XZPROJECT",          # 0
    "v1.0.0",             # 1
    "ACTIVE",             # 2
    "INJECTION",          # 3
    "INJECT",             # 4
    "VISUALS",            # 5
    "ESP",                # 6
    "Test Health",        # 7
    "COMBAT",             # 8
    "Aimbot",             # 9
    "MOVEMENT",           # 10
    "Fly",                # 11
    "STATUS",             # 12
    "BASE",               # 13
    "HOOK",               # 14
    "PLAYERS",            # 15
    "ON",                 # 16
    "OFF",                # 17
    "READY",              # 18
    "XZPROJECT // ff2018",# 19
    "iloader",            # 20
    "momoZbadou",         # 21
    "x",                  # 22
]


def main():
    out = ["// généré par tools/gen_strings.py — ne pas éditer à la main",
           "#ifndef XZ_STRINGS_H", "#define XZ_STRINGS_H", ""]
    for i, s in enumerate(STRINGS):
        data = ", ".join("0x%02X" % (ord(c) ^ KEY) for c in s)
        out.append("static const unsigned char xz_s%d[] = { %s };" % (i, data))
    out.append("")
    out.append("#define XZ_COUNT %d" % len(STRINGS))
    out.append("static NSString *XZS(int i) {")
    out.append("    static const unsigned char *tab[XZ_COUNT] = {")
    out.append("        " + ", ".join("xz_s%d" % i for i in range(len(STRINGS))))
    out.append("    };")
    out.append("    static const unsigned short len[XZ_COUNT] = {")
    out.append("        " + ", ".join(str(len(s)) for s in STRINGS))
    out.append("    };")
    out.append("    if (i < 0 || i >= XZ_COUNT) return @\"\";")
    out.append("    const unsigned char *p = tab[i];")
    out.append("    unsigned short n = len[i];")
    out.append("    char buf[96];")
    out.append("    if (n > 95) n = 95;")
    out.append("    for (unsigned short j = 0; j < n; j++) buf[j] = (char)(p[j] ^ 0x%02X);" % KEY)
    out.append("    buf[n] = 0;")
    out.append("    return [NSString stringWithUTF8String:buf];")
    out.append("}")
    out.append("")
    out.append("#endif")
    header = "\n".join(out) + "\n"
    with open(sys.argv[1] if len(sys.argv) > 1 else "xz_strings.h", "w", encoding="utf-8") as f:
        f.write(header)
    print("xz_strings.h: %d chaînes" % len(STRINGS))


if __name__ == "__main__":
    main()
