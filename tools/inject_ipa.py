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
import zipfile

LC_LOAD_DYLIB = 0xC
MAXCMDSZ = 0x10000
INSTALL_NAME = "@rpath/FF2018Menu.dylib"


def find_binary(entries):
    for name in entries:
        parts = name.split("/")
        if len(parts) == 3 and parts[0] == "Payload" and parts[1].endswith(".app") \
                and parts[2] == parts[1][:-4]:
            return name
    raise SystemExit("binaire principal introuvable dans Payload/*.app/")


def patch_macho(data, dylib_install_name):
    magic = struct.unpack_from("<I", data, 0)[0]
    if magic != 0xFEEDFACF:
        raise SystemExit(f"magic inattendu 0x{magic:x} (thin arm64 attendu)")

    ncmds, sizeofcmds = struct.unpack_from("<II", data, 16)
    p = 32
    cmds_end = 32 + sizeofcmds
    first_section = None
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, p)
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

    name = dylib_install_name.encode() + b"\0"
    cmdsize = (24 + len(name) + 7) & ~7
    slack = first_section - cmds_end
    print(f"  ncmds={ncmds} sizeofcmds={sizeofcmds} fin=0x{cmds_end:x} "
          f"1re section=0x{first_section:x} slack={slack} octets")
    if slack < cmdsize:
        raise SystemExit(f"pas assez de place dans le header ({slack} < {cmdsize})")
    if data[cmds_end:cmds_end + slack].strip(b"\0"):
        raise SystemExit("le padding du header n'est pas vide - abandon")

    cmd = struct.pack("<IIIIII", LC_LOAD_DYLIB, cmdsize, 24, 0, 0x10000, 0x10000)
    blob = cmd + name
    blob += b"\0" * (cmdsize - len(blob))
    data[cmds_end:cmds_end + cmdsize] = blob

    struct.pack_into("<II", data, 16, ncmds + 1, sizeofcmds + cmdsize)
    print(f"  LC_LOAD_DYLIB ajouté: {dylib_install_name} (cmdsize {cmdsize})")
    return data


def main():
    if len(sys.argv) < 4:
        raise SystemExit(__doc__)
    src, dylib_path, dst = sys.argv[1], sys.argv[2], sys.argv[3]

    with zipfile.ZipFile(src) as z:
        names = z.namelist()
    bin_name = find_binary(names)
    app_dir = bin_name.rsplit("/", 1)[0]
    print(f"source : {src}")
    print(f"binaire: {bin_name}")
    print(f"sortie : {dst}")

    with open(dylib_path, "rb") as d:
        dylib_bytes = d.read()

    with zipfile.ZipFile(src) as zin, zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED,
                                                      compresslevel=1) as zout:
        for item in zin.infolist():
            payload = zin.read(item.filename)
            if item.filename == bin_name:
                payload = patch_macho(bytearray(payload), INSTALL_NAME)
                payload = bytes(payload)
            zout.writestr(item.filename, payload)

        target = f"{app_dir}/Frameworks/FF2018Menu.dylib"
        zout.writestr(target, dylib_bytes)
        print(f"  ajouté: {target} ({len(dylib_bytes)} octets)")

    print(f"ok: {dst} ({os.path.getsize(dst)} octets)")


if __name__ == "__main__":
    main()
