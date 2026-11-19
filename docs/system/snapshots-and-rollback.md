---
name: gb5-snapshots-and-rollback
description: "Snapshot and rollback setup on the Galaxy Book5 — what already worked, the config that silently wasn't doing anything, and why GRUB-era snapshot tooling had to go"
metadata: 
  node_type: memory
  type: project
  originSessionId: 5f6b4d36-2b3c-40e8-8285-72954661d9dd
  modified: 2026-08-21T19:14:32.703Z
---

Reviewed and completed 2026-08-21 on the user's Galaxy Book5 (`GB5`). Root is
btrfs with `@`, `@home`, `@cache`, `@log` subvolumes on `nvme0n1p2`, ~450 GB free.

This matters more here than on a typical machine: it is a rolling distro carrying
**three DKMS modules** (camera sensor, speaker codec, v4l2loopback) plus a
**replaced libfprint**. A kernel update that outruns DKMS takes out the camera,
the speakers and the fingerprint reader at once.

## What was already working — do not "fix" it again

`timeshift-autosnap-manjaro` ships a pacman `PreTransaction` hook at
`/usr/share/libalpm/hooks/00-timeshift-autosnap.hook`, and it has been firing all
along. Snapshots tagged `{timeshift-autosnap} {created before upgrade}` exist.

**The trap:** `/etc/timeshift/timeshift.json` said `"btrfs_mode": "false"`, which
looks like Timeshift is doing rsync backups. It is not — that file was the
untouched distro default (dated 8 January, never written by Timeshift), and the
CLI autodetects btrfs. `timeshift --list` reporting `Mode : BTRFS` is the
authoritative answer, not the config file. A wrong conclusion was drawn from that
file before checking the runtime.

## What was actually missing, now set

- **No time-based snapshots.** Only package upgrades created restore points, so
  nothing covered a config change, a manual edit or a DKMS rebuild. `schedule_boot`
  and `schedule_daily` enabled (5 kept each).
- **The schedules could never have fired.** Timeshift creates its cron entries
  only when `timeshift --check` runs with schedules on — editing the JSON alone
  does nothing. Running it created `/etc/cron.d/timeshift-hourly` and
  `timeshift-boot`. `cronie` is enabled.
- **`btrfs_mode` pinned to true**, so opening the GUI cannot write the default
  back and silently switch to rsync — a full copy of a 468 GB root is a very
  different proposition to CoW snapshots.

## GRUB-era tooling removed

`grub-btrfs` generated snapshot entries for a GRUB menu this machine no longer
boots (systemd-boot is the chooser, see [[gb5-secureboot-uki]]). Removed, along
with `os-prober`; nothing depended on either. `grub` itself is kept as a
Secure-Boot-off rescue. `updateGrub=false` set in `/etc/timeshift-autosnap.conf`
so the hook stops calling a GRUB update that does nothing.

**Consequence worth knowing:** there is no boot-menu rollback any more. Restoring
is done from Timeshift itself (`timeshift --restore`, or the GUI), which swaps
the subvolume and reboots. That works without GRUB, but it means recovering from
a system that will not boot needs live media rather than a menu entry.

## Related

[[gb5-galaxybook5-hw-setup]] lists what breaks silently if reverted — that list is
exactly what these snapshots protect.


## Hibernation interacts with rollback, dangerously

Two things this document did not previously mention.

**A stale hibernation image will be restored over your rolled-back filesystem.**
Restoring a snapshot does not resume, so `@` is modified while an image still
sits in the swapfile waiting — and the next normal boot restores it on top.
**Before any restore:**

```bash
swapoff /swap/swapfile && mkswap /swap/swapfile && swapon /swap/swapfile
```

**A restore rolls back `/boot` but not the ESP.** `/boot` lives inside `@`, so a
restore reverts `/boot/vmlinuz-*` and `/usr/lib/modules/*` — but the thing that
actually boots is the UKI on the vfat ESP, which Timeshift never touches.
Restore across a kernel version bump and the **new** kernel boots against a tree
holding only the **old** modules: no i915, no Wi-Fi, and none of the three DKMS
modules. Recovery needs live media.

After any restore, before rebooting:

```bash
mkinitcpio -P && sbctl sign-all && sbctl verify
```

That is the rolling-distro-with-DKMS case these snapshots exist for, so it is
worth having in muscle memory.
