#!/bin/bash
# Every kernel package generates its preset from /usr/share/mkinitcpio/hook.preset,
# where default_uki= is commented out. Without this, installing a new kernel series
# produces no UKI, and with Secure Boot on the machine has nothing bootable.
# Runs after mkinitcpio's own hook and re-generates any preset that lacks a UKI.
ESP_UKI_DIR=/boot/efi/EFI/Linux
mkdir -p "$ESP_UKI_DIR"
changed=0
# A removed kernel package leaves its preset behind when it was edited (ours
# always are: default_uki is uncommented). linux71.preset outlived linux71 by a
# week and made every `mkinitcpio -P` exit non-zero -- which the rollback recipe
# chained with && in front of `sbctl sign-all`. Move such presets aside.
mkdir -p /etc/mkinitcpio.d/orphaned
for preset in /etc/mkinitcpio.d/*.preset; do
    [ -e "$preset" ] || continue
    k=$(sed -n 's/^ALL_kver="\{0,1\}\([^"]*\)"\{0,1\}/\1/p' "$preset" | head -1)
    if [ -n "$k" ] && [ ! -e "$k" ]; then
        mv -f "$preset" /etc/mkinitcpio.d/orphaned/ && echo "gb5-ensure-uki: moved orphaned $(basename "$preset") aside (its kernel $k is gone)"
    fi
done
for preset in /etc/mkinitcpio.d/*.preset; do
    [ -e "$preset" ] || continue
    name=$(basename "$preset" .preset)
    # already has an active (uncommented) default_uki?
    grep -qE '^\s*default_uki=' "$preset" && continue
    kver=$(sed -n 's/^ALL_kver="\{0,1\}\([^"]*\)"\{0,1\}/\1/p' "$preset" | head -1)
    tag=$(basename "${kver:-$name}" | sed 's/^vmlinuz-//')
    uki="$ESP_UKI_DIR/manjaro-${tag}.efi"
    if grep -qE '^#\s*default_uki=' "$preset"; then
        sed -i "s|^#\s*default_uki=.*|default_uki=\"$uki\"|" "$preset"
    else
        printf '\ndefault_uki="%s"\n' "$uki" >> "$preset"
    fi
    echo "gb5-ensure-uki: added UKI to $name -> $uki"
    mkinitcpio -p "$name" >/dev/null 2>&1 && echo "gb5-ensure-uki: built $uki" || echo "gb5-ensure-uki: BUILD FAILED for $name" >&2
    changed=1
done
# Since 2026-08-20 the firmware boots systemd-boot (Boot "Linux Boot Manager"),
# which discovers every UKI itself, so a per-UKI NVRAM entry is not required.
# The old warning fired for all three UKIs on every run (Nov 11) and trained
# readers to skip it. Warn only if the boot MENU itself has no firmware entry.
[ "$(efibootmgr 2>/dev/null | grep -ci 'systemd-bootx64.efi')" -gt 0 ] \
    || echo "gb5-ensure-uki: WARNING no firmware boot entry points at systemd-boot — check efibootmgr" >&2

# Keep systemd-boot's default pointed at the newest Manjaro UKI.
#
# The LoaderEntryDefault EFI variable outranks loader.conf's `default` pattern,
# and it holds a literal entry ID, so a kernel series bump (manjaro-7.1 ->
# manjaro-7.2) leaves it naming an entry that no longer exists. loader.conf's
# glob still catches that, but only as a fallback — better to keep both correct.
# Pick by kernel VERSION, not mtime. With a second kernel installed (the LTS
# fallback added 2026-09-11) the most recently BUILT UKI is usually the OLDER
# kernel, so mtime silently made the fallback the default. Fallback UKIs are
# excluded outright: they exist to be picked from the menu, never to be default.
newest_uki=$(ls -1 "$ESP_UKI_DIR"/manjaro-*.efi 2>/dev/null \
             | grep -v -- '-fallback\.efi$' | sort -V | tail -1)
if [ -n "$newest_uki" ] && command -v bootctl >/dev/null 2>&1; then
    want=$(basename "$newest_uki")
    # `Default Entry:` carries the value. `Default Boot Loader Entry:` is an
    # empty section HEADER further down bootctl's output — parsing that yielded
    # '' every time, so this block re-set the default on EVERY hook run.
    have=$(bootctl 2>/dev/null | sed -n 's/^ *Default Entry: *//p')
    if [ "$have" != "$want" ]; then
        bootctl set-default "$want" 2>/dev/null &&
            echo "gb5-ensure-uki: default boot entry set to $want"
    fi
fi
exit 0
