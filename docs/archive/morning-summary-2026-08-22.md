# Overnight run — what changed and what was learned

2026-08-22, roughly 03:00 to 06:00, machine on battery throughout.

## Read this first

**Your laptop draws 6.19 W at a light workload and gets 11.9 h ± 0.5-0.8 h.** That
is measured with the battery's coulomb counter over 3.93 h and 33 gauge steps,
not extrapolated, and it converged as data accumulated: 12.1 ± 0.9, then
12.1 ± 0.6, then 11.7 ± 0.4, then 11.9 ± 0.4. Overlapping error bars throughout.

**18 h is not reachable.** It needs 4.22 W sustained, which is below even the
quiet-moment floor once bursts are counted. Just under 12 h is still MacBook Air
territory for light work, which is what the original question was about.

**The one thing that matters more than everything else combined: what is on the
screen.** Full-screen white costs ~15 W against ~5 W for black on this OLED. That
10 W gap is larger than the gap between idling and compiling. A dark colour
scheme is worth more than every CPU, GPU and NPU change in this project.

## Changes made to the machine

| Change | Why |
|---|---|
| `openvino-intel-gpu-plugin` installed | OpenVINO could only see CPU and NPU; the GPU plugin was simply missing |
| `linux-studio-effects` → GPU, fallback NPU | 3.9× headroom against 1.2×, and ~1.4 W less at a fixed 30 fps |
| `intel_lpmd` masked, `AllowedCPUs` cleared | It pinned everything to CPUs 0–13 and the restriction outlived the daemon |
| `gb5-power-tune.sh` refresh switch now verifies | It had been logging a success that never happened for weeks |
| `gb5-power-profile.sh` re-asserts SLPC each minute | The GPU bias silently reverted to `base` on battery |
| `gb5-power-report` added | Snapshot and `--watch`; shows where the watts go |
| `gb5-power-log` service added | Continuous CSV; the only way past the ~6 W desktop noise floor |
| `turbostat` installed | Per-domain package power |

**One thing you did that mattered more than any of the above:** unplugging the
USB Ethernet adapter. It was holding the platform's latency floor at 128 µs and
package C8/C10 read exactly zero. With it gone they accumulate. Leave it
unplugged unless you need wired networking.

## Things I got wrong and corrected

Listed because the corrections are the useful part.

1. **"18 h is arithmetically impossible."** Based on a 4 W package idle that was
   contaminated by a busy desktop. Real package idle is 3.33 W.
2. **"15.6 h measured."** That was an idle *floor* extrapolated as a runtime. The
   machine is only that quiet 76–91% of the time. Real answer 11.9 h ± 0.5-0.8.
3. **"The NPU cannot sustain 30 fps."** Measured at 512×512; the app runs
   256×256, where the NPU manages 36.6 fps. The GPU is still the right default,
   but for headroom and energy, not because the NPU fails.
4. **"Package C7–C10 read zero."** Half architectural — `Pkg%pc7` and `Pkg%pc9`
   cannot be reported on this silicon at all.
5. **"The uncore is pinned at 3900 MHz."** It is not; that is the ceiling. It
   idles at 1300–1500.
6. **"The iGPU is Xe2 / Arc 140T" and "the NPU is NPU 4."** Both wrong — it is
   Xe-LPG+ and NPU 3720, Meteor Lake silicon, because Arrow Lake-H reuses the MTL
   SoC tile. Most tuning advice written for "Core Ultra 200" does not apply.
7. **The documented fix for the lpmd CPU restriction did not work.** Writing
   `cpuset.cpus` treats the symptom; systemd re-applied its own property on the
   next `daemon-reload`. Correct fix is `systemctl set-property --runtime`.

## Two measurement traps, worth carrying to other machines

- **A snapshot is not an average.** `current_now × voltage_now` sampled every
  30 s under-reported real drain by 17% and 22% in two windows. It misses bursts.
  Integrate `charge_now` for runtimes; snapshots are fine for an idle floor.
- **Count the gauge's steps before believing an A/B.** `charge_now` on this pack
  moves in 49 mAh jumps every ~445 s. A 12-minute arm therefore has ±50%
  resolution. A `quiet` vs `balanced` comparison run that way produced four arms
  reading 2, 2, 2 and 1 steps — pure quantisation, no information. Under about
  eight steps per arm you are measuring the gauge, not the machine.

## Open, needing you

- **Auto-brightness is configured on but is not acting.** `iio-sensor-proxy`
  correctly reports 0.802 lux — a dark room — while the panel sat at 2047/2047
  all night. Worth investigating for comfort; worth only ~0.2 W with dark
  content, but much more with bright content.
- **`quiet` vs `balanced` at idle is unresolved** and needs ~4 h on AC to settle.
  Theory says it should make no difference at idle. Under load it is real:
  1925 MHz against `performance`'s 2369 MHz.
- **Re-measure content cost at fixed brightness** if you want the content and
  auto-brightness contributions separated. Probably unnecessary — auto-brightness
  turned out not to be acting, so the 10 W figure is likely already clean.

## One caveat on every idle number here

The wakeup audit found that **the single largest source of wakeups during the
idle measurements was the agent process taking them** — 96.8/s, ahead of
`kwin_wayland` at 63.3 and Wi-Fi at 50.6. So 3.33 W package / 4.7 W system /
11.9 h describe *a machine with something light running on it*, not a synthetic
idle. That is arguably the more useful model, but the true floor is lower.

The one actionable item from that audit: `plasma-systemmonitor` and
`ksystemstats` burn ~41 wakeups/s keeping monitor widgets updated. Close them
when you are not watching them.

## Hibernation — fixed and tested since this was written

This section previously said the machine "will have hibernated, not died", and
then that hibernation was configured to fail. Both are superseded.

Hibernation now works: a 20 GiB swapfile on its own btrfs subvolume, verified by
a real S4 cycle on 2026-08-23 (same `boot_id`, uptime continued 527 s → 781 s).
See [`docs/system/hibernation.md`](../system/hibernation.md).

Two things S4 still does, both handled automatically now:

- it wedges part of the Samsung SCAI interface, so the keyboard backlight and
  `power_on_lid_open` break — a sleep hook reloads the driver on resume;
- it kills the fingerprint reader's SDCP session, so **the first touch after each
  resume fails**, then the driver reconnects and it works. That is expected
  behaviour, not a fault.

## Verification

`gb5-verify.sh`: **111 PASS, 0 FAIL** Everything that worked yesterday
still works. Camera relay active, fingerprint enrolment intact, Secure Boot on.
