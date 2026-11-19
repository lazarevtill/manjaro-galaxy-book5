#!/bin/bash
# Is this the machine these fixes were written for?
#
# Every step after this one loads out-of-tree kernel modules or replaces a
# system package. On the right laptop that is what makes the hardware work; on
# the wrong one it is a good way to break a working system. So check first, and
# be explicit about which mismatches are fatal and which are only a warning.
#
# Exits non-zero if anything essential does not match. setup.sh refuses to
# continue in that case.

# NOT pipefail. `grep -q` exits the moment it matches, which closes the pipe and
# leaves the producer (lsmod, lsusb) killed by SIGPIPE — under pipefail that
# reads as a failed pipeline and every detection below reports "not found" on a
# machine where everything is present. Cost an hour the first time.
set -u
warn=0 fail=0

ok()   { printf '  \033[32mok\033[0m    %-34s %s\n' "$1" "$2"; }
warns(){ printf '  \033[33mwarn\033[0m  %-34s %s\n' "$1" "$2"; warn=$((warn+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %-34s %s\n' "$1" "$2"; fail=$((fail+1)); }

echo "Hardware"
vendor=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null)
board=$(cat /sys/class/dmi/id/product_name 2>/dev/null)
case "$vendor" in
    *SAMSUNG*) ok "vendor" "$vendor" ;;
    *) bad "vendor" "$vendor — these fixes are Samsung Galaxy Book specific" ;;
esac
case "$board" in
    965XHD) ok "model" "$board (the machine this was built on)" ;;
    96*|95*|94*) warns "model" "$board — a different Galaxy Book. Camera and speaker quirks are per-board; read setup/README.md before continuing." ;;
    *) bad "model" "$board — not a Galaxy Book" ;;
esac

cpu=$(grep -m1 '^model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ *//')
case "$cpu" in
    *"Ultra 7 255H"*|*"Ultra"*2*H*) ok "cpu" "$cpu" ;;
    *) warns "cpu" "$cpu — expected Arrow Lake-H" ;;
esac

echo
echo "Kernel"
kver=$(uname -r)
kmaj=$(uname -r | cut -d. -f1)
if [ "${kmaj:-0}" -ge 6 ]; then ok "version" "$kver"; else bad "version" "$kver — needs 6.10+ for IPU6 ISYS"; fi
if [ -d "/lib/modules/$kver/build" ]; then ok "headers" "present"; else bad "headers" "missing — install linux-headers matching $kver"; fi
if [ "$(lsmod | grep -c '^intel_ipu6_isys')" -gt 0 ]; then ok "ipu6 isys" "loaded"
else warns "ipu6 isys" "not loaded — camera steps will do nothing useful"; fi

echo
echo "Devices this expects to find"
usb=$(lsusb 2>/dev/null || true)
if [ "$(printf '%s' "$usb" | grep -ci '1c7a:05a5')" -gt 0 ]; then ok "fingerprint reader" "EgisTec 1c7a:05a5"
elif [ "$(printf '%s' "$usb" | grep -ci '1c7a:')" -gt 0 ]; then warns "fingerprint reader" "an EgisTec device, but not 05a5 — the SDCP fork may still cover it"
else warns "fingerprint reader" "not found — skip 30-fingerprint.sh"; fi

# The sensor is not an i2c client with a readable name here — it is bound
# through the IPU6 bridge. Presence of the driver module is the reliable signal.
if [ "$(lsmod | grep -c '^ov02e10')" -gt 0 ] || [ -e /sys/bus/i2c/drivers/ov02e10 ]; then
    ok "camera sensor" "ov02e10 driver bound"
elif [ "$(dmesg 2>/dev/null | grep -ci ov02e10)" -gt 0 ]; then
    ok "camera sensor" "ov02e10 seen in dmesg"
else
    warns "camera sensor" "ov02e10 not seen — skip 10-camera.sh unless you know better"
fi

# 0x38 is declared in ACPI and binds through the HDA codec, so it never appears
# as an i2c client. Only the three this setup creates do. Counting max98390
# clients therefore reports 3 when everything worked, and 0 before the fix.
amps=$(grep -l max98390 /sys/bus/i2c/devices/*/name 2>/dev/null | wc -l)
if [ "$amps" -ge 3 ]; then ok "speaker amps" "$amps extra MAX98390 bound (already set up)"
elif [ "$(grep -c MAX98390 /sys/firmware/acpi/tables/DSDT 2>/dev/null || echo 0)" -gt 0 ] \
     || dmesg 2>/dev/null | grep -qi max98390; then
     warns "speaker amps" "hardware present, $amps of 3 extra amps bound — run 20-speakers.sh"
else warns "speaker amps" "MAX98390 not detected — 20-speakers.sh may not apply"; fi

echo
echo "Distribution"
if command -v pacman >/dev/null; then ok "package manager" "pacman"
else bad "package manager" "these scripts are written for Arch/Manjaro"; fi
if command -v makepkg >/dev/null; then ok "makepkg" "present"; else bad "makepkg" "install base-devel"; fi
if [ "$(id -u)" -eq 0 ]; then ok "privileges" "running as root"; else bad "privileges" "run with sudo"; fi

echo
if [ "$fail" -gt 0 ]; then
    echo "  $fail blocking problem(s), $warn warning(s). Not safe to continue." >&2
    exit 1
fi
[ "$warn" -gt 0 ] && echo "  $warn warning(s) — read them, then decide per step." || echo "  Everything matches."
exit 0
