#!/bin/bash
# Secure Boot with custom keys, a signed UKI, and systemd-boot. READ THIS FIRST.
#
# This is the only step here that can leave the machine unbootable, and parts of
# it CANNOT be done from Linux. It is written as a guided checklist rather than
# an automated run, because the failure mode is a laptop that will not start and
# the recovery involves the firmware menu.
#
# What was learned doing this the first time, which is most of why it is worth
# following an order:
#
#   * GRUB 2.14 CANNOT boot Linux under Secure Boot here. It embeds the
#     shim_lock verifier and no shim is installed, so the kernel is refused as
#     "prohibited by secure boot policy". --disable-shim-lock does NOT fix it.
#     Both obvious ways to check the flag are also invalid: `strings | grep
#     shim_lock` (those strings are always present) and reading sb.c from
#     rhboot/grub2 (that is Red Hat's fork, not what Manjaro ships).
#     A signed Unified Kernel Image sidesteps the whole problem.
#
#   * Enabling Secure Boot BEFORE enrolling keys fails everything Linux.
#     Enrolment needs Setup Mode, which means CLEARING keys in the BIOS — not
#     adding any there.
#
#   * Signed GRUB entries left in BootOrder load fine and then die at rescue.
#     There is no graceful fallthrough. Take them out of the order.
#
#   * \EFI\BOOT\BOOTX64.EFI is the NVRAM-reset fallback. If it holds GRUB, that
#     path is broken too.
#
# Nothing below is destructive without you typing the confirmation.

set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
HERE=$(cd "$(dirname "$0")/.." && pwd)

sb_state() { bootctl status 2>/dev/null | grep -m1 'Secure Boot:' | sed 's/^ *//'; }

echo "Current state"
echo "  $(sb_state)"
echo "  Setup Mode: $(sbctl status 2>/dev/null | grep -m1 'Setup Mode' | sed 's/.*Setup Mode:\s*//' || echo 'sbctl not installed')"
echo

cat <<'EOF'
Order of operations. Do not skip ahead.

  1. IN WINDOWS, if you dual boot: suspend BitLocker before touching Secure
     Boot. Changing it counts as a firmware change and will otherwise demand
     your recovery key at the next Windows boot.

  2. IN THE BIOS: clear the Secure Boot keys to enter Setup Mode. On this
     Samsung firmware that is the option that "deletes" or "clears" keys — you
     are not adding anything here. Leave Secure Boot itself DISABLED for now.

  3. Back in Linux, run this script with --enroll. It will create keys, sign
     everything, build a UKI, install systemd-boot and fix the boot order.

  4. IN THE BIOS: enable Secure Boot.

  5. Back in Linux, run this script again with no arguments to verify.

Steps 1, 2 and 4 cannot be done from Linux. Anything claiming otherwise on this
hardware is wrong.
EOF

[ "${1:-}" = "--enroll" ] || { echo; echo "Re-run with --enroll when you have completed steps 1 and 2."; exit 0; }

echo
echo "This will create Secure Boot keys and change the boot configuration."
printf 'Type ENROLL to continue: '
read -r reply
[ "$reply" = "ENROLL" ] || { echo "Aborted."; exit 1; }

pacman -S --needed --noconfirm sbctl systemd-ukify binutils >/dev/null

echo "==> Keys"
# grep -c, not grep -q: under `set -o pipefail` a matching grep -q exits early,
# SIGPIPEs sbctl, and the pipeline reports failure BECAUSE it matched -- which
# would abort here precisely when Setup Mode IS enabled.
[ "$(sbctl status | grep -c 'Setup Mode:.*Enabled')" -gt 0 ] || {
    echo "Setup Mode is not enabled — go back to step 2." >&2; exit 1; }
sbctl create-keys
# Keep Microsoft's certificates: without them the firmware's own Windows entry
# and any option ROM signed by Microsoft stop validating.
sbctl enroll-keys --microsoft
echo "    enrolled, Microsoft certificates preserved"

echo "==> Unified Kernel Image"
install -Dm755 "$HERE/bin/gb5-ensure-uki.sh" /usr/local/sbin/gb5-ensure-uki.sh
install -Dm644 "$HERE/config/system/95-gb5-ensure-uki.hook" /etc/pacman.d/hooks/95-gb5-ensure-uki.hook
/usr/local/sbin/gb5-ensure-uki.sh
# Phase 8 (2026-11-19): keep the boot chain right after EVERY transaction --
# removable fallback = signed systemd-boot, fallback UKI with a live kernel,
# sbctl db matching the ESP -- and disable Manjaro's install-grub hook, which
# since 2.16 copies a shim_lock GRUB over the removable fallback.
pacman -S --needed --noconfirm sbsigntools jq binutils
install -Dm755 "$HERE/bin/gb5-boot-guard.sh" /usr/local/sbin/gb5-boot-guard.sh
install -Dm644 "$HERE/config/system/zzz-gb5-boot-guard.hook" /etc/pacman.d/hooks/zzz-gb5-boot-guard.hook
ln -sfn /dev/null /etc/pacman.d/hooks/98-install-grub.hook
/usr/local/sbin/gb5-boot-guard.sh
echo "==> systemd-boot"
bootctl install
install -Dm644 "$HERE/config/boot/loader.conf" /boot/efi/loader/loader.conf
echo "==> Sign everything"
sbctl sign-all
sbctl verify | grep -c 'is signed' | xargs -I{} echo "    {} signed files"

cat <<'EOF'

Now:
  * Take GRUB out of BootOrder if it is still there (efibootmgr -o ...), or a
    hands-off boot will land in grub rescue.
  * If you keep GRUB installed, make sure its pacman hook passes --no-nvram, or
    every GRUB update puts it back at the head of the boot order silently.
  * Back up the keys. Losing /var/lib/sbctl means you cannot re-sign after an
    update, and an unsigned kernel will not boot.

      tar czf ~/sbctl-keys-backup-$(date +%F).tar.gz /var/lib/sbctl

  * Then go and enable Secure Boot in the BIOS (step 4).

Also worth knowing: `bootctl list` is one boot STALE. It reads the LoaderEntries
EFI variable systemd-boot wrote last boot, not the current loader.conf, so edits
appear to do nothing. That is not a failure.
EOF
