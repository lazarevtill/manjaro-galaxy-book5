#!/bin/bash
# Adaptive platform tuning for the Samsung Galaxy Book5 Pro H (Arrow Lake-H).
#
# Deliberately scoped to knobs that power-profiles-daemon does NOT manage.
# PPD already owns the intel_pstate EPP hint and the ACPI platform_profile;
# duplicating those here would just fight it. What is left is the HWP dynamic
# boost flag and PCIe link-state policy.

ac=1
for ps in /sys/class/power_supply/A{C,DP}*; do
    [ -r "$ps/online" ] && ac=$(cat "$ps/online") && break
done

w() { [ -w "$1" ] && echo "$2" > "$1" 2>/dev/null; }

# The GPU's SLPC (single-loop power controller) firmware has two bias profiles.
# "power_saving" makes it slower to ramp the GT clock and quicker to drop back to
# RC6; "base" is the latency-first default. The path only exists with GuC
# submission + SLPC enabled, which is the case here, and it is reversible.
GT=$(echo /sys/class/drm/card*/gt/gt0 | awk '{print $1}')

if [ "$ac" = "1" ]; then
    # On AC: let HWP ramp P-cores aggressively on wakeup, keep PCIe links hot.
    w /sys/devices/system/cpu/intel_pstate/hwp_dynamic_boost 1
    w /sys/module/pcie_aspm/parameters/policy default
    w "$GT/slpc_power_profile" base
else
    # On battery: HWP dynamic boost costs power for little perceived gain,
    # and deeper PCIe link states materially help idle drain.
    w /sys/devices/system/cpu/intel_pstate/hwp_dynamic_boost 0
    w /sys/module/pcie_aspm/parameters/policy powersupersave
    w "$GT/slpc_power_profile" power_saving
fi

# Runtime PM for PCI functions is safe on this platform and is what lets the
# SoC reach PC10 / S0ix substates while idle.
for d in /sys/bus/pci/devices/*/power/control; do
    [ -w "$d" ] && echo auto > "$d" 2>/dev/null
done

# Refresh rate.
#
# NOTE (2026-08-22): on THIS panel there is no 60 Hz mode at native resolution.
# kscreen-doctor lists exactly one 2880x1800 mode and it is 120 Hz; every 60 Hz
# mode the panel offers is at a lower resolution. So the "60 Hz on battery"
# switch below cannot fire here, and for a long time it silently pretended to:
# kscreen-doctor exits 0 even when it prints "Output mode ... not found", so the
# `&&` guard logged success on every boot. Verify, do not trust the exit code.
#
# What is left instead is VRR/adaptive-sync, which the panel does support and
# which KDE has set to Automatic — that lets the panel lower its own refresh on
# static content without the OS changing modes.
#
# The block is kept because it is correct on panels that DO expose 60 Hz at
# native resolution, and this script is meant to be reusable. It now checks.
# Set GB5_KEEP_120HZ=1 in /etc/default/gb5-power to skip it entirely.
[ -r /etc/default/gb5-power ] && . /etc/default/gb5-power
if [ "${GB5_KEEP_120HZ:-0}" != "1" ]; then
    # kscreen-doctor must run inside the graphical session, and it hangs forever
    # without a Wayland socket in its environment, so always time-box it.
    for sess in $(loginctl list-sessions --no-legend 2>/dev/null | awk '$NF=="active"||$3!=""{print $1}'); do
        suser=$(loginctl show-session "$sess" -p Name --value 2>/dev/null)
        stype=$(loginctl show-session "$sess" -p Type --value 2>/dev/null)
        [ "$stype" = "wayland" ] || continue
        suid=$(id -u "$suser" 2>/dev/null) || continue
        if [ "$ac" = "1" ]; then mode="2880x1800@120"; else mode="2880x1800@60"; fi

        ks() {
            timeout 25 setpriv --reuid="$suid" --regid="$suid" --init-groups \
                env XDG_RUNTIME_DIR="/run/user/$suid" \
                    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$suid/bus" \
                    WAYLAND_DISPLAY=wayland-0 \
                kscreen-doctor "$@" 2>&1
        }

        # Does the mode exist at all? Asking for one that does not is not an
        # error to kscreen-doctor, it just prints a message and exits 0.
        if ! ks -o | sed 's/\x1b\[[0-9;]*m//g' | grep -qF "$mode"; then
            logger -t gb5-power-tune "eDP-1 has no $mode mode; leaving refresh alone"
            continue
        fi

        ks "output.eDP-1.mode.$mode" >/dev/null
        # Confirm from the compositor rather than from the exit code.
        if ks -o | sed 's/\x1b\[[0-9;]*m//g' | grep -qE "${mode%@*}@${mode#*@}[^0-9].*\*|${mode}\*"; then
            logger -t gb5-power-tune "eDP-1 -> $mode"
        else
            logger -t gb5-power-tune "eDP-1 -> $mode REQUESTED BUT NOT APPLIED"
        fi
    done
fi

logger -t gb5-power-tune "applied tuning (ac=$ac)"
