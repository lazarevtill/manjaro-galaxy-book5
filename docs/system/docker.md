# Docker on the Galaxy Book5

Rootful Docker, socket-activated, with its data on a btrfs subvolume that
Timeshift does not snapshot. Reviewed by two independent agents; what they found
is recorded here because most of it is invisible until it bites.

## The one that would have been a security incident

`-p 8080:80` binds `0.0.0.0` by default. Docker inserts its `DOCKER-FORWARD`
jump at the **top** of the FORWARD chain, and NetBird's only inbound guard is
`-A FORWARD -i wt0 -j DROP` — the **last** rule. Verified live:

    -A FORWARD -i wt0 -j NETBIRD-RT-FWD-IN
    -A FORWARD -m mark --mark 0x1bd20 -j ACCEPT
    -A FORWARD -o wt0 -j NETBIRD-RT-FWD-OUT
    -A FORWARD -i wt0 -j DROP          <-- never reached for published ports

So every published port would have been reachable from all of `100.76.0.0/16`
and from the LAN. Fixed with `"ip": "127.0.0.1"` in `daemon.json`: exposure is
now opt-in per port (`-p 0.0.0.0:8080:80` when you mean it).

## Storage layout

`/var/lib/docker` is the `@docker` btrfs subvolume, a sibling of `@`, so
Timeshift's snapshots of `@` never contain image layers. Without this, tens of
GB land in every snapshot and a restore rolls container state back with the
system.

Three things hold that in place, and they cover each other's blind spots:

| Guard | Catches |
|---|---|
| `nofail` in fstab | a mount problem cannot drop the laptop into emergency mode |
| `RequiresMountsFor=` drop-in | the mount unit exists but failed |
| `gb5-docker-preflight` | the fstab line is **missing entirely** — then no mount unit exists for systemd to require |

`containerd`'s root is redirected to `/var/lib/docker/containerd-root` for the
same reason. Its default `/var/lib/containerd` is inside `@`. Today that is only
megabytes of task metadata — but Docker 29 makes the containerd image store the
**default**, and only the explicit `containerd-snapshotter: false` pins it off.
Flip that flag with containerd's root at its default and the entire image store
silently moves back inside `@`, where the preflight guard cannot see it.

`volumes/` has `chattr +C` (nodatacow), set while empty so it is inherited.
Database files in containers are the classic btrfs fragmentation case. The
trade-off, stated: nodatacow also disables checksums, so `btrfs scrub` cannot
detect corruption in exactly those volumes. Backups are their only integrity
story.

## Container DNS — the reviewers disagreed, and reality settled it

NetBird owns `/etc/resolv.conf` and points it at `100.76.231.97`, which is this
host's **own wt0 address**. Docker copies resolv.conf into containers at start
and refreshes it only on restart, so inheriting it is wrong in both directions:

* container started while the VPN is **down** bakes in the LAN resolver for life;
* container started while it is **up** keeps querying a dead address after
  NetBird drops.

So DNS is pinned in `daemon.json`, not inherited. One reviewer wanted a public
fallback so containers survive the VPN dropping; the other said that leaks
`*.in.vpn` lookups. It shipped with **no fallback** — and then two facts changed
the answer:

1. **NetBird already forwards `[.]` to `1.1.1.1` itself.** Confirmed with
   `netbird status -d`:

        [1.1.1.1:53, 1.0.0.1:53]                for [.]
        [192.168.100.200:53, 100.76.162.191:53] for [in.lazarev.cloud, lazarev.cloud]

   Public queries reach Cloudflare by design. While the VPN is up the fallback is
   never consulted, because the first resolver answers.
2. **On 2026-08-23 the VPN was down for over two hours.** With no fallback every
   container had zero DNS for that entire window — no builds, no pulls.

Current setting: `["100.76.231.97", "1.1.1.1", "1.0.0.1"]`. The residual leak is
narrow — internal hostnames hitting NXDOMAIN at Cloudflare while the VPN is down,
when those services are unreachable anyway. Drop the last two entries to return
to the strict position.

Neither reviewer caught the real fragility: the **first** entry is a dynamic
address. If NetBird reassigns this peer's IP, internal names silently resolve via
Cloudflare instead of failing loudly. `gb5-docker-verify` compares it against
`wt0` and FAILs on drift.

## Things deliberately NOT done

* **No idle-stop timer for dockerd.** Idle cost is ~0.1 W against a 6.22 W
  baseline. One gauge step is 0.795 Wh, so resolving 1.6% needs ~60 steps ≈ 7.7 h
  **per arm** — below the noise floor. Socket activation already captures the
  win that exists: zero cost on days Docker is never used. Also, `live-restore`
  means stopping dockerd leaves containers running but unmanaged, and the
  `containerd-shim` processes stay resident anyway.
* **No CPU pinning away from the LP-E cores.** `intel_pstate` is active with
  `hwp` and **`hfi`**, so the kernel already gets per-core efficiency hints and
  ITMT prefers P-cores. Note that `taskset` on the client does nothing — builds
  run in dockerd's cgroup. It would have to be
  `systemctl set-property docker.service AllowedCPUs=0-13`.
* **No nftables firewall backend.** `iptables` here is already v1.8.13
  (nf_tables), so Docker and NetBird share one backend through one compat layer.
  Switching would put Docker's rules in a different rule universe from NetBird's.

## GPU and NPU in containers — tested, not theorised

Both work. `config/docker/accel-base.Dockerfile` builds the base; all three OpenVINO
devices enumerate inside a container:

    CPU   Intel(R) Core(TM) Ultra 7 255H
    GPU   Intel(R) Arc(TM) Graphics (iGPU)
    NPU   Intel(R) AI Boost

and a real VA-API H.264 encode runs at 6.7x realtime.

Never hardcode the group id. Two udev rules conflict over `accel` — systemd's
`50-udev-default.rules` and intel-npu-driver's `10-intel-npu.rules` — so the
modes are not stable across updates. Today `renderD128` is 0666 and `accel0` is
0660. Derive it instead:

    docker run --rm \
      --device /dev/dri/renderD128 --device /dev/accel/accel0 \
      --group-add "$(stat -c %g /dev/dri/renderD128)" \
      --group-add "$(stat -c %g /dev/accel/accel0)" \
      gb5/accel-base:1 <cmd>

`--group-add <numeric gid>` does not require the group to exist in the
container, which is the clean answer to host-987 vs whatever the image uses.
Do not use `--privileged`, do not mount all of `/dev/dri` (that adds `card1`,
the modeset node), and do not use `--gpus` — that is the NVIDIA/CDI path.

### Three ways this fails silently, all hit while testing

1. **A distro image's media driver is too old for this silicon.**
   `jrottenberg/ffmpeg:7-vaapi` (Ubuntu 24.04) fails with
   `Failed to initialise VAAPI connection: -1 (unknown libva error)`, which reads
   like a permissions problem and is not — the driver does not know PCI
   `8086:7D51`. Tracking the host's own Arch packages makes the container's iHD
   the same 26.2.4 the host runs.
2. **The OpenVINO GPU and NPU plugins are SEPARATE Arch packages.** Install only
   `openvino` and `Core().available_devices` returns `['CPU']` — no error, no
   warning, no hint. You need `openvino-intel-gpu-plugin` and
   `openvino-intel-npu-plugin`. This is the same trap that bit the NPU camera
   work earlier in this project.
3. **NPU user-mode/kernel-mode skew.** The container ships `libze_intel_npu`;
   the host provides the `intel_vpu` kernel driver. A much older UMD fails to
   enumerate against a newer KMD. Arch packages `intel-npu-driver` at the host's
   exact version, so they match by construction. The iGPU tolerates skew; the
   NPU does not.

Also worth knowing: this box is on **i915**, not `xe`. Images or tools that
check for the `xe` DRM driver will fail, and tutorials increasingly assume it.
The NPU is 3720 (Meteor Lake), not 4000, and the iGPU is 5.62x its throughput —
default to GPU, use the NPU for sustained low-power inference.

## Gotcha that cost a VPN outage

Between a kernel upgrade and the reboot, `/usr/lib/modules/$(uname -r)` is
deleted. `nft_ct`, `nft_fib_ipv4` and `nft_masq` then cannot load, and **NetBird
dies on any restart** with:

    init firewall: router init: create containers: initialize tables:
    conn.Receive: netlink receive: no such file or directory

The running daemon survives only because it started before the upgrade. This is
not version-specific — 0.77.0 and 0.77.1 fail identically — and no flag avoids
it (`--disable-firewall`, `NB_FORCE_USERSPACE_FIREWALLS` are both too late; the
firewall manager is constructed first). **After a kernel update, do not restart
NetBird until you have rebooted.** Docker has the same dependency, which is why
`gb5-docker-preflight` checks `modprobe -n overlay` and says "reboot first"
instead of letting dockerd fail with an opaque storage-driver error.

## Verify

    sudo gb5-docker-verify

Reads state back rather than trusting exit codes, in the style of
`gb5-verify.sh`. Rationale for every `daemon.json` setting is in
`/etc/docker/daemon.json.why` — Docker rejects unknown keys, so it cannot live
in the JSON.

## Measured, not assumed

`compress=zstd:1` on `@docker`, against a real image store:

    Processed 45822 files
    Type       Perc     Disk Usage   Uncompressed
    TOTAL       58%      2.3G         4.0G
    none       100%      1.4G         1.4G
    zstd        35%      950M         2.6G

**1.72x overall**, 2.74x on the portion btrfs chose to compress; the other 1.4 GB
is already-compressed content it correctly left alone. A review predicted
1.5-2.2x and set "under 1.15 means revisit" — so compression stays, and raising
the level is not worth the write-burst CPU when space is not the constraint.

`volumes/` reports 100% `none`, confirming nodatacow is doing what it should
there. Re-measure any time with `sudo compsize /var/lib/docker`.

## Recovering a deleted module tree without rebooting

A kernel upgrade deletes `/usr/lib/modules/$(uname -r)` while that kernel is
still running. Everything that needs to load a *new* module then fails: Docker
(overlay, br_netfilter, veth, bridge) and NetBird (nft_ct, nft_fib_ipv4,
nft_masq). The running daemons survive only until something restarts them.

The tree is not gone. Every Timeshift snapshot taken before the upgrade still
has it, and those are byte-identical to what was deleted:

    sudo mount -o subvolid=5,ro /dev/nvme1n1p2 /mnt/btrfs-top
    SNAP=/mnt/btrfs-top/timeshift-btrfs/snapshots/<pre-upgrade>/@/usr/lib/modules/<running>

Verify before trusting it — the vermagic must match `/proc/version` exactly:

    modinfo -F vermagic "$SNAP/kernel/net/netfilter/nft_ct.ko.zst"
    # -> 7.1.8-1-MANJARO SMP preempt mod_unload

Then restore and rebuild the dependency index:

    sudo cp -a "$SNAP" /usr/lib/modules/
    sudo depmod -a <running>
    sudo umount /mnt/btrfs-top

This is safe because the files are the originals for the running kernel, not
modules from a different build. It is **not** forcing a version mismatch.

### The trap this creates

Restoring the tree makes a pending reboot **invisible** to anything that tests
for the directory's absence. Four places did exactly that: `gb5-verify.sh`,
`gb5-safe-update`, `gb5-unmask-hibernate.service`, and (by comment only)
`gb5-docker-preflight`. Left alone, `gb5-safe-update` would have happily stacked
a second kernel upgrade on top of an unrebooted one, and hibernation would have
been unmasked while a stale-kernel image could still be written.

They now compare **kernel versions** — running vs newest installed — which is
the real signal and cannot be faked by putting files back.

### After the reboot

The restored tree becomes 350 MB of stale files inside `@`, so it lands in every
snapshot from then on. `gb5-verify.sh` emits a NOTE about it. Remove it:

    sudo rm -rf /usr/lib/modules/<old-kernel>

### Why the reboot is still required

The DKMS modules (camera, speakers, v4l2loopback) are built only for the new
kernel, and the signed UKI boots it. Restoring the old tree buys a working
machine now; it does not make the old kernel the right one to be running.
