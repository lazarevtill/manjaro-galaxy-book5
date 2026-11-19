# For an agent working on this machine

Read this before touching anything. It is not a summary of the project — that is
[`HISTORY.md`](HISTORY.md). This is the operational file: **what is non-stock,
what will mislead you, and what to check.**

The single most useful fact: **36 confident wrong conclusions are catalogued in
`HISTORY.md`** (four of them made, and caught, while fixing the others). Almost every one came from a measurement or a check that looked
fine. Assume you are about to make number 37.

---

## First, orient

```bash
sudo gb5-verify.sh          # 135 checks, evidence inline. Run BEFORE and AFTER any change.
cat TASKS.md                # what is done, what is open, what needs a human
```

`gb5-verify.sh` is the source of truth for machine state. If it says 0 FAIL, the
subsystems below are healthy. If you change something, re-run it — and if you add
a capability, **add a check for it**, or the next agent will not know it exists.

## Repository layout (reorganised 2026-11-19)

| Path | Contents | Live location |
|---|---|---|
| `bin/` | every script the machine runs (`gb5-verify.sh`, `gb5-safe-update`, `gb5-boot-guard.sh`, power tools, …) | `/usr/local/sbin/` |
| `systemd/` | units and timers | `/etc/systemd/system/` |
| `config/system/` | sysctl, udev, pacman hooks, kernel cmdline, fstab, watchdog, Timeshift, ramoops | `/etc/…` (see `sync.sh` MAP) |
| `config/{camera,boot,browser,docker,netbird,pam,windows}/` | per-subsystem deployed config | `/etc/…`, the ESP, `~/.config` |
| `packaging/` | `dkms/` module sources, `libfprint/PKGBUILD`, `patches/`, `theme/` | built, not copied |
| `setup.sh`, `setup/` | reproduce everything on a new machine | — |
| `docs/` | topic notes; index in `docs/README.md` | — |
| `site/` | the published web page + `check.sh` / `preview.sh` | claude.ai artifact |

**Editing rule.** `bin/`, `systemd/` and `config/` are copies of live files. Change
the repo copy, install it to its live path, then run `sudo ./sync.sh` — it must
report `0 drifted`. Never edit only one side: a record that disagrees with the
machine gets trusted and is worse than none. The live → repo map is the `MAP`
block in `sync.sh`; add a line there for every new live file.

**Naming.** Paths in prose are repo-root relative (`bin/gb5-verify.sh`); a bare
`gb5-verify.sh` means the installed command. Markdown links are relative to the
file they are in.

## What is non-stock, and will break if you revert it

| Thing | Why it is not stock |
|---|---|
| `libfprint-egismoc-sdcp-git` | Replaces stock libfprint. Four local patches: a crash fix, SDCP host-key persistence, a match-reported-as-failure fix, and hibernate session recovery. **A stock libfprint update silently breaks fingerprint auth.** It `Provides: libfprint`, so pacman will not pull the stock one in — verify that stays true. |
| 3 DKMS modules | `ov02e10-26mhz` (camera sensor retimed for a 26 MHz clock), `max98390-hda` (speakers are silent without it), `v4l2loopback`. All must rebuild on every kernel update. |
| UKI + Secure Boot | systemd-boot loading a signed UKI. `/etc/kernel/cmdline` is the source; the UKI is rebuilt and signed by *pacman hooks*. `gb5-boot-guard.sh` (last hook) keeps the removable path = signed systemd-boot, the fallback UKI on a live kernel, and sbctl's db honest. |
| `98-install-grub.hook` → `/dev/null` | Manjaro's hook, disabled on purpose. **Do not remove the symlink**: since install-grub 2.16 it overwrites `\EFI\BOOT\BOOTX64.EFI` with a GRUB that refuses the kernel under Secure Boot. |
| 20 GiB btrfs swapfile | On `@swap`, a sibling of `@`. The hibernation resume device. |
| PAM in 5 services | `sudo sddm login polkit-1` (`sufficient`) and `kde-fingerprint` (`required`, an override of a vendor file). |
| `@docker` subvolume | `/var/lib/docker` is its own btrfs subvolume so image layers never enter a Timeshift snapshot. containerd's root is moved onto it too. Three guards keep it honest — see `docs/system/docker.md`. |
| NetBird | Installed by upstream's `install.sh` into `/usr/bin`, so **pacman does not own it** and `gb5-safe-update` will never update it. The installer also leaves the binaries owned by the invoking user while systemd runs them as root — a local root escalation. See `docs/system/netbird.md`. |

## The traps. These have all caught someone already.

### Measurement

- **A number read off a busy desktop is a number about the desktop.** Idle
  readings on this machine range 4–10 W depending on what is running.
- **Both arms of an A/B in the same minute, order alternated** — and if heat is
  involved, cooled to a common start. Alternating order does *not* defeat thermal
  soak; only cooling does.
- **If within-condition spread exceeds between-condition difference, say "not
  measurable".** That is a different claim from "no difference".
- **Count the instrument's steps.** `charge_now` moves in **49 mAh** jumps every
  ~445 s. Under ~8 steps per arm you are measuring the gauge.
- **`current_now` is biased ~23% low** on this gauge — not a sampling artefact.
  Integrate `charge_now` for runtimes. Snapshot-derived figures (including the
  "idle floor") are ~23% low in absolute terms and only good for ranking.
- **RAPL is the SoC package only** — not the panel, Wi-Fi, SSD or board.
  Whole-system draw exists **only while discharging**.
- **You are part of the measurement.** The agent process was the largest single
  wakeup source (96.8/s) during the idle runs.

Use `gb5-power-analyse`; it refuses to answer when the data cannot support one.

### Verification

- **Verify by reading state back, never by an exit code.** `kscreen-doctor` exits
  0 on "Output mode not found". Writing to `/sys/class/leds/*/brightness`
  succeeds while the hardware rejects it.
- **`ck` in `gb5-verify.sh` is a SUBSTRING test.** `want="1"` passes on `"10"` and
  fails on `"2"`. An empty `want` passes on anything — always guard a computed
  expected value.
- **A cumulative count cannot tell "broken now" from "was broken, then fixed".**
  Probe live instead.

### The fingerprint sensor

- **`verify-no-match` with no finger on the sensor proves nothing.** It never
  reaches the `AuthorizedIdentity` MAC check. This trap produced two wrong
  conclusions on consecutive days. **A real touch is the only test.**
- Healthy failed touch: `verify-no-match`. Dead SDCP session:
  `verify-unknown-error`. The latter is a *device error*, which `pam_fprintd`
  treats as fatal — so auth silently falls through to the password prompt.
- **`rm sdcp-claim` is destructive.** That file is the host keypair; deleting it
  mints a new identity and the sensor disowns your enrolments. Since pkgrel 5 it
  is unnecessary — `systemctl restart fprintd` first.
- **The first touch after every hibernate fails by design.** The driver learns
  the session is stale by failing, then reconnects.

### Hibernation — the dangerous one

- **Before any rollback, live-media boot, or fallback-UKI boot: destroy the
  image.** A hibernation image is *not* cleared by a boot that does not resume it
  (`swapon` refuses an `S1SUSPEND` header). Boot something else, modify the
  filesystem, and the next normal boot restores the stale image over it —
  guaranteed btrfs corruption.

  ```bash
  swapoff /swap/swapfile && mkswap /swap/swapfile && swapon --priority 1 /swap/swapfile
  ```

- **Every boot entry must share one resume target.** A fallback UKI pointing
  elsewhere is that trap with a menu item.
- **`image_size` is a soft target**, not a ceiling — the kernel raises the floor
  toward half of RAM when it cannot shrink. And the image needs the swapfile's
  **free** space; keep the swapfile at lower swap priority than the partition.
- **Hibernation writes RAM to an UNENCRYPTED disk.** No LUKS here. See
  [`docs/system/hibernation.md`](docs/system/hibernation.md).

### Boot and Secure Boot

- **`mkinitcpio -P` does NOT sign.** Signing is a *pacman* hook and never fires
  for a manual run. Manual rebuild is `mkinitcpio -P && sbctl sign-all && sbctl verify`.
- **A UKI's `.cmdline` section is UTF-16.** Grepping raw bytes reports every key
  as missing on a perfectly good file. `tr -d '\0'` first.
- **NVMe enumeration order is unstable.** It has swapped across a reboot — the
  Linux disk was `nvme0n1` and became `nvme1n1`. **Never hardcode `/dev/nvmeXnYpZ`**;
  derive with `findmnt`/UUID.
- **A Timeshift restore rolls back `/boot` but not the ESP.** Restoring across a
  kernel bump boots the new kernel against old modules. Run
  `mkinitcpio -P && sbctl sign-all` before rebooting after any restore.

### Containers

- **Never publish a port without thinking about the VPN.** `-p 8080:80` binds
  `0.0.0.0`, and Docker inserts `DOCKER-FORWARD` at the **top** of FORWARD while
  NetBird's `-i wt0 -j DROP` is the **last** rule — so the port is reachable from
  all of `100.76.0.0/16` and the LAN. `daemon.json` sets `"ip": "127.0.0.1"` to
  make exposure opt-in. Do not remove it.
- **`features.containerd-snapshotter: false` is load-bearing, not a leftover.**
  Docker 29 defaults it *on*. Flip it and the image store moves to
  `/var/lib/containerd` — and `gb5-docker-preflight` cannot see that.
- **`defaultKeepStorage` in `builder.gc` is a no-op whenever `policy` is set.**
  It only synthesises a default policy. Use `reservedSpace`/`maxUsedSpace`/
  `minFreeSpace` and no `policy`.
- **Container DNS is pinned, not inherited,** and the pinned value is this host's
  dynamic wt0 address. `gb5-docker-verify` FAILs if it drifts.
- **Never hardcode a device GID.** Two udev rules conflict over `accel`, so
  `/dev/dri/renderD128` (0666) and `/dev/accel/accel0` (0660) are not stable
  across updates. Use `--group-add "$(stat -c %g /dev/dri/renderD128)"`.
- Rationale for every `daemon.json` key is in `/etc/docker/daemon.json.why` —
  Docker rejects unknown keys, so it cannot live in the JSON.

### Kernel modules between an update and the reboot

- **A kernel upgrade deletes `/usr/lib/modules/$(uname -r)` while it is still
  running.** Anything needing a *new* module then fails. Docker needs `overlay`,
  `br_netfilter`, `veth`, `bridge`; NetBird needs `nft_ct`, `nft_fib_ipv4`,
  `nft_masq` and **dies on any restart** without them, with an error that names
  netlink and not modules.
- **The tree is recoverable without rebooting.** Every pre-upgrade Timeshift
  snapshot holds it byte-identical. Verify `modinfo -F vermagic` against
  `/proc/version` first, then `cp -a` + `depmod -a`. Full procedure in
  `docs/system/docker.md`.
- **Never detect a pending reboot by testing whether that directory exists.**
  Restoring the tree makes the pending reboot invisible, and four checks here
  once did exactly that. Compare **kernel versions** — running vs newest
  installed. That cannot be faked by putting files back.

### Shell

- **Never `pkill -f` a pattern that also appears in your own command line** — it
  kills your shell. Kill by PID.
- **`/tmp` is tmpfs (RAM).** Do not write large files there.
- **`ps -o pcpu` is a lifetime average, not current usage.** Use a delta over
  `/proc/<pid>/stat`.
- **`$HERE` differs between setup scripts** — repo root in `40-system.sh`,
  `setup/` in `60-hibernate.sh`. A wrong path fails *silently* through `[ -f ]`.
- **Never `producer | grep -q pattern` under `set -o pipefail`.** `grep -q` exits
  on the first match, the producer gets SIGPIPE, and `pipefail` turns 141 into a
  failed pipeline — so the test takes the false branch **because it matched**.
  This silently inverted six checks here, including `sbctl verify | grep -q '✗'`,
  which reported "all EFI binaries signed" on a machine with 116 unsigned ones.
  Use `grep -c` and compare, or the `matches()` helper in `gb5-safe-update`.
  Short producers can mask it: `dkms` finishes writing before `grep` exits, so
  that one worked by timing, not by correctness.
- **Do not `source` a file you generated with bare `echo "k=$v"`.** A value
  containing `;` executes. Write it with `printf '%q'`.

## Updating

**Use `gb5-safe-update`.** It does every check that used to be manual, refuses
rather than guessing, and verifies afterwards instead of trusting that a hook ran.

```bash
sudo gb5-safe-update --check    # pre-flight only, changes nothing
sudo gb5-safe-update            # do it
```

**It runs itself weekly.** `gb5-safe-update.timer` fires Sunday 10:00 (±10 min).
There is deliberately **no `OnBootSec`** — that is a monotonic trigger which
elapses once per *boot*, not a delay on the `Persistent=` catch-up, and adding it
turns a weekly timer into a per-boot one that can fire twice on the same boot.

It **refuses**, changing nothing, if: the update gate is already failing, a
kernel update is pending a reboot, a stale `pacman/db.lck` is present, the
battery is under 50% off AC, root or the **ESP** is short of space, `checkupdates`
errored (rc 1 — *not* the same as rc 2, "no updates"), or the transaction would
install **stock libfprint** over the patched build.

It then clears any hibernation image, snapshots, updates in a single `-Syu`, and
— when the **running** kernel was superseded — masks hibernation until the
reboot. Kernel change is decided from state (module trees before/after, running
vs newest), **never from a package name**: `linux71` hardcoded here silently
disabled this branch at the 7.1 -> 7.2 bump (HISTORY Phase 8).

The fallback UKI, the removable fallback and sbctl's database are kept right by
**`gb5-boot-guard.sh`**, run by `zzz-gb5-boot-guard.hook` after *every*
boot-relevant transaction (so a manual `pacman -Syu` is covered too) and again by
the updater. `gb5-boot-guard.sh --check` is read-only; the plain form repairs and
refuses while `db.lck` exists. Manjaro's `98-install-grub.hook` is **disabled**
(symlink to `/dev/null`) — it copies a shim_lock GRUB over the removable path.

### The gate is not `gb5-verify.sh`

Deliberately. That suite answers "is this desktop healthy", which is the wrong
question here: it fails on a busy microphone, on any unrelated failed unit, on
one transient journal line, and on `kscreen-doctor` when there is no Wayland
session. Under automation a false refusal is indistinguishable from a real one.

The gate is the `gate()` function inside `gb5-safe-update` — deterministic,
session-independent, and only about what an update can break: DKMS built **for a
named kernel** (`dkms status -k`, because a bare `grep installed` matches a stale
entry for *any* kernel), nothing unsigned by *our* key (filter `/EFI/Microsoft/`
— those 116 `✗` lines are Microsoft-signed and always will be), the main UKI
signed, the resume offset matching `/etc/kernel/cmdline`, the patched libfprint
present **and** its libraries resolvable (`ldd | grep 'not found'` catches a
soname bump, which every `strings`-based check survives while `fprintd` cannot
load the library and auth falls through to a password).

The full suite still runs afterwards, printed as **information, not a verdict**.

### Outcomes are not interchangeable

`/run/gb5-safe-update.status` records one of `nothing-to-do`, `updated`,
`refused`, `update-failed`, `verify-failed`, and `gb5-update-notify` renders each
differently. This matters: **"refused" means nothing was touched**, and telling
that user to restore a snapshot points a destructive recipe at a healthy machine.
Any printed rollback must start with **destroying the hibernation image** —
restoring with one live strands it over a rolled-back filesystem.

If no graphical session takes the notification it is left in
`/etc/motd.d/gb5-update` and `/var/lib/gb5/last-update-message`. Those are the
durable channels; the desktop popup is best-effort.

### What is still not protected

- A root `systemctl poweroff` bypasses the `systemd-inhibit` wrapper. If a
  transaction is killed between `90-mkinitcpio-install.hook` and `zz-sbctl.hook`
  the main UKI is **unsigned** — which under Secure Boot looks like a brick. The
  next run detects the leftover `db.lck` and says so.
- Nothing rebuilds the AUR `libfprint-egismoc-sdcp-git` after a soname bump. The
  gate *detects* it; you rebuild by hand from
  `packaging/libfprint/PKGBUILD`.
- Snapshot pruning is opt-in in the script and **opted in** by the service unit
  since 2026-11-19 (`GB5_PRUNE_SNAPSHOTS=1`, keep 3). Only snapshots the updater
  itself made are ever deleted.
- **AUR packages are never updated unattended** (`pacman -Qm`). Flatpak is, by
  `gb5-flatpak-update.timer` (Sun 10:30, AC only).

Doing it by hand instead? The sequence is in `bin/gb5-safe-update` — read it
rather than reinventing it, because each check is there for something that
actually happened.

**Between the update and the reboot, the running kernel has no modules.**
`/usr/lib/modules/<running>` is deleted by the upgrade, so `modinfo` resolves
nothing and any module load fails. `gb5-verify.sh` reports this as a NOTE rather
than a FAIL. It is also why the resume hook refuses to unload
`samsung_galaxybook` in this window — it could not put it back. Note that hook
**cannot refuse a hibernate**: `systemd-sleep` ignores system-sleep scripts' exit
status. Enforcement is `systemctl mask` on the sleep targets, undone at the next
boot with a matching module tree by `gb5-unmask-hibernate.service`.

## Where to look

| Question | File |
|---|---|
| What was done and every wrong turn | `HISTORY.md` |
| Battery, power, what is worth tuning | `docs/power/battery-plan.md`, `docs/power/power-and-tuning.md` |
| Hibernation, and what S4 breaks | `docs/system/hibernation.md` |
| Fingerprint, PAM, lock screen | `docs/system/pam.md`, `docs/hardware/setup-notes.md` |
| Secure Boot, UKI, boot traps | `docs/system/secureboot-uki.md` |
| Snapshots and rollback hazards | `docs/system/snapshots-and-rollback.md` |
| Settled hardware facts — do not re-investigate | `docs/hardware/audit-results.md` |
| What is deliberately absent | `docs/not-included.md` |
| Open work | `TASKS.md` |

## House style

Findings in this repo are written so the *reasoning* survives, not just the
conclusion. When you correct something, **say what was wrong and how it was
caught** rather than quietly editing — several entries in `HISTORY.md` are
corrections of corrections, and that trail is the point. If a claim cannot be
supported by a measurement you actually took, say so plainly.
