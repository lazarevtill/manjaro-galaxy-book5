# Galaxy Book5 Pro H on Manjaro — the whole record

Samsung 965XHD, Core Ultra 7 255H (Arrow Lake-H, family 6 model 0xC5),
Manjaro, kernel 7.2.9 (7.1.8 at the start), KDE Plasma 6 on Wayland.

This is the narrative: what was done, in what order, what was wrong along the
way, and how each error was caught. The per-subsystem detail lives in the other
files; this one exists so the reasoning is not lost.

**The single most useful thing in here is the list of mistakes.** Almost every
one was a confident, plausible, wrong conclusion drawn from a measurement that
looked fine. They are kept in place rather than quietly corrected.

---

## Phase 1 — Hardware enablement

Getting the machine to work at all. Detail in
[`docs/hardware/setup-notes.md`](docs/hardware/setup-notes.md).

| Subsystem | Outcome |
|---|---|
| **Camera** (IPU6 / ov02e10) | Working at 1920×1088 @ 30 fps. Needed a DKMS sensor patch retiming `vts_def` 2244 → 3039 for the 26 MHz clock, which took the sensor from 40.6 fps at gain 193 to 30.0 fps at gain 144 |
| **Speakers** (max98390) | DKMS module; silent without it |
| **Fingerprint** (Egis Match-on-Chip, SDCP) | Replaced libfprint with a patched build. Three fixes: a task_ssm crash, SDCP host-key persistence across reboots, and a match being reported as a failure |
| **Secure Boot** | Enabled, with a signed UKI behind systemd-boot. GRUB cannot be made to work here |
| **Snapshots** | Timeshift on btrfs, protecting a rolling distro carrying three DKMS modules |

### What went wrong in this phase

- **Declared fingerprint working prematurely.** `fprintd-list` reads fprintd's
  own record, not the sensor. A successful verify logs nothing, so "no errors"
  proves nothing. The only real test is an actual match.
- **`journalctl --since` matched future-stamped entries** because Windows leaves
  the RTC on local time. Fixed by using `--after-cursor`.
- **Claimed a GStreamer `hqdn3d` filter was "free".** The benchmark was
  `pngenc`-bound, not filter-bound. Re-measured with `fakesink` and pinned caps.

---

## Phase 2 — Power and efficiency

The bulk of the work. Detail in [`docs/power/power-and-tuning.md`](docs/power/power-and-tuning.md)
and [`docs/power/battery-plan.md`](docs/power/battery-plan.md).

### What was actually fixed

- **OpenVINO could not see the GPU.** `plugins.xml` declared it, but
  `openvino-intel-gpu-plugin` was not installed, so `available_devices` returned
  only `['CPU', 'NPU']`. Silent failure — code asking for `GPU` just fell back.
- **Camera effects were pinned to the NPU.** Moved to the iGPU: 3.9× headroom
  instead of 1.2×, and ~1.4 W less at a fixed 30 fps.
- **`intel-lpmd` was masked.** Patched to recognise model 0xC5, measured, found
  to save nothing (7.94 W vs 7.87 W), and found to pin the systemd slices to
  CPUs 0–13 — excluding the two LP-E cores — with the restriction outliving the
  daemon.
- **A USB Ethernet adapter was holding the platform's latency floor** at 128 µs,
  keeping package C8/C10 at exactly zero. Unplugged, they began accumulating.
- **The 60 Hz-on-battery switch never worked.** This panel has no 60 Hz mode at
  native resolution; `kscreen-doctor` exits 0 even when it prints "Output mode
  not found", so the script logged success for weeks.
- **The battery profile script never released its own override on AC**, leaving
  the machine capped at 1025 MHz on mains after any dip below 50%.

### The answer

**6.22 W at a light workload, 12.2 h** by coulomb count over 45 gauge steps, and
**5.91 W / 12.9 h** in the quietest window achieved — the realistic ceiling for
this configuration.

18 h is not reachable — it needs 4.22 W, below the idle floor once bursts are
counted. But **what is on the screen matters more than everything else combined**:
a white screen costs ~15 W against ~5 W for black, a bigger gap than idling
versus compiling.

The SoC is essentially optimal already: 3.30 W package, 0.23 W cores, 95% GPU
RC6, package C10 reached, every device power-management knob correct.

### What went wrong in this phase

This is the valuable part.

1. **"The uncore is pinned at 3900 MHz."** It is not — that is the ceiling. It
   idles at 1300–1500 and scales on its own. Capping it saves under 0.2 W, and the
   bandwidth cost is severe only at the extreme: 70% was measured at a **400 MHz**
   cap, not at every cap below 1600 MHz.
2. **"Package C-states never engage."** Measured under load. On a quiet machine
   the deepest residency is 12%. And `Pkg%pc7`/`Pkg%pc9` *cannot be reported* on
   this family at all, so half the alarm was architectural.
3. **"The iGPU is Xe2 / Arc 140T" and "the NPU is NPU 4."** Both wrong. It is
   Xe-LPG+ (kernel platform `METEORLAKE`) and NPU 3720 — literally Meteor Lake
   silicon, because Arrow Lake-H reuses the MTL SoC tile. Most tuning advice
   written for "Core Ultra 200" does not apply.
4. **The NPU benchmark used a resolution the application never runs.** Everything
   was measured at 512×512; `linux-studio-effects` uses 256×256. At the real
   shape the NPU manages 36.6 fps, so "the NPU cannot sustain 30 fps" — which had
   been written into `config.py` as justification — was false.
5. **"15.6 h measured."** That was an idle *floor* extrapolated as a runtime. The
   machine is only that quiet 76–91% of the time.
6. **`current_now` is biased low**, by 17–22%, so runtimes must integrate
   `charge_now`. Note the *reason* first given here — "snapshots miss bursts" —
   is itself wrong and is catalogued as mistake #11.
7. **The battery gauge has 49 mAh of resolution**, stepping roughly every 445 s.
   A `quiet` vs `balanced` A/B run as four 12-minute arms produced 98, 98, 98 and
   49 mAh — that is 2, 2, 2, 1 steps of pure quantisation. Reported as **"not
   measurable"**, which is a different claim from "no difference".
8. **The documented `intel-lpmd` recovery did not work.** Writing `cpuset.cpus`
   treats the symptom; lpmd sets a *systemd property*, which systemd re-applied
   on the next `daemon-reload` — triggered, an hour later, by installing an
   unrelated service.
9. **Alternating order does not defeat heat soak.** A profile comparison gave
   40.2 W and 31.6 W for the *same* profile, because by the second round the
   machine had been loaded for seven minutes. Only cooling between arms fixes it.
10. **The largest single source of wakeups during the idle measurements was the
    agent taking them** (96.8/s, ahead of the compositor at 63.3). The figures
    describe a machine with something light running on it, not a synthetic idle.
11. **"Snapshots miss bursts" was the wrong mechanism.** Periodic sampling is
    unbiased unless it correlates with load. Integrating `current_now` over 634
    samples gave 1699 mAh where `charge_now` decremented 2205 mAh — two registers
    of the *same gauge*, 23% apart, which sampling cannot cause. `current_now` is
    **biased low**, so the idle-floor figures derived from it are ~23% low in
    absolute terms and are only good for ranking states.
12. **The error bar quoted quantisation only.** 11.9 h ± 0.4 ignored the mAh→Wh
    voltage assumption and an optimistic `charge_full` (4900 mAh, above design).
    Honest figure: **± 0.5–0.8 h**.
13. **`quiet` at "exactly 1025 MHz, a hard cap"** contradicted three same-day
    readings of 1925, 1863 and 1862 MHz. The reconciliation — that quiet permits
    a burst then clamps, so only the cooled protocol saw the floor — is a
    hypothesis, and the config change shipped before it was tested.
14. **The profile comparison was measured on AC and deployed on battery**, where
    the EC enforces different limits. And with `GB5_PROFILE_LOW=balanced` the
    ≤50% threshold became dead code.

---

## Phase 3 — The 2026-08-22 hibernation incident

One failed hibernate, three broken subsystems, nine silent hours. Full account in
[`docs/power/power-and-tuning.md`](docs/power/power-and-tuning.md).

A hibernate was requested at 11% battery. It could never have succeeded: the
kernel sizes the image from `image_size` (12472 MiB default on 30 GiB of RAM)
against 9011 MiB of swap. It allocated, prepared S4, failed to write, and resumed
28 ms later — resetting the USB bus and wedging the Samsung SCAI/EC interface.

| Broken | Repair |
|---|---|
| Fingerprint auth (fell through to password) | at the time, `rm sdcp-claim` — **the destructive route**, since that file is the host keypair and deleting it makes the sensor disown the templates. Obsolete since the pkgrel-5 patch: `systemctl restart fprintd` |
| Keyboard backlight, Fn path | `modprobe -r samsung_galaxybook && modprobe samsung_galaxybook` |
| Keyboard backlight, KDE path | `systemctl restart upower` (stale LED handle) |
| `power_on_lid_open` | same driver reload |

Mitigated by capping `image_size` at 7 GiB. **Hibernation that is enabled but
cannot complete is worse than hibernation switched off.**

### What went wrong here too

- **"The keyboard backlight never worked."** Based on a `CSFI` failure at driver
  init — which appears in every healthy boot. Only comparing failure *counts*
  across boots showed it: 1, 1, 1, then 201. The user saying "it worked
  yesterday" is what forced that comparison.
- **The hardware audit recorded the keyboard backlight as verified**, on the
  evidence of "watching sysfs move". The LED class caches the written value and
  echoes it back whether or not the firmware accepted it.
- **Misread `KBCL` as an EC register.** It is in `OperationRegion (SNVS,
  SystemMemory, ...)` — ACPI NVS. The EC read at that offset returned an
  unrelated byte.

---

## Phase 4 — Hibernation, fixed and tested (2026-08-23)

The 2026-08-22 incident was a symptom; this is the cure. Detail in
[`docs/system/hibernation.md`](docs/system/hibernation.md).

Hibernation had been enabled and, *in the state the machine was actually in*, unable to complete: the kernel sizes the image
up to `image_size` (~2/5 of RAM) against an 8.8 GiB swap partition, and with a
build running RAM in use was 17.7 GiB. A 7 GiB `image_size` cap was tried first
and was **inadequate** — it only made the kernel give up earlier.

**The fix:** a 20 GiB swapfile on its own `@swap` btrfs subvolume, a sibling of
`@` so Timeshift never snapshots it, with `resume_offset` in the kernel command
line. Verified by a real S4 cycle — same `boot_id`, uptime continued 527 s →
781 s.

Two things a *successful* hibernate still does, both now handled automatically:

- **wedges part of the SCAI interface** — keyboard backlight and
  `power_on_lid_open` break while `usb_charging` and `platform_profile` keep
  working, so power management looks healthy while the backlight is dead. A
  sleep hook reloads `samsung_galaxybook` on resume.
- **kills the fingerprint SDCP session.** Driver patched (pkgrel 5) to treat the
  `AuthorizedIdentity` MAC failure as a reconnect trigger. The first touch after
  each resume still fails — the driver only learns the session is stale by
  failing — then it reconnects and works.

Also fixed: the machine resumed straight into an **unlocked** desktop.

### What went wrong in this phase

15. **"A clean S4 preserves the SDCP session."** Recorded on the strength of a
    `verify-no-match` with no finger on the sensor — which never reaches the
    `AuthorizedIdentity` check. **The identical trap as the `max-tries` test the
    day before.** Only a real finger settled it, and the session was dead.
16. **Three broken versions of one verify check.** The "match overturned"
    detector counted results across a whole boot (fails whenever there are more
    failed touches than successful ones), then compared a filtered sequence
    (made a match in one operation look adjacent to a no-match minutes later).
    It now pairs events by timestamp.
18. **"No amount of free memory would have helped."** Said of the failed
    hibernate. False: the kernel uses `min(saveable, target)`, so with RAM use
    under ~8.8 GiB the old partition would have worked — as this project's own
    earlier table (7.44 GiB in use, 1.36 GiB headroom) shows. It failed because
    17.7 GiB was in use, not because failure was unconditional.
19. **The fallback UKI was a corruption trap.** It was given the OLD command
    line deliberately, as "a genuine escape hatch". But the old cmdline pointed
    at a different resume device, so booting it after a hibernate would skip the
    resume, leave the image stranded (`swapon` refuses an `S1SUSPEND` header, so
    nothing clears it), and the next normal boot would restore that stale image
    over a filesystem that had moved on. Every boot entry must now share one
    resume target; a fallback should differ only in what is being tested.
20. **"Run mkinitcpio to rebuild and re-sign".** `mkinitcpio` does not sign —
    signing is a *pacman* hook, which never fires for a manual run. Following
    that instruction under Secure Boot produces an unsigned UKI that will not
    boot.
21. **A verify check that counted instead of probing.** "CSFI failures under 10"
    summed across the whole boot, so it could not distinguish "wedged now" from
    "was wedged and has been repaired" — and running diagnostics inflated it into
    a false failure. It now pokes the interface and checks whether *that* poke
    failed.
22. **A setup script that reproduced a bug the repo had already fixed.**
    `30-fingerprint.sh` inserted `pam_fprintd` before the first `auth` line,
    which in `/etc/pam.d/login` is `pam_nologin` — letting fingerprint auth
    bypass `/etc/nologin`, and producing a file different from the one the repo
    ships. It also never installed the `kde-fingerprint` override, so a fresh run
    recreated the missed-lock-screen bug.
17. **A setup script that installed nothing.** `$HERE` in `40-system.sh` is the
    repo root, not `setup/`, so `$HERE/../tools/` pointed outside the repo and
    every `install` was skipped silently by its `[ -f ]` guard.

## Phase 5 — Unattended updates (2026-08-23)

The last manual thing left was updating. `gb5-safe-update` already existed and
had done the 212-package update by hand; the ask was to put it on a weekly timer
and leave it alone. Automating a script is not the same as writing one, because
the failure modes change: nobody is watching, so every outcome has to be
*distinguishable*, and a check that cannot fire is worse than no check at all —
it reports success.

Two reviews ran over it. Between them they found that **the two protections that
mattered most were both inert**, and neither was inert in a way that showed up on
a normal run.

23. **The hibernation-image guard was dead code that printed success.** The
    branch was `swapoff && mkswap && swapon`, followed on the next line by an
    unconditional "cleared a hibernation image". But a swapfile whose header
    reads `S1SUSPEND` was *refused by `swapon` at boot*, so it is not active —
    `swapoff` fails with EINVAL, the `&&` chain short-circuits, `mkswap` never
    runs, and the success message prints anyway. The single guard against
    guaranteed btrfs corruption could not fire, and said it had. Now: no
    chaining, and failure **aborts** instead of warning.

24. **`grep -q` in a pipeline under `set -o pipefail` inverts the test.** This is
    the one worth remembering. `grep -q` exits the moment it matches; the
    producer gets SIGPIPE; `pipefail` propagates 141; the `if` therefore takes
    the *false* branch **because the match succeeded**. Measured, not reasoned:

        $ set -uo pipefail
        $ strings /usr/lib/libfprint-2.so.2 | grep -q 'Invalidated the cached SDCP session'
        $ echo $?
        141          # the string IS present

    Six checks were affected. `sbctl verify | grep -q '✗'` reported *"all EFI
    binaries signed"* on a machine with 116 unsigned binaries. The
    patched-libfprint check reported the patch **GONE** while it was present. The
    `ldd`-for-missing-libraries check could never report a missing library. The
    DKMS check only worked by luck — `dkms` output is small enough to finish
    writing before `grep` exits, so no SIGPIPE. That is timing, not correctness.

25. **A review can diagnose the right line for the wrong reason.** The review
    flagged the `sbctl` check as guaranteed to *fail* every run, on the sound
    observation that this ESP carries ~116 Microsoft-signed binaries that sbctl
    marks `✗`. Running it showed the opposite: it *passed* every run, because of
    #24. Both fixes were needed — filter `/EFI/Microsoft/` **and** stop using
    `grep -q` — but a fix aimed only at alarm fatigue would have left a check
    that still could not fire.

26. **The status file was a root command-injection.** The script wrote
    `echo "detail=$DETAIL"` and the notifier read it back by *sourcing* it. With
    `DETAIL="pre-flight refused; nothing was changed"`, sourcing runs `nothing`
    as a command, as root. Written with `printf '%q'` now, and the round-trip is
    tested against a payload.

27. **`OnBootSec=` does not delay a `Persistent=` catch-up — it adds a second
    trigger.** It is a *monotonic* timer that elapses once per boot, every boot,
    so `OnCalendar=Sun 10:00` plus `OnBootSec=20min` is not a weekly timer at
    all. Worse, on a boot that also owes a catch-up the service runs **twice**:
    the first run installs a kernel, and the second correctly refuses because a
    reboot is pending — producing a critical "verification FAILED, consider
    rolling back" alert for a machine whose only correct next action is to
    reboot. `OnBootSec` is gone.

28. **"Hibernate is refused by the sleep hook" was invented.** The script printed
    it after every kernel update. `systemd-sleep(8)` **ignores the exit status**
    of `/etc/systemd/system-sleep/` scripts — they have no veto — and this hook
    only skips a module reload. So hibernating between a kernel install and the
    reboot really did write an image the new kernel refuses to resume. Real
    enforcement now: the targets are `systemctl mask`ed, and
    `gb5-unmask-hibernate.service` restores them at the next boot that has a
    matching module tree.

29. **`ConditionACPower=true` fails silently and permanently.** A failed
    condition *skips* the unit: `ExecStopPost` never runs, so no notification,
    and the timer still marks the trigger elapsed, so `Persistent=` will not
    retry it. Someone who spends Sunday mornings unplugged would get no updates
    and no signal, indefinitely. Dropped from the unit — the script's own
    pre-flight refuses on battery instead, which is *loud* and retried next week.

Three smaller ones, recorded because each is the same shape as something above:
`checkupdates` returning **1 on error** and **2 on no-updates** was read as
"nothing to do", which would have produced cheerful weekly success notifications
on a machine that had silently stopped updating; `dkms status | grep installed`
matched an `installed` line for **any** kernel, so a failed build for the new one
passes while a stale entry for the old one lingers; and the ESP free-space
pre-flight demanded room for **one** UKI when a kernel *series* bump writes new
filenames for both the main image and the fallback — about 84 MiB, not 42.

And one committed while writing this up: the commit message describing the
`pacman -Sy` partial-upgrade fix contained an unquoted backtick, which executed a
live `pacman -Sy` mid-commit and pasted its output into the message — the exact
bug being described. Harmless here (nothing was pending), amended from a file.

## Phase 6 — Containers, and a self-inflicted VPN outage (2026-08-23)

Docker from scratch, reviewed by two agents before anything was enabled. They
disagreed with each other once, and verifying their findings turned up things
neither had seen — including a check I had just written that could never fire.

30. **A published port would have been open to the whole VPN.** `-p 8080:80`
    binds `0.0.0.0`; Docker inserts `DOCKER-FORWARD` at the **top** of FORWARD
    while NetBird's only inbound guard, `-i wt0 -j DROP`, is the **last** rule.
    Confirmed on the live ruleset, not reasoned about. Every published port would
    have been reachable from all of `100.76.0.0/16` and the LAN. Fixed with
    `"ip": "127.0.0.1"`.

31. **`defaultKeepStorage` was a silent no-op.** It only synthesises a default GC
    policy, and an explicit `policy` was present — so the 20 GB cap never
    applied. The hand-rolled policy had also dropped the BuildKit rule that
    reclaims `source.local`, `exec.cachemount` and git checkouts: exactly what
    grows in a dev loop.

32. **`containerd-snapshotter: false` is an opt-OUT, not a default.** Docker 29
    makes the containerd image store the default. That one line is the only thing
    keeping the image store on `@docker` rather than in `/var/lib/containerd`
    inside `@` — where the preflight guard cannot see it. containerd's root was
    moved onto the subvolume so the flag stops being load-bearing.

33. **The two reviewers disagreed about DNS, and both had a point.** One wanted
    a public fallback so containers survive the VPN dropping; the other said that
    leaks internal names on timeout. Pinned with no fallback, and the trade-off
    written down rather than hidden. Later found that NetBird already forwards
    `[.]` to `1.1.1.1` itself, so the leak was narrower than argued — the
    conclusion held for a smaller reason than the one given for it.

34. **Neither reviewer noticed the pinned DNS is dynamic.** It is this host's own
    wt0 address. If NetBird reassigns it, every container loses DNS with no
    visible cause. `gb5-docker-verify` now fails on the drift.

35. **I took the VPN down and then misdiagnosed it as a version regression.**
    Restarting NetBird to install 0.77.1 killed the tunnel. The instinct was
    "the update broke it" — wrong. Rolling back to 0.77.0 failed *identically*.
    The real cause: a kernel upgrade deletes `/usr/lib/modules/$(uname -r)` while
    that kernel still runs, so `nft_ct`, `nft_fib_ipv4` and `nft_masq` cannot
    load. The daemon had survived only because it predated the upgrade. **Any**
    restart would have done it. Established by probing each nft expression
    separately instead of arguing from the error text:

        table / chain / set / counter   OK
        ct state / fib / masquerade     FAIL

36. **No flag avoids it, and reading the source is what settled that.**
    `--disable-firewall`, `--disable-server-routes`,
    `NB_FORCE_USERSPACE_FIREWALLS` and `NB_FORCE_USERSPACE_ROUTER` are all
    evaluated *after* `Create()` builds the firewall manager, which is where it
    dies. Three of those were tried before checking; the source answered in one
    read.

37. **The fix was on the disk the whole time.** Manjaro's mirrors had dropped
    7.1.8 and `archive.manjaro.org` is IPv6-only with no route from here — but
    every pre-upgrade Timeshift snapshot still held the complete module tree,
    byte-identical. `modinfo -F vermagic` checked against `/proc/version` first,
    then `cp -a` and `depmod`. Not a forced version mismatch: these were the
    originals for the running kernel.

38. **And that fix quietly disabled four safety checks.** All four detected a
    pending reboot by testing whether `/usr/lib/modules/$(uname -r)` exists.
    Putting the tree back made a pending reboot invisible: `gb5-safe-update`
    would have stacked a second kernel upgrade onto an unrebooted one, and
    `gb5-unmask-hibernate` would have re-enabled hibernation while a stale-kernel
    image could still be written. Now they compare kernel *versions*, which
    cannot be faked by restoring files.

39. **The NetBird installer leaves a local root escalation.** `/usr/bin/netbird`
    owned `lazarevtill:755` while `netbird.service` runs it as **root**. Anything
    running as that user could overwrite it and own root at the next restart.
    Found only because the UI investigation happened to `stat` the binaries.

40. **The UI had never worked for a mundane reason.** It was installed all along;
    `ldd` showed it wants **WebKitGTK 6.0**, which is not on this machine. The
    GTK3 release asset links against the `webkit2gtk-4.1` already present. It
    also ships no `.desktop` and no icon, which is why nothing appeared in the
    launcher.

## The rules that came out of all this

1. **Both arms of an A/B run in the same minute, order alternated** — and if heat
   is involved, cooled to a common start, because reordering cannot fix heat soak.
2. **If within-condition spread exceeds between-condition difference, say "not
   measurable".** It is not the same as "no difference".
3. **Count the instrument's steps before believing it.** Under ~8 gauge steps per
   arm you are measuring the gauge, not the machine.
4. **A snapshot is not an average, and an idle floor is not a runtime.**
5. **Verify by reading state back, never by checking an exit code.**
   `kscreen-doctor` exits 0 on "mode not found"; sysfs echoes writes the hardware
   rejected.
6. **Say what was running.** Every "idle" number here includes the agent that
   measured it.
7. **A number read off a busy desktop is a number about the desktop.**
8. **Never `producer | grep -q pattern` under `pipefail`.** The match SIGPIPEs
   the producer and the pipeline reports failure *because* it matched. Use
   `grep -c` and compare, which reads its input to the end.
9. **Prove a check can fail before trusting that it passed.** Every guard here
   that turned out to be inert looked exactly like a passing guard. Run each one
   against a known-bad input once.
10. **A wrong diagnosis is most likely right after you changed something.** The
   VPN died on a NetBird restart, so the update looked guilty. Rolling back is
   what proved it innocent — and cost nothing. Reach for the rollback before the
   theory.
11. **Read the source before trying the third flag.** Three env vars and two CLI
   flags were tried against a failure that one look at `Create()` explained.
12. **A recovery can disable the detector for the thing it recovered from.**
   Restoring the module tree made a pending reboot invisible to four checks.
   After any repair, ask what now looks healthy that is not.
13. **Under automation, "refused" and "broke" need opposite advice.** Collapsing
   them into one alert told the user to restore a snapshot over a healthy
   machine — and, for a while, without destroying the hibernation image first.
14. **A guard keyed to a name expires with the name.** `linux71` as a literal
   turned the kernel branch into dead code the day Manjaro moved to `linux72`.
   Decide from state — what changed on disk — never from a package name.
15. **A fix is new, unexercised code.** The Phase 8 repair repeated the mtime
   bug it was fixing and introduced three more; an adversarial review caught
   them before commit. Review the fix as hard as the fault.

## Phase 7 — The freezes, diagnosed and made recoverable (2026-09-11)

After a full system freeze, the journal was mined for every abrupt termination.
Seven boots ended without a shutdown sequence; four of those were "froze during
active use" (boots -13, -11, -5, -1), the rest boot-time deaths.

**Two independent faults, not one:**

- **A — monitor-mode Wi-Fi (boots -13, -11).** Running aircrack-ng (airodump /
  aireplay) on the internal Intel BE201 (Wi-Fi 7, `iwlmld` op_mode) makes the
  firmware assert (`ADVANCED_SYSASSERT` / `NMI_INTERRUPT_LMAC_FATAL`); the
  restart path then hits a kernel `Oops: general protection fault …
  0xdead000000000122` (LIST_POISON2 = use-after-free) at
  `ieee80211_free_chanctx [mac80211]`, cascading through `iwlmld`. **Confirmed,
  reproducible.** Kernel 7.1.13 does NOT fix it — the wireless modules'
  `srcversion` is byte-identical to 7.1.9 (diffed against the pre-upgrade
  Timeshift snapshot), and it still loads `c102` firmware though c103/c106 are
  present. The only real remedy is to stop using the Intel card for monitor
  mode; an external USB adapter (AR9271 / MT7921AU) bypasses `iwlmld` entirely.

- **B — silent hard hangs (boots -5, -1).** No trace of any kind: no oops,
  panic, MCE, thermal, GPU, AER, RCU, or hung-task. An Arrow Lake-H platform/SoC
  hang below the kernel's ability to log. Root cause still unknown; now made
  *catchable* (see below).

**The amplifier common to both:** the machine was configured to turn recoverable
faults into permanent hangs — `kernel.panic_on_oops=0`, `kernel.panic=0`, and
`kernel.nmi_watchdog=0` (the last from `99-gb5-tuning.conf`, disabled to save a
PMU counter). The fix flips all of these: an oops or a detected lockup now
panics and auto-reboots in 20 s instead of deadlocking. Added the **iTCO
platform watchdog** (`RuntimeWatchdogSec=30s`) — it lives in the PCH,
independent of the CPU cores, so it recovers a full SoC hang the perf/NMI
detector provably cannot (that is the only mechanism that can rescue class B).
Installed **linux612 (LTS)** as a signed fallback UKI now that auto-reboot is
armed (camera and speakers do not build on 6.12 — acceptable for an emergency
kernel). New `gb5-verify.sh` "Crash recovery" section checks all seven knobs.

### What went wrong in this phase

- **"thermald is flooding the log with `FAN0._FST` errors."** A reviewer's
  confident attribution. Stopping thermald for 15 s changed the 2 Hz error rate
  by nothing; pausing KDE's `ksystemstats` dropped it to zero. The flood is the
  **Plasma fan-speed sensor** polling a broken Samsung fan AML method — not
  thermald, which was left untouched. Nearly became confident-wrong-conclusion
  number 30.
- **"The oops deadlocks the machine immediately."** It does not. The same GPF
  oops occurred in boots -12 and -14 and both *survived* (clean / degraded
  reboot); -10 had 24 firmware asserts and no oops and shut down cleanly. In the
  fatal boots the machine limped ~7.5 min after the oops before fully hanging.
  The oops is *intermittently* fatal — it wedges only when the dead worker
  thread happened to hold a contended net lock. This refined the model and, if
  anything, strengthened the `panic_on_oops=1` fix (it makes the coin-flip
  deterministic).
- **Adding the LTS kernel armed a latent bug in `gb5-ensure-uki.sh`.** Found by
  an Opus 5 review, missed by three earlier ones. The script picked the default
  boot entry by **mtime** (so the most recently *built* UKI won — the older LTS)
  and compared it against `Default Boot Loader Entry:`, which is an empty
  section *header* in `bootctl` output, not the value (`Default Entry:` is). The
  comparison therefore never matched and it re-set the default on **every** run.
  Its hook fires on `Target = linux*`, which matches all 17 `linux-firmware-*`
  packages — so the next weekly `gb5-safe-update` would have silently booted the
  machine into 6.12, with no camera and no speakers. Fixed to sort by version
  and exclude `-fallback` UKIs; `gb5-verify.sh` now asserts the default entry.
- **"Class B is a platform/SoC hang below the kernel's ability to log."**
  Overreach, corrected by Opus 5. `kernel.nmi_watchdog = 0` was in force during
  every freeze, and an ordinary *software* hard lockup (IRQs off, a CPU spinning
  in any driver) produces exactly this zero-trace signature when the detector is
  off and pstore is absent. B is **undetected, not proven platform-level** — so
  the now-armed NMI watchdog has a real chance of catching it.
- **A `sudo -S` heredoc leaked the temp password into a config file** under
  `/etc`. Caught and cleaned; the rest of the session used cached-cred `sudo -n`.

## Phase 8 — The updater met a series bump, alone (2026-09-12 → 2026-11-19)

For ten weeks nobody wrote in this record, and the machine kept running it:
the weekly timer fired eight times — six updates, one refusal
(2026-10-07, `checkupdates` failed on a bad mirror: refused, nothing touched,
exactly as designed), one "nothing to do". Every update printed **"Update
complete and verified."** The record went quiet; the journal did not.

Two things changed the machine in that window without an entry here:

- **BIOS P05RHH.280 → P06RHH.300 (2026-08-06 build)**, flashed between the
  2026-09-20 and 2026-09-28 boots, via Windows. TASKS still called it "the top
  untried lever" for the class-B freezes. Since the flash, `/sys/fs/pstore` is
  empty and every boot ended in a shutdown sequence. That is *correlation over
  ~25 boots*, not proof the freezes are fixed.
- **2026-11-11: 602 packages, on battery at 76%**, including the first
  **kernel-series bump** this setup ever met unattended: Manjaro retired
  `linux71` (7.1.13) for `linux72` (7.2.9) in a single transaction, plus
  grub 2.14 → 2.16, systemd 261.3, sof-firmware 2026.09.1, linux-firmware
  20260916. It was the "watch the first real run" item in TASKS, and nobody
  watched it.

### What held

`gb5-ensure-uki` caught the new `linux72.preset` arriving without a UKI and
built and signed one; the default boot entry moved to `manjaro-7.2`; all three
DKMS modules built for 7.2.9; the resume offset held; the patched libfprint
was kept. The machine booted 7.2 for the first time on 2026-11-19 (the Nov 11
session shut down cleanly 7 minutes after the update — which matters below).

### What only looked like it held

Run by hand as root on 2026-11-19, the suite's 4 FAILs (present, unread, in
both runs' journals) and a review by Fable gave this:

1. **The kernel branch never ran.** `gb5-safe-update` decided "kernel update"
   with `matches -x linux71` against the pending list. A series bump *replaces*
   the package, the pending list never names `linux71`, and the branch —
   hibernation mask, fallback UKI regeneration, the reboot notice — was skipped
   without a word. The status file says `kernel_updated=0`. **Hibernating in
   those 7 minutes would have written a 7.1 image the 7.2 UKI refuses to
   resume, stranding the swapfile.** It shut down instead. That was luck, and is
   recorded as luck. Worse, since `linux71` is gone, the branch was dead code
   for every future kernel too.
2. **The removable fallback became a GRUB that cannot boot.** Manjaro's
   `98-install-grub.hook` runs `/usr/bin/install-grub`, which since 2.16 copies
   `grubx64.efi` over `\EFI\BOOT\BOOTX64.EFI` whenever they differ — and builds
   it *without* `--disable-shim-lock`. `zz-sbctl` then signed it ("✓ Signed",
   where it had always said "already signed" — the only trace). That path is the
   firmware's last resort after an NVRAM reset — the event a BIOS update is
   most likely to cause — and under Secure Boot that GRUB refuses the kernel:
   the "looks bricked" trap README describes, re-armed by a hook this record had
   forgotten existed.
3. **The fallback UKI carried 7.1.13, whose modules were deleted.** A signed
   menu entry that boots without i915, Wi-Fi or any DKMS module — the exact
   hazard the skipped branch exists to prevent.
4. **sbctl tracked two deleted 7.1 paths and none of the three live UKIs**
   (`sign -s` on an already-signed file returns 0 *without* recording it; every
   UKI here arrives pre-signed by mkinitcpio's post hook).
5. **`linux71.preset` outlived `linux71`**, so every `mkinitcpio -P` exited
   non-zero — and the printed rollback recipe chained `mkinitcpio -P && sbctl
   sign-all`, the same `&&` shape as an earlier wrong conclusion: a rollback
   would never have reached the signing step.
6. **`.pacnew` detection could never fire.** `find -newer` compares mtime, and
   pacman restores the *package's* mtime: `/etc/default/grub.pacnew` was written
   Nov 11 carrying Oct 28, and the run reported "no new .pacnew files".

### The repair (2026-11-19)

- **`gb5-boot-guard.sh` + `zzz-gb5-boot-guard.hook`**, running last in every
  boot-relevant transaction (after `zz-sbctl`), whatever started it — the timer,
  a manual `pacman -Syu`, pamac. It keeps four things true: the removable path
  is the signed systemd-boot; the fallback UKI's kernel has a module tree
  (rebuilt and re-signed only when it does not, superseded-series fallbacks
  deleted only after the new one verifies); sbctl's database matches the ESP;
  every tracked file is actually signed (`sbverify` against our db cert, not
  sbctl's opinion). It also keeps systemd-boot current through a pre-signed
  `.efi.signed` and `bootctl update --variables=no`, freshness pinned by a
  sha256 of the source. `--check` reports without changing anything.
- **Manjaro's `98-install-grub.hook` disabled** (`/etc/pacman.d/hooks` symlink
  to `/dev/null`); `99-grub-disable-shim-lock` already does the only
  `grub-install` this machine wants.
- **Kernel detection from state, not names**: module trees before vs after the
  transaction, and running vs newest. A series bump, a point release and an
  LTS-only update are now told apart.
- `.pacnew` by `-cnewer`; the gate's main-UKI pick by `sort -V`; orphaned
  presets moved aside by `gb5-ensure-uki`; the rollback recipe uses `;`.
- **Unattended housekeeping, at the user's request**: snapshot pruning on
  (newest 3 of the updater's own); weekly Flatpak update on AC
  (`gb5-flatpak-update.timer`); unowned stale module trees removed (the 350 MB
  7.1.8 tree had sat in `@` since 2026-08-23).
- Eight new checks in `gb5-verify.sh` (135 in all); two vacuous ones fixed (a literal 7.1
  path through `basename`, which could not fail; a DKMS check that passed on
  another kernel's line). **132 PASS / 2 FAIL** — both are "no fingers
  enrolled", one fact counted twice. **133 PASS / 2 FAIL** after the
  loader-version check was added (supervised run, below).

Tested by fault injection, not by exit codes: guard `--check` against a
deliberately dropped sbctl entry (reported, unchanged), then repaired; refusal
while `db.lck` exists; a real `pacman -S grub` transaction (removable path
survived; and it exposed item 4b below); NVRAM and `Loader*` variables
byte-identical across a guard run — *weak evidence*, because systemd-boot had
nothing newer to copy at the time. Then one **supervised real run** of
`gb5-safe-update.service` (one package downgraded from cache so something was
pending; a fake unowned module tree with a `vmlinuz` planted): guard ran, six
snapshots pruned keeping three (including the pre-7.2 one), the planted tree
removed, `kernel_updated=0`, verify 133/2/1. A second Fable pass over the
committed code found one more real hole — an unmounted ESP would have made the
guard drop every ESP entry from sbctl's database — now refused.

### What went wrong in this phase

- **#30 "Update complete and verified" meant the kernel bump was handled.** It
  meant the gate passed. The gate does not look at the fallback UKI or the
  removable path, and the kernel branch had silently not run. Four FAILs sat in
  the journal for eight days because the suite runs "as information".
- **#31 "zz-sbctl re-signs the rebuilt GRUB."** Written in
  `99-grub-disable-shim-lock.hook` since August. A grub-only transaction matches
  none of `zz-sbctl`'s path triggers; reinstalling grub left `grubx64.efi`
  unsigned. Found only because the advisor insisted on a real transaction as
  the test.
- **#32 the `.pacnew` check** — mtime trusted, see item 6.
- Then the repair made four mistakes of its own, all caught by Fable before
  this was committed:
  - **#33 freshness by `-nt`** — mtime *again*, in the fix for an mtime bug.
    The installed systemd-boot binary is dated Sep 11 though installed Nov 11;
    the pre-signed copy would have frozen systemd-boot forever. Now a sha256.
  - **#34 a prune that read an error as permission.** `pacman -Qoq | wc -l` is 0
    on *any* failure, and the branch was `rm -rf` — a db error would have
    deleted the 6.12 tree under its own signed UKI. Now only on pacman's
    explicit "No package owns", and never a tree some UKI on the ESP still boots.
    (A first patch said "never a tree holding a `vmlinuz`" — which would have
    skipped the snapshot-restored 7.1.8 case the prune exists for.)
  - **#35 a verifier that repairs.** The new verify check called the guard in
    repair mode, so the suite showed a fault once and erased the evidence —
    and could, mid-transaction, have copied a half-written UKI into the
    fallback and signed it. Now `--check`, and the guard refuses to repair
    standalone while `db.lck` exists.
  - **#36 an LTS-only update counted as a kernel update** — it would mask
    hibernation (and the critical-battery hibernate with it) and print "Kernel
    7.2.9 -> 7.2.9 … reboot". Now two flags: running-kernel superseded vs any
    tree changed.

**What the fallback UKI is, honestly:** a copy of the main UKI, refreshed only
when its kernel loses its modules. After a plain initramfs rebuild it is the
previous, already-booted image of the same kernel; right after a kernel change
it is a copy of a never-booted one. The real escape from a bad kernel is the
LTS UKI — which has never been booted at 6.12.112.

### Still untested on 7.2 (one day of uptime)

One supervised S4 cycle (`boot_id` preserved); a fingerprint touch (nothing is
enrolled); speaker playback and a camera call; booting the 6.12 UKI once;
whether the monitor-mode use-after-free survives (7.2.9 loads Wi-Fi firmware
c106, not c102); and the kernel branch itself, which has *still* never run on
real input — the next 7.2.x point release is its first test. **Per rule 9 and
the Phase 4 lesson, none of the Phase 8 fixes counts as proven until it has
survived a reboot and a real kernel transaction.**

## Tools built along the way

    gb5-verify.sh          135 checks across every subsystem (111 at Phase 5)
    gb5-power-report       where the watts go now; --watch for a live table
    gb5-power-log          systemd service, CSV every 30 s
    gb5-power-analyse      reads those CSVs and refuses to answer when the data cannot
    bin/pam-check.py     verify a PAM stack without locking yourself out
    gb5-safe-update        guarded update: refuses, snapshots, repairs, verifies
    gb5-update-notify      renders the five outcomes as five different messages
    gb5-safe-update.timer  weekly, Sunday 10:00, no per-boot trigger
    gb5-docker-verify      25 checks across the container stack
    gb5-docker-preflight   refuses to start Docker off the @docker subvolume
    setup/70-docker.sh     reproduces the whole container layout
    gb5-boot-guard.sh      keeps the boot chain right after every transaction; --check is read-only
    gb5-flatpak-update     weekly Flatpak update on AC (service + timer)
