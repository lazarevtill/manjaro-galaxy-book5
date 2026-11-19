#!/bin/bash
# Hibernation, and the two things S4 breaks on this machine.
#
# Out of the box hibernation here is enabled and cannot complete: the kernel
# sizes the image up to image_size (~2/5 of RAM) and the stock swap partition is
# 8.8 GiB. On a 31 GiB machine that is never enough under real load, and an
# aborted hibernate is not harmless -- it resets the USB bus and wedges the
# Samsung SCAI/EC interface, silently killing fingerprint auth and the keyboard
# backlight. See docs/system/hibernation.md.
#
# This creates a 20 GiB swapfile on its own btrfs subvolume, points resume at it,
# and installs a sleep hook that repairs what a *successful* S4 still breaks.
#
# Idempotent. Requires the root filesystem to be btrfs.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SIZE_GB="${GB5_SWAPFILE_GB:-20}"

[ "$(id -u)" -eq 0 ] || { echo "run as root"; exit 1; }

# The warning belongs HERE, not only in the documentation. This is the script
# that creates the plaintext image, and running it directly is the only way it
# ever runs.
if [ -z "${GB5_HIBERNATE_ACK:-}" ]; then
    cat <<'WARN'

  ────────────────────────────────────────────────────────────────────────
  HIBERNATION WRITES YOUR RAM TO DISK IN THE CLEAR

  This machine has no full-disk encryption. Every hibernate writes up to
  ~2/5 of RAM to /swap/swapfile unencrypted, where it stays until
  overwritten: browser sessions, SSH agent keys, decrypted password
  manager state, the fingerprint host private key.

  Anyone who can read the disk can read all of it. Secure Boot does not
  help -- it verifies what boots, not what is stored.

  If this machine dual-boots Windows with BitLocker, the Linux side
  becomes the weaker half.

  Encrypt the disk first if that matters. See docs/system/hibernation.md.
  ────────────────────────────────────────────────────────────────────────

WARN
    printf "  Type ENABLE to continue: "
    read -r ack
    [ "$ack" = "ENABLE" ] || { echo "  aborted — nothing changed"; exit 1; }
    echo
fi

ROOTDEV=$(findmnt -no SOURCE / | sed 's/\[.*//')
ROOTUUID=$(findmnt -no UUID /)
[ "$(findmnt -no FSTYPE /)" = "btrfs" ] || { echo "root is not btrfs; not supported here"; exit 1; }

echo "==> Swapfile subvolume"
# A sibling of @, not a child: anything inside @ is captured by Timeshift's
# snapshots, and a 20 GiB file in every snapshot is not what anyone wants.
mkdir -p /mnt/btrfs-top
mountpoint -q /mnt/btrfs-top || mount -o subvolid=5 "$ROOTDEV" /mnt/btrfs-top
[ "$(btrfs subvolume list /mnt/btrfs-top | grep -c ' @swap$')" -gt 0 ] \
    || btrfs subvolume create /mnt/btrfs-top/@swap
mkdir -p /swap
mountpoint -q /swap || mount -o subvol=@swap,noatime "$ROOTDEV" /swap
echo "    ok"

echo "==> ${SIZE_GB} GiB swapfile"
if [ ! -f /swap/swapfile ]; then
    # mkswapfile sets nocow and nodatasum, which btrfs requires. The root here is
    # mounted compress=zstd:1 and btrfs refuses to swapon a compressed, COW or
    # multi-device file -- so a successful swapon below is itself the proof this
    # is configured correctly.
    btrfs filesystem mkswapfile --size "${SIZE_GB}g" /swap/swapfile
fi
[ "$(swapon --show=NAME --noheadings | grep -cx /swap/swapfile)" -gt 0 ] || swapon /swap/swapfile
echo "    ok"

echo "==> fstab"
if ! grep -q '^[^#]*/swap ' /etc/fstab; then
    cp /etc/fstab "/etc/fstab.bak-$(date +%Y%m%d-%H%M%S)"
    cat >> /etc/fstab <<FSTAB

# Swapfile on its own btrfs subvolume, for hibernation. @swap is a sibling of @
# so Timeshift never snapshots it.
UUID=$ROOTUUID  /swap  btrfs  subvol=@swap,noatime  0 0
/swap/swapfile  none  swap  defaults  0 0
FSTAB
fi
echo "    ok"

echo "==> resume target"
OFFSET=$(btrfs inspect-internal map-swapfile -r /swap/swapfile)
# Runtime first: these are writable, so hibernation works this boot without
# touching the bootloader at all. Only persistence needs the kernel cmdline.
echo "$OFFSET" > /sys/power/resume_offset        # offset BEFORE device
echo "$(stat -c '%t:%T' "$ROOTDEV" | awk -F: '{printf "%d:%d", strtonum("0x"$1), strtonum("0x"$2)}')" > /sys/power/resume
echo "    runtime: resume_offset=$OFFSET"

# Rewrite the resume settings unconditionally rather than guarding on whether
# resume_offset is already present. Three ways the guarded version failed:
#
#   * /etc/kernel/cmdline absent (a GRUB install that never ran step 50): the
#     whole block was skipped and the script still printed ok, so hibernation
#     worked for one boot and then silently wrote 12.5 GB of plaintext RAM that
#     nothing would ever resume.
#   * resume= present but not as UUID= (PARTUUID=, LABEL=, /dev/...): the sed
#     no-opped, the fallback grep matched anyway, and the cmdline kept pointing
#     at the old undersized partition -- producing exactly the aborted S4 this
#     script exists to prevent.
#   * re-running after resizing the swapfile left the OLD offset in place.
WANT="resume=UUID=$ROOTUUID resume_offset=$OFFSET"
if [ ! -f /etc/kernel/cmdline ]; then
    echo
    echo "  !! /etc/kernel/cmdline does not exist, so this machine does not boot a UKI." >&2
    echo "     Hibernation works for THIS boot only. Add the following to your" >&2
    echo "     bootloader's kernel command line by hand, then re-run:" >&2
    echo "         $WANT" >&2
    echo "     Until then, do NOT hibernate: the image cannot be resumed and it is" >&2
    echo "     an unencrypted copy of your RAM sitting on disk." >&2
    exit 1
fi
if ! grep -qF "$WANT" /etc/kernel/cmdline; then
    cp /etc/kernel/cmdline "/etc/kernel/cmdline.bak-$(date +%Y%m%d-%H%M%S)"
    # Strip any existing resume settings on the first line only, then append ours.
    sed -i -E '1s/ ?resume(_offset)?=[^ ]*//g; 1s|[[:space:]]*$| '"$WANT"'|' /etc/kernel/cmdline
    grep -qF "$WANT" /etc/kernel/cmdline || { echo "  !! cmdline rewrite failed" >&2; exit 1; }
    echo "    cmdline updated"
    echo
    echo "    NOW REBUILD AND RE-SIGN, in this order:"
    echo "        mkinitcpio -P && sbctl sign-all && sbctl verify"
    echo
    echo "    mkinitcpio alone does NOT sign. Signing is a pacman hook, so it does"
    echo "    not fire for a manual run, and under Secure Boot an unsigned UKI will"
    echo "    not boot."
    echo "    Keep a signed fallback first, carrying the SAME resume settings:"
    echo "        cp <uki> <uki>-fallback.efi && sbctl sign <uki>-fallback.efi"
    echo "    A fallback with a DIFFERENT resume target is dangerous — booting it"
    echo "    after a hibernate strands the image, and the next normal boot restores"
    echo "    it over a filesystem that has moved on."
else
    echo "    cmdline already correct"
fi
echo "    ok"

echo "==> Resume fix-ups (S4 wedges part of the SCAI interface)"
install -Dm755 "$HERE/../config/system/gb5-resume-fixups" /etc/systemd/system-sleep/gb5-resume-fixups
echo "    ok"

echo "==> Lock on resume"
# The machine was observed resuming from hibernate straight into an unlocked
# desktop. The sleep hook locks before suspending as well, because a pre-sleep
# lock cannot lose the race a post-resume one can.
u=$(logname 2>/dev/null || echo "${SUDO_USER:-}")
if [ -n "$u" ]; then
    sudo -u "$u" kwriteconfig6 --file kscreenlockerrc --group Daemon --key LockOnResume true 2>/dev/null || true
    sudo -u "$u" kwriteconfig6 --file kscreenlockerrc --group Daemon --key Autolock     true 2>/dev/null || true
fi
echo "    ok"

echo
echo "Hibernation configured. It works this boot already; the cmdline change only"
echo "matters across reboots. Test with: systemctl hibernate"
echo "Expect ONE failed fingerprint touch after each resume — the driver learns the"
echo "SDCP session is stale by failing, then reconnects. See docs/system/hibernation.md."
