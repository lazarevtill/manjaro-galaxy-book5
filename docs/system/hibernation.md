# Hibernation

Working as of 2026-08-23. It was not before, and the way it failed is worth
keeping.

## Read this before enabling hibernation: it writes your RAM to disk in the clear

**This disk is not encrypted.** There is no LUKS anywhere on the machine — root
is plain btrfs. Enabling hibernation therefore means that every time you
hibernate, **up to 12.5 GB of RAM contents is written to `/swap/swapfile`
unencrypted and stays there until overwritten.**

That image contains whatever was resident: browser sessions and cookies,
SSH agent keys, decrypted password-manager state, and the SDCP fingerprint host
private key. Anyone who can read the disk — someone who takes the laptop, or
boots it from USB — can read all of it. Secure Boot does not help; it verifies
what boots, not what is stored.

**This is a real change to the machine's at-rest security posture and it was
introduced by the hibernation fix.** It is written here first because it is easy
to enable hibernation for the convenience and never think about this.

Three honest options:

| | |
|---|---|
| **Accept it** | Reasonable if the machine does not leave home and nothing sensitive is resident. This is the current state. |
| **Encrypt the disk** | The real fix, and a reinstall or an in-place LUKS conversion. Then the swapfile inherits the encryption and hibernation is safe. |
| **Turn hibernation off** | `systemctl mask hibernate.target hybrid-sleep.target suspend-then-hibernate.target`, and set UPower's `CriticalPowerAction` away from `Auto`. Costs the clean shutdown at 2% battery. |

Note the Windows partition on this machine *is* BitLocker-encrypted, so the Linux
side is now the weaker half.

## Before any rollback, live-media boot, or fallback-UKI boot: destroy the image

**This is the way to corrupt the filesystem, and it is not obvious.**

The `resume` hook runs *before* root is mounted, so a valid hibernation image is
restored unconditionally. And a hibernation image is **not** cleared by a boot
that does not resume it — the swapfile header reads `S1SUSPEND`, `swapon`
refuses it, and the image simply waits.

So this sequence destroys the filesystem:

1. hibernate;
2. boot something that does not resume — live media, or a Timeshift restore;
3. `@` is mounted read-write and modified;
4. next normal boot restores the stale image on top of the changed filesystem.

The restored kernel has a page cache describing a filesystem generation that no
longer exists. That is guaranteed btrfs corruption.

**Before rolling back, booting live media, or booting a fallback entry:**

```bash
swapoff /swap/swapfile && mkswap /swap/swapfile && swapon /swap/swapfile
btrfs inspect-internal map-swapfile -r /swap/swapfile   # confirm the offset is unchanged
```

**And keep every boot entry's resume settings identical.** A fallback UKI that
points somewhere else is the trap above with a menu item: booting it skips the
resume, strands the image, and the next normal boot restores it over a moved-on
filesystem. A fallback should differ only in the thing being tested.

## What was wrong

Hibernation was enabled and could not complete. The kernel wants an image of up
to `image_size` (default ~2/5 of RAM = 12.6 GiB here) and the only
resume-capable swap was an **8.8 GiB partition**. With 17.7 GiB of RAM in use
during an Android build, it was short by nearly 9 GB.

On 2026-08-22 at 13:35:18, at 11% battery, something requested a hibernate. It
allocated the image, prepared S4, and woke 28 ms later. **The abort reset the USB
bus**, which destroyed the fingerprint reader's SDCP session and wedged the
Samsung SCAI/EC interface — killing fingerprint auth, the keyboard backlight and
`power_on_lid_open` for nine hours before anyone noticed. See
[`docs/power/power-and-tuning.md`](../power/power-and-tuning.md).

An earlier mitigation capped `image_size` at 7 GiB. **That was inadequate**: with
17.7 GiB in use the machine was still far past the swap, and the cap only meant
the kernel gave up earlier.

## The fix

    @swap subvolume     sibling of @, so Timeshift's snapshots never capture it
    20 GiB swapfile     nocow + nodatasum via 'btrfs filesystem mkswapfile'
    resume=UUID=<btrfs FS>  resume_offset=6168051
    image_size          cap removed, back to the kernel default

```bash
# Do NOT hardcode /dev/nvmeXn1pY. The NVMe enumeration order on this machine is
# unstable -- it swapped across a reboot on 2026-08-23, and the device that was
# nvme0n1p2 became the Windows disk. Derive it.
ROOTDEV=$(findmnt -no SOURCE / | sed 's/\[.*//')
mount -o subvolid=5 "$ROOTDEV" /mnt/btrfs-top
btrfs subvolume create /mnt/btrfs-top/@swap
mount -o subvol=@swap,noatime "$ROOTDEV" /swap
btrfs filesystem mkswapfile --size 20g /swap/swapfile
swapon /swap/swapfile
btrfs inspect-internal map-swapfile -r /swap/swapfile   # -> resume_offset
```

**A successful `swapon` is the proof it is configured correctly** — btrfs refuses
to swap on anything compressed, COW, or spanning multiple devices, and the root
filesystem is mounted `compress=zstd:1`.

Sizing, stated correctly — an earlier version of this got it wrong three ways:

- **`image_size` is a soft target, not a ceiling.** When the kernel cannot shrink
  that far it raises the floor toward roughly **half of RAM** (~15.7 GiB here).
  The live value is 12,474 MiB, not the 12,594 quoted before.
- **The image must fit the swapfile's FREE space**, not its size. The swapfile is
  also ordinary swap.
- So the honest figure is 20,480 MiB against a ~15,742 MiB worst case — it fits,
  **by about 4.7 GB, and only while the swapfile is empty of ordinary paging.**
  Not the "7.9 GB spare whatever RAM usage does" claimed before.

That last point is why the swap priorities matter:

    zram 100  >  partition 10  >  swapfile 1

Day-to-day paging fills zram, then the 8.8 GiB partition, and reaches the
swapfile only as a last resort — keeping it free for the image. At equal
priority the kernel round-robins, and ordinary swap eats the room the image
needs in exactly the heavy-RAM situations that motivated the fix.

The old 8.8 GiB partition stays active as ordinary swap; it is simply no longer
the resume device.

## Two things that made this safer than expected

**`/sys/power/resume` and `/sys/power/resume_offset` are writable at runtime.**
The whole fix can be applied and tested with zero boot risk:

```bash
echo 6168051 > /sys/power/resume_offset   # offset FIRST
echo 259:7   > /sys/power/resume          # then the device
```

Only making it survive a reboot needs the kernel command line, and therefore a
UKI regeneration under Secure Boot.

**A fallback UKI carrying the OLD command line** sits beside the new one at
`/boot/efi/EFI/Linux/manjaro-7.1-x86_64-fallback.efi`, signed, and appears as its
own systemd-boot entry. If the new one fails, pick the fallback at the boot menu.
An offline copy is at `/root/uki-known-good-*.efi`.

## Verifying a UKI change

The `.cmdline` section is **UTF-16**, so grepping the raw bytes silently fails
and reports everything as missing. Strip the nulls first:

```bash
objcopy -O binary --only-section=.cmdline \
        /boot/efi/EFI/Linux/manjaro-7.1-x86_64.efi /tmp/c.txt
tr -d '\0' < /tmp/c.txt
```

Then check: `resume=` points at the **btrfs filesystem** UUID (not the old swap
partition), `resume_offset=` is present, `sbctl verify` passes, and the new image
is not byte-identical to the fallback.

## Tested, 2026-08-23

**A real hibernate was performed and it worked.** Same `boot_id`, uptime
continued 527 s → 781 s, battery unchanged — a genuine S4, not a cold boot.

### What S4 breaks on this machine, and what repairs it

A *successful* hibernate wedges part of the Samsung SCAI/EC interface. This is
not specific to the failed hibernate of 2026-08-22; a clean one does it too, and
only partly, which is what makes it easy to miss:

| after resume | state |
|---|---|
| `kbd_backlight` | **broken** — every CSFI call answers `0xff`, writes give `-ENXIO` |
| `power_on_lid_open` | **broken** — reads empty, and each read costs a CSFI failure |
| `usb_charging` | works |
| `platform_profile` | works |

Because the profile still switches, power management looks healthy while the
keyboard backlight is dead. `/etc/systemd/system-sleep/gb5-resume-fixups` reloads
`samsung_galaxybook` after hibernate, which re-runs its ACPI init and clears the
wedge. Verified: backlight writes clean, `power_on_lid_open` back to `1`.

### The fingerprint chain, verified end to end

`usb 3-5` is reset six times by S4, so the reader loses its SDCP session while
the kernel `boot_id` is unchanged and the cached claim still looks current:

    touch #1   Enrollment ID identified by the device
               SDCP AuthorizedIdentity verification failed
               "Invalidated the cached SDCP session; the next claim will
                reconnect under the same host identity."      <- the patch
               claim file rewritten 17:57:49 -> 18:13:52
    next claim SDCP ConnectResponse verified successfully
    touch #2   verify-match

Enrolment intact, no new host keys minted.

**The first touch after each hibernate still fails.** The driver only learns the
session is stale *by* failing, so it cannot be repaired mid-operation. Expect one
rejected touch after a resume, then normal behaviour. That is a large improvement
on the previous state — broken until someone deleted the claim file by hand — but
it is not invisible, and it is not worth pretending otherwise.

### One more thing S4 exposed

The machine resumed straight into an **unlocked** desktop (`LockedHint=no`).
Fixed twice over: KDE's `LockOnResume=true`, and a `pre/*` branch in the sleep
hook that calls `loginctl lock-session` before suspending — a pre-sleep lock
cannot lose the race that a post-resume one can.
