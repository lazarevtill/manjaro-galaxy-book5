#!/bin/bash
# Fingerprint: an SDCP-capable libfprint, three local fixes, and PAM wiring.
#
# Stock libfprint does not carry EgisTec match-on-chip readers like 1c7a:05a5.
# The SDCP fork does. Three problems on top of that, all fixed in the PKGBUILD's
# prepare() and all of which look like broken hardware:
#
#   1. egismoc_close() never clears task_ssm, so any verify that times out kills
#      fprintd with SIGABRT on the next open. Every ignored prompt took the
#      daemon down.
#   2. The SDCP claim is scoped to the kernel boot_id, so every boot mints a new
#      host keypair, the sensor disowns the templates, and fprintd prunes them.
#      Enrolments never survived a reboot.
#   3. A successful match was reported as a failure: the driver reports the
#      result, libfprint cancels the in-flight command, and the resulting error
#      discards the result that had already been reported.
#
# This REPLACES the system libfprint. Idempotent.

set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
HERE=$(cd "$(dirname "$0")/.." && pwd)
U=${SUDO_USER:?run with sudo, not as a root login — makepkg refuses to run as root}
HOME_U=$(getent passwd "$U" | cut -d: -f6)
BUILD="$HOME_U/.cache/gb5-build/fpaur"

echo "==> Packages"
pacman -S --needed --noconfirm base-devel git fprintd >/dev/null
echo "    ok"

echo "==> Build the patched libfprint"
if pacman -Q libfprint-egismoc-sdcp-git >/dev/null 2>&1; then
    echo "    already installed: $(pacman -Q libfprint-egismoc-sdcp-git)"
else
    sudo -u "$U" mkdir -p "$BUILD"
    cp "$HERE/packaging/libfprint/PKGBUILD" "$BUILD/PKGBUILD"
    chown "$U:$U" "$BUILD/PKGBUILD"
    ( cd "$BUILD" && sudo -u "$U" makepkg -si --noconfirm --nocheck )
    echo "    installed"
fi

echo "==> Keep the reader awake"
# Not a power saving worth having: libfprint's own autosuspend database lists
# this ID only in its known-but-unsupported block, so upstream never validated
# it here, and the saving is a few milliwatts on a device you authenticate with
# all day.
cat > /etc/udev/rules.d/99-gb5-fprint-power.rules <<'EOF'
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="1c7a", ATTR{idProduct}=="05a5", TEST=="power/control", ATTR{power/control}="on"
EOF
udevadm control --reload
echo "    ok"

echo "==> PAM"
# -auth sufficient: the leading dash skips a missing module instead of failing,
# and sufficient means a failed scan falls straight through to your password.
for svc in sddm login sudo polkit-1; do
    f=/etc/pam.d/$svc
    [ -f "$f" ] || { echo "    $svc: absent, skipped"; continue; }
    if grep -q pam_fprintd "$f"; then echo "    $svc: already wired"; continue; fi
    cp "$f" "$f.bak-$(date +%F)"
    # Insert AFTER any requisite gate rather than before the first auth line.
    # /etc/pam.d/login begins with pam_nologin, and inserting above it let
    # fingerprint auth bypass /etc/nologin entirely. It also produced a file
    # different from the one this repo ships in pam/.
    if grep -qE '^auth\s+requisite' "$f"; then
        sed -i '0,/^auth\s\+requisite.*/s//&\n-auth      sufficient pam_fprintd.so max-tries=5 timeout=45/' "$f"
    else
        sed -i '0,/^auth/s//-auth      sufficient pam_fprintd.so max-tries=5 timeout=45\nauth/' "$f"
    fi
    echo "    $svc: added (backup at $f.bak-$(date +%F))"
done

# The Plasma lock screen is the one that matters most -- it is where most
# fingerprint verifies happen -- and it was missed the first time round. It
# authenticates through /usr/lib/pam.d/kde-fingerprint, a VENDOR file, so it
# needs an override in /etc rather than an edit that a package update reverts.
#
# Note this stack is 'required', not 'sufficient': the '-' prefix only suppresses
# the missing-module log line, it does NOT make the stack skip a module that
# cannot load. That is safe here because Plasma runs this backend beside the
# password stack, but do not copy the pattern somewhere it would short-circuit.
if [ -f /usr/lib/pam.d/kde-fingerprint ] && [ ! -f /etc/pam.d/kde-fingerprint ]; then
    install -Dm644 "$HERE/config/pam/kde-fingerprint" /etc/pam.d/kde-fingerprint
    echo "    kde-fingerprint: override installed (lock screen)"
else
    echo "    kde-fingerprint: already present or vendor file absent — left alone"
fi

echo
echo "Done. Enrol with:"
echo "  fprintd-enroll -f right-index-finger"
echo
echo "Verify it survives a reboot — that is the whole point of fix 2:"
echo "  gb5-test-sdcp-persistence.sh arm    # then touch the sensor"
echo "  gb5-test-sdcp-persistence.sh check"
echo
echo "Two things that mislead while debugging this:"
echo "  fprintd-list reads fprintd's record, NOT the sensor. It will list fingers"
echo "  the device has forgotten; the two reconcile only when a match FAILS."
echo "  And a successful verify logs nothing, so an empty log proves nothing."
