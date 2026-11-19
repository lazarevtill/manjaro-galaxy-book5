# Peak performance and long battery on the Galaxy Book5 Pro H

Reviewed adversarially and corrected on 2026-08-22. Several numbers in the first
draft were wrong; the corrections are noted inline rather than quietly patched.

## First, the target is being compared against the wrong number

The "18 hours" figure people carry over from Apple is **video playback at about
half brightness** — Apple's own spec for the 13-inch M4 Air is "up to 18 h
streaming video" and, separately, "up to 15 h wireless web". Independent web
browsing tests land near 15 h.

**A MacBook Air does not do 18 hours of active work either.** So the honest
comparison is not "18 h of use versus what this machine can do", it is
like-for-like per workload.

## The arithmetic

The pack reports `charge_full` 4900 mAh × `voltage_min_design` 15.52 V =
**76.0 Wh**. Treat that as an estimate, not a constant: the driver exposes charge
rather than energy, mAh × nominal volts ignores the discharge curve, and
`charge_full` sitting *above* the 73.9 Wh design capacity at 161 cycles means the
fuel gauge is optimistic. Real delivered energy is likely at or below 73.9 Wh, so
shave 3-5% off every runtime below.

    18 h  ->  76.0 / 18  =  4.22 W  whole machine, sustained
    15 h  ->  76.0 / 15  =  5.07 W

For scale, the M4 Air's ~15 h on 53.8 Wh is about **3.6 W**.

This machine carries **41% more battery** (76.0 / 53.8 = 1.41). So it may draw
41% more power and still match the runtime — which means it needs about **70% of
Apple's efficiency**, not "within 41% of it". (Those are different claims and the
first draft got this backwards: being allowed to draw 41% more power is being
*29% less efficient*, not 41% less.)

### Is 18 h reachable? — measured three times, and the answer kept moving

This section has been wrong twice. Both errors are left visible because the way
they were caught is the useful part.

**Draft 1 said 18 h was arithmetically impossible**, on the grounds that the SoC
package alone idles near 4.0 W. That number came off a busy desktop and was
contaminated.

**Draft 2 said 15.6 h was measured**, from 113 quiet samples showing 4.86 W. That
figure is a real *idle floor* but it is not a runtime, and using it as one was
the second mistake.

**What ground truth says.** The battery's coulomb counter is authoritative:
`capacity` on this pack is exactly `charge_now / charge_full` (51.00% reading as
51%), so percentage drop converts to energy linearly. Over 1.69 h of undisturbed
operation, 203 samples:

| Method | Power | Implied runtime |
|---|---|---|
| median of instantaneous readings | 5.02 W | 15.1 h |
| mean of instantaneous readings | 5.23 W | 14.5 h |
| **observed charge drop** | **6.30 W** | **12.1 h** |

Extended to 3.40 h and 29 gauge steps, the figure converges and tightens:

    6.19 W  ->  11.9 h  +/- 0.4 h   (+/-3.0%)   [33 steps, 3.93 h]

Consistent with the 12.1 h ± 0.9 above — the error bars overlap — and this is
the one to quote, because more steps means less quantisation. The snapshot bias
grew slightly to −24.2% over the longer window, which is what a systematic
sampling error does as more bursts are missed.

The instantaneous readings under-report by 17-20%. The reason is **not** sampling, though that was the first explanation and it is
wrong: periodic sampling is an unbiased estimator unless it correlates with load.
Integrating `current_now` over 634 samples gave 1699 mAh where `charge_now`
decremented 2205 — two registers of the *same gauge*, 23% apart, which no
sampling artefact can produce. **`current_now` is biased low on this gauge.** The tail it discards is real — the ten largest samples in
that window ran 6.5, 6.6, 7.0, 7.2, 7.9, 8.6, 9.7, 13.8 and 21.2 W. Averaging
snapshots of a bursty load systematically under-counts energy.

**So the honest numbers are:**

- **Idle floor: 4.83 W.** Genuine, and the machine is there 76% of the time.
- **Actual sustained drain at a light workload: 6.19 W → 11.9 h ± 0.5-0.8 h.**
- **18 h needs 4.22 W**, which is below even the idle floor once bursts are
  included. **Not reachable**, and this time the claim rests on a coulomb count
  rather than an extrapolation.

Twelve hours is still a good result — it is MacBook Air territory for light work,
which is what the original question asked. It is simply not eighteen.

The logger now records `charge_now` alongside the instantaneous reading so future
analysis integrates the counter instead of averaging snapshots.

### Replicated

A second, independent 1.70 h window — different time, different platform profile
(`quiet` rather than `balanced`), 204 samples, 14 counter steps:

| | Phase 1 (`balanced`) | Phase 2 (`quiet`) |
|---|---|---|
| coulomb ground truth | 6.30 W | **6.13 W** |
| implied runtime | 12.1 h | **12.1 h ± 0.9 h** |
| snapshot mean | 5.23 W | 4.77 W |
| snapshot under-report | −17.0% | −22.2% |

**Two independent windows, both 12.1 h.** The figure is replicated, and the
snapshot bias is confirmed as systematic rather than a one-off — same direction
both times, magnitude varying with how bursty the window happened to be.

As a side effect this is the closest thing to a `quiet`-versus-`balanced` result
available: 6.13 W against 6.30 W, a 2.7% difference sitting well inside the ±7.1%
quantisation. Still **not measurable**, but consistent with the theoretical
expectation that a profile which sets *limits* changes nothing at idle, because
nothing is pushing against the limits.

### What now limits deep package states

Nothing meaningful. Since the USB Ethernet adapter was removed, the tightest
latency tolerance any IP block advertises is `ISH` at 10.5 ms in 52 of 54
samples — permissive by three orders of magnitude compared to the 128 µs the USB
controller was demanding. Package C8 and C10 accumulate at 2.25% and 3.79%.

## What is already correct — verified, not assumed

The first draft called several of these "nothing to gain", which was premature.
They were then checked individually and are, in fact, already right:

| Subsystem | State | Verified by |
|---|---|---|
| eDP self-refresh | **PSR2 enabled, in DEEP_SLEEP**, selective fetch on | `i915_edp_psr_status` |
| PCIe ASPM | L1 enabled on every link | `lspci -vvv` |
| PCIe L1 substates | L1.1 **and L1.2** enabled on every link | `L1SubCtl1` |
| Wi-Fi power save | on | `iw dev wlo1 get power_save` |
| Audio codec | `power_save=10`, controller power save on | `snd_hda_intel` params |
| File indexing | baloo not running | `balooctl6 status` |
| GPU | GuC submission, HuC authenticated, SLPC, RC6 92% | `dmesg`, gt sysfs |
| NPU | runtime-suspended 99.5% of uptime | `power/runtime_status` |
| CPU idle | core C10 residency 78.5% | `cpuidle` sysfs |
| Boot SSD | APST reaching PS4 (0.005 W) | `nvme get-feature -f 0x0c` |

PSR in particular was the biggest suspected miss and it is already optimal.

## What is actually still wrong

### 1. A USB Ethernet adapter is holding the platform's latency floor

`pmc_core/ltr_show` reports the latency tolerance each IP block advertises. Every
block reads 0 (no constraint) except:

    PMC0:XHCI          Snoop(ns): 128000        <- 128 us, tightest on the platform
    PMC0:SOUTHPORT_C   Snoop(ns): 15564800      <- 15.5 ms, permissive

And the package C-state counters show exactly the shape that implies:

    Package C2 : 876415716      Package C7  : 0
    Package C3 :   4639185      Package C8  : 0
    Package C6 : 742690755      Package C10 : 0

The package reaches C6 and stops. The USB controller's 128 µs LTR is the
tightest constraint on the machine, and what is on that controller is a
**TP-Link UE300 gigabit Ethernet adapter**, sitting at `power/control = on`. An
RTL8153 draws roughly 0.5-1 W by itself, and it is also the thing pinning XHCI.

**This is the single most actionable item found.** Unplug it when not using
wired networking. (The 29 GB USB stick that previously sat here has already been
removed.)

The fingerprint reader is also at `control = on`, deliberately — libfprint lists
this device only in its known-but-unsupported autosuspend block. That is an
accepted ~0.1 W, documented so a later pass does not "optimise" it and break
authentication.

### 2. The 60 Hz-on-battery saving never existed

`gb5-power-tune.sh` has been switching the panel to `2880x1800@60` on battery
since it was written, and logging success. **This panel has no 60 Hz mode at
native resolution.** `kscreen-doctor` lists exactly one 2880x1800 mode and it is
120 Hz; every 60 Hz mode it offers is at a lower resolution. `kscreen-doctor`
exits 0 even when it prints "Output mode not found", so the `&&` guard logged a
success that never happened.

Fixed: the script now checks the mode exists, applies it, and then confirms from
the compositor rather than trusting the exit code. On this machine it now logs
`eDP-1 has no 2880x1800@60 mode; leaving refresh alone`.

What remains for refresh is VRR/adaptive-sync, which the panel does support and
KDE has set to Automatic.

**Any earlier claim in these notes about 60 Hz saving power on battery is void.**

### 3. Both SSDs are fine — an earlier reading here was wrong

This section previously claimed the Windows disk parked one power state
shallower than it could, worth ~73 mW. That was a misreading: only the first
three APST entries were inspected. The full descent for both drives:

    nvme0 (boot, MZVLQ512HALU)   100 ms idle -> PS4  (0.005 W)
    nvme1 (990 EVO Plus, Windows) 100 ms idle -> PS3, then 2 s -> PS4 (0.007 W)

`nvme1` takes two hops rather than one, but it does reach PS4. **Nothing to fix.**
Worth recording because "the unmounted Windows disk is wasting power" is an
appealing story and it happens to be false.

## Where the remaining watts are

Ranked by expected value, with what is known and what is not:

1. **The panel — and specifically what is ON it, not how bright it is.**
   Measured, full-screen, 45 s samples, order alternated, quietest quartile:

   | Screen | Whole-system draw |
   |---|---|
   | Black, brightness 30% | **4.9 W** |
   | Black, brightness 100% | **5.3 W** |
   | White, brightness 100% | **15.4 W** |
   | White, brightness 30% | **15.9 W** |

   Two things fall out, and the second was not expected.

   **Content is worth about 10 W.** A white screen costs three times what a black
   one does. That dwarfs every other lever in this project combined — the entire
   SoC package draws 4 W at idle. On an emissive panel this is expected: power
   follows light actually emitted.

   **The brightness numbers above are not trustworthy, and the reason is worth
   more than the measurement was.** White at 30% first measured the same as white
   at 100%; a follow-up run with HDR disabled gave 100% -> 13.6 W, 30% -> 7.0 W,
   10% -> 13.0 W. Non-monotonic: 10% cannot draw more than 30%.

   The cause is that **this machine has an ambient light sensor and KDE
   auto-brightness is enabled** — `automaticBrightness: true` in
   `kwinoutputconfig.json`, PowerDevil driving it via `iio-sensor-proxy` from
   `iio:device0` (`als`). Every `intel_backlight` write the test made was being
   overridden seconds later. The giveaway: the panel finished on 1126, a value
   neither the test nor anything else had written.

   Worse, it is a **feedback loop**: a white test screen lights the room, the
   sensor reads brighter, auto-brightness raises the panel, which emits more
   light. So the 10 W content figure is real as an end-to-end observation of this
   machine as configured, but part of it is auto-brightness amplification rather
   than content alone. Measuring the two apart requires disabling auto-brightness
   first, which was not done here because the machine was on battery and the
   test is expensive.

   **What this means practically:** auto-brightness is already doing the job the
   brightness slider would do, and doing it from room light. The lever left in
   your hands is content.

   Refresh is not a lever on this panel (see above).
2. **Deeper package states**, gated by item 1 in the previous section.
3. **Platform profile.** `quiet` measured 4.8 W package at idle. Already
   automated: AC untouched, battery >50% `balanced`, ≤50% `quiet`, 55%
   hysteresis, backs off if a human changes it.
4. **Lid-closed time.** Most of a long day away from a charger is suspended, not
   used. s2idle here reaches S0i2.2 and holds it. If the goal is "a full day on
   one charge" rather than "18 h of screen-on time", this is the largest single
   contributor and it already works.

## Peak performance is not being traded away

Everything above is conditional on being on battery. On AC the machine stays at
`balanced` with turbo and HWP dynamic boost on, PCIe links hot, 120 Hz, and the
GPU on the latency-first SLPC profile. `performance` is available for sustained
all-core work: it holds 2369 MHz against `quiet`'s 1925 MHz at +5 °C, so `quiet`
gives up **18.7%** of sustained clock (the first draft said 23%, which is the
ratio the other way round).

Caveat on that trade: the battery script runs `balanced` above 50%, not `quiet`,
and no sustained-clock figure has been measured for `balanced`. So the 18.7%
applies only below 50% battery.

The one genuine performance *gain* found: inference moved off the NPU onto the
iGPU, 3.7× faster on the model in question.

## Explicitly not worth doing

- `intel-lpmd` — patched to recognise this CPU, measured, no effect, and it
  leaves the systemd slices pinned to CPUs 0-13 after exiting. Masked.
- Clamping uncore frequency — it is not pinned; 1500 MHz at idle, range 400-3900.
- zram vs disk swap — no measurable power difference.
- Bluetooth — ~0.1 W; turn it off when unused, not worth measuring.
- thermald — affects behaviour under load, not idle drain.
- s2idle vs deep sleep — no choice exists, Arrow Lake dropped S3.
- A hardware-specific kernel build — the idle path is already optimal **on kernel
  7.1.8**. Native `intel_idle` tables land continually, so re-check after kernel
  upgrades rather than treating this as settled forever.

## Next

1. Long-form panel measurement (90 s samples, 4 alternations) — **running**.
2. Unplug the USB Ethernet adapter, re-read `ltr_show` and the package C-state
   counters, and see whether C8/C10 start accumulating. This is a clean causal
   test with a large expected effect.
3. Push `nvme1` to PS4.
4. Rebuild the tier table from measured battery draw per workload and delete the
   projections below.

### Runtime tiers

Idle is measured. The rest are scaled from it using the measured content cost and
the platform-profile figures, and are marked as such.

| Tier | Draw | Runtime on 76 Wh | Basis |
|---|---|---|---|
| Screen on, dark content, doing nothing | **6.19 W** | **11.9 h ± 0.5-0.8** | **measured, 33 gauge steps** |
| &nbsp;&nbsp;&nbsp;of which, quiet-moment floor | 4.83 W | (not a runtime) | measured, n=113 |
| Reading / writing, dark theme | ~6 W | ~12.5 h | idle + light CPU |
| Light browsing, mixed content | ~9 W | ~8.5 h | scaled |
| Bright/white content on screen | ~15 W | ~5 h | **measured** content delta |
| Development, compiles, many tabs | ~14 W | ~5.5 h | scaled |
| Video call with camera | ~19 W | ~4 h | scaled |

The two measured rows are the ones to trust. Note that they bracket everything
else: **the difference between a dark screen and a bright one (4.8 W vs 15 W) is
larger than the difference between idling and compiling.**

## The short answer

Your SoC is already tuned about as well as it can be — 3.34 W package at idle,
0.24 W in the cores, 95% GPU RC6, package C10 being reached, and every device
power-management knob already correct. There is very little left there.

What decides whether you get 15 h or 5 h is **what is on the screen**. A dark
colour scheme on this OLED is worth more than every CPU, GPU and NPU change in
this project combined.

Concretely, in order:

1. **Dark theme everywhere** — desktop, editor, terminal, browser. Worth up to
   ~10 W against light content.
2. **Keep the USB Ethernet adapter unplugged** unless you need it. It was
   holding the platform's latency floor at 128 µs and blocking package C8/C10.
3. **Leave auto-brightness on.** It is already doing the dimming, driven by room
   light, and it overrode every manual brightness change the tests attempted.
4. Everything else in this document is either already correct or worth under a
   watt.

## What is actually achievable, with everything applied

Measured, not summed from speculative savings.

| | drain | runtime on 76 Wh |
|---|---|---|
| Whole 5.29 h run (agent active throughout) | 6.22 W | 12.2 h |
| **Best 1.34 h window achieved** (11 steps, CPU 2.7% busy) | **5.91 W** | **12.9 h** |

Both are coulomb-counted. The best window is the honest ceiling for *this
configuration doing light work*: **about 13 hours**.

### Why there is not much left

Every remaining lever was measured and is small:

| Lever | Worth | Note |
|---|---|---|
| Dark content | up to 10 W | **already applied** in every measurement above |
| Brightness | ~0.2 W | with dark content; the slider barely matters when pixels are off |
| HDR off | not measurable | |
| `quiet` vs `balanced` | not measurable | and costs 27% clock under load |
| Closing `plasma-systemmonitor` + `ksystemstats` | ~41 wakeups/s | unquantified in watts |
| The measuring agent itself | 96.8 wakeups/s | the largest single source during these runs |

The last row is the interesting one. **Every number here was taken on a machine
running the thing measuring it**, so a genuinely unattended desktop should do
slightly better than 12.9 h — but that improvement has never been measured,
because measuring it is what causes it.

### The ceiling, stated honestly

- **~13 h** for light, dark-content work. Measured.
- **~12.2 h** for a realistic mixed session. Measured.
- **~5 h** whenever the screen shows bright content. Measured (~15 W).
- **18 h is not reachable.** It needs 4.22 W, below anything observed, and below
  even the snapshot-derived idle floor once that floor is corrected upward for
  the gauge's 23% bias.

For comparison, a MacBook Air does ~15 h of light use on 53.8 Wh (~3.6 W). This
machine carries 41% more battery and needs about 70% of Apple's efficiency to
match its runtime. At 5.91 W against 3.6 W it is at roughly 61% — close, and the
gap is the SoC's idle floor, not anything left untuned.
