---
name: gb5-camera-pipeline
description: "The Galaxy Book5 camera relay pipeline — all-GPU vapostproc chain, the GstBaseSink one-second clause that freezes it, and how to benchmark it without lying to yourself"
metadata: 
  node_type: memory
  type: project
  originSessionId: 5f6b4d36-2b3c-40e8-8285-72954661d9dd
  modified: 2026-08-21T18:51:39.870Z
---

The camera on the user's Galaxy Book5 (`GB5`) reaches applications through
`v4l2-relayd`, which bridges libcamera into a v4l2loopback device. Settled
2026-08-21 after three wrong turns; the reasoning matters more than the config.

## The working configuration

`/etc/default/v4l2-relayd`:

    VIDEOSRC="libcamerasrc ! vapostproc ! video/x-raw(memory:VAMemory),format=NV12 ! vapostproc denoise=64 sharpen=0 disable-passthrough=true"
    FORMAT=YUY2 ; WIDTH=1920 ; HEIGHT=1088 ; FRAMERATE=30/1

Requires `gst-plugin-va`. Measured 30.00 fps over 300 frames, gap median 33.3 ms,
p99 34.9 ms, worst 39.1 ms, zero gaps over 100 ms, 20% of a core.

Plus `/etc/systemd/system/v4l2-relayd@.service.d/20-sync-false.conf`, a copy of
the stock `ExecStart` with `sync=false` added to `v4l2sink`. **Re-derive that copy
from `systemctl cat v4l2-relayd@` if the package ever updates its unit.**

## Three things that are counter-intuitive

**VEBOX denoise is a silent no-op on an RGB input surface.** libcamera's SoftISP
outputs BGRx, so `libcamerasrc ! vapostproc denoise=64` does nothing at all —
spatial noise measured flat at 5.33-5.35 across denoise=0/16/32/48/64. Hence the
first `vapostproc` stage converting to NV12. It also moves colour conversion and
scaling to the GPU, so the all-GPU chain is *cheaper* than the CPU one it replaced.

**A CPU filter freezes the camera for ~1033 ms at a time, and it is not a
throughput problem.** `v4l2-relayd` runs two pipelines and copies buffers across
carrying their original capture timestamps, but the output pipeline's only source
is a live `appsrc` with `min-latency 0` — so it has no idea the input pipeline
exists, and every millisecond of capture is undeclared lateness against
`v4l2sink`'s ~38 ms budget. Over budget, `GstBaseSink` drops every frame except
the one per second its emergency clause renders anyway; 1 s rounded to the next
33.3 ms frame is 1033 ms. relayd's bus watch handles only `ERROR` and
`STATE_CHANGED`, so the warning is discarded and it fails silently. Adding a
`queue` makes it *worse* (1.4 fps = 1/1.033) because more delay means every frame
takes the emergency path.

**Never end `VIDEOSRC` with a capsfilter.** `gst_parse_launch` rejects a
description ending in caps; relayd then calls `gst_element_set_state()` on NULL
and only the splash frame reaches the loopback.

## How to benchmark it without lying to yourself

Two measurements sent this work in the wrong direction:

- A `pngenc` in the chain made a filter look free. **No encoder in a throughput
  benchmark, ever.**
- `fakesink sync=false` with unconstrained caps let the trailing `videoconvert`
  negotiate passthrough — it converted nothing — *and* removed the late-frame
  dropping that is the actual failure mode. Pin the caps to the relay's and keep
  `sync=true` to emulate it.

Judge by the **inter-frame gap distribution as delivered through the loopback**,
not average fps: the failure is a p99 of 1033 ms behind a median of 33 ms.

## Related

Sensor retiming (`vts_def` 2244 -> 3039) and the noise/gain analysis are in
[[gb5-galaxybook5-hw-setup]]. The NPU blur app that consumes this bridge is in
[[gb5-npu-camera-effects]]. Power behaviour in [[gb5-power-and-tuning]].
