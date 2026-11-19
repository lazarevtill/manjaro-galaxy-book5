# Disk encryption — the decision, the measurement, and the plan

**Status: decided in principle, not executed.** Deferred by the user on
2026-08-23 to revisit later. Nothing here has been done to the machine.

## The question that was actually asked

"Hibernation writes RAM to an unencrypted disk — accept, encrypt, or disable?"
had been open for days. It is the wrong frame, and that is why it stayed open.

## Why hibernation is not the issue

Confirmed on the running machine, 2026-08-23:

    /var/lib/netbird/default.json   contains "PrivateKey"   <-- WireGuard peer identity
    ~/.ssh                          28K
    ~/.local/share/kwalletd         12K
    ~/.config/BraveSoftware         1.2G   session cookies, tokens

All mode `0600` and root-owned, which means nothing against someone holding the
powered-off laptop. The hibernation image is a rounding error on top of a disk
that already hands over **network access to `in.vpn`**, not merely files.

Encrypting "only the hibernation image" is not a thing anyway: resume needs the
key before userspace exists, so it means LUKS regardless.

So the decision is whole-disk encryption, yes or no. Hibernation follows from it
— under LUKS the swapfile lives inside the encrypted volume, so the RAM image is
encrypted and hibernation keeps working exactly as built.

## The power objection is dead — measured, not estimated

Same loop device, same bytes, once through LUKS and once not, so the only
variable is dm-crypt. Energy from the RAPL counter, not averaged watts. Opened
with `--perf-no_read_workqueue --perf-no_write_workqueue`.

| arm | throughput | energy per GB |
|---|---|---|
| raw | 658 MB/s | 14.0 J |
| luks | 568 MB/s | 20.3 J |
| raw | 718 MB/s | 13.3 J |
| luks | 552 MB/s | 18.7 J |

**~6 J per GB written.** A third pair was discarded as contaminated — the *raw*
arm alone went from 13 to 23 J/GB and package power from 9 W to 16 W, so
something else was running. Reported rather than averaged in.

Against a 4.90 Ah / ~79 Wh battery:

* **idle: exactly zero.** No I/O, no crypto. The 6.22 W figure does not move.
* a hibernation cycle (~12 GB out, back in) ≈ **0.05%** of a charge
* a heavy Docker-build day, ~100 GB written ≈ **0.2%**
* you would write **~470 GB to spend 1%**

For scale, the OLED panel is ~10 W: a whole heavy day of encryption overhead
costs about **one minute of screen-on time**.

An earlier attempt at this measurement was invalid and is recorded so it is not
repeated: it compared LUKS against writing zeros to btrfs, where `compress=zstd`
makes zeros nearly free while LUKS writes incompressible ciphertext.

### What does cost

Throughput fell ~22% (700 → 550 MB/s). Directional only — a loop device
serialises in a way real NVMe does not, and dm-crypt parallelises across cores
on a real disk. But this, not the watts, is the effect that might be noticed.

Two things in this machine's favour: the CPU has **VAES + VPCLMULQDQ** (one core
did 4.7 GB/s of raw AES-256-XTS), and with btrfs-on-LUKS zstd compresses
*before* encryption, so there is less data to encrypt, not more.

## Recommendation

**Encrypt the root disk.** Reasons specific to this machine:

1. The power cost is negligible and now measured, so that objection is closed.
2. TPM2 is present (`MSFT0101:00`, `tpm_crb_acpi`) and `sd-encrypt` is available,
   so `systemd-cryptenroll` with PCR binding keeps boot passwordless.
3. Custom Secure Boot keys and a signed UKI protect **boot integrity** and do
   nothing for **data at rest**. Encryption is the missing half of work already
   done.
4. The concrete loss from theft today is a VPN private key, not just data.

**But not in place on a running system, and not as a follow-on to anything
else.** Reencryption of a root filesystem carrying a signed UKI, a hibernation
`resume_offset` and three DKMS modules is the highest-risk operation in this
project. `--reduce-device-size` shifts the filesystem to make room for the LUKS
header, and that step is what turns a mistake into an unbootable disk.

## The plan, when it is picked up

Prerequisites, all of them:

* the 7.1.9 reboot done and the machine stable for several days
* one unattended update cycle observed
* a **verified external backup** — not a Timeshift snapshot, which lives on the
  disk about to be rewritten
* a Manjaro live USB, tested to boot on this machine under Secure Boot (or
  Secure Boot temporarily disabled in firmware, then re-enabled)
* a few hours, unhurried

Outline. Do not run this as a script; each step needs its output read.

1. **From the live USB**, shrink the filesystem to make room for the header:

        cryptsetup luksHeaderBackup ...        # nothing to back up yet, but note the pattern
        mount /dev/nvme1n1p2 /mnt -o subvol=/
        btrfs filesystem resize -32M /mnt
        umount /mnt

2. **Encrypt in place.** Hours, and it must not be interrupted:

        cryptsetup reencrypt --encrypt --type luks2 \
          --cipher aes-xts-plain64 --key-size 512 \
          --reduce-device-size 32M /dev/nvme1n1p2

3. **Back up the LUKS header immediately**, off-machine. Losing it loses
   everything, and it is a single point of failure that no snapshot covers.

        cryptsetup luksHeaderBackup /dev/nvme1n1p2 --header-backup-file gb5-luks-header.img

4. **Open, mount the subvolume layout, chroot.** `@`, `@home`, `@cache`, `@log`,
   `@swap`, `@docker`, plus the ESP at `/boot/efi`.

5. **initramfs.** TPM2 unlock needs the *systemd* initramfs, which is a bigger
   change than adding one hook. Current:

        HOOKS=(base udev autodetect microcode kms modconf block keyboard keymap consolefont plymouth resume filesystems)

   Target shape:

        HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt plymouth filesystems fsck)

   Note `resume` is dropped: systemd's own `systemd-hibernate-resume` handles it.

6. **`/etc/kernel/cmdline`** — this is the source for the UKI, not
   `/proc/cmdline`. Needs `rd.luks.uuid=<LUKS UUID>`, `root=/dev/mapper/...`,
   and `resume=` pointing at the mapper device. The btrfs UUID does **not**
   change through reencryption, so `/etc/fstab` stays valid.

7. **`resume_offset` — re-derive, do not assume.** The swapfile's offset within
   the filesystem should be unchanged, but verify rather than trust:

        btrfs inspect-internal map-swapfile -r /swap/swapfile

8. **Rebuild and sign the UKI.** `mkinitcpio -P` does **not** sign — signing is
   a pacman hook that will not fire in a chroot. Sign explicitly and verify:

        mkinitcpio -P && sbctl sign-all && sbctl verify | grep -v /EFI/Microsoft/

9. **Enrol TPM2** with a passphrase kept as fallback. PCR 7 (Secure Boot state)
   is the sane binding here; PCR 11 binds to the UKI itself and would need
   re-enrolling on every kernel update unless signed PCR policy is set up:

        systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 /dev/nvme1n1p2

10. **Verify before trusting it**: `sudo gb5-verify.sh`, `sudo gb5-docker-verify`,
    then a real hibernate/resume cycle.

### The trap in this plan

**`/dev/nvme1n1p3` is a plain swap partition at priority 10.** Encrypting root
while leaving it as-is means memory pages continue to land on plaintext disk,
which defeats most of the point. Hibernation does not use it — the swapfile
inside the encrypted root does — so either remove it from `/etc/fstab`, or give
it a random key per boot via `/etc/crypttab`. Decide this deliberately; it is
the easiest thing in the whole procedure to overlook.

## If the answer ends up being "no"

A legitimate call: it is real risk against a threat requiring physical theft.
Then accept it deliberately rather than leaving it open:

* **Keep hibernation.** Disabling it buys almost nothing while the disk is
  plaintext, and it works well now.
* Record that "laptop stolen" means **rotate the NetBird peer key**, not just
  change passwords.

## Unrelated finding, worth checking from Windows

An earlier review described the Windows install as BitLocker'd. `lsblk` reports
`nvme0n1p3` as plain `ntfs`; a BitLocker volume normally reports as such. So
Windows is probably **not** encrypted either. Not verified from Linux.
