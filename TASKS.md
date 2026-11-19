# Efficiency project — task state

Source of truth for the autonomous continuation cron (`de680f74`, every 29 min).
Update this file the moment something completes. A tick may start with a fresh
context and this file is all it will have.

Hardware: Samsung Galaxy Book5 Pro H, Core Ultra 7 255H (Arrow Lake-H, fam 6
model 0xC5), 6 P + 8 E + 2 LP-E, no SMT. iGPU is **Xe-LPG+**, graphics IP 12.74,
kernel platform METEORLAKE, driver i915 (not Xe2, not Arc 140T). NPU is
**NPU 3720** — Meteor Lake silicon, not NPU 4.
Battery **76.0 Wh** (charge_full 4900 mAh x 15.52 V — read, never assume).

## Phase 8 — open after 2026-11-19 (see HISTORY Phase 8)

- [ ] **Reboot, then re-run `sudo gb5-verify.sh`.** Every Phase 8 fix was
      measured on the boot that made it. Expect 133 PASS / 2 FAIL (fingerprint).
- [ ] **Watch the first kernel transaction under the new detection** — the
      next 7.2.x point release. Check the journal shows "kernel A -> B",
      "hibernation masked", and the guard rebuilding `manjaro-7.2-x86_64-fallback.efi`.
      The kernel branch has still never run on real input.
- [ ] **Boot the 6.12 LTS UKI once** from the menu — the only real escape from a
      bad kernel, never booted at 6.12.112. (Camera/speakers absent there: expected.)
- [ ] **One supervised S4 on 7.2** (boot_id preserved, swapfile clean after).
- [ ] **Speaker playback + a camera call on 7.2.** DKMS modules load; output untested.
- [ ] **Monitor-mode UAF on 7.2.9** (Wi-Fi fw c106): unknown, not fixed. Keep
      using `gb5-monitor-mode` or an external adapter.
- [ ] Two snapshots per update (gb5-safe-update's own + timeshift-autosnap's).
      Harmless; autosnap prunes its own. Revisit only if space matters.
- [ ] AUR packages (`pacman -Qm`, 5) are not updated unattended. Check monthly:
      `pamac checkupdates -a`. The patched libfprint is AUR-built on purpose.

## Done

- [x] **Stability: freezes diagnosed and made recoverable (2026-09-11).** Two
      faults. (A) CONFIRMED iwlmld/mac80211 use-after-free under aircrack-ng
      monitor mode on the BE201 — NOT fixed by 7.1.13 (wireless srcversion
      identical to 7.1.9); remedy is an external USB adapter, not a kernel bump.
      (B) two silent SoC hangs, no trace, root cause unknown. Fix: recovery
      sysctls (nmi_watchdog=1, panic_on_oops=1, hard/softlockup_panic=1,
      panic=20) + iTCO platform watchdog (RuntimeWatchdogSec=30s, the only thing
      that catches class B) + linux612 LTS signed fallback UKI. gb5-verify.sh
      "Crash recovery" section added (7 checks). Full story in HISTORY Phase 7.

- [x] intel-lpmd patched for 0xC5, measured, rejected, service masked.
      Left cgroups pinned to CPUs 0-13 after exit; cleared, documented.
- [x] Corrected core topology everywhere: P=0-5, E=6-13, LP-E=14-15 (no SMT).
- [x] `openvino-intel-gpu-plugin` installed — OpenVINO saw only CPU+NPU before.
- [x] MODNet benchmarked on all three engines, 3 independent runs agreeing:
      GPU 30 ms/730 mJ · NPU 113 ms/2550 mJ · CPU 166 ms/3700 mJ per frame.
      Static FP16 IR does not help the NPU (~118 ms) — it is the model.
- [x] linux-studio-effects switched to device="GPU", fallback="NPU". Verified
      it resolves to GPU at runtime.
- [x] `gb5-power-report` written (+ `--watch`). Reads pack size from sysfs.
- [x] `turbostat` installed (linux-tools).
- [x] SLPC power_saving wired into gb5-power-tune.sh (battery only).
- [x] Corrected two earlier false claims: package C-states DO work (12% quiet,
      78.5% core C10); uncore is NOT pinned (1500 MHz idle, range 400-3900).

## Measured and found to be nothing

- SLPC `base` vs `power_saving` on sustained GPU load: overlapping across 4
  order-alternated rounds. Kept on battery anyway (free, reversible, and it
  targets bursty idle which this test does not exercise).
- 1080p60 hardware vs software decode: **not measurable** on a live desktop.
  Idle arms alone ranged 4.29–10.20 W. Four attempts, all failed. See notes.

## Overnight autonomous run (from 2026-08-22 ~03:10)

The user is asleep. Work continuously; do not wait for answers. **The machine
must be on AC** — at 10 W it had 5.5 h of battery left, so if `ADP1/online` is 0
and capacity is falling, the top priority is to note it in this file and to stop
running anything expensive, because the session dies when the battery does.

`gb5-power-log.service` is running and writing `/var/log/gb5-power.csv` every
30 s. That file is the overnight deliverable — hours of rows let you select
genuinely quiet windows after the fact, which is the only way past the ~6 W
desktop noise floor that wrecked every short measurement so far.

Analysis to run against it once there are a few hours of data:
- Filter to rows where `P_busy < 2 and E_busy < 2` — that is a real idle floor.
- Report median `pkg_w` and `sys_w` for those rows. **That, not 4.0 W, is the
  number the 18 h argument should rest on.**
- Correlate `pc10_pct` against `ltr_ns` / `ltr_who` to see what is actually
  gating deep package states now that the USB Ethernet adapter is gone.

## Pending — stability follow-ups (2026-09-11)

- [x] **`FAN0._FST` ACPI log flood — FIXED 2026-09-12 (udev), after a first
      attempt that did not survive a reboot.** The fan's `_FST` AML always fails
      (`acpi_fan` `fan1_input` returns `Input/output error`), and KDE's
      `ksystemstats` polled it at 2 Hz: ~8000 kernel errors per boot, burying the
      ring buffer. thermald was blamed first and is innocent.
      First attempt set `compactShowFan=false` in the Plasma applet. It measured
      0 over 30 s at the time but the flood returned at exactly 2.00/s after the
      next reboot: that setting governs *display*, not whether ksystemstats
      subscribes to the sensor. Do not trust a post-fix measurement taken in the
      same session — re-measure after a reboot.
      Real fix is `config/system/99-gb5-hide-broken-fan.rules`: a udev rule chmods
      `fan1_input` to 0600 when the hwmon appears, so unprivileged pollers cannot
      trigger the AML. Verified 0 errors over 40 s, and the rule (not a manual
      chmod) proven to fire via `udevadm trigger`. Nothing is lost — the sensor
      never returns a value. No cleaner lever exists: `CONFIG_ACPI_FAN=y` is
      built in, `/sys/bus/acpi/drivers` has no fan entry to unbind, and
      `cooling_device0` is in no thermal zone's cooling policy (the EC drives the
      fan in firmware). gb5-verify.sh asserts the permission.
- [x] **Monitor-mode Wi-Fi made survivable (2026-09-12).** `gb5-monitor-mode
      on|off|status` reloads iwlwifi with `fw_restart=0` for the duration of an
      aircrack session. The confirmed UAF lives in the firmware-RESTART path, so
      with restart disabled the adapter simply stays down after an assert instead
      of walking a freed chanctx. Tested both directions; wlo1 returns and
      NetworkManager reconnects. **This reduces risk, it does not remove the
      bug** -- only an external USB adapter (AR9271/ath9k_htc, MT7921AU/mt76)
      bypasses iwlmld entirely. Daily default stays `fw_restart=Y` (self-healing).
- [x] **Persistent crash capture added (2026-09-12)** -- the prerequisite for
      ever diagnosing the class-B silent hangs. `reserve_mem=8M:4096:oops` on the
      cmdline + `ramoops mem_name=oops ecc=1 max_reason=2`, loaded at boot. Uses
      mem_name rather than a hardcoded physical address. The 7.1 UKI was rebuilt
      and re-signed; the **fallback UKI deliberately keeps the old cmdline** as a
      safety net. efi-pstore stays off (NVRAM wear, Samsung firmware risk).
- [x] **BIOS updated to P06RHH.300.260806.02** (flashed via Windows between the
      2026-09-20 and 09-28 boots; recorded 2026-11-19). pstore empty and every boot
      since ended cleanly: correlation, not proof that class B is gone.
      Original note: **BIOS/EC update remains the top untried lever for class B.** Confirmed
      from Linux there is no path: `fwupdmgr get-updates` reports none, and
      Samsung does not publish to LVFS (ESRT entry exists, version 528, but
      nothing to apply). Samsung Update under Windows is the only route.
      Current BIOS `P05RHH.280.251204.01` (2025-12-04).
- [x] **Wi-Fi 7: the machine is already configured correctly; the AP is the
      limit (2026-09-12).** Checked end to end. The card is detected as "Wi-Fi 7
      BE201 320MHz", advertises full EHT PHY capabilities, `disable_11be=N`, and
      has no modprobe overrides. The link runs at VHT-MCS 9 / 80 MHz / NSS 2 =
      866.7 Mbit/s, which is **802.11ac (Wi-Fi 5) and the exact ceiling for a 2x2
      client on that AP** -- the AP "LC" advertises HT + VHT only (no HE, no EHT)
      and "neither 160 nor 80+80". Nothing on this laptop is throttling it.
      Using Wi-Fi 7 requires a Wi-Fi 7 / 6E AP; 6 GHz remains BIOS-gated as
      already documented (24/59 channels, all no-IR, which is the normal LPI
      regime for a 6 GHz *client* rather than a fault). Note the PHY is
      self-managed and reports ES while cfg80211 is RS -- no user lever exists.
- [x] **Wi-Fi power save made AC-aware (2026-09-12).** Was pinned on always.
      Measured against the gateway, 40 pings each: on = avg 2.25 / max 6.91 /
      mdev 1.02 ms; off = avg 1.98 / max 3.36 / mdev 0.46 ms -- worst case halved,
      jitter down 55%. Now off on AC, on on battery, re-asserted every run by
      gb5-power-profile.sh so a reassociation cannot leave the wrong setting.
- [ ] **Fingerprint re-enrolment** — the only standing gb5-verify FAILs (two lines, one fact); the
      on-chip templates are empty (predates this work).

## Pending

- [x] **P8. RESOLVED — switch kept, but the stated reason was false.**
      Re-measured at the production 256x256 shape, order-alternated:
      NPU 27.3 ms / 36.6 fps / 1.2x headroom / 4.19 W net at 30 fps;
      GPU 8.5 ms / 117.6 fps / 3.9x headroom / 2.75 W net. **The NPU CAN sustain
      30 fps at the real resolution** — the "it cannot" claim written into
      config.py was a 512x512 artefact and has been corrected in the source.
      GPU stays default on headroom (3.9x vs 1.2x) and energy (~1.4 W less at
      fixed 30 fps, because duty cycle beats peak power). Unmeasured risk noted
      in the code: GPU contention with the camera pipeline.
- [x] **P0. USB Ethernet adapter removed — confirmed causal.** `pmc_core/ltr_show`
      showed `PMC0:XHCI` advertising a 128 µs latency tolerance, the tightest on
      the platform, while package C7/C8/C9/C10 read exactly **zero**. With the
      TP-Link UE300 (RTL8153) unplugged, XHCI's LTR relaxed to 51.2 µs and C8/C10
      began accumulating (0.70% / 0.47% in the logger's first row). Tightest LTR
      is now `SOUTHPORT_A` at 71.7 µs. Keep the adapter unplugged unless wired
      networking is actually needed.
- [x] **P1. Battery-side measurement DONE — and it overturns the central claim.**
      54 undisturbed 30 s samples on battery from `gb5-power-log`, filtered to
      genuinely quiet rows (P<2%, E<2%, n=40): **system 4.82 W -> 15.8 h**,
      package 3.34 W, cores 0.24 W, RC6 95.1%, pkg C6 22.5% / C8 2.25% /
      C10 3.79%. Spread min 3.86 / p25 4.62 / median 5.02 / p75 5.49 — tight
      enough to trust. 18 h needs 4.22 W, so the gap is **0.6 W**, not the
      impossibility the first two drafts asserted. Tightest LTR is now ISH at
      10.5 ms; nothing is blocking deep package states.
- [x] **P2a. Panel: brightness and HDR are NOT measurable levers with dark
      content.** 90 s samples, 4 order-alternated rounds, comparing HDR-on/100%
      against HDR-off/30%. Using the quietest quartile of each (least
      contaminated): 6.22 W vs 6.15 W. One round (r3) was badly contaminated
      (median 13.03 W, max 22.8 W) and is excluded. The likely reason the slider
      does nothing: the screen showed a dark terminal throughout, and on an
      emissive panel power tracks light actually emitted. P2b tests that.
- [x] **P2b. OLED content test — DONE, and it is the biggest finding so far.**
      Full-screen, 45 s samples, order alternated, quietest quartile:
      black@30% 4.9 W · black@100% 5.3 W · white@100% 15.4 W · white@30% 15.9 W.
      **Content is worth ~10 W** — three times the draw, and more than the entire
      SoC package. **The brightness slider is worth nothing**, which on an
      emissive panel should be impossible.
- [x] **P2d. Answered — it was not HDR, it was auto-brightness.** The HDR-off run
      came back non-monotonic (100% 13.6 W, 30% 7.0 W, 10% 13.0 W), which is
      impossible. Cause: `automaticBrightness: true` in `kwinoutputconfig.json`,
      PowerDevil driving the panel from `iio:device0` (`als`) via
      `iio-sensor-proxy`. Every test write was overridden within seconds — the
      panel ended on 1126, a value nothing in the test ever wrote.
      **All brightness numbers in this project are void.** The content figure
      survives as an end-to-end observation but is inflated by the feedback loop
      (white screen -> brighter room -> auto-brightness raises panel).
- [x] **P2e RESOLVED without the test.** The concern was that the 10 W content
      figure was inflated by an auto-brightness feedback loop. But auto-brightness
      is not actually adjusting (see P2f), so there was no loop and the figure is
      genuine content cost at fixed brightness. The expensive white-screen test
      is unnecessary.
- [x] **P2f ANSWERED. Auto-brightness is configured on but is not acting, and it
      barely matters anyway.** `iio-sensor-proxy` reports 0.802 lux — correctly
      sensing a dark room — while the panel sat at 2047/2047 all night; twelve
      samples over a minute gave a flat `als=802 brightness=2047`. Separately,
      brightness is worth ~0.2 W with dark content (100%: 6.21/5.71 W, 10%:
      5.65/5.81 W, arms overlapping and non-monotonic across rounds). Dark
      content is the lever; brightness only matters when content is bright.
      Loose end: the backlight was once seen at 1126, which nothing in the tests
      wrote, so PowerDevil does act sometimes. Unexplained, low priority.

- [x] **P10. Runtime corrected against the coulomb counter.** The 15.6 h figure
      was an idle FLOOR extrapolated as if it were a runtime. Ground truth over
      1.69 h undisturbed: median snapshot 5.02 W (15.1 h), mean 5.23 W (14.5 h),
      **observed charge drop 6.30 W -> 12.1 h**. Snapshots under-report 17-20%
      because `current_now` is biased low on this gauge (NOT a sampling artefact; tail ran to
      21.2 W). Logger now records `charge_now` and `voltage_now`; phase-1 data
      preserved at /var/log/gb5-power-phase1.csv. **18 h is not reachable** —
      and this time that rests on a coulomb count, not an extrapolation.

- [x] **P12. ANSWERED: no. `charge_now` steps by exactly 49 mAh every ~445 s.** `charge_now`
      sat frozen at 2058000 for 60 s of sampling at 5 s intervals, during which
      ~6 mAh should have been consumed. It updates in coarse, infrequent steps.
      P11's first two arms both read *exactly* 98.0 mAh, which now looks like a
      quantisation artifact rather than a genuine tie. `/tmp/chgstep.sh` (pid in
      tick log, output `/tmp/chgstep.out`) is sampling for 15 min to find the
      real step size. **If the step is large, P11 cannot resolve its arms and its
      result must be reported as "not measurable" rather than "no difference" —
      those are different claims.**

- [x] **P11. NOT MEASURABLE** (not 'no difference' — the experiment could not have
      detected one). Four 12-min arms gave 98/98/98/49 mAh = 2/2/2/1 steps, no
      sub-step information. Resolution +/-50% on the signal. Would need ~1 h per
      arm, 4 h total, and is worth redoing on AC. Profile management restored by
      the EXIT trap; verified `GB5_PROFILE_MANAGE=0` gone and profile back to
      `quiet`. The 12.1 h runtime figure is unaffected: 14 steps, +/-7.1%.
      **superseded detail below** `/tmp/profbench.sh`,
      pid recorded in the tick log, output `/tmp/profbench.out`. Four 12-minute
      arms, order alternated, measured by `charge_now` delta rather than
      instantaneous power (snapshots under-report 17-20%). It sets
      `GB5_PROFILE_MANAGE=0` in `/etc/default/gb5-power` for the duration and
      restores on exit via a trap. **If a tick finds that line still present and
      the process gone, remove it and re-run `gb5-power-profile.sh`.**
      Quantifies what the <=50% auto-switch to `quiet` actually buys, which is
      the one number the automation was built on and never verified end to end.

- [x] **P13. Final pass done at 17% battery.** `gb5-verify.sh`: 111 PASS, 0 FAIL,
      2 notes. Final figure 6.19 W / 11.9 h +/- 0.4 over 33 gauge steps,
      propagated to BATTERY-PLAN, MORNING-SUMMARY, README and the published page.
      All watch settings holding. Nothing uncommitted. If the machine hibernates
      before the user wakes, nothing is lost.

- [x] **P9. Overnight watch — CLOSED, and the cron with it.** Ran ~13 ticks from
      03:00. Both settings that had silently reverted (`AllowedCPUs`, SLPC bias)
      held clean for every subsequent check once fixed properly. Final summary
      written at 17%, well before the threshold.

      **Stopped deliberately at 13% battery rather than running to the end.**
      The wakeup audit found the agent process was the single largest source of
      wakeups on this machine (96.8/s, ahead of the compositor at 63.3). So each
      further tick measurably shortens the battery life it exists to measure,
      for no remaining benefit: there are no open items that do not need AC or a
      human. The machine will hibernate cleanly at 2%.

## Closed 2026-08-23

- [x] **Hibernation fixed and tested.** 20 GiB swapfile on `@swap`,
      `resume_offset` in the UKI, verified by a real S4 (boot_id preserved,
      uptime 527 -> 781 s). The 7 GiB `image_size` cap was inadequate and is
      removed.
- [x] **Fingerprint survives hibernate.** Driver pkgrel 5 reconnects after the
      `AuthorizedIdentity` MAC failure. First touch after each resume still
      fails by design; second works. Enrolment intact.
- [x] **S4 SCAI wedge repaired automatically** by
      `/etc/systemd/system-sleep/gb5-resume-fixups`.
- [x] **Lock on resume** — KDE `LockOnResume` plus a pre-sleep
      `loginctl lock-session` in the same hook.
- [x] **True black** OLED colour scheme, worth ~264 mW (below measurement
      resolution; applied on physics, not on a graph).
- [x] **PAM** `max-tries=5 timeout=45` across five services including the lock
      screen, which had been missed.
- [x] **Docs, setup and verify updated.** `setup/60-hibernate.sh` added,
      `40-system.sh` installs the measurement tools, `gb5-verify.sh` grew
      Hibernation / S4-fallout / Fingerprint-SDCP sections. 111 PASS, 0 FAIL.

## Closed 2026-08-23 — unattended updates

- [x] **Weekly guarded update is live.** `gb5-safe-update.timer`, Sunday 10:00
  (±10 min), `Persistent=true`, **no `OnBootSec`**. Verified it does not fire on
  enable. Next: Sun 2026-08-30.
- [x] **Reviewed by Fable, which returned "do not enable".** It was right; see
  HISTORY.md Phase 5 for the seven findings and the three that verifying them
  turned up. Two protections were inert, one of which reported success.
- [x] **Project-wide `grep -q` audit.** Six inverted checks fixed in
  `gb5-safe-update`, six more in setup scripts. `gb5-verify.sh` does not set
  `pipefail`, so its uses are safe and were left alone.

### Watch the first real run

**2026-11-19: overtaken.** It ran unwatched on 2026-11-11 (602 packages, a
7.1 -> 7.2 series bump) and the kernel branch it was meant to exercise never
fired -- see HISTORY Phase 8. The branch is rewritten; the watch item moved to
the Phase 8 list at the top.

Fable asked for one supervised run before the timer is trusted, and it has not
happened: there were 0 packages pending and a reboot outstanding, so no full path
could be exercised. After rebooting into 7.1.9, when updates next exist:

```bash
sudo systemctl start gb5-safe-update.service   # then watch it
journalctl -u gb5-safe-update -f
```

The parts that have **not** been exercised end-to-end on real input: the
kernel-update branch (mask, fallback UKI regeneration, DKMS re-check) and the
snapshot/rollback path. Everything else was tested directly, including each of
the five notification outcomes and the mask/unmask round-trip.

## Closed 2026-08-23 — containers and VPN

- [x] **Docker installed**: rootful, socket-activated, `/var/lib/docker` on the
  `@docker` btrfs subvolume so image layers never enter a Timeshift snapshot.
  containerd's root moved alongside it. `gb5-docker-verify`: 25 PASS / 0 FAIL.
- [x] **Reviewed by two agents before enabling.** Found a published-port hole
  against the VPN, a no-op GC setting, and an opt-out mistaken for a default.
  See HISTORY.md Phase 6.
- [x] **NetBird 0.77.1**, checksum-verified, binaries taken out of user ownership
  (the installer left a local root escalation).
- [x] **NetBird tray UI working** — needed the GTK3 build plus a `.desktop` and
  icon that upstream does not ship.
- [x] **Kernel module tree restored from a Timeshift snapshot**, so the machine
  works before its reboot. Reboot detection changed to compare kernel versions,
  because restoring the tree hid the pending reboot from four checks.

### Still needs the reboot

**2026-11-19: done.** Rebooted long ago; the 7.1.8 tree was removed by hand and
unowned stale trees are now pruned by `gb5-safe-update`.

Restoring the tree bought a working machine; it did not make 7.1.8 the right
kernel. DKMS modules are built only for 7.1.9 and the signed UKI boots it.
Afterwards:

```bash
sudo rm -rf /usr/lib/modules/7.1.8-1-MANJARO   # 350 MB of stale files inside @
sudo gb5-verify.sh && sudo gb5-docker-verify
```

`gb5-verify.sh` NOTEs the stale tree so it is not forgotten.

### Docker follow-ups, none blocking

- [ ] `docker-credential-secretservice` is AUR-only; without it `docker login`
  writes a base64 (not encrypted) token to `~/.docker/config.json`. KWallet
  already provides `org.freedesktop.secrets` here.
- [x] **compression settles at 1.72x** on a real 4.0 GB image store (2.3 GB on
  disk; 2.74x on the compressible portion). Well above the 1.15 revisit
  threshold, so `compress=zstd:1` stays. `volumes/` confirmed 100% uncompressed,
  as nodatacow intends.
- [ ] Multi-arch builds need `containerd-snapshotter: true`, which relocates the
  image store and re-pulls everything. Revisit trigger, not a task.

## Deferred by the user, 2026-08-23

- [ ] **Disk encryption.** Decided in principle (yes), not executed; the user
  will return to it. Everything needed to pick it up cold is in
  **`docs/system/encryption.md`**: why "encrypt hibernation" was the wrong question, the
  measured power cost (~6 J/GB, exactly zero at idle, ~0.2% of a charge for a
  heavy build day), the recommendation, the full live-USB procedure, and the
  trap in it — `/dev/nvme1n1p3` is a plain swap partition that would keep
  leaking memory pages to plaintext even after root is encrypted.
  Prerequisites before starting: the 7.1.9 reboot done, several stable days, one
  observed unattended update, and a **verified external backup**.

## Decision needed from the user

- [ ] **Hibernation writes RAM to an unencrypted disk.** No LUKS on this machine,
      so up to 12.5 GB of RAM contents — browser sessions, SSH keys, the SDCP
      host private key — lands on `/swap/swapfile` in the clear on every
      hibernate and stays until overwritten. Introduced by the hibernation fix
      and documented at the top of `docs/system/hibernation.md`. Accept, encrypt the
      disk, or disable hibernation. The Windows half of this dual-boot IS
      BitLocker-encrypted, so Linux is now the weaker side.

## Still open, needs a human or a quiet machine

- [ ] **HDR vs true black** — `sudo gb5-hdr-black-test` when the laptop is idle,
      unplugged and free for ~5 h. It refuses to run otherwise. Until then leave
      HDR on; the risk is speculative and bounded by ~0.2 W.
- [ ] **`quiet` vs `balanced` on BATTERY.** The measurement that changed
      `GB5_PROFILE_LOW` was taken on AC, and the setting only ever applies on
      battery where the EC enforces different limits. Also: the "exactly
      1025 MHz hard cap" contradicts three same-day readings of 1925/1863/1862
      and is unreconciled.
- [ ] **Snapshot bias root cause.** `current_now` reads ~23% low against the
      coulomb counter — two registers of one gauge. Cause unidentified; it means
      the idle-floor figures are ~23% low in absolute terms.

