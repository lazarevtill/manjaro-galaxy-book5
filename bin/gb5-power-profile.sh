#!/bin/bash
# Pick the platform profile from power source and battery level.
#
#   on AC            release our own override, then leave it to KDE and PPD
#   on battery >50%  GB5_PROFILE_BATTERY   (default: balanced)
#   on battery <=50% GB5_PROFILE_LOW       (default: balanced -- see below)
#
# WHAT IS ACTUALLY MEASURED, and what is not.
#
# An earlier version of this header quoted "quiet 4.8 W / balanced 7-10 W /
# performance 17.5 W at idle", a 79.5 Wh battery, and "23% of sustained clock".
# All of it is superseded and none of it should be relied on: the idle figures
# came from short samples on a busy desktop, the pack is 76.0 Wh by the gauge
# (73.9 Wh design), and the clock figure was revised twice.
#
# What survives measurement, under all-core load on AC, each arm cooled to
# TCPU <= 52 C first:
#
#   quiet      19.77 W   1025 MHz        balanced   19.73 W   1404 MHz
#
# i.e. no measurable package-power difference, and 27% less clock. That is why
# GB5_PROFILE_LOW now defaults to balanced rather than quiet.
#
# THREE LIMITS ON THAT RESULT, stated because the setting shipped on it:
#
#   * It was measured on AC. GB5_PROFILE_LOW only ever applies on BATTERY, where
#     the EC may enforce different power limits. The deployed regime is untested.
#   * The load was a 16-way shell busy-loop: integer only, no AVX, no memory
#     traffic. A heavier load could change the ranking.
#   * RAPL cannot see the fan, and quieter fans are what Samsung's "Silent" mode
#     is for. The acoustic case was never quantified. Set GB5_PROFILE_LOW=quiet
#     in /etc/default/gb5-power if noise matters more than sustained speed.
#
# NOTE: with GB5_PROFILE_LOW = GB5_PROFILE_BATTERY (both balanced by default) the
# threshold and hysteresis below are inert. They are kept, not deleted, because
# setting GB5_PROFILE_LOW=quiet re-arms them with no other change.
#
# TWO THINGS MAKE THIS AWKWARD, both handled below.
#
# 1. power-profiles-daemon also writes platform_profile, and KDE tells it to
#    whenever the charger changes or the battery gets low. So this cannot set a
#    value once -- it has to reassert. A timer does that every minute.
#
# 2. PPD only maps to three of the four modes (power-saver -> low-power,
#    balanced -> balanced, performance -> performance). "quiet" is unreachable
#    through it, which is why it has to be written directly.
#
# It deliberately does NOT fight a deliberate human choice -- but see the
# authorship note at the back-off rule: telling a human apart from PPD is done
# by excluding PPD's own mapping, not by value equality alone.

set -u
PROFILE=/sys/firmware/acpi/platform_profile
# /var/lib, not /run: on /run the state died with every reboot, so a profile this
# script had set on battery stayed stuck after a reboot on AC -- the exact bug the
# AC branch exists to fix -- because "last" was empty and the release never fired.
STATE=/var/lib/gb5-power-profile.last
[ -w "$PROFILE" ] || exit 0

# Thresholds and targets are overridable; the defaults are what was asked for.
# GB5_PROFILE_MANAGE=0 turns the whole thing off without uninstalling anything.
[ -r /etc/default/gb5-power ] && . /etc/default/gb5-power
: "${GB5_PROFILE_MANAGE:=1}"
: "${GB5_PROFILE_BATTERY:=balanced}"
# What to hand the profile back to when the charger returns, if and only if this
# script was the one holding it. Not "performance": that is the desktop's call,
# and balanced is what an untouched machine sits at.
: "${GB5_PROFILE_AC:=balanced}"
: "${GB5_PROFILE_LOW:=balanced}"   # measured: quiet costs 27% clock for no package saving
: "${GB5_PROFILE_LOW_PCT:=50}"
# Hysteresis: drop to the low profile at or below LOW_PCT, but do not climb back
# until BACK_PCT. Without a gap the profile flaps every time the reading wobbles
# across the threshold, and each change is a firmware call.
: "${GB5_PROFILE_BACK_PCT:=55}"

[ "$GB5_PROFILE_MANAGE" = "1" ] || exit 0

supports() { grep -qw "$1" /sys/firmware/acpi/platform_profile_choices 2>/dev/null; }

# Re-assert the GPU's SLPC bias every tick.
#
# gb5-power-tune.sh sets this on AC/battery transitions, but it does not stick:
# it was observed back at "base" while on battery, having been reset somewhere
# between a display mode change and an HDR toggle. Since this script already
# runs once a minute and already knows the power source, re-asserting here costs
# one file write and closes the gap. Idempotent -- writing the current value is
# a no-op.
slpc_want() {
    local want=$1 gt f cur
    for gt in /sys/class/drm/card*/gt/gt*; do
        f="$gt/slpc_power_profile"
        [ -w "$f" ] || continue
        cur=$(sed -n 's/.*\[\([a-z_]*\)\].*/\1/p' "$f")
        [ "$cur" = "$want" ] || echo "$want" > "$f" 2>/dev/null
    done
}

# Wi-Fi power save buys nothing worth having while plugged in, and it costs
# latency and jitter. Measured against the gateway, 40 pings each, 2026-09-12:
#     on  : avg 2.25 ms, max 6.91 ms, mdev 1.02
#     off : avg 1.98 ms, max 3.36 ms, mdev 0.46
# Worst case halved, jitter down 55%. It stays ON on battery, where the saving is
# the whole point. NetworkManager pins the base to "disable" so a reconnect on AC
# cannot quietly re-enable it; this re-asserts every run, the same way SLPC does,
# because a reassociation resets the driver setting.
wifi_ps() { # wifi_ps <on|off>
    local want="$1" d
    for d in /sys/class/net/wl*; do
        [ -e "$d" ] || continue
        iw dev "$(basename "$d")" set power_save "$want" 2>/dev/null
    done
}

ac=0
for ps in /sys/class/power_supply/A{C,DP}*; do
    [ -r "$ps/online" ] && [ "$(cat "$ps/online")" = "1" ] && ac=1
done

# On AC there is nothing to save and no reason to override the desktop.
#
# But "leave it alone" was too literal and produced a real bug: this script sets
# "quiet" below 50% battery, and then on AC it exited without undoing it. So
# after any low-battery episode the machine stayed in a reduced-performance
# profile while plugged in, indefinitely, with nothing to explain why. Observed:
# platform_profile "quiet" on AC while power-profiles-daemon reported
# "power-saver" -- and PPD maps power-saver to "low-power", not "quiet", so the
# stuck value was demonstrably ours rather than the desktop's.
#
# Undo our own override and nothing else. If the profile is not the value this
# script last set, a human or another tool chose it and it is left untouched --
# the same rule the battery branch below follows.
if [ "$ac" = "1" ]; then
    slpc_want base
    wifi_ps off
    last=$(cat "$STATE" 2>/dev/null || echo "")
    current=$(cat "$PROFILE" 2>/dev/null)
    if [ -n "$last" ] && [ "$current" = "$last" ]; then
        # Only forget the override once it has actually been released. Clearing
        # $STATE unconditionally threw away the evidence that we still held the
        # profile, so an unsupported or failed write left it stuck with nothing
        # recording why.
        if supports "$GB5_PROFILE_AC" \
           && echo "$GB5_PROFILE_AC" > "$PROFILE" 2>/dev/null; then
            logger -t gb5-power-profile "on AC: released our '$last' -> $GB5_PROFILE_AC"
            rm -f "$STATE"
        else
            logger -t gb5-power-profile "on AC: could not release '$last' to $GB5_PROFILE_AC; keeping state"
        fi
    else
        rm -f "$STATE"
    fi
    exit 0
fi

slpc_want power_saving
wifi_ps on

cap=100
for b in /sys/class/power_supply/BAT*; do
    [ -r "$b/capacity" ] && cap=$(cat "$b/capacity")
done

current=$(cat "$PROFILE" 2>/dev/null)
last=$(cat "$STATE" 2>/dev/null || echo "")

# Back-off rule: do not fight a deliberate human choice.
#
# The hard part is telling a human apart from power-profiles-daemon, which also
# writes platform_profile and does so on its own schedule -- notably it writes
# "low-power" when KDE hits its LowBattery threshold. The previous rule was
# "current != last means a human did it", which misread every one of those PPD
# writes as a human choice and disengaged this script for the rest of the
# discharge. It only ever appeared to work because GB5_PROFILE_BATTERY happens to
# equal PPD's own battery mapping.
#
# So exclude PPD's mapping explicitly, and only then treat a difference as human.
ppd_expected() {
    command -v powerprofilesctl >/dev/null 2>&1 || return 1
    case "$(powerprofilesctl get 2>/dev/null)" in
        power-saver) echo low-power ;;
        balanced)    echo balanced ;;
        performance) echo performance ;;
        *)           return 1 ;;
    esac
}
if [ -n "$last" ] && [ "$current" != "$last" ]; then
    ppd=$(ppd_expected || echo "")
    if [ -n "$ppd" ] && [ "$current" = "$ppd" ]; then
        : # PPD wrote this, not a person -- carry on and reassert
    else
        exit 0
    fi
fi

if [ "$cap" -le "$GB5_PROFILE_LOW_PCT" ]; then
    want=$GB5_PROFILE_LOW
elif [ "$last" = "$GB5_PROFILE_LOW" ] && [ "$cap" -lt "$GB5_PROFILE_BACK_PCT" ]; then
    want=$GB5_PROFILE_LOW          # inside the hysteresis band, stay put
else
    want=$GB5_PROFILE_BATTERY
fi

supports "$want" || exit 0

# Record authorship only when this script actually WRITES the profile.
#
# The previous version stamped $STATE whenever the current value merely happened
# to equal $want, which claimed authorship of values it never set. A human who
# deliberately chose the same profile the script would have chosen was then
# indistinguishable from the script, and their choice got "released" to balanced
# on the next AC transition.
if [ "$current" = "$want" ]; then
    exit 0
fi

echo "$want" > "$PROFILE" 2>/dev/null || exit 0
echo "$want" > "$STATE"
logger -t gb5-power-profile "battery ${cap}% -> platform profile $want"
