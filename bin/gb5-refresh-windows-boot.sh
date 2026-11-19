#!/bin/bash
# Refresh the mirrored Windows boot files on the Linux ESP.
#
# Windows lives on a separate disk with its own ESP, and systemd-boot only
# auto-discovers entries on the partition it booted from. To get a "Windows Boot
# Manager" entry in the menu, \EFI\Microsoft is mirrored onto the Linux ESP.
#
# That mirror is a COPY, so it goes stale: a Windows update that rewrites
# bootmgfw.efi or the BCD store will not be reflected here. Symptom is the
# Windows entry in systemd-boot failing (commonly 0xc000000f) while Windows
# still boots fine from the firmware menu. Re-run this script after any Windows
# feature update, or whenever that entry misbehaves.
#
# The firmware's own Windows entry is never touched, so it always remains as a
# working fallback.

set -euo pipefail

LINUX_ESP=${LINUX_ESP:-/boot/efi}
MNT=$(mktemp -d)

# Find the Windows ESP rather than naming a device.
#
# This machine has two NVMe drives and the kernel does NOT enumerate them in a
# stable order — nvme0n1 has been the Linux disk on one boot and the Windows
# disk on the next. A hardcoded /dev/nvmeXn1p1 is therefore a coin flip, and the
# wrong half of that flip points at our own ESP. Probe every EFI System
# Partition except the one we booted from and take the one holding bootmgfw.efi.
find_windows_esp() {
    local linux_dev probe
    linux_dev=$(findmnt -n -o SOURCE "$LINUX_ESP")
    while read -r probe; do
        [ "$probe" = "$linux_dev" ] && continue
        if mount -o ro "$probe" "$MNT" 2>/dev/null; then
            if [ -f "$MNT/EFI/Microsoft/Boot/bootmgfw.efi" ]; then
                umount "$MNT"; printf '%s' "$probe"; return 0
            fi
            umount "$MNT"
        fi
    done < <(lsblk -rno PATH,FSTYPE,PARTTYPENAME |
             awk '$2=="vfat"{print $1}')
    return 1
}

cleanup() { mountpoint -q "$MNT" && umount "$MNT"; rmdir "$MNT" 2>/dev/null || true; }
trap cleanup EXIT

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
mountpoint -q "$LINUX_ESP" || { echo "$LINUX_ESP is not mounted" >&2; exit 1; }

WIN_ESP_DEV=${WIN_ESP_DEV:-$(find_windows_esp)}
[ -n "$WIN_ESP_DEV" ] || { echo "could not find a Windows ESP on any disk" >&2; exit 1; }
echo "Windows ESP: $WIN_ESP_DEV"

mount -o ro "$WIN_ESP_DEV" "$MNT"
[ -f "$MNT/EFI/Microsoft/Boot/bootmgfw.efi" ] || {
    echo "no bootmgfw.efi on $WIN_ESP_DEV — is that the Windows ESP?" >&2; exit 1; }

src_sum=$(sha256sum "$MNT/EFI/Microsoft/Boot/bootmgfw.efi" | cut -d' ' -f1)
dst_sum=$(sha256sum "$LINUX_ESP/EFI/Microsoft/Boot/bootmgfw.efi" 2>/dev/null | cut -d' ' -f1 || echo none)

if [ "$src_sum" = "$dst_sum" ]; then
    echo "already current (bootmgfw.efi ${src_sum:0:12})"
    exit 0
fi

echo "Windows boot files changed — refreshing the mirror"
echo "  on Windows ESP : ${src_sum:0:12}"
echo "  mirrored copy  : ${dst_sum:0:12}"

# Need room for the new copy before dropping the old one.
need=$(du -sk "$MNT/EFI/Microsoft" | cut -f1)
free=$(df -k --output=avail "$LINUX_ESP" | tail -1)
[ "$free" -gt "$need" ] || { echo "not enough space on $LINUX_ESP (${free}K free, ${need}K needed)" >&2; exit 1; }

rm -rf "$LINUX_ESP/EFI/Microsoft.old"
[ -d "$LINUX_ESP/EFI/Microsoft" ] && mv "$LINUX_ESP/EFI/Microsoft" "$LINUX_ESP/EFI/Microsoft.old"
if cp -a "$MNT/EFI/Microsoft" "$LINUX_ESP/EFI/"; then
    rm -rf "$LINUX_ESP/EFI/Microsoft.old"
    sync
    echo "refreshed. bootmgfw.efi is Microsoft-signed, and those certificates are in db,"
    echo "so it validates under Secure Boot without any signing on our part."
else
    echo "copy failed — restoring the previous mirror" >&2
    rm -rf "$LINUX_ESP/EFI/Microsoft"
    mv "$LINUX_ESP/EFI/Microsoft.old" "$LINUX_ESP/EFI/Microsoft"
    exit 1
fi
