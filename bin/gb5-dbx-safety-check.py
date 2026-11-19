#!/usr/bin/env python3
"""Authenticode SHA-256 of a PE/COFF image — the hash UEFI dbx matches against.

Per the Authenticode spec the signature itself cannot be part of what is signed,
so three regions are excluded: the OptionalHeader CheckSum field, the Certificate
Table data-directory entry, and the attribute certificate table those point at.
Everything else is hashed in section order, then the trailing bytes after the
last section.
"""
import hashlib
import struct
import sys


def authenticode_sha256(path):
    d = open(path, 'rb').read()
    if d[:2] != b'MZ':
        raise ValueError('not a PE image')
    pe = struct.unpack_from('<I', d, 0x3c)[0]
    if d[pe:pe + 4] != b'PE\0\0':
        raise ValueError('bad PE signature')

    coff = pe + 4
    n_sections = struct.unpack_from('<H', d, coff + 2)[0]
    opt_size = struct.unpack_from('<H', d, coff + 16)[0]
    opt = coff + 20
    magic = struct.unpack_from('<H', d, opt)[0]
    pe32plus = magic == 0x20b

    checksum_off = opt + 64
    # NumberOfRvaAndSizes sits at a different offset in PE32 vs PE32+
    ddir_off = opt + (112 if pe32plus else 96)
    n_rva = struct.unpack_from('<I', d, ddir_off)[0]
    ddir = ddir_off + 4
    # Data directory entry 4 is the Certificate Table
    cert_entry = ddir + 4 * 8
    cert_rva, cert_size = (struct.unpack_from('<II', d, cert_entry)
                           if n_rva > 4 else (0, 0))

    h = hashlib.sha256()
    # 1. start of file up to the CheckSum field
    h.update(d[:checksum_off])
    # 2. skip CheckSum (4 bytes), continue to the Certificate Table entry
    h.update(d[checksum_off + 4:cert_entry])
    # 3. skip the Certificate Table entry (8 bytes)
    headers_end = opt + opt_size
    h.update(d[cert_entry + 8:headers_end])

    # 4. sections, in ascending file-offset order
    sect = headers_end
    regions = []
    for i in range(n_sections):
        s = sect + i * 40
        raw_size, raw_ptr = struct.unpack_from('<II', d, s + 16)
        if raw_size:
            regions.append((raw_ptr, raw_size))
    regions.sort()
    end = headers_end
    for ptr, size in regions:
        h.update(d[ptr:ptr + size])
        end = max(end, ptr + size)

    # 5. anything after the last section, minus the certificate table itself
    tail_end = len(d) - cert_size if cert_size else len(d)
    if tail_end > end:
        h.update(d[end:tail_end])

    return h.hexdigest()


if __name__ == '__main__':
    revoked = set()
    try:
        revoked = set(open('/tmp/dbx_hashes.txt').read().split())
    except OSError:
        pass
    worst = 0
    for p in sys.argv[1:]:
        try:
            digest = authenticode_sha256(p)
        except Exception as e:
            print(f"  {p}: ERROR {e}")
            worst = 2
            continue
        hit = digest in revoked
        if hit:
            worst = 1
        print(f"  {'REVOKED ' if hit else 'ok      '} {digest}  {p}")
    sys.exit(worst)
