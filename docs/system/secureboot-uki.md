---
name: gb5-secureboot-uki
description: "Secure Boot on the user's Galaxy Book5 runs off a signed UKI, not GRUB — why GRUB cannot work, and the boot-order footguns that make it look bricked"
metadata: 
  node_type: memory
  type: project
  originSessionId: 5f6b4d36-2b3c-40e8-8285-72954661d9dd
  modified: 2026-08-19T21:38:32.362Z
---

On `GB5` (see [[gb5-galaxybook5-hw-setup]]), Secure Boot uses a **signed Unified Kernel
Image booted directly by firmware**. GRUB is kept only as a Secure-Boot-OFF rescue path.

**GRUB cannot work under Secure Boot here — settled, do not retry.** With SB ON, GRUB
2:2.14 dies at `kern/verifiers.c:grub_verifiers_open:119: verification requested but
nobody cares: .../normal.mod` -> grub rescue. This happens EVEN THOUGH the image carries
the `--disable-shim-lock` marker. Two dead-end diagnostics to avoid repeating:
- `strings … | grep shim_lock` proves NOTHING — those strings are present either way.
  The real test is parsing the PE `mods` section for module type 7.
- `grub-core/kern/efi/sb.c` fetched from `rhboot/grub2` is Red Hat's DOWNSTREAM fork and
  does NOT describe Manjaro's GRUB. Reading it produced a confidently wrong conclusion.
The observed boot failure overrules both. No shim is installed.

**The UKI setup**
- `/boot/efi/EFI/Linux/manjaro-7.1-x86_64.efi` (~44 MB), built by mkinitcpio 41 via
  `default_uki=` in `/etc/mkinitcpio.d/linux71.preset`, cmdline from `/etc/kernel/cmdline`,
  auto-signed by `/usr/lib/initcpio/post/sbctl`, tracked in `/var/lib/sbctl/files.json`.
- Verified good: `.linux` byte-identical to `/boot/vmlinuz-7.1-x86_64`, `.initrd` identical
  to the initramfs, Intel microcode rev 0x121 present in the early CPIO, signer
  `CN=Database Key` matching the live firmware `db`.
- `/etc/pacman.d/hooks/95-gb5-ensure-uki.hook` + `/usr/local/sbin/gb5-ensure-uki.sh` add
  `default_uki=` to any NEW kernel series' preset (the mkinitcpio template has it
  commented out and pointing at `/efi`, which does not exist here) and warn if a UKI has
  no EFI boot entry.

**Three footguns that were fixed — do not reintroduce**
1. `99-grub-disable-shim-lock.hook` originally ran `grub-install` WITHOUT `--no-nvram`,
   which moves GRUB to the head of BootOrder on every grub upgrade. Now has `--no-nvram`.
2. BootOrder is `0002,0000` (UKI, Windows). GRUB entries 0001/0003 are deliberately NOT
   in the order: under SB the firmware LOADS them fine and they then die at grub rescue —
   there is no graceful fallthrough.
3. `\EFI\BOOT\BOOTX64.EFI` (the NVRAM-reset fallback) was a GRUB copy; it now holds a
   signed copy of the UKI, so every fallback path lands in a working system. The grub hook
   no longer copies GRUB over it.

**Open items**
- `dbx` is EMPTY — only `dbxDefault` exists, so the firmware enforces zero revocations.
  Strictly less protected than factory Secure Boot. Enroll the UEFI revocation list once
  the UKI is proven to boot.
- Do NOT enable the mkinitcpio fallback preset: a fallback UKI measured ~239 MB against a
  300 MB ESP.
- The sbctl mkinitcpio post hook exits 0 when keys are missing, so a `mkinitcpio`- or
  `linux-firmware`-only upgrade can leave an UNSIGNED UKI with pacman reporting success.
  Run `sbctl verify` after every `pacman -Syu` before rebooting.
- `objcopy` unlinks and recreates the UKI in place, so the old good image is gone during
  the rebuild; a 0-byte file is what ENOSPC leaves behind. `\EFI\BOOT\BOOTX64.EFI` doubles
  as the frozen known-good copy.
- Samsung Knox "BIOS Configuration Recovery" may revert enrolled keys after a BIOS update;
  keys backed up at `/root/sbctl-keys-backup-2026-08-19.tar.gz` and on the Windows partition.
- Secure Boot does NOT break the DKMS modules: `CONFIG_LOCK_DOWN_KERNEL_FORCE_NONE=y`, no
  `CONFIG_LOCK_DOWN_IN_EFI_SECURE_BOOT`, `sig_enforce=N`.

2026-08-20: the UKI was PROVEN to boot, with Secure Boot still off (BootCurrent=0002,
no BOOT_IMAGE= in /proc/cmdline, systemd-stub 261.2 running, "Measured UKI: yes").
Full verification: 55 PASS / 0 FAIL. Fingerprint enrolment survived that reboot, so the
earlier loss was the BIOS key work resetting the sensor, not the driver.
That step is now done — see the DONE entry at the end of this note.

gb5-verify.sh gotcha: display checks MUST be scoped to eDP-1. `kscreen-doctor -o | grep -m1`
reads whichever output is listed first, which becomes an external monitor the moment one
is plugged in — that produced four bogus "incapable" failures.

TRAP (bit me 2026-08-20): the Windows NTFS volume at
/run/media/lazarevtill/FC06AA6106AA1D20 is auto-mounted by udisks and can be unmounted at
any time. Writing to that path while it is UNMOUNTED silently creates a shadow directory
on tmpfs (/run), which then MASKS the real mountpoint — the files look written, survive
nothing, and the real contents appear to have vanished. Always
`findmnt /run/media/lazarevtill/<UUID>` before writing there; if unmounted, remount with
`udisksctl mount -b /dev/nvme0n1p3` rather than writing to the bare path. Nothing was lost
when this happened; the originals were safe on the unmounted volume.

DONE 2026-08-20: Secure Boot is ENABLED (user mode), booting the UKI (BootCurrent 0002,
Measured UKI: yes). 62 checks, 0 failures. Everything survived — Windows untouched, both
fingerprints still enrolled (so the earlier enrolment loss was the key-clearing step, not
merely toggling Secure Boot), and all three DKMS modules still load.

No OS chooser exists any more and that is correct, not a fault: firmware Timeout=0, GRUB is
out of BootOrder, and a firmware-launched UKI has no menu. Windows is reached with F10.
`systemd-boot` is the clean way to get a menu back if ever wanted.

Order that worked: build+sign UKI (SB off) -> BIOS CLEAR keys (= Setup Mode; enroll nothing
in BIOS) -> `sbctl enroll-keys -m -f` -> boot the UKI once with SB still off -> BIOS SB on.
Enabling SB before enrolling fails every Linux entry; that was the first false start.

Passkeys (asked 2026-08-20): CANNOT be stored on-device. Linux has no platform
authenticator, so device-bound passkeys are impossible despite a working TPM 2.0. Firefox
on Linux does USB security keys only; Chromium is broader. Options are a password manager,
a hardware key, or tpm-fido (Chromium-only, unpackaged). Native support was on the FOSDEM
2026 roadmap but is not shipping. The user deferred deciding.

systemd-boot added 2026-08-20 as the OS chooser (menu was absent because a
firmware-launched UKI has none). `bootctl install`, then **sign it immediately** —
Secure Boot is on: `/boot/efi/EFI/systemd/systemd-bootx64.efi` and
`/boot/efi/EFI/BOOT/BOOTX64.EFI`. Config `/boot/efi/loader/loader.conf`
(default manjaro-*.efi, timeout 5, editor no, auto-firmware no). BootOrder = 0006 (Linux Boot Manager),
0002 (UKI direct), 0000 (Windows firmware entry) — a three-deep fallback chain.

`bootctl install` REPLACED the UKI copy at \EFI\BOOT\BOOTX64.EFI with systemd-boot.
That is an improvement (fallback now yields a menu), but it means the "frozen known-good
UKI" role is gone; the backup lives at /root/bootx64.efi.uki-fallback.bak.

WINDOWS ON A SEPARATE ESP: systemd-boot only auto-discovers on the partition it booted
from (`man loader.conf`: "found on the boot partition"), so Windows on nvme0n1p1 was
invisible. Fixed by MIRRORING \EFI\Microsoft (32 MB) onto the Linux ESP — the binary has
`config_add_entry_windows`, so it is then detected with no hand-written entry. The mirror
is a COPY and goes STALE on Windows updates; refresh with
`/usr/local/sbin/gb5-refresh-windows-boot.sh` (compares sha256, keeps a rollback copy).
Symptom of staleness: the menu's Windows entry fails (often 0xc000000f) while the firmware
entry still boots Windows fine.

`sbctl verify` now reports ~116 "not signed" files under /EFI/Microsoft. That is EXPECTED —
they are Microsoft-signed and validate via the MS certs in db; sbctl only means "not signed
by our key". gb5-verify.sh excludes that path. Suite is 70 checks.



## The menu preselected the BIOS, not Manjaro (fixed 2026-08-21)

`LoaderEntryPreferred` in efivars read `auto-reboot-to-firmware-setup`, so a hands-off
boot counted down into the firmware setup screen instead of Manjaro. Three layers now
guard against it, deliberately belt-and-braces because the boot-time selection cannot be
tested from a running system:

1. `LoaderEntryDefault` EFI variable, set with `bootctl set-default
   manjaro-7.1-x86_64.efi`. This outranks loader.conf.
2. `default manjaro-*.efi` in loader.conf, as a fallback whose glob keeps working after a
   kernel series bump when the literal ID above goes stale.
3. `auto-firmware no` in loader.conf, which removes the offending pseudo-entry from the
   menu entirely. The firmware is still reachable: tap F2 at power on, or
   `systemctl reboot --firmware-setup`.

`gb5-ensure-uki.sh` now re-points `LoaderEntryDefault` at the newest UKI after a kernel
update, so layer 1 does not rot.

**`bootctl list` output is one boot stale.** Its entry list comes from the `LoaderEntries`
EFI variable that systemd-boot wrote during the *last* boot, not from the current
loader.conf. Editing loader.conf and re-running `bootctl` shows no change, and
`isDefault` keeps naming whatever last boot preferred. Do not read that as the edit having
failed — it only means the config has not been through a boot yet. This wasted real time
during diagnosis.

## The two NVMe drives do not enumerate in a stable order

`nvme0n1` was the Windows disk on one boot and the Linux disk on the next; the Linux ESP
moved from `nvme1n1p1` to `nvme0n1p1` across a single reboot. Anything that hardcodes
`/dev/nvmeXn1pY` is a coin flip. Two scripts had this bug and were fixed to look the
device up at runtime:

- `gb5-refresh-windows-boot.sh` now probes every vfat partition other than the booted ESP
  and takes the one holding `bootmgfw.efi`.
- `gb5-ensure-uki.sh` derives the disk and partition for its `efibootmgr` hint from
  `findmnt /boot/efi`.

Use PARTUUID or `findmnt` in anything new. The ESP's PARTUUID is stable:
`2368ea8a-5baf-44ae-962b-8b5f482fc9e5`.

## dbx is empty, and fwupd's "up to date" means nothing (checked 2026-08-21)

There is no `dbx` variable at all — only `dbxDefault` (17840 bytes), the
firmware's default list, which is not enforced until enrolled. So Secure Boot
here enforces **zero revocations**: a Microsoft-signed but known-vulnerable
bootloader would still validate, and Microsoft's certificate is in `db` because
Windows needs it. That is the real gap.

`fwupdmgr` reports "UEFI dbx: latest available firmware version". Ignore it. The
device's `Version` reads `None` because the variable does not exist, and the
device carries `only-version-upgrade` — with nothing to compare against, fwupd
offers nothing. It is not telling you dbx is current; it is telling you it cannot
tell.

**Before enrolling, check nothing that boots would be revoked.**
`gb5-dbx-check.sh` does this: it fetches Microsoft's current DBXUpdate, parses
the signature lists, and hashes every bootable image the way UEFI does —
**Authenticode**, not plain `sha256sum`, which is the distinction that makes the
comparison meaningful. Result on 2026-08-21:

    443 revoked image hashes, 0 revoked certificates
      ok  bootmgfw.efi           96da0da4...
      ok  systemd-bootx64.efi    e424095f...
      ok  manjaro-7.1-x86_64.efi 384b8c16...
      ok  grubx64.efi            96241d5d...
    SAFE — nothing that boots here is on the revocation list

Zero certificate revocations in the current list means a hash check is complete:
nothing can be revoked via its signer instead. Microsoft's KEK is present in our
KEK, so their pre-signed update would authenticate.

Not enrolled yet — it is close to irreversible. Undoing it means restoring
firmware default keys, which also wipes the custom PK/KEK/db and means redoing
the whole Secure Boot setup. Re-run the check before ever enrolling; a future
list could contain certificate revocations, and then hashes alone are not enough.
