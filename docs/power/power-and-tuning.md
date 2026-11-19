---
name: gb5-power-and-tuning
description: Power, CPU and kernel tuning applied to the user's Galaxy Book5 laptop, and which daemon owns which knob
metadata:
  type: project
---

On `GB5` (see [[gb5-galaxybook5-hw-setup]]), power management is deliberately split
so nothing fights:

- **power-profiles-daemon owns** the intel_pstate EPP hint and the ACPI
  `platform_profile`. KDE PowerDevil switches PPD profiles per power source via
  `~/.config/powerdevilrc`: AC=performance, Battery=balanced, LowBattery=power-saver.
  Do NOT install TLP or auto-cpufreq — they conflict with PPD and KDE's integration.
- **`/usr/local/sbin/gb5-power-tune.sh` owns only what PPD does not**:
  `hwp_dynamic_boost` and the PCIe ASPM policy. Driven by
  `/etc/udev/rules.d/99-gb5-power.rules` on charger plug/unplug plus a boot service.
- CPU topology: cpu0-5 = P-cores (5.1 GHz), cpu6-13 = E-cores (4.4 GHz),
  cpu14-15 = low-power E-cores (2.5 GHz, no L3). The kernel uses hybrid capacity
  scaling, not ITMT, so `/proc/sys/kernel/sched_itmt_enabled` legitimately does
  not exist — that is not a misconfiguration.
- zram (`/etc/systemd/zram-generator.conf`) is swap priority 100; the 8.8 GB disk
  swap partition is kept at priority -1 ONLY so hibernate has somewhere to go.
  8.8 GB is smaller than the 30 GB of RAM, so hibernation is unreliable when
  memory is well used.
- `/etc/sysctl.d/99-gb5-tuning.conf` holds the zram/NVMe/network tuning.

Sleep was measured, not assumed (19 Aug 2026): a 31 s RTC-woken s2idle cycle spent
28.3 s (91%) in S0ix and 27.3 s in the deepest substate S0i2.2, on both PMC dies.
`s2idle` is the ONLY sleep state — Arrow Lake dropped S3 — so `[s2idle]` in
`/sys/power/mem_sleep` is correct, not a misconfiguration. The residency counters
in `/sys/kernel/debug/pmc_core/` read 0 on a running desktop and only advance
while suspended, so they can never be checked without actually suspending.

The fingerprint reader (`/sys/bus/usb/devices/3-5`) is deliberately pinned to
`power/control = on` via `/etc/udev/rules.d/99-gb5-usb-autosuspend.rules`.
Autosuspend was tried and reverted: libfprint's autosuspend hwdb lists 1c7a:05a5
only in its known-but-unsupported block, so upstream never validated it there.
Do not "optimise" this back to auto.

2026-08-20: `gb5-power-tune.sh` also switches the panel refresh rate — 120 Hz on AC,
60 Hz on battery — since KDE has no automatic switching and the display is the largest
idle consumer. Disable with `GB5_KEEP_120HZ=1` in `/etc/default/gb5-power`. It runs
kscreen-doctor inside the active Wayland session via setpriv, time-boxed because
kscreen-doctor hangs forever without WAYLAND_DISPLAY.

2026-08-21: two camera-related power notes.

- The v4l2-relayd bridge is on-demand and idles at 0% CPU with no consumer. If the privacy
  light is on and you do not know why, `sudo fuser -v /dev/video0` names the process. The
  usual culprit is the NPU effects app, which is deliberately NOT a service — running it
  holds the camera powered.
- The camera pipeline was moved onto the GPU's VEBOX unit (`vapostproc`), which does colour
  conversion and denoise at 20% of a core versus 24% for the CPU chain it replaced, while
  also removing the frame stalls. Cheaper and better at once; see
  [[gb5-galaxybook5-hw-setup]].

## Platform profiles are the biggest battery lever on this machine (2026-08-22)

The earlier note that this script deliberately leaves `platform_profile` to
power-profiles-daemon is now only half true — see below for why that changed.

Measured, idle, package power via RAPL, two independent rounds:

| profile | idle | under all-core load |
|---|---|---|
| `quiet` | **4.8 W** | 1925 MHz, 79 C |
| `balanced` | 7.1-10.0 W | — |
| `performance` | **17.5 W** | 2369 MHz, 84 C |

Performance mode costs ~3.5x quiet at idle for clocks nothing is using. The
load difference is thermal headroom, not a power limit: package power was ~40 W
either way, and performance simply lets the fan work harder so the CPU holds a
higher clock. This is the same mechanism Samsung Settings drives on Windows —
`platform_profile` is provided by the `samsung-galaxybook` driver, and the write
reaches the EC (byte 0x8e changes with the mode).

Four modes, all mapped, none hidden — the driver logs
`ignoring unmapped performance mode` when firmware offers one it does not
understand, and that count is zero. Windows exposes three; `low-power` has no
counterpart in Samsung Settings.

**KDE reaches only three of them.** PPD maps power-saver/balanced/performance to
low-power/balanced/performance. `quiet` is unreachable through it, which is why
`gb5-power-profile.sh` writes `platform_profile` directly:

- on AC — left alone, KDE and PPD own it
- on battery above 50% — `balanced`
- on battery at or below 50% — `quiet`, with a 55% hysteresis band so it does
  not flap across the threshold

It reasserts on a 1-minute timer because PPD rewrites `platform_profile`
whenever KDE switches profile on a charger change, and it **backs off entirely
if the current profile is not the one it last set** — a deliberate manual choice
is left alone until the power state next changes. `GB5_PROFILE_MANAGE=0` in
`/etc/default/gb5-power` disables it.

Correction to an earlier conclusion recorded during this work: "there is no fan
control" was wrong in the way that matters. It is true that the ACPI fan control
methods (`_FSL`, `_FPS`, `_FIF`) are all absent and `cooling_device0` is binary
— but the control is not a speed dial, it is a mode the EC interprets, and it
was tested at 48 C idle where no fan curve diverges. Test under load.

## C-states: what the names hide (2026-08-22)

`cpuidle` on this machine shows only three states and they are named misleadingly.
`intel_idle` has **no native table for Arrow Lake** — mainline has entries for
Meteor Lake-L and even the newer Panther Lake-L, but not Arrow Lake — so it falls
back to the firmware's ACPI `_CST`. That path names states by ACPI's own generic
numbering, which is **not** the hardware C-state:

| shown as | MWAIT hint | actually is |
|---|---|---|
| `C1_ACPI` | 0x00 | C1 |
| `C2_ACPI` | 0x21 | **C6** |
| `C3_ACPI` | 0x60 | **C10** |

The hint encodes the real state: `hint >> 4` is the C-state index. Reading
`C1/C2/C3` as literal hardware states leads straight to the wrong conclusion that
the machine is capped at C3 — it is not, the cores reach **C10** routinely
(861,820 entries and 40 minutes of a 55-minute uptime, measured).

**A custom kernel would gain nothing here.** The only thing Meteor Lake's native
table adds over this ACPI path is a nominal `C1E` entry, and C1E auto-promotion
is already enabled in hardware — `MSR_IA32_POWER_CTL` (0x1FC) bit 1 is set on all
16 logical CPUs, so a C1 request is promoted to C1E by the CPU regardless of what
the OS asks for. Energy-Efficient Turbo (bit 18) is on too.

### Package C10 is a different question

Core C10 and *package* C10 are not the same thing. Package C10 needs every core
in C10 *and* the uncore and GPU idle simultaneously. With anything running that
window never opens: measured over 10 s with a Node dev process, browsers and KDE
polling active, the package spent **0.03 s** in any C-state, and package C7-C10
read zero for the whole boot.

So the earlier note that PCI runtime PM "lets the package reach C10 — deep idle
at 97.5%" describes a genuinely idle moment, not a general property. It is a
point measurement, and it is only reproducible when the machine is actually idle.

### The idle governor is over-committing

`above` counts entries where the idle duration was **too short** for the state
chosen — the transition cost was not repaid. (`below` is the opposite: it should
have gone deeper. Easy to reverse; the kernel's sysfs ABI doc is the authority.)

    C10  878,233 entries, 670,832 too short   (76%)
    C6   910,764 entries, 190,411 too short   (21%)

Three quarters of C10 entries wake before the 3,144 us residency target. That is
not a tuning fault — it is what constant background wakeups do. Fixing the
workload is the lever; there is no governor setting that makes a premature wakeup
cheaper.

## intel-lpmd: patched to run, measured, rejected (2026-08-22)

`intel_lpmd` is Intel's low-power-mode daemon. On idle it is supposed to herd work
onto the two LP-E cores and let the rest of the package sleep. It refuses to start
on this machine:

    Unsupported CPU model

The model table in `src/lpmd_cpu.c` knows Arrow Lake as `0xb5`. This chip is
**family 6, model 0xc5, stepping 2** — Arrow Lake-H, a different model number for
the same architecture. Adding one line makes it run
(`packaging/patches/intel-lpmd-0001-recognise-arrowlake-h-0xc5.patch`). It then detects the
topology correctly:

    Detected 6 Pcores, 8 Ecores, 2 Lcores, TDP 28W
    Use CPU 14,15 as Default Low Power CPUs (Lcores)

**It was measured and then removed. Two reasons.**

### 1. It saves nothing here

Back-to-back in the same minute, package RAPL:

    with intel_lpmd running   7.94 W
    intel_lpmd stopped        7.87 W
    after full revert         ~8.0 W median over 60 s

That is one number, three times. There is no effect to detect.

A word on how this nearly went wrong: an earlier comparison appeared to show
3.73 W baseline against 7.17 W with lpmd, i.e. lpmd doubling power. That was
**not a real result** — the baseline had been taken half an hour earlier on a
quieter machine and compared against a fresh run. Two measurements taken far
apart on a desktop with browsers and a dev server running are not an A/B test.
Both arms have to run in the same minute.

### 2. It leaves the machine restricted after it exits

This is the part that matters. lpmd applies low-power mode by writing
`cpuset.cpus` on the systemd slices over D-Bus:

    Sending Dbus message to systemd: system.slice: 0xff 0x3f 0x00 0x00
    [ Enter] [AUTO] [DEFAULT_HFI]: CPUMASK [2]

It entered `DEFAULT_HFI` immediately at startup and pinned everything to CPUs
**0-13** — which *excludes* cores 14 and 15, the LP-E cores it had just
identified as the low-power ones. Whatever the intent, the observable effect is
the opposite of the goal, and it matches what the utilisation counters showed at
the time: LP-E busy fell while P-core busy rose.

Worse, **killing the daemon does not undo it**, and the obvious fix does not
either. After `intel_lpmd` was gone, all three slices still read `0-13`.

Writing the cgroup file directly *looks* like it works:

```bash
# WRONG -- this comes back
for c in system.slice user.slice machine.slice; do
    echo "" > /sys/fs/cgroup/$c/cpuset.cpus
done
```

It held for about an hour and then silently reverted. The reason: lpmd does not
write the cgroup file, it sets a **systemd property over D-Bus**, which leaves
runtime drop-ins behind:

    /run/systemd/system.control/system.slice.d/50-AllowedCPUs.conf
      [Slice]
      AllowedCPUs=0-13

systemd re-applies its recorded property on the next `daemon-reload` — which
here was triggered by installing an unrelated service. So the sysfs write fixes
the symptom and systemd undoes it at an unpredictable later moment.

The actual fix is to clear the property:

```bash
for c in system.slice user.slice machine.slice; do
    systemctl set-property --runtime "$c" AllowedCPUs=
done
```

Verify by running `systemctl daemon-reload` afterwards and checking that
`systemctl show system.slice -p AllowedCPUs` is empty and a fresh process reports
all 16 CPUs (`bash -c 'taskset -pc $$'`). When it is genuinely unset, systemd
removes the cpuset controller from those slices, so
`/sys/fs/cgroup/system.slice/cpuset.cpus.effective` stops existing — that absence
is the success condition, not an error.

The service is now `masked`, not merely disabled, so nothing pulls it in as a
dependency. The patch is kept because it is correct and worth upstreaming; the
daemon is not kept because it does not help.

### The topology, for reference

Arrow Lake-H has **no hyper-threading** — 16 logical CPUs are 16 physical cores.
Every `thread_siblings_list` is a single entry. It is easy to assume 6 P-cores
means CPUs 0-11 and get every per-core-type measurement wrong:

| CPUs | Type | Max clock | `cpu_capacity` |
|---|---|---|---|
| 0-5 | P-core, Lion Cove | 5100 MHz | 1024 |
| 6-13 | E-core, Skymont | 4400 MHz | 774 |
| 14-15 | LP-E, Skymont on the SoC tile | 2500 MHz | 312 |

Measured at a typical idle-ish desktop, over 30 s:

    P-core  (0-5)    busy 14.5%
    E-core  (6-13)   busy  3.8%
    LP-E    (14-15)  busy  1.1%
    system total     busy  7.5%

Light background work lands mostly on P-cores. That looks wrong and mostly is
not: Thread Director sends short latency-sensitive wakeups to a P-core at low
clock, which finishes sooner and returns to C10 faster than an LP-E core would.
Race-to-idle beats slow-and-steady for millisecond-scale work. It is only a
problem for sustained low-priority load, and there the fix is `cgroup` placement
for that specific workload, not a daemon that repartitions the whole machine.

## The compute stack: CPU, GPU and NPU (2026-08-22)

### Two corrections to the section above

Both of the alarming readings in the C-state notes were **measured under load**
and are wrong as stated:

- *"the package spent 0.03 s of 10 s in any C-state"* and *"package C7-C10 read
  zero for the whole boot"* — on a quiet machine the deepest package residency
  reads **12%**, not zero. Package C-states work. What is true is the weaker
  claim: anything running keeps the package awake, and this laptop is rarely
  quiet.
- *"uncore pinned at 3900 MHz"* — it is not pinned. `current_freq_khz` reads
  3900000 under load and **1500000** at idle, against a range of 400-3900 MHz.
  The uncore scales on its own; there is nothing to fix and no reason to clamp
  `max_freq_khz`.

The lesson is the same one the intel-lpmd measurement taught: a number read off a
busy desktop is a number about the desktop.

### `gb5-power-report`

`/usr/local/sbin/gb5-power-report` answers the question no single existing tool
does — *where are the watts going?*

    gb5-power-report            one snapshot
    gb5-power-report --watch    one line per sample, averages on Ctrl-C

The important design decision: **RAPL is not the system.** `intel-rapl` measures
the SoC package and nothing else — not the panel, not Wi-Fi, not the SSD, not the
board. At idle the package is well under half of total draw, so tuning by RAPL
alone optimises the minority of the problem. The only source for whole-machine
draw is the battery (`current_now × voltage_now`), which means **the numbers that
decide battery life are only available on battery**. On AC the tool says so
rather than guessing.

Inside the package it splits `PkgWatt` into cores, GPU and the remainder — the
fabric, memory controller and I/O, which people forget exists and which at idle
here is the *largest* of the three:

    package 3.9 W total
      0.72 W  CPU cores
      0.17 W  GPU
      3.00 W  fabric, memory ctrl, I/O

Needs `turbostat` (`pacman -S linux-tools`); falls back to raw RAPL without it.

### OpenVINO could not see the GPU at all

`plugins.xml` declares a GPU plugin, but `openvino-intel-gpu-plugin` was not
installed — so `Core().available_devices` returned only `['CPU', 'NPU']`. One
package fixes it:

```bash
pacman -S openvino-intel-gpu-plugin
```

Worth checking on any Arch-family install: the metapackage does not pull it in,
and nothing warns you. The failure mode is silent — code asking for `GPU` just
falls back.

### The NPU is the wrong engine for camera segmentation

MODNet portrait segmentation at 512x512, package-RAPL energy, three independent
runs in different machine states, all agreeing:

| Engine | ms/frame | fps | energy/frame |
|---|---|---|---|
| **iGPU** (Xe-LPG+, kernel calls it METEORLAKE) | **30** | **33** | **730 mJ** |
| NPU (AI Boost — **NPU 3720**, Meteor Lake silicon) | 113 | 8.8 | 2550 mJ |
| CPU | 166 | 6.0 | 3700 mJ |

The GPU is 3.7x faster *and* uses 3.5x less energy per frame. The NPU cannot
sustain a 30 fps camera on this model at all — 30 fps needs 33 ms/frame and it
delivers 113.

Converting the ONNX to a static-shape FP16 OpenVINO IR does **not** help: the NPU
stays at ~118 ms. So this is the model, not the input format.

This is not "the NPU is bad". It is built for small INT8-quantised models running
continuously at very low power, and it does sleep properly when unused (99.5% of
uptime runtime-suspended here). FP16 MODNet is simply not that workload. If the
model is ever quantised to INT8, re-measure before assuming this still holds.

`linux-studio-effects` now defaults to `device="GPU"` with `fallback_device="NPU"`.

### What was already right

Worth stating, because the temptation is to "fix" things that are not broken:

- **GPU**: `i915` with GuC 70.53 submission, HuC authenticated for all workloads,
  SLPC and RC6 enabled, 92% RC6 residency at idle. Nothing to do.
- **VA-API**: full decode *and* encode for H.264, HEVC, VP9 and AV1 via
  `intel-media-driver` 26.2.4. Nothing to do.
- **NPU**: `intel_vpu` runtime-suspends correctly, `sched_mode HW`.
- **CPU**: `intel_pstate` active with HWP, `powersave` governor, turbo enabled.

### What could not be measured honestly

**Whether hardware video decode saves meaningful power at 1080p.** Four separate
attempts failed, and the failures are instructive:

1. A synthetic `testsrc2` clip decodes at 46x realtime — too easy to discriminate
   between paths.
2. `-f null` with `-hwaccel vaapi` but no `-hwaccel_output_format vaapi` forces a
   GPU-to-CPU copy of every frame, which no real player does. That made hardware
   decode look *worse* than software.
3. Decoding "as fast as possible" measures the race, not the workload. Playback
   is a realtime problem; the arms must run at `-re`.
4. With all of that fixed, the run still failed: across three alternating pairs
   the **idle** arms alone ranged 4.29 W to 10.20 W. Within-condition spread
   exceeded between-condition difference, because the machine is a live desktop
   with a browser and KDE on it.

The one clean pair suggests software ~0.96 W and VA-API ~0.55 W above idle, but
that is n=1 and is not reported as a result. The honest position: at 1080p this
CPU decodes at 17x realtime, so the saving is small either way; it would matter
at 4K, for several simultaneous streams, or on battery where fractions of a watt
compound. Use `gb5-power-report --watch` during a real call to find out.

## What the research pass established (2026-08-22)

A six-topic research fan-out with adversarial verification (each finding handed
to a separate agent told to refute it, defaulting to refuted when unconfirmable).
109 findings proposed, 19 verified, 13 survived. The verifiers had shell access
to this machine, so most of what follows was checked against the hardware rather
than against documentation. Several of them correct things written earlier in
this file.

### The NPU is Meteor Lake silicon, and the MODNet gap has a specific cause

**This is not "NPU 4".** Arrow Lake-H reuses the Meteor Lake SoC tile, so the
accelerator is **NPU 3720** — literally the MTL NPU. `PCI_ID=8086:7D1D`, firmware
`intel/vpu/vpu_37xx_v1.bin`. Every "Core Ultra 200 has a 13-TOPS NPU 4" figure
you read about the 255H is about a different tile than the one in this chip.

OpenVINO's own declared throughput settles the argument:

    NPU DEVICE_GOPS   FP16 6553.6    INT8 13107.2
    GPU DEVICE_GOPS   FP16 ~5.62x the NPU, in both precisions

So the measured 3.7-4.4x wall-clock gap is not a misconfiguration — it is
slightly *better* than the declared ratio predicts.

**The specific collapse has a named cause.** Per-layer profiling
(`compile_model(..., {'PERF_COUNT': True})`, then read `profiling_info`) shows
only **10.2% of NPU time is convolution**. The cost is bilinear `Interpolate`
upsampling: a single 32-channel 256->512 upsample takes **85-88 ms on the NPU
against 17 ms on the iGPU**. Downsampling is fine; it is upsampling that falls
off a cliff.

That also kills the obvious next idea. **INT8 quantisation will not close the
gap**: by Amdahl, making all convolution infinitely fast still leaves the NPU at
~9.4 fps against the measured 8.5. Roughly +5%, for a substantial quantisation
effort. Not worth doing.

### The iGPU is not Xe2

Earlier notes here called it "Arc 140T / Xe2". Wrong on both counts:

    graphics version 12.74   media 13   display 14
    platform: METEORLAKE     require_force_probe: no

It is **Xe-LPG+**, and the kernel classifies it as Meteor Lake — which is why it
loads `mtl_*` GuC/HuC firmware. Worth correcting because it rules out a whole
category of tuning advice written for Xe2/Xe3 (DMC wakelock, FBC dirty-rect
arbitration, the display>=20 DC-state table); none of it applies.

### Stay on i915

`xe` still sets `require_force_probe = true` for this device (`0x7D51`,
`INTEL_ARL_H_IDS`) on kernel 7.1, so i915 is the only officially-supported path.
There is no published i915-vs-xe idle-power comparison for ARL-H. And switching
would *remove* the one GPU power knob that exists: `slpc_power_profile` is an
i915 sysfs file with no `xe` equivalent. (TLP's documentation claims the opposite
— that it is xe-only. On this kernel it is present and writable on both i915 GTs.)

### Uncore: capping it is worse than useless

Confirms and extends the correction above. Alternated A/B, four rounds, 8 s
turbostat windows on a quiet machine: lowering `max_freq_khz` saves **under
0.2 W** at idle, inside run-to-run noise, because the hardware already parks the
uncore at 1300-1500 MHz on its own.

And the downside is severe. Sweeping the cap against a 6-thread streaming read:

    cap 3900 MHz (hardware's own choice)   32.1 GB/s
    cap  400 MHz                           ~30% of that

Capping below ~1600 MHz destroys memory bandwidth, and 1600 is already where the
hardware sits — so the only safe cap is one that changes nothing.

### Two package C-state columns do not exist

`Pkg%pc7` and `Pkg%pc9` **cannot be reported on this family**. turbostat maps
`INTEL_ARROWLAKE_H` to `adl_features`, whose supported set is
`CC1|CC6|CC7|PC2|PC3|PC6|PC8|PC10` — PC7 and PC9 are absent, with an explicit
upstream comment "Copied from cnl_features, with PC7/PC9 removed". Requests for
those columns are silently dropped, and MSRs 0x3FA/0x631 read a permanent zero.

So of the earlier alarm that "package C7 through C10 read exactly zero", **half
was architectural**. Only C8 and C10 were meaningful zeros. The five columns that
exist here are pc2, pc3, pc6, pc8, pc10.

Also settled: the zeros were never a turbostat reporting gap. The architectural
residency MSRs work correctly on family 6 model 0xC5.

### The scheduler is already doing the right thing

`sched_itmt_enabled` is absent **by design**, not broken: `intel_pstate` calls
`sched_clear_itmt_support()` on hybrid-without-SMT parts. The scheduler instead
learns the asymmetry through **Capacity-Aware Scheduling**, using per-CPU
`cpu_capacity` that intel_pstate publishes:

    cpu0-5   1024      cpu6-13  774      cpu14-15  312

That is working, and wakeups go through `select_idle_capacity()` with misfit
load balancing. **Do not set `intel_pstate=no_cas`** — it destroys `cpu_capacity`
along with the thing it disables.

**HFI is disabled in hardware** because no userspace thermal-netlink client is
bound to it (`IA32_HW_FEEDBACK_PTR` valid, but the enable bit clear). Subscribing
thermald would only tell userspace which cores are currently preferred; it does
not change scheduling. Zero measurable gain.

### Browser hardware decode is already on — do not add flags

**VA-API decode is enabled by default in Brave 1.93 / Chromium M151 on Linux.**
`kAcceleratedVideoDecodeLinux` is `FEATURE_ENABLED_BY_DEFAULT` in
`media/base/media_switches.cc`. Nothing needs adding.

Two flags commonly copy-pasted from 2021-era guides:

- `VaapiVideoDecodeLinuxGL` — **obsolete, does not exist in M151.** The current
  name is `AcceleratedVideoDecodeLinuxGL`, and it is already default-on. Grep the
  real binary (`/usr/lib/brave-browser/brave`, not the wrapper script) to confirm.
- `VaapiIgnoreDriverChecks` — a no-op on Intel iHD. The blocklist it bypasses only
  targets non-Intel VA-API backends.

The actionable advice is the reverse of the usual: **remove stale flags**, which
can force paths that no longer exist and create false confidence.

### One topic failed

`uncore-fabric` research died on an API error after its findings were already
verified through the other topics. Nothing lost — the uncore question is answered
above with direct measurement.


## Correction: the NPU benchmark used the wrong resolution (2026-08-22)

Everything above about MODNet on the NPU was measured at **512x512**.
`linux-studio-effects` runs the model at **256x256** (`MODEL_INPUT_HEIGHT` /
`MODEL_INPUT_WIDTH` in `src/effects/background.py`) — a quarter of the pixels.
The device choice has to be made at the shape the application actually uses.

Re-measured at 256x256, order alternated, two full passes:

| Device | ms/frame | max fps | headroom over 30 fps | net W at 30 fps |
|---|---|---|---|---|
| NPU | 27.3 | 36.6 | 1.2x | 4.19 |
| GPU | 8.5 | 117.6 | 3.9x | 2.75 |

**The claim that "the NPU cannot sustain a 30 fps camera" is false at the real
resolution.** It manages 36.6 fps. That claim was written into `config.py` as
justification for switching the app to the GPU, and it has been corrected there.

The GPU remains the right default, but for different reasons than the ones
originally given:

- **Headroom.** 3.9x against 1.2x. Twenty percent of margin is not enough to
  absorb jitter on a live desktop; a single slow frame drops one.
- **Energy.** At a fixed 30 fps the GPU costs about **1.4 W less**, because it
  finishes each frame in a third of the time and returns to idle. Peak power is
  higher (14.1 W against 8.5 W) but duty cycle is a quarter, and duty cycle wins.

One thing not measured: **GPU contention.** The camera pipeline already uses the
GPU for relay, blur and compositing, so inference there competes with work the
NPU would leave alone. If frame pacing regresses, that is the first suspect, and
`fallback_device = "NPU"` is a legitimate answer.

### A discrepancy worth flagging

The published page states 11.3 ms/frame for the NPU at 256x256. This measurement
says 27.3 ms — 2.4x slower. Both numbers are recorded rather than one being
quietly deleted, because the conditions differed (this run was on battery at the
`balanced` platform profile; the original may have been on AC, or used a
throughput hint, or a warm compile cache). Whichever is right, the conclusion
holds: at 11.3 ms the NPU would have 2.9x headroom and the energy argument would
narrow but not reverse.


## Auto-brightness, and what brightness is actually worth (2026-08-22)

### The sensor works; the auto-brightness does not appear to act

`iio-sensor-proxy` reports `HasAmbientLight true` and `LightLevel 0.802 lux` —
a dark room, correctly sensed. KDE has `automaticBrightness: true` for this panel.

And yet the panel sat at **2047/2047, full brightness**, for the entire night.
Sampling the raw sensor and the backlight together once every five seconds for a
minute produced a completely flat pair: `als=802 brightness=2047`, twelve times.

So auto-brightness is configured on, the sensor is being read, and the panel is
at maximum in a 0.8 lux room. Something between the two is not happening. (One
loose end: during earlier testing the backlight was observed at 1126, a value
nothing in the tests had written, so PowerDevil does act at *some* point. Not
explained.)

This also retires an earlier worry. The white-versus-black measurements were
suspected of being inflated by an auto-brightness feedback loop — white screen
lights the room, sensor reads brighter, panel goes brighter. If auto-brightness
is not adjusting at all, there was no loop, and **the ~10 W content figure is
genuine content cost at fixed brightness**.

### Brightness with real content is worth almost nothing

A/B on battery with the actual desktop on screen (a dark terminal), 60 s samples,
order alternated:

    brightness 100%   6.21 W  /  5.71 W      median ~5.96
    brightness  10%   5.65 W  /  5.81 W      median ~5.73

About **0.2 W**, and the arms overlap — in round 2 the 100% sample came out
*lower* than the 10% one. Not a measurable lever.

That is exactly what the OLED model predicts and it is the point worth carrying:
**brightness is a multiplier on emitted light, and dark content has almost no
light to multiply.** Turning the brightness down on a dark screen saves nothing
because the pixels are already off. On a bright screen it would matter a great
deal, which is where the 10 W content figure comes from.

So the practical ordering is:

1. **Dark content** — up to 10 W.
2. Brightness — irrelevant with dark content, significant with bright content.
3. Auto-brightness — currently not acting; worth investigating for comfort and
   for the bright-content case, but worth ~0.2 W as things stand tonight.

## The battery gauge has 49 mAh of resolution, and it defeats short A/Bs (2026-08-22)

Worth knowing before designing any battery measurement on this machine.

`/sys/class/power_supply/BAT1/charge_now` does **not** update continuously. It
holds a value and then jumps, in steps of exactly **49000 µAh (49 mAh)**, roughly
every **445 seconds**:

    start 2058000
      step at t+282s : 2058000 -> 2009000   (delta 49000)
      step at t+727s : 2009000 -> 1960000   (delta 49000)

Sampling it every 5 s for a minute shows a completely flat reading, during which
about 6 mAh was actually drawn.

### What that cost

A `quiet` versus `balanced` comparison was run as four alternating 12-minute
arms, measured by charge delta. The results:

    quiet      98 mAh   ->  7.45 W
    balanced   98 mAh   ->  7.44 W
    balanced   98 mAh   ->  7.43 W
    quiet      49 mAh   ->  3.71 W

Read as step counts those are **2, 2, 2, 1** — there is no sub-step information
in them at all. The apparent halving in the last arm is one step that had not
landed yet, not an effect. Resolution on a 12-minute arm is ±49 mAh against a
~98 mAh signal, i.e. **±50%**.

**So the result is "not measurable", which is not the same claim as "no
difference".** The experiment could not have detected a difference if one existed.

Resolving it would need about 8 steps per arm — roughly 1 hour per arm, 4 hours
for the alternated set. That is a reasonable thing to run on AC some time; it was
not feasible on a draining battery.

### What it does not threaten

The 12.1 h runtime figure came from a 14% drop over 1.69 h — 686 mAh, or **14
steps**. Quantisation error there is ±49/686 = ±7.1%, so 12.1 h ± 0.9 h. That
figure stands.

The rule this suggests: **count the steps before believing a battery A/B.**
Anything under about 8 steps per arm is measuring the gauge, not the machine.

### A theoretical note, offered as expectation rather than result

`platform_profile` sets power and thermal *limits*. Limits only bind when
something is pushing against them, so no idle difference between `quiet` and
`balanced` is expected in the first place — the early figure of "4.8 W quiet
against 7-10 W balanced" was package-only RAPL taken before any of this
project's measurement discipline existed, and should not be relied on. Where
`quiet` should genuinely matter is under sustained load, where it was separately
measured to hold 1925 MHz against `performance`'s 2369 MHz. That comparison is
still the one worth trusting for this knob.

## What is actually waking the machine (2026-08-22)

C10 residency is 91.6% and package power at idle is 3.48 W, so the idle *depth*
is fine. What is not fine is the wakeup *rate*: **2208 interrupts per second** on
a machine at 3% busy, of which 86% are local timer interrupts. Over half of all
C10 entries wake before their residency target is repaid (60.5% on a P-core,
52.0% on an E-core, 52.3% on an LP-E core).

`powertop`'s software section came back completely empty — it could not attribute
wakeups to processes at all — so attribution came from voluntary context switches
per process instead, sampled over 10 s:

|  wakeups/s | process |
|---|---|
| **96.8** | **`claude`** — the agent taking the measurement |
| 75.0 | `rcu_preempt` (kernel, follows from everything else) |
| 63.3 | `kwin_wayland` |
| 50.6 | `irq/193-iwlwifi` |
| 42.9 | `yakuake` |
| 30.8 | `kworker/u69:2-i915_flip` |
| 26.8 | `plasma-systemmonitor` |
| 14.0 | `ksystemstats` |
| | **623/s total across 104 processes** |

### The caveat this puts on every idle number in this document

**The single largest wakeup source during the idle measurements was the process
doing the measuring.** Every "idle" figure here — 3.33 W package, 4.7-4.8 W
system, 12.1 h runtime — was taken on a machine running an active agent session
with a terminal open.

That does not invalidate them; it locates them. They describe *a machine with
something light running on it*, which is a fair model of real use and arguably
more honest than a synthetic idle. But the true floor, with a logged-in desktop
and genuinely nothing happening, is lower than anything measured here.

### The one actionable item

`plasma-systemmonitor` and `ksystemstats` together account for **~41 wakeups/s**
purely to keep monitor widgets updated. If those widgets are not on screen and
being looked at, that is pure overhead. Worth closing.

Everything else on the list is either the compositor doing its job, Wi-Fi
receiving, or the measurement apparatus itself.

### Not a tick-rate problem

Worth ruling out explicitly, because 1908 timer interrupts per second invites the
conclusion that dynticks is broken. It is not. The kernel has
`CONFIG_NO_HZ_FULL=y` with no `nohz_full=` on the command line, which behaves as
dynticks-idle, and `CONFIG_HZ` is 1000. A genuinely periodic tick across 16 CPUs
would be 16000/s. At 1908/s the CPUs are tickless most of the time and the timer
interrupts are tracking real wakeups, not a fixed tick.

## The three tools, and why the third one refuses to answer sometimes

Copies live in `tools/`; the working versions are in `/usr/local/sbin/`.

    gb5-power-report            one snapshot: where the watts go right now
    gb5-power-report --watch    live table, averages on Ctrl-C
    gb5-power-log               systemd service, CSV every 30 s
    gb5-power-analyse           reads the CSVs and reports what they can support

`gb5-power-analyse` encodes the four lessons this project paid for:

- It integrates `charge_now` for runtimes and only uses snapshots for an idle
  floor, because snapshots under-reported real drain by 17% and 22% in two
  separate windows.
- It labels the idle floor as a floor, with the percentage of samples that were
  actually quiet, so it cannot be mistaken for a runtime again.
- **It counts gauge steps and prints `NOT MEASURABLE` when a window spans fewer
  than eight**, rather than dividing two numbers and producing a confident answer
  from quantisation noise.
- It prints the snapshot bias explicitly, so the discrepancy is visible rather
  than something to rediscover.

Current output on the two logs from the overnight run:

    phase 1 (no charge counter)   snapshots only, flagged as such
    phase 2   980 mAh = 20.0 steps   6.14 W -> 12.1 h +/- 0.6 h   (+/-5.0%)
              snapshot bias -21.8%   idle floor 4.69 W (quiet 90% of samples)

## What happens when the battery actually runs out (2026-08-22)

Checked rather than assumed, because "it will just hibernate" is the kind of
thing that turns out to be false at the worst moment.

    CanHibernate      yes
    CanHybridSleep    yes
    /sys/power/state  freeze mem disk
    resume=           set on the kernel command line
    UPower            PercentageAction=2.0, CriticalPowerAction=Auto

`Auto` resolves to HybridSleep where available, so at 2% the machine suspends to
disk cleanly rather than losing power mid-write.

**"Nothing to fix" was wrong** — everything below in this section is the state
*before* 2026-08-23 and is kept as a record of how the problem was first
misjudged. Hibernation could not complete at all, and the 7.44 GiB figure below
was a quiet moment: with an Android build running it was 17.7 GiB against 8.8 GiB
of swap. The fix is a 20 GiB swapfile, in
[`docs/system/hibernation.md`](../system/hibernation.md).

**The margin is thinner than it looks, though.** Hibernation must fit used RAM
into *disk* swap, and zram does not count:

    RAM in use          7.44 GiB
    disk swap           8.80 GiB   (/dev/nvme0n1p3)  <- the only usable space
    zram swap           7.69 GiB   (irrelevant to hibernate)
    headroom            1.36 GiB

At a light desktop that is fine. Run anything memory-heavy — a large build, a VM,
a browser with a hundred tabs — and used RAM crosses 8.8 GiB, hibernation fails,
and the 2% critical action falls through to a hard power-off with whatever was
unsaved. The machine has 30 GiB of RAM and 8.8 GiB of hibernation space, so this
is not a hypothetical.

If that matters, the fix is a larger swap partition or a resume-capable swapfile;
`AllowRiskyCriticalPowerAction=false` in `UPower.conf` means UPower will not
attempt an action it believes unsafe, so it fails quietly rather than loudly.

### Converged figure

Extended to 3.40 h and **29 gauge steps**, the runtime estimate settles:

| window | steps | drain | runtime |
|---|---|---|---|
| 1.69 h | 14 | 6.30 W | 12.1 h ± 0.9 |
| 2.42 h | 20 | 6.14 W | 12.1 h ± 0.6 |
| 3.40 h | 29 | 6.29 W | 11.7 h ± 0.4 |
| **3.93 h** | **33** | **6.19 W** | **11.9 h ± 0.4** |

The error bars overlap throughout, which is what convergence should look like.
Quote the last row: more steps, less quantisation. The snapshot bias grew from
−17% to −24% across the same windows, which is what a systematic sampling error
does as it accumulates more missed bursts.


### The analyser segments the log, which matters more than it sounds

`gb5-power-analyse` originally computed drain from the first and last row of a
file. That is correct only while the log is one unbroken discharge. The moment it
contains a charging period or a suspend gap — which any real overnight log will —
wall-clock keeps advancing while charge stops falling, or rises, and the result
is nonsense presented with the same confidence as a good measurement.

It now splits the log into contiguous discharging runs, breaking on any gap
longer than four sample intervals or on charge increasing, and reports the
longest run with a note saying it did so. Verified against a synthetic log
containing a two-hour suspend and a recharge: it finds two runs, uses the 40-
sample one, and says so.

Final overnight data, one contiguous run of 3.93 h and 33 steps: **6.19 W → 11.9 h ± 0.4** (±3.0%).

## Auto-brightness is enabled and does nothing (2026-08-22, on AC)

Chased down properly with the charger in. Every component works in isolation and
the feature still does not function.

**The sensor works and is live.** `iio-sensor-proxy` reports `HasAmbientLight
true` and a `LightLevel` that tracks the room — 0.802 lux overnight, 27-29 lux
after dawn, varying between samples.

**The write path works.** KDE writes brightness through logind, and calling it by
hand succeeds:

```bash
busctl call org.freedesktop.login1 /org/freedesktop/login1/session/auto \
  org.freedesktop.login1.Session SetBrightness ssu backlight intel_backlight 1500
```

**The setting is on and in the right place.** `automaticBrightness: true` in
`~/.config/kwinoutputconfig.json` — in Plasma 6 this moved kwin-side, and
`powerdevilrc` correctly carries no auto-brightness key.

**And yet it never acts.** Brightness was set to 1500 by hand and then watched for
a minute while the sensor varied live between 27 and 29 lux. It stayed at 1500 for
all ten samples. Overnight it sat at 2047/2047 through a 0.802 lux room.

One `[BacklightBrightness]: Failed to set screen brightness ""` appeared in the
journal — exactly once, at 13:35:18, which is when this investigation was writing
to the sysfs file directly. Self-inflicted; not the cause.

So the conclusion is narrow and honest: **the feature is configured, its
dependencies all function, and it does not run.** No root cause found. Whether
that is a Plasma bug, a missing System Settings toggle that the JSON key does not
imply, or something else on this machine is unresolved.

### Does it matter?

Barely, as things stand. Brightness with dark content on screen is worth about
0.2 W (measured, arms overlapping). With bright content it would matter a great
deal, because that is where the 10 W content difference lives. So this is worth
fixing for comfort and for the bright-content case, not for idle battery life.

For now the panel simply stays wherever it is put — which also means the earlier
worry that auto-brightness inflated the content measurement through a feedback
loop is definitively retired. There is no loop, because there is no loop closing.

## platform_profile under load: quiet costs 27% of clock and saves nothing measurable (2026-08-22, on AC)

The idle comparison could not be measured — the battery gauge's 49 mAh steps made
it impossible. On AC, RAPL is a fine instrument and the gauge is irrelevant, and
under load is the only place a profile *can* act, because it sets limits and
limits need something pushing against them.

### The first attempt was confounded, and alternating order did not save it

Six arms, order alternated, 15 s between them:

    round 1 (cold -> hot)    quiet 26.60 W/1863   balanced 29.10 W/1950   performance 40.19 W/2519
    round 2 (hot throughout) performance 31.60 W/2700   balanced 19.07 W/1413   quiet 17.72 W/1862

Same profile, 40.2 W and 31.6 W. **Alternating order cannot fix cumulative heat
soak** — by round 2 the machine had been loaded for seven minutes and every arm
was thermally limited. Reordering shuffles the confound; only cooling removes it.

### Done properly

Each arm gated on `TCPU <= 52 °C` before starting, 60 s of load discarded to skip
the turbo burst, and only the following 90 s measured:

| profile | power (2 runs) | clock (2 runs) | spread |
|---|---|---|---|
| `quiet` | 21.11 / 18.43 W | **1025 / 1025 MHz** | power 13.6%, clock **0.0%** |
| `balanced` | 20.26 / 19.21 W | 1395 / 1413 MHz | power 5.3%, clock 1.3% |
| `performance` | 30.78 / 28.36 W | 1977 / 2531 MHz | power 8.2%, clock 24.6% |

The clock figures looked like the trustworthy ones — `quiet` returned *exactly*
1025 MHz twice.

**But that claim does not survive comparison with the rest of the same day's
data.** `quiet` under all-core load also measured **1925 MHz** (earliest table),
then **1863** and **1862 MHz** (rounds 1-2 of the first attempt). A hard cap that
three same-knob measurements sat 80% above is not a hard cap. The package figure
has the same problem: 19.77 W here against "~40 W either way" earlier — a 2x
discrepancy in the same arm.

The likeliest reconciliation is that `quiet` permits a multi-minute burst and
then clamps, so only the cooled-start protocol with its 60 s discard ever saw the
floor. **That is a hypothesis, not a result, and the config change shipped before
anyone tested it.**

### The result

    quiet vs balanced    power  19.77 vs 19.73 W   +0.2%   ranges overlap
                         clock   1025 vs  1404 MHz  -27%   no overlap

**`quiet` gives up 27% of sustained clock and returns no measurable package power
saving.** Under sustained load it is strictly worse than `balanced`.

`performance` is real: roughly 50% more power for 40-80% more clock. Its clock
varied 24.6% between runs, so treat that range loosely — it is still thermally
sensitive even with a cooled start.

### The caveat that matters

**RAPL cannot see the fan, and the fan is what "Silent" mode is for.** Samsung's
Silent profile exists to reduce noise and skin temperature, and lower fan speed
is itself system power that never appears in a package reading. The fan
tachometer on this machine returns `Input/output error`, so none of that can be
quantified here.

So the honest statement is narrow: *for package power under sustained load*,
`quiet` buys nothing and costs a quarter of the clock. Whether it is worth it for
noise is a real question this measurement cannot answer.

### Three limits on that result

Stated plainly, because a setting was changed on the strength of it.

1. **Measured on AC; only ever applies on battery.** `GB5_PROFILE_LOW` fires at
   ≤50% battery, and the EC routinely enforces different power limits on DC. The
   regime where the setting actually acts was never measured — the battery A/B
   was impossible because of the 49 mAh gauge quantisation.
2. **The load bounds the conclusion.** A 16-way shell busy-loop is integer-only:
   no AVX, no memory traffic. Both arms sat against the same package limit *for
   that load*. Something AVX- or memory-heavy draws more power per MHz and could
   pull `balanced` down toward the cap, or push `quiet` against a lower DC limit
   and reveal a real saving. The honest finding is **"no package saving for a
   shell busy-loop on AC"**, not "no saving".
3. **RAPL cannot see the fan**, which is what Silent mode is for. Never
   quantified; the tachometer returns an I/O error.

### What that means for the battery automation

**With `GB5_PROFILE_LOW=balanced` equal to `GB5_PROFILE_BATTERY`, the ≤50%
threshold and its hysteresis are now inert** — the script picks the same profile
either side of the line. The machinery is kept rather than deleted because
setting `GB5_PROFILE_LOW=quiet` re-arms it with no other change, but nobody
should read the threshold and assume it is doing something.

`gb5-power-profile.sh` switched to `quiet` at ≤50% battery. **Changed to
`balanced`** on the strength of the measurement above: `GB5_PROFILE_LOW=balanced`
in `/etc/default/gb5-power`, no code edit needed.

The reasoning, stated plainly so it can be reversed on purpose rather than by
accident: under sustained load `quiet` gave up 27% of clock for +0.2% power with
overlapping ranges. If noise on battery ever matters more than sustained speed,
set it back to `quiet` — the fan side was never quantified, because the
tachometer returns an I/O error, so this measurement genuinely cannot argue
against the acoustic case.

While editing that file, a false comment was removed from it. It claimed the
60 Hz-on-battery switch was "a real power saving on this OLED". That saving was
never measured and, as established above, never happened at all — the panel has
no 60 Hz mode at native resolution.

## Hibernation was configured to fail, and it took the fingerprint reader with it (2026-08-22)

At 13:35:18, with the battery at 11%, something requested a hibernate through
logind. It allocated a 12.7 GB image, prepared S4, could not write it, and
resumed 28 ms later. The journal timestamps collapse across the freeze, so the
requester is not recoverable from the log and is not guessed at here.

**The consequence was not just a failed hibernate.** The aborted attempt reset
the USB bus:

    usb usb1: root hub lost power or was reset
    usb 3-5: reset full-speed USB device number 2 using xhci_hcd

`3-5` is the fingerprint reader. That reset destroyed its SDCP session, and every
verify from then on returned:

    verify_cb: result verify-unknown-error
    Device reported an error during verify: Device SDCP Identify response was not valid

Which is a *device error*, not a failed match — so `pam_fprintd` treated it as
fatal and fell straight through to the password prompt on the first prompt.
Fingerprint authentication was silently broken for nine hours.

### Why it could never have worked

    kernel image_size default   12472 MiB   (~2/5 of 30 GiB RAM)
    resume-capable swap          9011 MiB   (/dev/nvme0n1p3)
    shortfall                    3461 MiB

The kernel sizes the image from `image_size`, not from what the swap can hold, so
**no amount of free memory would have helped**. zram does not count — it lives in
RAM and cannot hold a RAM image.

### The repair

**Superseded.** This said "clearing the stale claim is enough; the enrolment
survives". Deleting `sdcp-claim` is the *destructive* route: the file holds the
host EC keypair, deleting it mints a new one, and the sensor then disowns the
templates it holds for the old identity. The pkgrel-5 driver patch makes it
unnecessary — a stale session is now invalidated in place, under the same host
identity. Restart the daemon instead:

```bash
# FIRST, and almost always enough since the pkgrel-5 patch:
systemctl restart fprintd

# ONLY if that fails. This DELETES THE HOST IDENTITY: the sensor stops
# recognising your templates and you must re-enrol.
# systemctl stop fprintd
# rm -f /var/lib/fprint/egismoc/*/sdcp-claim
# systemctl start fprintd
```

Afterwards the handshake succeeds and verify returns `verify-no-match` — a real
match attempt — instead of `verify-unknown-error`. That distinction is what makes
`max-tries` work at all.

### Superseded: the mitigation, and then the real fix

`/etc/tmpfiles.d/gb5-hibernate.conf` capped `image_size` at 7 GiB. **That was
inadequate and has been removed.** With 17.7 GiB of RAM in use during an Android
build the machine was short by nearly nine gigabytes, and the cap only meant the
kernel gave up earlier.

Replaced on 2026-08-23 by a 20 GiB swapfile on its own btrfs subvolume, with
`resume_offset` in the kernel command line. Tested with a real S4 cycle. Full
account in [`docs/system/hibernation.md`](../system/hibernation.md).

**The general lesson: hibernation that is enabled but cannot complete is worse
than hibernation switched off.** It costs battery, resets the USB bus, and can
wedge firmware interfaces in ways nothing surfaces for hours.

### The recurrence this created — now fixed in the driver

Making hibernation succeed armed a new bug: a successful S4 is a full power
cycle, the sensor loses its SDCP session, but the kernel `boot_id` does not
change — so the patched driver saw a same-boot cached claim, skipped Connect, and
failed with `SDCP AuthorizedIdentity verification failed`.

**Fixed.** `libfprint-egismoc-sdcp-git` pkgrel 5 treats that MAC failure as a
trigger to invalidate the cached session and reconnect under the same host
keypair. Verified on 2026-08-23: first touch after resume fails, the driver logs
`Invalidated the cached SDCP session`, the next claim reconnects, and the touch
after that returns `verify-match` with the enrolment intact.

**The first touch after each hibernate still fails**, because the driver only
learns the session is stale by failing. That is documented behaviour, not a
regression.


## The snapshot shortfall is the gauge, not the sampling (2026-08-22)

Every earlier note here explained the 17-24% gap between instantaneous readings
and the coulomb count as "snapshots miss bursts". **That explanation is wrong.**

Periodic sampling of instantaneous power is an *unbiased* estimator of the mean
unless the sampling correlates with load — missing bursts also means catching
them pro rata. A reproducible one-directional shortfall cannot come from that.

The test settles it. Both figures come from the **same fuel gauge**, so
integrating one register should converge on the other:

    window 5.29 h, 634 samples

    integral of current_now      1699.1 mAh
    delta of charge_now          2205.0 mAh   (45 steps)
    disagreement                  -22.9%

A sampling artifact cannot make two registers of one chip disagree. With 634
samples over five hours, integrating `current_now` would converge on the true
charge drawn if sampling were the problem. It does not. **`current_now` on this
gauge systematically under-reports by roughly 23%** — a gauge or driver
characteristic, not a methodology error.

The coulomb counter is the one to believe: `capacity` is derived from
`charge_now`, and the observed wall-clock discharge (~8.9 %/h from 71% to 13%
over 6.5 h, so ~11.2 h for a full pack) matches the coulomb figure of 11.9 h, not
the snapshot figure of 15-16 h.

**The operational rule was right for the wrong reason.** Integrate `charge_now`
for runtimes. But the corollary is sharper than previously written: `current_now`
is not merely imprecise here, it is *biased*, so the "idle floor" figures derived
from it — 4.7-4.9 W — are themselves likely ~23% low. The floor is a comparative
number, useful for ranking states, not an absolute.

### The error bar was too narrow

11.9 h was quoted as ±0.4 h. That is the **quantisation term only**: ±49 mAh on
1617 mAh, ±3.0%. (And ±1 step is correct, not ±2 — the unknown phase at each end
is a fraction of a step and the two enter with opposite signs, so the total is
bounded by strictly less than one step.)

Two systematic terms of comparable size were omitted: the mAh→Wh conversion
assumes a mean voltage, and `charge_full` reads 4900 mAh, *above* the 73.9 Wh
design capacity at 161 cycles, so the gauge is optimistic by a few percent.

**Honest figure: 11.9 h ± 0.5-0.8 h.**
