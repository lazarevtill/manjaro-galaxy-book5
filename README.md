# Galaxy Book5 Pro H — enablement record

Samsung 965XHD (Arrow Lake-H), Manjaro, kernel 7.2.9 (LTS 6.12 fallback), KDE Plasma Wayland.
Same content published as a private web page; this directory is the offline copy.

**State: Secure Boot on, signed UKI behind a systemd-boot menu, camera running
entirely on the GPU, snapshots armed, updates unattended (pacman weekly via
gb5-safe-update, Flatpak weekly, boot chain guarded after every transaction).
135 checks: 133 pass, 2 fail (no fingerprint enrolled — one fact, two checks),
1 note. As of 2026-11-19, on the boot the Phase 8 fixes were made.**

## Start here

| You are… | Read |
|---|---|
| **Setting up a Galaxy Book5 Pro** | [`setup/README.md`](setup/README.md), then run `sudo ./setup.sh` |
| **Curious what it took** | [`HISTORY.md`](HISTORY.md) — eight phases, every wrong turn kept in place |
| **Looking for one topic** | [`docs/README.md`](docs/README.md) — the index of every note |
| **An AI agent / LLM** | [`AGENTS.md`](AGENTS.md) (also `CLAUDE.md`), then [`llms.txt`](llms.txt) |
| **Checking what is open** | [`TASKS.md`](TASKS.md) |

The same story as a web page: **<https://gb5.lazarev.cloud>** (source: [`site/galaxy-book5-enablement.html`](site/galaxy-book5-enablement.html), deployed by GitHub Pages on every push).

## Repository layout

```
README.md  AGENTS.md (= CLAUDE.md)  HISTORY.md  TASKS.md  llms.txt
setup.sh   setup/        reproduce everything on another machine, step by step
sync.sh                  is this repo still true of the machine? (compares 40 files)
bin/       every script installed to /usr/local/sbin
             gb5-verify.sh (135 checks) · gb5-safe-update · gb5-boot-guard.sh ·
             gb5-ensure-uki.sh · gb5-power-{report,log,analyse,tune.sh,profile.sh} · …
systemd/   units and timers: weekly guarded update, Flatpak, power logging, hibernate unmask
config/    deployed configuration, one folder per subsystem
             system/  sysctl, udev, pacman hooks, kernel cmdline, fstab, watchdog, Timeshift
             camera/ boot/ browser/ docker/ netbird/ pam/ windows/
packaging/ things built from source: dkms/ (camera, speakers), libfprint/ PKGBUILD,
           patches/ (upstream fixes), theme/ (true-black OLED scheme)
docs/      the notes: hardware/ power/ system/ + publishing, not-included, archive/
site/      the published web page and its check/preview tools
```

Every file under `bin/`, `systemd/` and `config/` is a **copy of something live**;
`sudo ./sync.sh` says whether any of them has drifted, `sudo ./sync.sh --pull`
refreshes them. Secrets are deliberately absent — see
[`docs/not-included.md`](docs/not-included.md).

## The tools you will actually run

| Command | What it does |
|---|---|
| `sudo gb5-verify.sh` | 135 checks across every subsystem, evidence inline. Run before and after any change. |
| `sudo gb5-safe-update` | Updates with the checks this machine needs; refuses on anything unsafe, verifies afterwards. `--check` = pre-flight only. Runs weekly by itself. |
| `sudo gb5-boot-guard.sh --check` | Is the boot chain right? (removable fallback, fallback UKI, signatures). Silent = yes. |
| `gb5-power-report --watch` | Where the watts go right now. |
| `sudo gb5-docker-verify` | The container stack, verified the same way. |

## Battery, in one screen

Measured on this machine, not estimated. The full working is in
`docs/power/battery-plan.md`; the short version:

| | |
|---|---|
| Pack | 76.0 Wh (`charge_full` 4900 mAh, 161 cycles) |
| Idle floor, quiet moments | 4.83 W — real, and the machine is there 76% of the time |
| **Actual sustained drain, light use** | **6.22 W → 12.2 h**, by coulomb count over 45 gauge steps |
| **Best achieved** (quietest 1.34 h window) | **5.91 W → 12.9 h** — the realistic ceiling |
| Bright/white content on screen | ~15 W → ~5 h |

**The single biggest lever is what is on the screen, not how the machine is
tuned.** Full-screen white costs about 10 W more than full-screen black on this
OLED — a larger difference than between idling and compiling. A dark colour
scheme is worth more than every CPU, GPU and NPU change in this project combined.

Three things that actually matter, in order:

1. **Dark theme everywhere** — desktop, editor, terminal, browser.
2. **Do not leave a USB Ethernet adapter plugged in.** One was holding the
   platform's latency floor at 128 µs and blocking package C8/C10 entirely.
3. Everything else is under a watt.

The SoC side is already about as good as it gets: 3.34 W package at idle, 0.24 W
in the cores, 95% GPU RC6, package C10 being reached, and every device
power-management knob already correct out of the box.

### Two measurement traps this project fell into

Both are easy to repeat and both produce confident, wrong numbers.

- **`current_now` is biased low on this gauge**, by about 23%. Not a sampling
  artefact — integrating it over 634 samples still disagrees with the charge
  counter, and two registers of one chip cannot differ for sampling reasons. If you want
  a runtime, integrate `charge_now`. If you want an idle floor, snapshots are fine.
- **An idle floor is not a runtime.** 4.83 W is genuine, but extrapolating it to
  15.6 h was wrong; the machine is only that quiet 76% of the time.

## Setting this up on another machine

    sudo ./setup.sh            # guided, asks before each step
    sudo ./setup.sh --list     # what the steps are

`setup/` reproduces everything below on another Galaxy Book5, with the DKMS
module sources bundled so nothing has to be re-derived. Read `setup/README.md`
first — these fixes are **per-board**, and the from-scratch path has been
reasoned about rather than executed end to end.

## If you are doing this on the same laptop

Five things are not stock and will break silently if reverted:

1. **Camera sensor** — DKMS `ov02e10-26mhz`: accepts the board's 26 MHz clock (in-tree only
   allows 19.2), forces a 180° readout, advertises `SRGGB10`, and adds blanking
   (`vts_def` 2244 → 3039) so the sensor runs at a true 30 fps instead of 40.6.
2. **Camera pipeline** — `v4l2-relayd` bridging libcamera into a v4l2loopback device, with
   an all-GPU `vapostproc` chain and a `sync=false` drop-in on the relay unit.
3. **Speakers** — DKMS `max98390-hda` plus a service creating the 3 I2C amps ACPI omits.
4. **Fingerprint** — `libfprint-egismoc-sdcp-git` replaces libfprint and carries three local
   patches; `epoch=1` stops the AUR's placeholder version looking newer.
5. **Boot** — a signed Unified Kernel Image launched by signed systemd-boot, not GRUB.

Do not install TLP, tuned or auto-cpufreq — power-profiles-daemon owns those knobs and KDE
drives it.

## The traps, in the order they bite

- **GRUB cannot boot Linux under Secure Boot on 2.14.** `--disable-shim-lock` does not fix
  it. Worse, the two obvious ways to check whether the flag applied are both invalid:
  `strings | grep shim_lock` (those strings are always present) and reading `sb.c` from
  `rhboot/grub2` (that is Red Hat's fork, not what Manjaro ships). Parse the PE `mods`
  section for module type 7 instead — or just trust the boot failure.
- **Enabling Secure Boot before enrolling keys** fails everything Linux. Enrolment needs
  Setup Mode, which means *clearing* keys in BIOS, not adding any there.
- **`grub-install` without `--no-nvram`** moves GRUB to the head of BootOrder on every GRUB
  package update, undoing the boot order silently.
- **`\EFI\BOOT\BOOTX64.EFI`** is the NVRAM-reset fallback. If it holds GRUB, that path is
  broken too. Put signed systemd-boot there.
- **`bootctl list` is one boot stale.** It reads the `LoaderEntries` EFI variable that
  systemd-boot wrote *last* boot, not the current `loader.conf`, so edits appear to do
  nothing and `(default)` keeps naming the old choice.
- **The two NVMe drives swap enumeration between boots.** `nvme0n1` was the Windows disk one
  boot and the Linux disk the next. Never hardcode `/dev/nvmeXn1pY`; use PARTUUID or
  `findmnt`.
- **Windows leaves the RTC on local time**, so the first seconds of each Linux boot are
  stamped in the future and `journalctl --since` keeps matching them — which produced a
  false test result here. Scope log windows with `--after-cursor`; fix Windows with the
  supplied `.reg`.
- **`/dev/videoN` numbers move between boots.** The bridge was `video48` one boot and
  `video0` the next. Find it by card name.
- **Writing to `/run/media/<user>/<UUID>` while unmounted** silently creates a tmpfs shadow
  that masks the real mountpoint. Always `findmnt` first.
- **`timeshift --list` is authoritative, its config file is not.** A default
  `/etc/timeshift/timeshift.json` says `"btrfs_mode": "false"` while Timeshift is
  actually running in BTRFS mode — the CLI autodetects. Editing schedules in that
  file also does nothing until `timeshift --check` runs and creates the cron
  entries. Pin `btrfs_mode` anyway, or opening the GUI writes the default back
  and switches to rsync copies of a 468 GB root.
- **Setting the Wi-Fi regulatory domain does not enable 6 GHz on this card.** The
  PHY is self-managed; the firmware decides, via ACPI `_DSM` function 3 returning
  the BIOS NVS field `UHBS`. No module parameter overrides it. Also: 6 GHz
  channels start at **5955 MHz**, so a grep for `6[0-9]{3} MHz` reports zero
  channels when 59 exist.
- **`fwupdmgr` reporting "UEFI dbx: latest available" means nothing** when dbx is
  empty — the version reads `None` and `only-version-upgrade` leaves it nothing
  to compare. Check with `gb5-dbx-check.sh` instead.
- **Fingerprint enrolments vanish after every reboot** unless libfprint is patched to keep
  the SDCP host keypair. Two things hide this while you debug it: `fprintd-list` reads
  fprintd's own record, not the sensor, so it lists fingers the device has already
  forgotten — the two are reconciled only when a match is attempted *and fails*; and a
  successful verify logs nothing at all, so an empty log is not evidence of failure.
- **A CPU filter in the relay pipeline freezes the camera for ~1 s at a time.** Not a
  throughput problem — see below.
- **Restarting `pipewire` costs a running browser its microphone.** To re-probe video
  devices restart `wireplumber` alone.

## Measuring anything in the camera pipeline

Two measurements here were wrong in ways that sent the work in the wrong direction, both
worth copying as rules:

- **Never leave an encoder in a throughput benchmark.** A `pngenc` in the chain made a
  filter look free when it was not.
- **`fakesink sync=false` hides the exact failure being investigated**, and unconstrained
  sink caps let a trailing `videoconvert` negotiate passthrough so it converts nothing.
  Pin the caps and keep `sync=true` to emulate the real relay.

Judge by the inter-frame gap distribution as delivered through the loopback, not by average
fps — the failure mode is a p99 of 1033 ms behind a median of 33 ms.

## After a kernel update

    sudo gb5-verify.sh
    sudo sbctl verify      # the signing hook exits 0 even when it cannot sign

## Known limitations

- Camera image quality is capped by libcamera's *software* ISP. The IPU6's hardware ISP
  (PSYS) was never mainlined — Intel treats it as proprietary — and Intel's own
  `ipu6-camera-hal` supports Tiger through Meteor Lake, **not Arrow Lake**, with
  out-of-tree drivers that stopped tracking kernel APIs around 6.16. There is no route to
  the hardware ISP on this machine.
- libcamera's SoftISP has no denoise, sharpening, lens-shading or fixed-pattern-noise
  stage at all — the complete algorithm list is BlackLevel, Awb, Ccm, Adjust, Agc. Noise
  reduction has to happen downstream, which is what the GPU pipeline does.
- Vertical fixed-pattern noise in low light is a known unresolved defect on this sensor,
  present on both CPU and GPU SoftISP paths.
- `dbx` is **enrolled** (revocations enforced; `gb5-verify.sh` checks it). It was
  empty in Aug 2026; when it was enrolled is not recorded (the Sep BIOS update or a
  Windows Secure Boot update are the likely causes — unverified).
- 6 GHz is unavailable — the BIOS gates it, not Linux. See `docs/hardware/wireless-and-6ghz.md`.
- No boot-menu rollback: recovering an unbootable system needs live media, since
  `grub-btrfs` went with GRUB.
- The root filesystem is **not encrypted**, and neither is swap. TPM 2.0 and
  `systemd-cryptenroll` are available if that changes.
- **Hibernation** works as of 2026-08-23 — 20 GiB btrfs swapfile, tested with a real S4. It writes RAM to an **unencrypted** disk; see `docs/system/hibernation.md`.
- Passkeys cannot be stored on-device — Linux has no platform authenticator.
- Custom touchpad gestures are not bindable on Plasma 6.7.
- `pantheon-camera` hangs; use `snapshot`.

## Applications

- **Fingerprint** (`fingerprint-manager`) — enrol, test and remove fingerprints. Source at
  `~/projects/fingerprint-manager`, GPL-3.0-or-later.
- **Camera Effects** (`linux-studio-effects`) — NPU background blur, published as the
  `StudioEffects` camera. Source at `~/projects/linux-studio-effects`. Not a background
  service: running it keeps the camera powered and the privacy light on.

## Backups

- `/root/sbctl-keys-backup-2026-08-19.tar.gz` — also on the Windows partition. Losing these
  means you cannot re-sign after an update.
- `/root/grubx64.efi.bak-2026-08-19`, `bootx64.efi.bak-2026-08-19`
- `/etc/pam.d/*.bak-2026-08-19`, `/etc/pacman.conf.bak-2026-08-19`
- `/etc/default/v4l2-relayd.bak-preva`, `/usr/src/ov02e10-26mhz-1.0/ov02e10.c.bak-*`
- Fingerprint build tree: `~/.cache/gb5-build/fpaur`
