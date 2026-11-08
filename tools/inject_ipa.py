#!/usr/bin/env python3
"""Injecte FF2018Menu.dylib dans un IPA Free Fire et ajoute le LC_LOAD_DYLIB.

Usage:
    python tools/inject_ipa.py <source.ipa> <dylib> <out.ipa> [app_dir_name]

Le binaire principal est patché dans le header (padding existant, aucun
déplacement de données), puis l'archive est réécrite. La signature d'origine
devient invalide : l'IPA doit être re-signé avant installation (iLoader/zsign).
"""
import os
import struct
import sys
import time
import zipfile

LC_LOAD_DYLIB = 0xC
LC_LOAD_WEAK_DYLIB = 0x80000018
MAXCMDSZ = 0x10000


def _patch_id_slice(macho, new_id):
    magic = struct.unpack_from("<I", macho, 0)[0]
    if magic != 0xFEEDFACF:
        return False
    ncmds = struct.unpack_from("<I", macho, 16)[0]
    p = 32
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", macho, p)
        if cmd == 0xD:  # LC_ID_DYLIB
            if 24 + len(new_id) + 1 > cmdsize:
                return False
            blob = struct.pack("<IIIIII", 0xD, cmdsize, 24, 0, 0x10000, 0x10000)
            blob += new_id.encode() + b"\0"
            blob += b"\0" * (cmdsize - len(blob))
            macho[p:p + cmdsize] = blob
            return True
        p += cmdsize
    return False


def patch_dylib_id(data, new_id):
    """Réécrit LC_ID_DYLIB du dylib injecté.

    Theos laisse `/Library/MobileSubstrate/DynamicLibraries/<nom>.dylib` :
    la chaîne "MobileSubstrate" est une signature de jailbreak en clair
    dans le binaire. On la remplace par le chemin @rpath réel.
    """
    if struct.unpack_from("<I", data, 0)[0] == 0xCAFEBABE:
        n = struct.unpack_from(">I", data, 4)[0]
        done = False
        for i in range(n):
            _cpu, _sub, off, size, _al = struct.unpack_from(">IIIII", data, 8 + i * 20)
            sl = bytearray(data[off:off + size])
            if _patch_id_slice(sl, new_id):
                data[off:off + size] = sl
                done = True
        return done
    return _patch_id_slice(data, new_id)


def clone_info(src_info):
    """Copie d'une entrée zip en gardant mode/permissions et compression.

    zipfile.writestr(nom, data) avec une chaîne crée une entrée en 0600 :
    le binaire principal perd son bit exécutable et l'app ne démarre plus.
    """
    zi = zipfile.ZipInfo(src_info.filename, date_time=src_info.date_time)
    zi.compress_type = src_info.compress_type
    zi.external_attr = src_info.external_attr
    zi.internal_attr = src_info.internal_attr
    zi.create_system = src_info.create_system
    zi.comment = src_info.comment
    return zi


def find_binary(entries):
    for name in entries:
        parts = name.split("/")
        if len(parts) == 3 and parts[0] == "Payload" and parts[1].endswith(".app") \
                and parts[2] == parts[1][:-4]:
            return name
    raise SystemExit("binaire principal introuvable dans Payload/*.app/")


def patch_macho(data, dylib_install_name, weak_system=False, replace_weak=None,
                weak_module=False, first=False):
    magic = struct.unpack_from("<I", data, 0)[0]
    if magic != 0xFEEDFACF:
        raise SystemExit(f"magic inattendu 0x{magic:x} (thin arm64 attendu)")

    ncmds, sizeofcmds = struct.unpack_from("<II", data, 16)
    p = 32
    cmds_end = 32 + sizeofcmds
    first_section = None
    replaced = False
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, p)
        if cmd == LC_LOAD_DYLIB and weak_system:
            name_off = struct.unpack_from("<I", data, p + 8)[0]
            lib = data[p + name_off:p + cmdsize].split(b"\0")[0].decode()
            if lib.startswith("/System/") or lib.startswith("/usr/lib/"):
                struct.pack_into("<I", data, p, LC_LOAD_WEAK_DYLIB)
                print(f"  weak: {lib}")
        if cmd == LC_LOAD_DYLIB and replace_weak and not replaced:
            name_off = struct.unpack_from("<I", data, p + 8)[0]
            lib = data[p + name_off:p + cmdsize].split(b"\0")[0].decode()
            if replace_weak in lib:
                name = dylib_install_name.encode() + b"\0"
                if 24 + len(name) > cmdsize:
                    raise SystemExit(
                        f"chemin trop long pour remplacer {lib} "
                        f"({24 + len(name)} > {cmdsize})")
                blob = struct.pack("<IIIIII", LC_LOAD_DYLIB, cmdsize, 24, 0, 0x10000, 0x10000) + name
                blob += b"\0" * (cmdsize - len(blob))
                data[p:p + cmdsize] = blob
                print(f"  remplacé: {lib} -> {dylib_install_name} "
                      f"(cmdsize {cmdsize} conservé)")
                replaced = True
        if cmd == 0x19:  # LC_SEGMENT_64
            segname = data[p + 8:p + 24].split(b"\0")[0].decode()
            fileoff = struct.unpack_from("<Q", data, p + 40)[0]
            if segname == "__TEXT" and fileoff == 0:
                nsects = struct.unpack_from("<I", data, p + 64)[0]
                for i in range(nsects):
                    so = p + 72 + i * 80
                    s_off = struct.unpack_from("<I", data, so + 48)[0]
                    if s_off and (first_section is None or s_off < first_section):
                        first_section = s_off
        p += cmdsize

    if replace_weak:
        if not replaced:
            raise SystemExit(f"aucun LC_LOAD_DYLIB contenant {replace_weak!r}")
        print(f"  ncmds={ncmds} sizeofcmds={sizeofcmds} (inchangés)")
        return data

    name = dylib_install_name.encode() + b"\0"
    cmdsize = (24 + len(name) + 7) & ~7
    slack = first_section - cmds_end
    print(f"  ncmds={ncmds} sizeofcmds={sizeofcmds} fin=0x{cmds_end:x} "
          f"1re section=0x{first_section:x} slack={slack} octets")
    if slack < cmdsize:
        raise SystemExit(f"pas assez de place dans le header ({slack} < {cmdsize})")
    if data[cmds_end:cmds_end + slack].strip(b"\0"):
        raise SystemExit("le padding du header n'est pas vide - abandon")

    lc = LC_LOAD_WEAK_DYLIB if weak_module else LC_LOAD_DYLIB
    cmd = struct.pack("<IIIIII", lc, cmdsize, 24, 0, 0x10000, 0x10000)
    blob = cmd + name
    blob += b"\0" * (cmdsize - len(blob))
    if first:
        # place notre dylib en tête de liste : dyld le charge avant les
        # autres images, donc l'interposition (stealth.c) s'applique à
        # tous les bindings, y compris ceux de l'anti-cheat.
        block = bytes(data[32:cmds_end])
        data[32 + cmdsize:32 + cmdsize + len(block)] = block
        pos = 32
    else:
        pos = cmds_end
    data[pos:pos + cmdsize] = blob

    struct.pack_into("<II", data, 16, ncmds + 1, sizeofcmds + cmdsize)
    kind = "LC_LOAD_WEAK_DYLIB" if weak_module else "LC_LOAD_DYLIB"
    print(f"  {kind} ajouté: {dylib_install_name} (cmdsize {cmdsize}"
          f"{', en tête' if first else ''})")
    return data


def main():
    if len(sys.argv) < 4:
        raise SystemExit(__doc__)
    src, dylib_path, dst = sys.argv[1], sys.argv[2], sys.argv[3]
    weak_system = "--weak" in sys.argv[4:]
    weak_module = "--weak-mod" in sys.argv[4:]
    first = "--first" in sys.argv[4:]
    replace_weak = None
    if "--replace-weak" in sys.argv[4:]:
        i = sys.argv[4:].index("--replace-weak")
        if i + 1 >= len(sys.argv[4:]):
            raise SystemExit("--replace-weak attend un nom de framework")
        replace_weak = sys.argv[4:][i + 1]

    with zipfile.ZipFile(src) as z:
        names = z.namelist()
    bin_name = find_binary(names)
    app_dir = bin_name.rsplit("/", 1)[0]
    print(f"source : {src}")
    print(f"binaire: {bin_name}")
    print(f"sortie : {dst}")

    dylib_name = os.path.basename(dylib_path)
    if not dylib_name.endswith(".dylib"):
        raise SystemExit(f"le dylib doit finir par .dylib: {dylib_name}")
    install_name = f"@rpath/{dylib_name}"

    with open(dylib_path, "rb") as d:
        dylib_bytes = bytearray(d.read())

    if "--fix-id" in sys.argv[4:]:
        if patch_dylib_id(dylib_bytes, install_name):
            print(f"  LC_ID_DYLIB -> {install_name} (signature à refaire)")
        else:
            print("  LC_ID_DYLIB inchangé (pas de place)")
    elif b"MobileSubstrate" in dylib_bytes:
        print("  attention: LC_ID_DYLIB contient encore MobileSubstrate")
    else:
        print(f"  LC_ID_DYLIB propre")

    with zipfile.ZipFile(src) as zin, zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED,
                                                      compresslevel=1) as zout:
        for item in zin.infolist():
            payload = zin.read(item.filename)
            if item.filename == bin_name:
                payload = patch_macho(bytearray(payload), install_name, weak_system,
                                      replace_weak, weak_module, first)
                payload = bytes(payload)
            # On réécrit l'entrée en CONSERVANT ses métadonnées d'origine :
            # un writestr(nom, data) nu repart en mode 0600, ce qui rend le
            # binaire principal non exécutable -> iOS refuse de lancer l'app
            # ("crash avant lancement").
            zout.writestr(clone_info(item), payload)

        target = f"{app_dir}/Frameworks/{dylib_name}"
        zi = zipfile.ZipInfo(target, date_time=time.localtime()[:6])
        zi.compress_type = zipfile.ZIP_DEFLATED
        zi.create_system = 3
        zi.external_attr = 0o100755 << 16          # exécutable
        zout.writestr(zi, dylib_bytes)
        print(f"  ajouté: {target} ({len(dylib_bytes)} octets, mode 0755)")

    print(f"ok: {dst} ({os.path.getsize(dst)} octets)")


if __name__ == "__main__":
    main()
