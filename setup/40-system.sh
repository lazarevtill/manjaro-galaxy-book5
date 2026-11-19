#!/bin/bash
# Power, memory, wireless and snapshots — the parts with no custom kernel code.
#
# Deliberately does NOT install TLP, tuned or auto-cpufreq. They take over the
# same knobs power-profiles-daemon owns, and PPD is what KDE's battery applet
# drives. Adding one produces contradictory behaviour that is miserable to
# debug. This only touches what PPD does not.
#
# Idempotent.

set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
HERE=$(cd "$(dirname "$0")/.." && pwd)

echo "==> Packages"
pacman -S --needed --noconfirm power-profiles-daemon thermald zram-generator \
    intel-media-driver libva-utils wireless-regdb timeshift >/dev/null
# The legacy i965 VA-API driver has no Arrow Lake support at all, so every video
# decode runs on the CPU while it is installed.
pacman -R --noconfirm libva-intel-driver 2>/dev/null || true
systemctl enable --now power-profiles-daemon thermald >/dev/null 2>&1 || true
echo "    ok"

echo "==> Power tuning (only what PPD does not own)"
install -Dm755 "$HERE/bin/gb5-power-tune.sh" /usr/local/sbin/gb5-power-tune.sh
[ -f "$HERE/config/system/gb5-power" ] && install -Dm644 "$HERE/config/system/gb5-power" /etc/default/gb5-power
[ -f "$HERE/config/system/99-gb5-power.rules" ] && install -Dm644 "$HERE/config/system/99-gb5-power.rules" /etc/udev/rules.d/99-gb5-power.rules
udevadm control --reload
/usr/local/sbin/gb5-power-tune.sh >/dev/null 2>&1 || true
echo "    ok"

echo "==> Measurement tools"
# gb5-power-analyse deliberately refuses to answer when the data cannot support
# an answer -- see docs/power/power-and-tuning.md for the four ways this project got
# confident wrong numbers before those rules were encoded in the tool.
for t in gb5-power-report gb5-power-log gb5-power-analyse gb5-hdr-black-test gb5-safe-update; do
    [ -f "$HERE/bin/$t" ] && install -Dm755 "$HERE/bin/$t" "/usr/local/sbin/$t"
done
if [ -f "$HERE/systemd/gb5-power-log.service" ]; then
    install -Dm644 "$HERE/systemd/gb5-power-log.service" /etc/systemd/system/gb5-power-log.service
    systemctl daemon-reload
    systemctl enable --now gb5-power-log.service 2>/dev/null || true
fi
# Unattended maintenance (added 2026-11-19; the update timer was live on the
# machine but no setup script installed it). Pacman weekly via the guarded
# updater, Flatpak weekly on AC. enable, never --now: starting the updater from
# a setup script would run a full system upgrade mid-setup.
for u in gb5-safe-update.service gb5-safe-update.timer gb5-unmask-hibernate.service \
         gb5-flatpak-update.service gb5-flatpak-update.timer; do
    [ -f "$HERE/systemd/$u" ] && install -Dm644 "$HERE/systemd/$u" "/etc/systemd/system/$u"
done
install -Dm755 "$HERE/bin/gb5-update-notify" /usr/local/sbin/gb5-update-notify
systemctl daemon-reload
systemctl enable gb5-safe-update.timer gb5-flatpak-update.timer gb5-unmask-hibernate.service 2>/dev/null || true
# turbostat gives the per-domain package split; without it the tools fall back
# to raw RAPL and cannot separate cores from GPU.
pacman -S --needed --noconfirm linux-tools >/dev/null 2>&1 || true
echo "    ok"

echo "==> Memory"
[ -f "$HERE/config/system/zram-generator.conf" ] && install -Dm644 "$HERE/config/system/zram-generator.conf" /etc/systemd/zram-generator.conf
[ -f "$HERE/config/system/99-gb5-tuning.conf" ] && install -Dm644 "$HERE/config/system/99-gb5-tuning.conf" /etc/sysctl.d/99-gb5-tuning.conf
sysctl --system >/dev/null 2>&1 || true
echo "    ok"

echo "==> Wireless regulatory domain"
# Unset, the kernel uses country 00 — the world fallback, with no 6 GHz
# allocation at all. Set it to where the machine actually is; that is a legal
# question, not a performance one.
if [ -f "$HERE/config/system/wireless-regdom.conf" ]; then
    install -Dm644 "$HERE/config/system/wireless-regdom.conf" /etc/conf.d/wireless-regdom
    dom=$(grep -m1 '^WIRELESS_REGDOM' /etc/conf.d/wireless-regdom | cut -d'"' -f2)
    iw reg set "$dom" 2>/dev/null || true
    echo "    set to $dom — CHANGE THIS if you are not in that country"
fi
# On Intel cards with a self-managed PHY this does not enable 6 GHz: the
# firmware decides, via ACPI _DSM function 3 returning the BIOS field UHBS.
# There is no module parameter that overrides it.

echo "==> Snapshots"
# The pre-upgrade hook comes from timeshift-autosnap. What is usually missing is
# a time axis: without it, only package upgrades create restore points, so
# nothing covers a config change or a DKMS rebuild.
pacman -S --needed --noconfirm timeshift-autosnap 2>/dev/null || \
    echo "    timeshift-autosnap not in the repos — install it from the AUR for pre-upgrade snapshots"
if [ -f "$HERE/config/system/timeshift.json" ] && [ ! -s /etc/timeshift/timeshift.json ]; then
    install -Dm644 "$HERE/config/system/timeshift.json" /etc/timeshift/timeshift.json
fi
# Editing that JSON alone does nothing: Timeshift writes its cron entries only
# when --check runs with schedules enabled.
command -v timeshift >/dev/null && timeshift --check >/dev/null 2>&1 || true
echo "    $(ls /etc/cron.d/ 2>/dev/null | grep -c '^timeshift') cron entries armed"

echo
echo "Done. Check the result with: gb5-verify.sh"
