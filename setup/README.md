# Setting this up on another Galaxy Book5

    sudo ./setup.sh

Runs each step in order, asking before each one. Every step is idempotent, so
re-running is safe and is the normal way to repair something after a kernel
update.

    sudo ./setup.sh --list     what the steps are
    sudo ./setup.sh 10 30      just the camera and fingerprint steps

## Read this before you run anything

**These fixes are per-board, not per-platform.** The camera clock, the Bayer
order and the speaker amp addresses were all determined on a **965XHD**
specifically. A different Galaxy Book may need different values, and applying
these blindly will give you a camera that produces wrong colours rather than one
that works. `00-precheck.sh` warns rather than blocks in that case; the warning
is the point.

**Nothing here was tested on a clean install.** It is derived from a machine
where all of it already works, and each step is written to detect what is
already present and skip it. That makes it safe to re-run, but it means the
from-scratch path has been reasoned about rather than executed end to end. Read
each script before running it — they are commented with *why*, not just *what*.

**Take a snapshot first** if your root is btrfs. Step 40 sets up automatic ones,
which does not help you before step 40.

## The steps

| | |
|---|---|
| `00-precheck` | Is this the right machine? Always runs; `setup.sh` stops on a hard mismatch. |
| `10-camera` | Sensor driver (DKMS), the `/dev/video` bridge, the all-GPU pipeline, browser enumeration. |
| `20-speakers` | Side-codec driver plus a service creating the three amps ACPI omits. |
| `30-fingerprint` | Replaces libfprint with the SDCP fork carrying three local fixes, then wires PAM. |
| `40-system` | Power split, zram, VA-API, wireless regulatory domain, snapshot schedules. |
| `50-secureboot` | Custom keys, signed UKI, systemd-boot. **Run directly, after reading it.** |

Secure Boot is excluded from a full run on purpose. It needs BIOS steps that
cannot be done from Linux, and it is the only part that can leave the machine
unbootable.

## What each step actually changes

Nothing is hidden in a binary. Every file the scripts install is in this
repository — `camera/`, `config/`, `boot/` and `dkms/` — so you can read exactly
what lands on your system before it does, and `sync.sh` will later tell you if
any of it has drifted from what is running.

The two DKMS module sources are bundled rather than patched on the fly. The
camera's Bayer order was found empirically by testing all four orders against a
known-good capture, and the frame timing is derived from this board's clock;
asking someone to re-derive either from a description would be much worse than
shipping the source.

## After it finishes

    sudo gb5-verify.sh

111 checks with the evidence inline. A reboot is needed before the camera and
speakers are fully up.

## If something goes wrong

Every step is independent. Nothing depends on an earlier step having run, so you
can re-run one in isolation. To undo:

    dkms remove ov02e10-26mhz/1.0 --all      # restores the in-tree camera driver
    dkms remove max98390-hda/1.0 --all       # speakers go silent again
    pacman -S libfprint                      # reverts the fingerprint stack
    rm /etc/udev/rules.d/99-gb5-*.rules      # power and reader pinning

PAM is safe either way: the `-` prefix on `-auth sufficient pam_fprintd.so`
means a missing module is skipped rather than fatal, so removing libfprint
cannot lock you out.
