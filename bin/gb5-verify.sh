#!/bin/bash
# Post-boot verification for the Samsung Galaxy Book5 Pro H enablement work.
# Safe to run any time: read-only apart from writing its own report.
#   gb5-verify.sh            -> report to stdout
#   gb5-verify.sh <file>     -> report to <file> as well

OUT="${1:-}"
U=lazarevtill
UID1=$(id -u "$U" 2>/dev/null || echo 1000)
export XDG_RUNTIME_DIR="/run/user/$UID1"
export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$UID1/bus"
export WAYLAND_DISPLAY=wayland-0
# kscreen-doctor hangs indefinitely if it cannot reach KWin, so always time-box it.
kd() { timeout 40 sudo -u "$U" env XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
       DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS" \
       WAYLAND_DISPLAY=wayland-0 kscreen-doctor "$@" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g'; }
pass=0; fail=0; warn=0

emit() { if [ -n "$OUT" ]; then printf '%s\n' "$*" >> "$OUT"; fi; printf '%s\n' "$*"; }
ck() { # ck <label> <expected-substring> <actual>
  local label="$1" want="$2" got="$3"
  if [[ "$got" == *"$want"* ]]; then pass=$((pass+1)); emit "  PASS  $label — $got"
  else fail=$((fail+1)); emit "  FAIL  $label — got: ${got:-<empty>} (wanted: $want)"; fi
}
note() { warn=$((warn+1)); emit "  NOTE  $*"; }
hdr()  { emit ""; emit "── $* ──"; }

[ -n "$OUT" ] && : > "$OUT"
emit "Galaxy Book5 Pro H — post-boot verification"
emit "$(date '+%Y-%m-%d %H:%M:%S %Z')   kernel $(uname -r)   up $(cut -d. -f1 /proc/uptime)s"

hdr "DKMS modules (must rebuild on every kernel update)"
for m in ov02e10-26mhz max98390-hda v4l2loopback; do
  # -k: a bare `dkms status` lists every kernel, and head -1 passed v4l2loopback
  # on its 6.12 line while asking about the running kernel.
  ck "$m" "installed" "$(dkms status -k "$(uname -r)" "$m" 2>/dev/null | head -1)"
done

hdr "Camera"
# After a kernel update the running kernel's module tree is deleted, so modinfo
# resolves nothing until reboot. That is a pending reboot, not a breakage --
# distinguish them, or every post-update run reports a false failure.
#
# Do NOT test for the tree's ABSENCE to detect this. The tree can be restored
# from a Timeshift snapshot to get a machine working before its reboot (see
# docs/system/docker.md), and then a pending reboot becomes invisible to every check
# that keys off the directory. Compare kernel VERSIONS -- that is the real
# signal and it cannot be faked by putting files back.
NEWEST_K=$(ls -1 /usr/lib/modules 2>/dev/null | grep -v '^extramodules' | sort -V | tail -1)
if [ "$(uname -r)" != "$NEWEST_K" ]; then
  note "kernel updated, reboot pending — running $(uname -r), newest installed $NEWEST_K"
  [ -d "/usr/lib/modules/$(uname -r)" ] && note "the running kernel's module tree is present but STALE (restored by hand?) — it is 350 MB inside @ and lands in every snapshot; remove it after rebooting: sudo rm -rf /usr/lib/modules/$(uname -r)"
  ck "patched camera driver built for the new kernel" "installed" \
     "$(dkms status ov02e10-26mhz 2>/dev/null | head -1 | grep -o 'installed' || echo missing)"
else
  ck "patched driver active" "updates/dkms" "$(modinfo ov02e10 2>/dev/null | awk '/^filename:/{print $2}')"
fi
clk=$(dmesg 2>/dev/null | grep -c "external clock 26000000 is not supported")
if [ "$clk" = "0" ]; then pass=$((pass+1)); emit "  PASS  no 26 MHz clock rejection this boot"
else fail=$((fail+1)); emit "  FAIL  clock still rejected ($clk occurrences)"; fi
ck "sensor Bayer order" "SRGGB10" "$(media-ctl -p -d /dev/media0 2>/dev/null | grep -A4 'entity.*ov02e10' | grep -m1 -o 'S[A-Z]*10_1X10')"
# The register list programs the PLL for a 19.2 MHz MCLK; this board feeds it
# 26 MHz, so without extra blanking the sensor runs 1.354x fast (40.6 fps) and
# the maximum exposure is 1.354x too short. The AGC then makes up the light with
# analogue gain, which is what the noise was. vts_def = 3039 puts it back.
SENSOR_SD=$(for sd in /dev/v4l-subdev*; do
              v4l2-ctl -d "$sd" --list-ctrls 2>/dev/null | grep -q vertical_blanking && echo "$sd" && break
            done)
ck "sensor retimed for the 26 MHz clock" "3037" \
   "$(v4l2-ctl -d "$SENSOR_SD" --list-ctrls 2>/dev/null | sed -n 's/.*exposure.*max=\([0-9]*\).*/\1/p' | head -1)"
# Analogue gain is 4.4 fixed point: 16 = 1x. Sustained gain near the 248 ceiling
# means the sensor is light-starved and the picture will be noisy.
again=$(v4l2-ctl -d "$SENSOR_SD" --get-ctrl analogue_gain 2>/dev/null | grep -oE '[0-9]+$')
if [ -n "$again" ] && [ "$again" -lt 200 ]; then
  pass=$((pass+1)); emit "  PASS  analogue gain not pinned high — $again ($(( again * 100 / 16 ))% of 1x)"
else
  note "analogue gain is ${again:-unknown} (>=200 means very dim light, expect noise)"
fi
# `cam -l` cannot enumerate while another application holds the camera, which is a
# normal state, not a fault. Treat "in use" as success.
camout=$(cam -l 2>&1)
lcam="$(grep -m1 'front camera' <<<"$camout")"
# Ask libcamera itself rather than guessing from PipeWire node names, which
# change whenever the daemon restarts. A held camera fails the media-link setup
# with EBUSY and lists nothing.
if [ -z "$lcam" ] && grep -q "Device or resource busy" <<<"$camout"; then
  lcam="Internal front camera (in use by an application)"
fi
ck "libcamera enumerates" "Internal front camera" "$lcam"
# Apps that open /dev/video directly need the loopback bridge; without it they
# grab a raw Bayer IPU6 node, light the LED and show nothing.
# The loopback's /dev/videoN number depends on probe order and moves between
# boots, so locate it by card name rather than hardcoding a node.
BRIDGE=$(for d in /dev/video*; do
           [ "$(cat /sys/class/video4linux/$(basename "$d")/name 2>/dev/null)" = "Integrated Camera" ] && echo "$d" && break
         done)
ck "V4L2 bridge device" "Integrated Camera" "$([ -n "$BRIDGE" ] && v4l2-ctl -d "$BRIDGE" --info 2>/dev/null | grep -m1 'Card type' | sed 's/.*: //')"
ck "relay running" "active" "$(systemctl is-active v4l2-relayd)"
# A filter in the relay pipeline at full resolution stalls it to ~6 fps with
# sub-second freezes. Keep full-resolution pipelines filter-free.
ck "no CPU filter in the relay pipeline" "clean" \
   "$(if grep -q '^VIDEOSRC=.*frei0r' /etc/default/v4l2-relayd; then
        echo "frei0r filter present — blows v4l2sink's lateness budget"
      else echo clean; fi)"
# VEBOX denoise is a no-op unless the VPP input surface is NV12, and libcamera
# hands out BGRx, so the NV12 conversion stage has to be there for it to do
# anything at all.
ck "GPU denoise actually engaged" "1" \
   "$(grep -c '^VIDEOSRC=.*format=NV12.*vapostproc denoise=[1-9]' /etc/default/v4l2-relayd)"
ck "va plugin installed" "gst-plugin-va" "$(pacman -Q gst-plugin-va 2>/dev/null | awk '{print $1}')"
# Without this the output pipeline drops every late frame except one per second,
# which reads as the camera freezing for ~1 s at a time.
ck "relay sink clock-sync disabled" "1" \
   "$(systemctl cat 'v4l2-relayd@.service' --no-pager 2>/dev/null | grep -c 'v4l2sink.*sync=false')"
# The emergency-render warning is the fingerprint of that failure.
ck "no emergency frame drops this boot" "0" \
   "$(journalctl -u 'v4l2-relayd@*' -b --no-pager 2>/dev/null | grep -ci 'buffers are being dropped')"
# The bridge advertises whatever WIDTH/HEIGHT in /etc/default/v4l2-relayd say, and
# meeting clients just take what is offered — a 1280x720 cap here is invisible
# locally and shows up as a soft picture on the other end of a call.
brdev=""
for d in /dev/video*; do
  v4l2-ctl -d "$d" --info 2>/dev/null | grep -q "Integrated Camera" && { brdev="$d"; break; }
done
ck "bridge offers full sensor resolution" "1920x1088" \
   "$(v4l2-ctl -d "$brdev" --list-formats-ext 2>/dev/null | grep -oE '[0-9]+x[0-9]+' | sort -t x -k1 -n | tail -1)"
# PipeWire probes the loopback once and caches it, so a resolution change here
# needs `systemctl --user restart pipewire wireplumber` before clients see it.
pwmax=$(sudo -u $U env XDG_RUNTIME_DIR=/run/user/$UID1 pw-dump 2>/dev/null |
  python3 -c "
import sys,json
try: d=json.load(sys.stdin)
except Exception: sys.exit()
print(' '.join(str(o['id']) for o in d
      if ((o.get('info') or {}).get('props') or {}).get('media.class')=='Video/Source'))" 2>/dev/null)
best=0
for n in $pwmax; do
  m=$(sudo -u $U env XDG_RUNTIME_DIR=/run/user/$UID1 pw-cli e "$n" EnumFormat 2>/dev/null |
      grep -oE 'Rectangle [0-9]+x[0-9]+' | awk '{split($2,a,"x"); print a[1]}' | sort -n | tail -1)
  [ -n "$m" ] && [ "$m" -gt "$best" ] && best=$m
done
if [ "$best" -ge 1920 ]; then
  pass=$((pass+1)); emit "  PASS  PipeWire sources offer ${best}px wide"
else
  fail=$((fail+1)); emit "  FAIL  PipeWire sources cap at ${best}px — restart pipewire/wireplumber to re-probe"
fi
# Every raw IPU6 node has its ID_V4L_CAPABILITIES cleared, so the only devices an
# app should see are the loopbacks: the camera bridge, plus StudioEffects when
# the NPU effects are set up. Count them rather than pinning a number.
visible=$(for d in /dev/video*; do
            udevadm info --query=property --name=$d 2>/dev/null |
              grep -q '^ID_V4L_CAPABILITIES=.\+' && basename "$d"
          done)
loopbacks=$(for d in $visible; do cat /sys/class/video4linux/$d/name 2>/dev/null; done |
            grep -cE 'Integrated Camera|StudioEffects')
nvisible=$(printf '%s\n' $visible | grep -c .)
ck "only loopbacks visible to apps" "$nvisible" "$loopbacks"

hdr "Wireless"
# Unset, the kernel uses country 00 (world) — the most restrictive fallback, with
# no 6 GHz allocation at all. Setting it does NOT enable 6 GHz on this card (the
# PHY is self-managed and the BIOS gates it, see below) but it is still correct.
ck "regulatory domain set" "country RS" "$(iw reg get 2>/dev/null | sed -n '2p')"
ck "regdomain persists across boots" "RS" "$(grep -m1 '^WIRELESS_REGDOM' /etc/conf.d/wireless-regdom 2>/dev/null | cut -d'"' -f2)"
# 6 GHz is gated by ACPI _DSM function 3, which returns the BIOS NVS field UHBS.
# There is no module parameter to override it. Reported as a NOTE, not a FAIL:
# it is a firmware decision, not a misconfiguration we can fix.
sixg_total=$(iw phy phy0 info 2>/dev/null | sed -n '/Band 4:/,$p' | grep -c 'MHz \[')
sixg_off=$(iw phy phy0 info 2>/dev/null | sed -n '/Band 4:/,$p' | grep 'MHz \[' | grep -c disabled)
if [ "${sixg_total:-0}" -gt 0 ] && [ "$sixg_off" -eq "$sixg_total" ]; then
  note "6 GHz: all $sixg_total channels disabled by firmware (ACPI _DSM fn3 -> \\UHBS). Not fixable from Linux."
elif [ "${sixg_total:-0}" -gt 0 ]; then
  pass=$((pass+1)); emit "  PASS  6 GHz usable — $((sixg_total-sixg_off))/$sixg_total channels"
fi

hdr "Snapshots and rollback"
# Pre-upgrade snapshots come from a pacman hook; the time-based ones need cron
# entries that only appear once `timeshift --check` has run with schedules on.
ck "pre-upgrade snapshot hook" "timeshift-autosnap" \
   "$(pacman -Qo /usr/share/libalpm/hooks/00-timeshift-autosnap.hook 2>/dev/null | grep -oE 'timeshift-autosnap[a-z-]*' | head -1)"
ck "timeshift in BTRFS mode" "BTRFS" "$(timeshift --list 2>/dev/null | grep -m1 '^Mode' | awk '{print $3}')"
# The shipped config says btrfs_mode false; opening the GUI would write that back
# and silently switch to rsync, which on a 468 GB root is a different animal.
ck "btrfs_mode pinned in config" "true" "$(python3 -c "
import json;print(json.load(open('/etc/timeshift/timeshift.json')).get('btrfs_mode'))" 2>/dev/null)"
ck "scheduled snapshots armed" "2" "$(ls /etc/cron.d/ 2>/dev/null | grep -c '^timeshift')"
nsnap=$(timeshift --list 2>/dev/null | grep -cE '^[0-9]+ +>')
ck "snapshots exist" "1" "$([ "${nsnap:-0}" -ge 1 ] && echo 1 || echo 0)"
# grub-btrfs generated snapshot entries for a GRUB menu we no longer boot.
ck "no dead GRUB snapshot tooling" "0" "$(pacman -Q grub-btrfs 2>/dev/null | wc -l)"

hdr "Audio"
ck "amp driver loaded" "snd_hda_scodec_max98390" "$(lsmod | grep -m1 '^snd_hda_scodec_max98390')"
n=$(ls /sys/bus/i2c/devices/ 2>/dev/null | grep -cE '^2-00(39|3c|3d)$')
ck "extra amps bound (3 expected)" "3" "$n"
ck "i2c setup service" "active" "$(systemctl is-active max98390-hda-i2c-setup)"

hdr "Fingerprint"
ck "patched libfprint installed" "libfprint-egismoc-sdcp-git" "$(pacman -Q libfprint-egismoc-sdcp-git 2>&1 | awk '{print $1}')"
ck "crash fix present in .so" "1" "$(strings /usr/lib/libfprint-2.so.2 2>/dev/null | grep -c 'stale task SSM')"
# Without this, the SDCP host keypair is regenerated on every boot, the sensor
# disowns every template, and fprintd prunes its records ("unknown to device").
# The reboot symptom is enrolments silently vanishing.
ck "SDCP host identity persists across boots" "1" \
   "$(strings /usr/lib/libfprint-2.so.2 2>/dev/null | grep -c 'host identity is reusable')"
# Without this, a match is reported and then discarded when libfprint cancels the
# driver's trailing command: "verify-match" followed by "verify-no-match".
ck "match survives post-match cancellation" "1" \
   "$(strings /usr/lib/libfprint-2.so.2 2>/dev/null | grep -c 'Cancelled after the result was reported')"
claim=$(find /var/lib/fprint -name sdcp-claim -print -quit 2>/dev/null)
if [ -n "$claim" ]; then
  emit "  PASS  SDCP claim cached — $claim"
  pass=$((pass+1))
else
  note "no SDCP claim cached yet; it is written on the first match after enrolment"
fi
# fprintd only reconciles against the sensor during a match, so a stale prune is
# only visible in the log. Any occurrence this boot means templates were lost.
pruned=$(journalctl -u fprintd -b --no-pager 2>/dev/null | grep -c 'unknown to device')
ck "no templates disowned by the sensor this boot" "0" "$pruned"
# A match reported and then OVERTURNED is the signature of the cancellation bug:
# report_verify_status says verify-match, and the verify_cb for the SAME
# operation says verify-no-match.
#
# Two earlier versions of this check were wrong. Counting both results across the
# boot failed whenever there were more failed touches than successful ones, which
# is normal. Filtering the log down to just match/no-match markers then made a
# match in one operation look adjacent to a no-match minutes later. Pair them by
# time instead: a real overturn has both within the same second.
overturned=$(journalctl -u fprintd -b --no-pager -o short-unix 2>/dev/null |
  grep -oE '^[0-9]+\.[0-9]+.*(report_verify_status|verify_cb): result verify-[a-z-]+' |
  sed -E 's/^([0-9]+)\..*(report_verify_status|verify_cb): result (verify-[a-z-]+)/\1 \2 \3/' |
  awk '$2=="report_verify_status" && $3=="verify-match" { t[$1]=1 }
       $2=="verify_cb" && $3=="verify-no-match" && ($1 in t) { n++ }
       END { print n+0 }')
got=$(journalctl -u fprintd -b --no-pager 2>/dev/null |
      grep -c 'report_verify_status: result verify-match')
if [ "${overturned:-0}" -gt 0 ]; then
  fail=$((fail+1)); emit "  FAIL  $overturned reported match(es) overturned to no-match — the cancellation bug is back"
elif [ "$got" -gt 0 ]; then
  pass=$((pass+1)); emit "  PASS  no reported match was overturned — $got match(es) this boot"
else
  note "no fingerprint match attempted this boot — cannot check the cancellation bug"
fi
ck "epoch beats the AUR placeholder" "1:" "$(pacman -Q libfprint-egismoc-sdcp-git 2>/dev/null | awk '{print $2}')"
nf=$(sudo -u $U fprintd-list $U 2>/dev/null | grep -c '^ - #')
if [ "${nf:-0}" -gt 0 ]; then pass=$((pass+1))
  emit "  PASS  fingers enrolled ($nf) — $(sudo -u $U fprintd-list $U 2>/dev/null | grep '^ - #' | sed 's/^ - #[0-9]*: //' | tr '\n' ' ')"
else fail=$((fail+1)); emit "  FAIL  no fingers enrolled"; fi
for f in sddm login sudo polkit-1; do
  ck "pam_fprintd in $f" "pam_fprintd" "$(grep -m1 fprintd /etc/pam.d/$f 2>/dev/null | tr -s ' \t' ' ')"
done

hdr "Microphone"
ck "beamformer" "on" "$(amixer -c 0 sget 'Dmic0 Capture TDFB beam switch' 2>/dev/null | grep -m1 -oE '\[on\]|\[off\]')"
ck "compressor" "on" "$(amixer -c 0 sget 'Dmic0 Capture DRC switch' 2>/dev/null | grep -m1 -oE '\[on\]|\[off\]')"
mw=$(mktemp /tmp/gb5mic.XXXX.wav)
timeout 8 arecord -D hw:0,6 -f S32_LE -r 48000 -c 2 -d 3 "$mw" >/dev/null 2>&1
lvl=$(python3 -c "
import wave,array,math,sys
try:
    w=wave.open('$mw'); n=w.getnframes(); sw=w.getsampwidth()
    a=array.array({1:'b',2:'h',4:'i'}[sw]); d=w.readframes(n); a.frombytes(d[:len(d)-(len(d)%sw)])
    full=float(2**(8*sw-1)); rms=math.sqrt(sum(x*x for x in a)/len(a))
    print('live' if rms>full*0.0002 else 'silent')
except Exception: print('error')" 2>/dev/null)
rm -f "$mw"
ck "captures audio" "live" "$lvl"

hdr "Graphics"
ck "VA-API profiles (42 expected)" "42" "$(LIBVA_DRIVER_NAME=iHD vainfo 2>/dev/null | grep -c VAProfile)"
ck "AV1 decode" "AV1" "$(LIBVA_DRIVER_NAME=iHD vainfo 2>/dev/null | grep -m1 -o 'VAProfileAV1Profile0')"
ck "panel self-refresh" "PSR2 enabled" "$(grep -m1 'PSR mode' /sys/kernel/debug/dri/0000:00:02.0/i915_edp_psr_status 2>/dev/null | sed 's/.*: //')"

hdr "Display (OLED, 2880x1800@120)"
# Scope to the internal panel: with an external monitor attached, the first
# output kscreen lists is no longer eDP-1 and every check reads the wrong screen.
DOUT="$(kd -o | awk '/^Output: .*eDP-1/,/^Output: .*[^1]$/')"
[ -z "$DOUT" ] && DOUT="$(kd -o)"
ck "HDR" "enabled" "$(printf '%s' "$DOUT" | grep -m1 'HDR:' | sed 's/.*: //')"
ck "wide colour gamut" "enabled" "$(printf '%s' "$DOUT" | grep -m1 'Wide Color Gamut:' | sed 's/.*: //')"
ck "adaptive sync" "Automatic" "$(printf '%s' "$DOUT" | grep -m1 'Vrr:' | sed 's/.*: //')"
ck "auto brightness" "enabled" "$(printf '%s' "$DOUT" | grep -m1 'Automatic brightness:' | sed 's/.*, //')"
DD=/sys/kernel/debug/dri/0000:00:02.0
ck "colour depth (30 = 10bpc)" "bpp=30" "$(grep -m1 -o 'bpp=[0-9]*' $DD/i915_display_info 2>/dev/null)"
ck "DSC engaged" "DSC_Enabled: yes" "$(grep -m1 'DSC_Enabled' $DD/eDP-1/i915_dsc_fec_support 2>/dev/null)"

hdr "Boot chain (UKI, not GRUB)"
# Was a literal manjaro-7.1 path piped through basename, which cannot fail.
UKI=$(ls -1 /boot/efi/EFI/Linux/manjaro-*.efi 2>/dev/null | grep -v -- '-fallback\.efi$' | sort -V | tail -1)
ck "UKI present" "manjaro" "$([ -f "$UKI" ] && basename "$UKI")"
ck "no orphaned mkinitcpio preset" "0" "$(for p in /etc/mkinitcpio.d/*.preset; do k=$(sed -n 's/^ALL_kver="\{0,1\}\([^"]*\)"\{0,1\}/\1/p' "$p" | head -1); [ -n "$k" ] && [ ! -e "$k" ] && basename "$p"; done | wc -l | sed 's/^[1-9].*/orphaned/')"
ck "UKI signed" "is signed" "$(sbctl verify 2>/dev/null | grep -m1 'EFI/Linux')"
ck "UKI tracked by sbctl" "EFI/Linux" "$(sbctl list-files 2>/dev/null | grep -m1 'EFI/Linux')"
# Since systemd-boot was installed as the OS chooser, the firmware launches it
# (Boot0006 "Linux Boot Manager") and it in turn loads the UKI. Booting 0002
# would mean going straight to the UKI and getting no menu, which is what the
# firmware falls back to if systemd-boot goes missing -- still bootable, but
# no Windows entry. Confirm the chain by checking what the stub actually loaded.
ck "booted through systemd-boot" "Linux Boot Manager" \
   "$(efibootmgr 2>/dev/null | grep -m1 "^Boot$(efibootmgr | grep -m1 '^BootCurrent' | awk '{print $2}')" | sed 's/^Boot[0-9A-F]*\*\?[[:space:]]*//;s/\t.*//')"
ck "stub loaded a Manjaro UKI" "EFI/Linux/manjaro" \
   "$(bootctl status 2>/dev/null | grep -m1 -oE '/EFI/Linux/manjaro[^ ]*' | sed 's#^/##')"
ck "loaded by firmware, not GRUB" "0" "$(grep -c BOOT_IMAGE /proc/cmdline)"
ck "systemd-stub running" "systemd-stub" "$(bootctl status 2>/dev/null | grep -m1 -o 'systemd-stub [0-9.]*')"
ck "removable fallback is the boot menu" "systemd-boot" "$(cmp -s /boot/efi/EFI/systemd/systemd-bootx64.efi /boot/efi/EFI/boot/bootx64.efi && echo systemd-boot || echo other)"
ck "GRUB kept out of BootOrder" "0" "$(efibootmgr 2>/dev/null | grep -m1 '^BootOrder' | grep -c '0001')"
ck "ensure-uki hook installed" "gb5-ensure-uki" "$(ls /etc/pacman.d/hooks/ 2>/dev/null | grep -m1 ensure-uki)"
# dbx empty means Secure Boot enforces zero revocations — a signed but known
# vulnerable bootloader would still validate, and Microsoft's cert is in db
# because Windows needs it. Reported as a NOTE: enrolling is a deliberate,
# near-irreversible choice, not something a check should nag about.
if ls /sys/firmware/efi/efivars/dbx-* >/dev/null 2>&1; then
  pass=$((pass+1)); emit "  PASS  dbx enrolled — revocations enforced"
else
  note "dbx is empty: zero revocations enforced. gb5-dbx-check.sh says whether enrolling is safe."
fi
ck "grub hook has --no-nvram" "no-nvram" "$(grep -m1 -o 'no-nvram' /etc/pacman.d/hooks/99-grub-disable-shim-lock.hook 2>/dev/null)"

hdr "Boot menu (systemd-boot)"
ck "systemd-boot installed" "systemd-boot" "$(bootctl status 2>/dev/null | grep -m1 -oE 'systemd-boot [0-9.]+')"
ck "systemd-boot signed" "is signed" "$(sbctl verify 2>/dev/null | grep -m1 'systemd-bootx64')"
ck "removable fallback signed" "is signed" "$(sbctl verify 2>/dev/null | grep -m1 -i 'EFI/BOOT/BOOTX64\|EFI/boot/bootx64')"
ck "UKI discoverable by the menu" "manjaro" "$(bootctl list 2>/dev/null | grep -m1 -oE 'manjaro[^ ]*\.efi')"
ck "Windows entry present" "bootmgfw" "$(ls /boot/efi/EFI/Microsoft/Boot/bootmgfw.efi 2>/dev/null | xargs -r basename)"
ck "Windows BCD mirrored" "BCD" "$(ls /boot/efi/EFI/Microsoft/Boot/BCD 2>/dev/null | xargs -r basename)"
ck "menu boots first" "0006" "$(efibootmgr 2>/dev/null | grep -m1 '^BootOrder' | cut -d' ' -f2 | cut -d, -f1)"
ck "loader config present" "timeout" "$(grep -m1 -o timeout /boot/efi/loader/loader.conf 2>/dev/null)"
# Guards the 2026-09-11 gb5-ensure-uki bug: it parsed an empty section header and
# picked the newest UKI by mtime, so it silently made the LTS fallback the default.
want_uki=$(ls -1 /boot/efi/EFI/Linux/manjaro-*.efi 2>/dev/null | grep -v -- '-fallback\.efi$' | sort -V | tail -1 | xargs -r basename)
ck "default boot entry is the newest kernel, not the LTS fallback" "$want_uki" \
   "$(bootctl 2>/dev/null | sed -n 's/^ *Default Entry: *//p')"

# Phase 8 (2026-11-19): the first unattended kernel-series bump left a shim_lock
# GRUB as the removable fallback, a fallback UKI whose kernel had no modules, and
# sbctl tracking deleted paths. gb5-boot-guard.sh keeps all three right.
ck "boot-guard hook installed (runs after zz-sbctl)" "zzz-gb5-boot-guard" "$(ls /etc/pacman.d/hooks/ 2>/dev/null | grep -m1 zzz-gb5-boot-guard)"
ck "Manjaro 98-install-grub.hook disabled" "/dev/null" "$(readlink /etc/pacman.d/hooks/98-install-grub.hook 2>/dev/null)"
# --check only: this suite must stay read-only (Fable, 2026-11-19).
ck "boot guard finds nothing to repair" "clean" "$(out=$(gb5-boot-guard.sh --check 2>&1) && [ -z "$out" ] && echo clean || echo "${out:-rc!=0}" | head -1)"
fbk=$(for f in /boot/efi/EFI/Linux/*-fallback.efi; do [ -e "$f" ] && objcopy -O binary --only-section=.uname "$f" /dev/stdout 2>/dev/null | tr -d '\0'; done | head -1)
ck "fallback UKI's kernel has a module tree" "yes" "$([ -n "$fbk" ] && [ -d "/usr/lib/modules/$fbk" ] && echo "yes ($fbk)" || echo "no (${fbk:-no fallback UKI})")"
ck "safe-update has no hardcoded kernel package" "0" "$(grep -vE '^[[:space:]]*#' /usr/local/sbin/gb5-safe-update 2>/dev/null | grep -cE 'linux[0-9]{2,3}\b' | awk '{print ($1>0)?"hardcoded":"0"}')"
sbsrc=/usr/lib/systemd/boot/efi/systemd-bootx64.efi
ck "pre-signed systemd-boot matches the package version" "match" "$(a=$(strings "$sbsrc" 2>/dev/null | grep -m1 -oE 'LoaderInfo: systemd-boot [^ ]+'); b=$(strings "$sbsrc.signed" 2>/dev/null | grep -m1 -oE 'LoaderInfo: systemd-boot [^ ]+'); [ -n "$a" ] && [ "$a" = "$b" ] && echo "match (${a#LoaderInfo: })" || echo "src='$a' signed='$b'")"
ck "flatpak update timer enabled" "enabled" "$(systemctl is-enabled gb5-flatpak-update.timer 2>/dev/null)"

hdr "Power and thermals"
ck "thermald" "active" "$(systemctl is-active thermald)"
ck "power-profiles-daemon" "active" "$(systemctl is-active power-profiles-daemon)"
ck "boot power tuning ran" "enabled" "$(systemctl is-enabled gb5-power-tune)"
ck "resume power tuning armed" "enabled" "$(systemctl is-enabled gb5-power-tune-resume)"
ck "zram active" "zram0" "$(swapon --show=NAME --noheadings 2>/dev/null | grep -m1 zram)"
ck "swappiness" "100" "$(sysctl -n vm.swappiness)"
ck "writeback interval" "1500" "$(sysctl -n vm.dirty_writeback_centisecs)"
ck "TCP congestion" "bbr" "$(sysctl -n net.ipv4.tcp_congestion_control)"
onauto=$(for f in /sys/bus/pci/devices/*/power/control; do cat "$f"; done | grep -c auto)
total=$(ls -d /sys/bus/pci/devices/*/power/control 2>/dev/null | wc -l)
ck "PCI runtime PM auto" "$total" "$onauto"
# Wi-Fi power save became AC-aware on 2026-09-12. Measured against the gateway,
# 40 pings each: on = avg 2.25 / max 6.91 / mdev 1.02 ms, off = avg 1.98 / max
# 3.36 / mdev 0.46 ms. Worst case halved and jitter down 55%, for a saving that
# does not matter while plugged in. gb5-power-profile.sh re-asserts it each run.
if [ "$(cat /sys/class/power_supply/ADP1/online 2>/dev/null)" = "1" ]; then
  ck "wifi power save off on AC" "off" "$(iw dev wlo1 get power_save 2>/dev/null | sed 's/.*: //')"
else
  ck "wifi power save on on battery" "on" "$(iw dev wlo1 get power_save 2>/dev/null | sed 's/.*: //')"
fi
ck "fingerprint reader pinned on" "on" "$(cat /sys/bus/usb/devices/3-5/power/control 2>/dev/null)"
# The ACPI fan's _FST always fails; if it is world-readable ksystemstats polls it
# at 2 Hz and ~8000 ACPI errors per boot bury the evidence of anything else.
ck "broken ACPI fan hidden from pollers (no _FST flood)" "-rw-------" \
   "$(stat -c '%A' /sys/class/hwmon/*/fan1_input 2>/dev/null | head -1)"

hdr "Sleep readiness"
ck "sleep state" "s2idle" "$(cat /sys/power/mem_sleep)"
res=$(cat /sys/kernel/debug/pmc_core/slp_s0_residency_usec 2>/dev/null)
if [ "${res:-0}" -gt 0 ] 2>/dev/null; then
  emit "  PASS  S0ix residency accrued: $(awk -v x="$res" 'BEGIN{printf "%.1f", x/1e6}')s"; pass=$((pass+1))
else
  note "S0ix residency is 0 — expected on a fresh boot; it only accrues while suspended."
fi

hdr "Secure Boot readiness"
ck "sbctl keys created" "sbctl is installed" "$(sbctl status 2>/dev/null | grep -m1 Installed | sed 's/.*\t//')"
# Exclude the mirrored Windows tree: those are Microsoft-signed and validate via
# the MS certificates in db. sbctl only reports "not signed by OUR key".
unsigned=$(sbctl verify 2>/dev/null | grep "is not signed" | grep -vc "/EFI/Microsoft/")
ck "unsigned EFI binaries (ours)" "0" "$unsigned"
sbstate=$(sbctl status 2>/dev/null | grep -m1 "Secure Boot" | grep -o "Enabled\|Disabled")
if [ "$sbstate" = "Enabled" ]; then pass=$((pass+1)); emit "  PASS  Secure Boot is Enabled"
else note "Secure Boot is OFF in firmware. Keys stay enrolled, so this is reversible — re-enable it in BIOS when you are done rescuing."; fi
ck "module sig enforcement" "not set" "$(zcat /proc/config.gz 2>/dev/null | grep -q '^CONFIG_MODULE_SIG_FORCE=y' && echo 'FORCED' || echo 'not set')"

hdr "Hibernation"
ck "swapfile active" "/swap/swapfile" "$(swapon --show=NAME --noheadings 2>/dev/null | grep -x /swap/swapfile || echo missing)"
ck "@swap is its own subvolume" "@swap" "$(findmnt -no OPTIONS /swap 2>/dev/null | grep -o 'subvol=/@swap' || echo 'not mounted')"
# Timeshift snapshots @ and @home; a 20 GiB swapfile inside either would be
# copied into every snapshot.
ck "swapfile excluded from snapshots" "yes" "$(findmnt -no OPTIONS /swap 2>/dev/null | grep -q 'subvol=/@swap' && echo yes || echo NO)"
ck "resume_offset set" "$(btrfs inspect-internal map-swapfile -r /swap/swapfile 2>/dev/null || echo '?')" "$(cat /sys/power/resume_offset 2>/dev/null)"
# Compare the cmdline offset to the swapfile's ACTUAL offset, not merely that
# some offset is present. A stale offset -- left behind by resizing or recreating
# the swapfile -- otherwise passes every check and then fails at hibernate time
# as the damaging aborted-S4, not a clean refusal.
realoff=$(btrfs inspect-internal map-swapfile -r /swap/swapfile 2>/dev/null || echo '?')
ck "cmdline offset matches the swapfile" "resume_offset=$realoff" "$(grep -o 'resume_offset=[0-9]*' /proc/cmdline || echo absent)"
# Every boot entry must resume from the same place. One that does not will skip
# the resume, strand the image, and the next normal boot restores it over a
# filesystem that has moved on.
badentry=0
for u in /boot/efi/EFI/Linux/*.efi; do
  objcopy -O binary --only-section=.cmdline "$u" /tmp/.gb5cl 2>/dev/null || continue
  tr -d '\0' < /tmp/.gb5cl | grep -qF "resume_offset=$realoff" || badentry=$((badentry+1))
done
rm -f /tmp/.gb5cl
ck "all UKIs share the resume target" "0" "$badentry"
rootmm=$(stat -c '%t:%T' "$(findmnt -no SOURCE / | sed 's/\[.*//')" 2>/dev/null | awk -F: '{printf "%d:%d", strtonum("0x"$1), strtonum("0x"$2)}')
# ck passes on an empty want (every string contains ""), so a failed stat would
# make this vacuously green. Refuse instead.
if [ -z "$rootmm" ]; then note "could not determine the root device numbers — resume target unchecked"
else ck "resume points at the root FS" "$rootmm" "$(cat /sys/power/resume 2>/dev/null)"; fi
ck "logind can hibernate" "yes" "$(busctl call org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager CanHibernate 2>/dev/null | grep -o '"[a-z]*"' | tr -d '"')"
# image_size is a SOFT target, not a ceiling: when the kernel cannot shrink that
# far it raises the floor toward ~half of RAM. And the image must fit in the
# swapfile's FREE space, not its size -- the swapfile is also ordinary swap.
# Comparing against size passes in exactly the state that fails.
half_ram=$(awk '/MemTotal/{print int($2/1024/2)}' /proc/meminfo)
swp_free=$(swapon --show=NAME,SIZE,USED --bytes --noheadings 2>/dev/null |
           awk '$1=="/swap/swapfile"{print int(($2-$3)/1024/1024)}')
ck "swapfile free space covers the worst-case image" "yes" \
   "$([ "${swp_free:-0}" -gt "$half_ram" ] && echo "yes (${swp_free} MiB free vs ${half_ram} MiB worst case)" \
      || echo "NO (${swp_free} MiB free vs ${half_ram} MiB worst case)")"
# Ordinary paging must prefer the partition, or it eats the image's room.
sf_pri=$(swapon --show=NAME,PRIO --noheadings 2>/dev/null | awk '$1=="/swap/swapfile"{print $2}')
pt_pri=$(swapon --show=NAME,PRIO --noheadings 2>/dev/null | awk '$1 ~ /nvme/ {print $2}' | head -1)
ck "swapfile is lower priority than the partition" "yes" \
   "$([ "${sf_pri:-0}" -lt "${pt_pri:-0}" ] && echo "yes ($sf_pri < $pt_pri)" || echo "NO ($sf_pri vs $pt_pri)")"
ck "resume fix-up hook" "present" "$([ -x /etc/systemd/system-sleep/gb5-resume-fixups ] && echo present || echo MISSING)"

hdr "S4 fallout (these break on every hibernate and the hook repairs them)"
# Reading power_on_lid_open costs a CSFI call, so a wedged interface shows up
# here as an empty value AND a rising failure count.
pol=$(cat /sys/class/firmware-attributes/samsung-galaxybook/attributes/power_on_lid_open/current_value 2>/dev/null)
# The VALUE does not matter -- 0 is a legitimate setting. What matters is that
# the attribute reads at all; an empty read means the SCAI interface is wedged.
ck "power_on_lid_open readable" "yes" "$([ -n "$pol" ] && echo "yes ($pol)" || echo "NO (empty — SCAI wedged)")"
# Probe the interface LIVE rather than counting failures across the boot.
#
# A cumulative count cannot tell "wedged now" from "was wedged earlier and has
# since been repaired" -- and running diagnostics inflates it, which is how this
# check first produced a false failure. One CSFI failure at driver init is normal
# and appears in every healthy boot, so the total is meaningless on its own.
#
# Instead: note the count, poke the interface, and see whether the poke itself
# produced a new failure.
before=$(journalctl -b -k --no-pager 2>/dev/null | grep -c 'failed to execute CSFI')
cat /sys/class/firmware-attributes/samsung-galaxybook/attributes/power_on_lid_open/current_value >/dev/null 2>&1
sleep 1
after=$(journalctl -b -k --no-pager 2>/dev/null | grep -c 'failed to execute CSFI')
ck "SCAI responds now (live probe)" "0 new failures" "$(( after - before )) new failures"
ck "lock on resume" "true" "$(sudo -u "$U" kreadconfig6 --file kscreenlockerrc --group Daemon --key LockOnResume 2>/dev/null || echo unset)"

hdr "PAM lock screen override"
# /etc/pam.d/kde-fingerprint overrides a VENDOR file and is owned by no package,
# so pacman will never offer a .pacnew when Plasma changes the stack upstream.
# Drift here is silent and indefinite; compare them on every run.
if [ -f /etc/pam.d/kde-fingerprint ] && [ -f /usr/lib/pam.d/kde-fingerprint ]; then
  d=$(diff <(sed 's/ *max-tries=5 timeout=45//' /etc/pam.d/kde-fingerprint | grep -vE '^\s*#|^\s*$') \
           <(grep -vE '^\s*#|^\s*$' /usr/lib/pam.d/kde-fingerprint) | wc -l)
  ck "override differs from vendor only in options" "0" "$d"
  ck "lock screen has the retry options" "max-tries=5" "$(grep -o 'max-tries=[0-9]*' /etc/pam.d/kde-fingerprint || echo absent)"
else
  note "kde-fingerprint override or vendor file absent — lock screen not checked"
fi

hdr "Fingerprint SDCP"
ck "hibernate-recovery patch present" "1" "$(strings /usr/lib/libfprint-2.so.2 2>/dev/null | grep -c 'Invalidated the cached SDCP session')"
en=$(sudo -u "$U" fprintd-list "$U" 2>/dev/null | grep -c '#')
ck "at least one enrolment" "yes" "$([ "${en:-0}" -ge 1 ] && echo "yes ($en)" || echo "NO (0)")"

hdr "Crash recovery (a freeze auto-reboots instead of hanging — see HISTORY 2026-09-11)"
# A panic that auto-reboots teaches nothing unless it lands somewhere persistent.
ck "ramoops region reserved on the cmdline" "reserve_mem=8M:4096:oops" \
   "$(tr ' ' '\n' < /proc/cmdline | grep -m1 '^reserve_mem=')"
ck "pstore backend live (a panic will be captured)" "ramoops" \
   "$(cat /sys/module/pstore/parameters/backend 2>/dev/null)"
ck "monitor-mode guard available" "gb5-monitor-mode" \
   "$(command -v gb5-monitor-mode 2>/dev/null | xargs -r basename)"
ck "iwlwifi self-heal on for daily use (guard off)" "Y" \
   "$(cat /sys/module/iwlwifi/parameters/fw_restart 2>/dev/null)"
ck "hard-lockup detector (NMI watchdog) armed" "1" "$(sysctl -n kernel.nmi_watchdog 2>/dev/null)"
ck "an oops triggers a panic" "1" "$(sysctl -n kernel.panic_on_oops 2>/dev/null)"
ck "a hard lockup triggers a panic" "1" "$(sysctl -n kernel.hardlockup_panic 2>/dev/null)"
ck "a soft lockup triggers a panic" "1" "$(sysctl -n kernel.softlockup_panic 2>/dev/null)"
ck "a panic then auto-reboots" "20" "$(sysctl -n kernel.panic 2>/dev/null)"
ck "platform watchdog present (iTCO, catches SoC hangs the NMI cannot)" "iTCO_wdt" "$(cat /sys/class/watchdog/watchdog0/identity 2>/dev/null)"
ck "systemd arms the platform watchdog" "30s" "$(systemctl show -p RuntimeWatchdogUSec --value 2>/dev/null)"
ck "recovery sysctls persist on disk (survive a reboot)" "5" \
   "$(grep -cE '^kernel\.(nmi_watchdog|panic_on_oops|hardlockup_panic|softlockup_panic|panic) *=' /etc/sysctl.d/99-gb5-tuning.conf 2>/dev/null)"
ck "watchdog setting persists on disk" "RuntimeWatchdogSec=30s" \
   "$(grep -h '^RuntimeWatchdogSec' /etc/systemd/system.conf.d/50-gb5-watchdog.conf 2>/dev/null)"

hdr "Health"
f=$(systemctl --failed --no-pager --plain --no-legend 2>/dev/null | wc -l)
ck "failed systemd units" "0" "$f"
c=$(coredumpctl list --since "$(uptime -s)" --no-pager 2>/dev/null | grep -c fprintd)
ck "fprintd coredumps this boot" "0" "$c"

emit ""
emit "════════════════════════════════════════"
emit "  PASS $pass    FAIL $fail    NOTE $warn"
emit "════════════════════════════════════════"
[ "$fail" -eq 0 ] || exit 1
exit 0
