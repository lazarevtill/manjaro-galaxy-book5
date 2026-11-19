#!/bin/bash
# Speakers: bind the three amplifiers ACPI never enumerates.
#
# Four MAX98390 amps sit on i2c-2 at 0x38, 0x39, 0x3c, 0x3d — two woofers, two
# tweeters. ACPI declares only the first, and no kernel quirk exists for this
# subsystem ID, so nothing binds and the kernel reports speaker_outs=0. Audio
# routes to the ALC298 pin and dies there.
#
# Two halves: a side-codec driver, and a service that creates the three missing
# I2C devices at boot. Idempotent.

set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
HERE=$(cd "$(dirname "$0")/.." && pwd)

echo "==> DKMS max98390-hda"
if [ "$(dkms status max98390-hda 2>/dev/null | grep -c installed)" -gt 0 ]; then
    echo "    already installed"
else
    pacman -S --needed --noconfirm dkms >/dev/null
    rm -rf /usr/src/max98390-hda-1.0
    cp -r "$HERE/dkms/max98390-hda" /usr/src/max98390-hda-1.0
    dkms add    max98390-hda/1.0 >/dev/null 2>&1 || true
    dkms build  max98390-hda/1.0
    dkms install max98390-hda/1.0 --force
    echo "    built and installed"
fi

echo "==> Service that creates the missing I2C devices"
install -Dm644 "$HERE/systemd/max98390-hda-i2c-setup.service" \
    /etc/systemd/system/max98390-hda-i2c-setup.service
systemctl daemon-reload
systemctl enable --now max98390-hda-i2c-setup.service
echo "    enabled"

echo
n=$(ls /sys/bus/i2c/devices/ 2>/dev/null | grep -cE '^2-00(39|3c|3d)$')
echo "Extra amps bound: $n of 3"
if [ "$n" -lt 3 ]; then
    echo "A reboot is usually needed for all four to come up." >&2
fi
echo
echo "Note: the amps stay powered. The HDA component-master quirk that would idle"
echo "them does not exist upstream, so expect a small constant draw."
