#!/bin/bash
# Is this record still the same as the running system?
#
# Everything here is a COPY of something live. Copies drift: a kernel update
# rebuilds the DKMS source, a package update rewrites a hook, someone edits a
# config in place. A record that quietly disagrees with the machine is worse
# than no record, because it gets trusted.
#
#   ./sync.sh          report drift, change nothing   (safe, no root needed)
#   ./sync.sh --pull   refresh the copies from live   (needs root to read some)
#
# Run it before publishing, and after any kernel or package update that touches
# the camera, the fingerprint stack or the boot chain.

set -uo pipefail
cd "$(dirname "$0")"
PULL=0
[ "${1:-}" = "--pull" ] && PULL=1

drift=0 missing=0 same=0

# copy-here : live-there
MAP="
bin/gb5-verify.sh:/usr/local/sbin/gb5-verify.sh
bin/gb5-power-tune.sh:/usr/local/sbin/gb5-power-tune.sh
bin/gb5-refresh-windows-boot.sh:/usr/local/sbin/gb5-refresh-windows-boot.sh
bin/gb5-ensure-uki.sh:/usr/local/sbin/gb5-ensure-uki.sh
bin/gb5-test-sdcp-persistence.sh:/usr/local/sbin/gb5-test-sdcp-persistence.sh
bin/gb5-dbx-check.sh:/usr/local/sbin/gb5-dbx-check.sh
bin/gb5-dbx-safety-check.py:/usr/local/sbin/gb5-dbx-safety-check.py
config/camera/v4l2-relayd.env:/etc/default/v4l2-relayd
config/camera/20-sync-false.conf:/etc/systemd/system/v4l2-relayd@.service.d/20-sync-false.conf
config/camera/10-dmabuf.conf:/etc/systemd/system/v4l2-relayd@.service.d/10-dmabuf.conf
config/camera/modprobe-v4l2loopback.conf:/etc/modprobe.d/v4l2-relayd.conf
config/camera/ov02e10-26mhz-patched.c:/usr/src/ov02e10-26mhz-1.0/ov02e10.c
config/system/wireless-regdom.conf:/etc/conf.d/wireless-regdom
packaging/libfprint/PKGBUILD:/home/lazarevtill/.cache/gb5-build/fpaur/PKGBUILD
config/system/99-ipu6-hide-raw-nodes.rules:/etc/udev/rules.d/99-ipu6-hide-raw-nodes.rules
config/system/95-gb5-ensure-uki.hook:/etc/pacman.d/hooks/95-gb5-ensure-uki.hook
config/system/99-grub-disable-shim-lock.hook:/etc/pacman.d/hooks/99-grub-disable-shim-lock.hook
bin/gb5-boot-guard.sh:/usr/local/sbin/gb5-boot-guard.sh
config/system/zzz-gb5-boot-guard.hook:/etc/pacman.d/hooks/zzz-gb5-boot-guard.hook
bin/gb5-safe-update:/usr/local/sbin/gb5-safe-update
systemd/gb5-safe-update.service:/etc/systemd/system/gb5-safe-update.service
systemd/gb5-safe-update.timer:/etc/systemd/system/gb5-safe-update.timer
config/system/timeshift-autosnap.conf:/etc/timeshift-autosnap.conf
config/system/timeshift.json:/etc/timeshift/timeshift.json
systemd/max98390-hda-i2c-setup.service:/etc/systemd/system/max98390-hda-i2c-setup.service
config/system/99-gb5-power.rules:/etc/udev/rules.d/99-gb5-power.rules
config/system/gb5-power:/etc/default/gb5-power
config/system/99-gb5-tuning.conf:/etc/sysctl.d/99-gb5-tuning.conf
config/system/50-gb5-watchdog.conf:/etc/systemd/system.conf.d/50-gb5-watchdog.conf
config/system/99-gb5-hide-broken-fan.rules:/etc/udev/rules.d/99-gb5-hide-broken-fan.rules
config/system/gb5-ramoops-modprobe.conf:/etc/modprobe.d/gb5-ramoops.conf
config/system/gb5-ramoops-load.conf:/etc/modules-load.d/gb5-ramoops.conf
config/system/kernel-cmdline:/etc/kernel/cmdline
bin/gb5-monitor-mode:/usr/local/sbin/gb5-monitor-mode
config/system/zram-generator.conf:/etc/systemd/zram-generator.conf
config/boot/loader.conf:/boot/efi/loader/loader.conf
config/browser/brave-flags.conf:/home/lazarevtill/.config/brave-flags.conf
bin/gb5-power-profile.sh:/usr/local/sbin/gb5-power-profile.sh
systemd/gb5-power-profile.service:/etc/systemd/system/gb5-power-profile.service
systemd/gb5-power-profile.timer:/etc/systemd/system/gb5-power-profile.timer
"

for pair in $MAP; do
    here=${pair%%:*}; there=${pair#*:}
    if [ ! -r "$there" ]; then
        printf '  %-44s live file unreadable (need root?)\n' "$here"
        missing=$((missing+1)); continue
    fi
    if [ ! -f "$here" ]; then
        printf '  %-44s NOT CAPTURED\n' "$here"
        missing=$((missing+1))
        [ "$PULL" = 1 ] && { mkdir -p "$(dirname "$here")"; cp "$there" "$here" && echo "      pulled"; }
        continue
    fi
    if diff -q "$here" "$there" >/dev/null 2>&1; then
        same=$((same+1))
    else
        printf '  %-44s DRIFTED from %s\n' "$here" "$there"
        drift=$((drift+1))
        if [ "$PULL" = 1 ]; then cp "$there" "$here" && echo "      pulled"; fi
    fi
done

echo
echo "  $same identical, $drift drifted, $missing missing"
if [ "$PULL" = 1 ]; then
    echo "  Copies refreshed. Review with 'git diff' before committing."
elif [ "$drift" -gt 0 ] || [ "$missing" -gt 0 ]; then
    echo "  Run './sync.sh --pull' as root to refresh them." >&2
    exit 1
fi
