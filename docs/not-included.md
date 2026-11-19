# What is deliberately not in here

Two categories, for different reasons. Both are listed so their absence reads as
a decision rather than an oversight.

## Secrets — never commit these

**Secure Boot keys** (`/var/lib/sbctl`). The private key that signs your
bootloader and kernel. Anyone holding it can sign something your firmware will
trust. Back it up somewhere *not* shared:

    tar czf ~/sbctl-keys-backup-$(date +%F).tar.gz /var/lib/sbctl

Losing it is also bad in the other direction — you cannot re-sign after a kernel
update, and an unsigned kernel will not boot under Secure Boot.

**NetworkManager connection profiles** (`/etc/NetworkManager/system-connections/`).
Each one contains the Wi-Fi password in plain text. Nothing here needs them; a
fresh machine will have its own networks.

## Lives elsewhere, on purpose

**The Fingerprint app** — <https://github.com/lazarevtill/fingerprint-manager>,
GPL-3.0, released as v1.0.4. It is a separate project with its own history and
issue tracker, not a config file. Install it from there or from the AUR PKGBUILD
in that repository.

**linux-studio-effects** — upstream is
<https://github.com/ericjchang/linux-studio-effects>. The NPU background blur.
Four fixes were needed to make it usable on this machine and they are **not
upstream yet**, so `packaging/patches/linux-studio-effects-0001-fix-1fps-pipeline.patch`
carries them here. Apply onto upstream commit `7ad1588`:

    git clone https://github.com/ericjchang/linux-studio-effects
    cd linux-studio-effects
    git am < /path/to/patches/linux-studio-effects-0001-fix-1fps-pipeline.patch

Without it the pipeline runs at **1 fps**: a V4L2 device hands out a small
buffer ring, and once the consumer does ~30 ms of work between reads the reads
themselves start blocking — 274 ms, then 977 ms, degrading as it falls further
behind. Draining the camera in its own thread and taking the newest frame fixes
it. See `docs/hardware/npu-camera-effects.md` for the other three.

**PAM files** — `docs/system/pam.md` documents the change and how to undo it, but the
files themselves are not copied. They are machine-specific, they change with
package updates, and restoring a stale copy over a newer one is a good way to
break authentication.
