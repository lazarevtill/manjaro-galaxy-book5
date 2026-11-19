#!/bin/bash
# Docker, laid out so it cannot poison this machine's snapshots.
#
# The whole point is /var/lib/docker on its OWN btrfs subvolume. Left in @, image
# layers go into every Timeshift snapshot -- tens of GB each -- and a restore
# rolls container state back together with the system. containerd's root is moved
# alongside it for the same reason, and because Docker 29 makes the containerd
# image store the default: flip features.containerd-snapshotter and the entire
# image store silently relocates to /var/lib/containerd, back inside @.
#
# Rootful and socket-activated: the daemon costs nothing until first use, but
# membership in the 'docker' group IS root-equivalent. See docs/system/docker.md.
#
# Idempotent. Requires the root filesystem to be btrfs.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
USER_NAME="${GB5_USER:-lazarevtill}"

[ "$(id -u)" -eq 0 ] || { echo "run as root"; exit 1; }
[ "$(findmnt -no FSTYPE /)" = "btrfs" ] || { echo "root is not btrfs; this layout does not apply"; exit 1; }

ROOTDEV=$(findmnt -no SOURCE / | sed 's/\[.*//')
UUID=$(blkid -s UUID -o value "$ROOTDEV")

echo "==> @docker subvolume"
mkdir -p /mnt/btrfs-top
mountpoint -q /mnt/btrfs-top || mount -o subvolid=5 "$ROOTDEV" /mnt/btrfs-top
# grep -c, never grep -q in a pipeline under pipefail: a matching grep -q exits
# early, SIGPIPEs the producer, and inverts the test. See AGENTS.md.
if [ "$(btrfs subvolume list /mnt/btrfs-top | grep -c ' @docker$')" -gt 0 ]; then
    echo "    already exists"
else
    btrfs subvolume create /mnt/btrfs-top/@docker
fi
umount /mnt/btrfs-top && rmdir /mnt/btrfs-top

echo "==> fstab"
mkdir -p /var/lib/docker
if [ "$(grep -c '/var/lib/docker' /etc/fstab)" -gt 0 ]; then
    echo "    entry present"
else
    cp /etc/fstab "/etc/fstab.bak-$(date +%Y%m%d%H%M%S)"
    cat >> /etc/fstab <<FSTAB

# Docker's image and container store on its own btrfs subvolume, a sibling of @,
# so Timeshift's snapshots never capture image layers. 'nofail' keeps a mount
# problem from dropping the machine into emergency mode; the pairing is the
# docker.service drop-in below, so Docker REFUSES to start rather than silently
# writing into @ instead.
UUID=$UUID  /var/lib/docker  btrfs  subvol=@docker,noatime,compress=zstd:1,nofail  0 0
FSTAB
fi
findmnt --verify --fstab >/dev/null || { echo "fstab failed validation -- not mounting"; exit 1; }
systemctl daemon-reload
mountpoint -q /var/lib/docker || mount /var/lib/docker
chmod 710 /var/lib/docker

echo "==> nodatacow for volumes"
# Databases in containers are the classic btrfs fragmentation case. +C only
# takes effect on a directory that is still EMPTY, so this must happen before
# Docker ever runs. It also disables checksums for that subtree -- the accepted
# trade, since backups are those volumes' only integrity story either way.
mkdir -p /var/lib/docker/volumes && chmod 700 /var/lib/docker/volumes
lsattr -d /var/lib/docker/volumes 2>/dev/null | grep -q C || chattr +C /var/lib/docker/volumes || true

echo "==> packages"
pacman -S --needed --noconfirm docker docker-compose docker-buildx pigz compsize

echo "==> configuration"
install -Dm644 "$REPO/docker/daemon.json"     /etc/docker/daemon.json
install -Dm644 "$REPO/docker/daemon.json.why" /etc/docker/daemon.json.why
install -Dm644 "$REPO/docker/containerd-config.toml" /etc/containerd/config.toml
install -Dm644 "$REPO/docker/docker.service.d-gb5-storage.conf"     /etc/systemd/system/docker.service.d/gb5-storage.conf
install -Dm644 "$REPO/docker/containerd.service.d-gb5-storage.conf" /etc/systemd/system/containerd.service.d/gb5-storage.conf
install -Dm755 "$REPO/tools/gb5-docker-preflight" /usr/local/sbin/gb5-docker-preflight
install -Dm755 "$REPO/tools/gb5-docker-verify"    /usr/local/sbin/gb5-docker-verify

# The pinned container DNS is this host's own VPN address and is NOT portable.
pinned=$(python3 -c "import json;print((json.load(open('/etc/docker/daemon.json')).get('dns') or [''])[0])" 2>/dev/null || true)
live=$(ip -4 -o addr show wt0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 || true)
if [ -n "$pinned" ] && [ -n "$live" ] && [ "$pinned" != "$live" ]; then
    echo "    WARNING: daemon.json pins container DNS to $pinned but wt0 is $live."
    echo "             Containers will have no DNS. Edit /etc/docker/daemon.json."
fi

dockerd --validate --config-file /etc/docker/daemon.json

echo "==> lifecycle (socket activation, daemon off until first use)"
systemctl daemon-reload
systemctl enable docker.socket
systemctl disable docker.service containerd.service 2>/dev/null || true
id -nG "$USER_NAME" 2>/dev/null | grep -qw docker || gpasswd -a "$USER_NAME" docker

echo
echo "Done. '$USER_NAME' must log out and back in for the docker group to apply."
echo "Verify with:  sudo gb5-docker-verify"
