#!/bin/bash
# Would enrolling the current UEFI revocation list stop anything here booting?
#
# dbx is empty on this machine, so Secure Boot enforces ZERO revocations: a
# Microsoft-signed but known-vulnerable bootloader would still validate, and
# Microsoft's certificate is in our db because Windows needs it. Enrolling dbx
# closes that, but it is close to irreversible — undoing it means restoring
# firmware default keys, which also wipes the custom PK/KEK/db.
#
# So check first. Every binary that must keep booting is hashed the way UEFI
# hashes it (Authenticode, not plain sha256sum) and compared against the list.

set -uo pipefail
URL=${DBX_URL:-https://github.com/microsoft/secureboot_objects/raw/main/PostSignedObjects/DBX/amd64/DBXUpdate.bin}
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

echo "Fetching the current revocation list..."
curl -sL -o "$TMP/dbx.bin" "$URL" || { echo "download failed" >&2; exit 2; }
echo "  $(stat -c%s "$TMP/dbx.bin") bytes"

python3 - "$TMP/dbx.bin" "$TMP/hashes.txt" <<'PY'
import struct, sys
d = open(sys.argv[1], 'rb').read()
off = 16 + struct.unpack_from('<I', d, 16)[0]   # skip EFI_VARIABLE_AUTHENTICATION_2
SHA256 = bytes.fromhex('2616c4c14c509240aca941f936934328')
X509   = bytes.fromhex('a159c0a5e494a74a87b5ab155c2bf072')
out, certs, p = [], 0, off
while p + 28 <= len(d):
    g = d[p:p+16]
    sls, shs, ss = struct.unpack_from('<III', d, p+16)
    if sls == 0 or p + sls > len(d):
        break
    if g == SHA256:
        q, end = p+28+shs, p+sls
        while q + ss <= end:
            out.append(d[q+16:q+48].hex()); q += ss
    elif g == X509:
        certs += (sls-28-shs)//ss if ss else 0
    p += sls
open(sys.argv[2], 'w').write('\n'.join(out))
print(f"  {len(out)} revoked image hashes, {certs} revoked certificates")
if certs:
    print("  NOTE: certificate revocations present — a hash check alone is NOT")
    print("        sufficient. A binary can be revoked by its signer instead.")
PY

cp "$TMP/hashes.txt" /tmp/dbx_hashes.txt
ESP=${ESP:-/boot/efi}
mapfile -t BINS < <(find "$ESP" -maxdepth 4 -type f \
    \( -iname 'bootmgfw.efi' -o -iname 'systemd-boot*.efi' -o -iname 'bootx64.efi' \
       -o -iname 'grubx64.efi' -o -path "$ESP/EFI/Linux/*.efi" \) 2>/dev/null | sort -u)
echo
echo "Checking ${#BINS[@]} bootable images:"
python3 /usr/local/sbin/gb5-dbx-safety-check.py "${BINS[@]}"
rc=$?
echo
case $rc in
  0) echo "SAFE — nothing that boots here is on the revocation list." ;;
  1) echo "DO NOT ENROL — a binary above is revoked and would stop booting." >&2 ;;
  *) echo "INCONCLUSIVE — a binary could not be hashed." >&2 ;;
esac
exit $rc
