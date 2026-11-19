---
name: gb5-hardware-audit-results
description: "Verified state of every remaining subsystem on the user's Galaxy Book5 laptop — what works, what does not exist in hardware, so none of it gets re-investigated"
metadata: 
  node_type: memory
  type: project
  originSessionId: 5f6b4d36-2b3c-40e8-8285-72954661d9dd
  modified: 2026-08-19T01:30:27.169Z
---

Audit of `GB5` (Samsung Galaxy Book5 Pro H / 965XHD) on 2026-08-19, verified against
live command output rather than assumed. See [[gb5-galaxybook5-hw-setup]] and
[[gb5-power-and-tuning]]. Treat these as settled — do not re-investigate:

**Working, evidence-backed**
- **Fn/hotkeys**: all functional. systemd hwdb Galaxy Book rules match this SKU
  (`skuSCAI-PROT-A5A5-ARLH-PRHH`); no `atkbd: Unknown key` in any journal. Verified
  end-to-end by injecting keycodes through a temporary uinput device and watching
  sysfs move: brightness, volume, mute, mic-mute, touchpad toggle, kbd backlight.
  Keyboard backlight is handled entirely inside `samsung-galaxybook` and emits no
  keycode, so KDE shows no OSD for it — that is expected, not a bug.

  **Correction (2026-08-22): "watching sysfs move" does not verify this one.** The
  LED class caches the written value and echoes it back from `brightness`
  regardless of whether the firmware accepted the command. On 2026-08-22 the
  hardware write was failing with `-ENXIO` while sysfs still read back every value
  written. If you need to verify the keyboard backlight, check `dmesg` for
  `failed to execute CSFI` — or look at the keys.
- **Touchscreen** `GXTP7936:00 27C6:0123` on hid-multitouch, `INPUT_PROP_DIRECT`,
  343x214 mm vs the panel's 344x215 mm, identity calibration — correct under Wayland.
- **Microphone**: SOF `sof-hda-generic-2ch.tplg`. The beamformer is ALREADY on
  (`Dmic0 Capture TDFB beam switch: on`, angle index 6 = 0 degrees) plus DRC and
  IIR EQ. Nothing to tune.
- **Bluetooth codecs**: complete — AAC, aptX/HD/LL, LDAC, LC3/LE-Audio, mSBC,
  SBC-XQ, all with backing libraries resolved. Only aptX Adaptive is missing and it
  has no Linux implementation. `bluez-utils` had to be installed (bluez was there
  without `bluetoothctl`).
- **Thunderbolt/USB4**: `iommu+user` security with `iommu_dma_protection=1`, boltd
  running with default prompt-on-connect, `kded_bolt` loaded. Correct posture —
  do not relax it. Untested without a dock.
- **Ambient light sensor**: `iio:device0 name=als` via iio-sensor-proxy; KDE
  auto-brightness now enabled.

**Does NOT exist in hardware — stop looking for it**
- **No accelerometer.** Clamshell chassis; `HasAccelerometer = false`, KWin reports
  `Auto Rotate Policy: incapable`. Auto-rotate is not misconfigured, it is N/A.
- **No stylus/pen.** The 693-byte HID report descriptor contains only Digitizer/Touch
  Screen usage plus three vendor pages — no Pen usage. The two `... UNKNOWN` input
  nodes (event9/event10) are those vendor collections and are harmless.

**Known-benign noise, do not chase**
- `acpi SAM0430:00: failed to execute CSFI ... 0xff` — the driver's `block_recording`
  firmware attribute, unimplemented in this BIOS. Camera-cover and mic-mute use a
  different, working ACPI notify path.
- ACPI `_FST` fan-status and `SEN3.CTYP` errors — firmware bugs; the EC still runs
  the fans, only the reporting path is broken.
- `auxiliary intel_ipu6.psys: Failed to get runtime PM` on resume — the IPU
  processing-system block, which this camera pipeline does not use.
- `ZNT0001:00 ... kernel bug: Touch jump detected and discarded` — libinput already
  discards the bad samples.
- `xe` module loads but binds nothing; i915 owns the GPU. Harmless.

**Verification tooling**: `/usr/local/sbin/gb5-verify.sh` runs ~48 checks across all
of the above and prints PASS/FAIL/NOTE. `gb5-verify-boot.service` runs it once
45 s after the next `graphical.target`, writes `/var/log/gb5-verify.log`, then
disables itself.

**Camera: which apps work (2026-08-20).** The IPU6 exposes ~48 raw Bayer nodes; only
libcamera can debayer them. Three consumer paths, verified:
- **PipeWire** (GNOME `snapshot`, Firefox, Chromium) — WORKS. Best default.
- **libcamerasrc in GStreamer** — WORKS (1008 frames captured, well exposed).
- **/dev/video48 "Integrated Camera"** — a v4l2loopback fed on demand by `v4l2-relayd`,
  for apps that open a device path directly (Zoom, OBS, Discord). WORKS.
- `pantheon-camera` (io.elementary.camera) HANGS — it enumerates via GStreamer's device
  monitor, which offers only the libcamera device, and it cannot handle it. Not worth
  chasing; use `snapshot`.

Two non-obvious things about the relay setup:
1. The shipped `v4l2-relayd@.service` sets a `DeviceAllow` whitelist. Once DeviceAllow is
   set, everything absent is denied, and `/dev/dma_heap/system` is absent — so libcamera
   logs "Could not open any dma-buf provider", disables software debayering and emits a
   flat grey frame. Drop-in at
   `/etc/systemd/system/v4l2-relayd@.service.d/10-dmabuf.conf` grants it.
2. libcamera outputs 1928x1088 while the relay's caps ask 1280x720, and the stock output
   pipeline has videoconvert but NO scaler, so negotiation fails silently. Fixed by making
   VIDEOSRC in `/etc/default/v4l2-relayd`.

SUPERSEDED 2026-08-21: that VIDEOSRC is now an all-GPU chain and the bridge runs at the
sensor's full 1920x1088, not 1280x720:

    VIDEOSRC="libcamerasrc ! vapostproc ! video/x-raw(memory:VAMemory),format=NV12 ! vapostproc denoise=64 sharpen=0 disable-passthrough=true"

Needs `gst-plugin-va`. Two vapostproc stages because VEBOX denoise is a silent no-op on an
RGB input surface and libcamera hands out BGRx. Measured 30.00 fps over 300 frames, gap p99
34.9 ms, worst 39.1 ms, at 20% of a core. A CPU filter here instead freezes the camera for
~1033 ms at a time — see [[gb5-galaxybook5-hw-setup]] for why. The sensor was also retimed
for the board's 26 MHz clock, so it now runs a true 30 fps rather than 40.6 with a
correspondingly short maximum exposure.

Browsers do not respect the udev rule that hides the raw nodes — they open device nodes
directly and list 49 "cameras". Route them through PipeWire instead:
`media.webrtc.camera.allow-pipewire` (Firefox), `--enable-features=WebRtcPipeWireCamera`
(Chromium/Brave).
Instances come from `/etc/v4l2-relayd.d/*.conf` (a systemd generator), and FRAMERATE must
be `30/1` — it is interpolated straight into GStreamer caps.

GStreamer's v4l2 device monitor never enumerates the loopback (verified: not caused by the
udev rule hiding raw nodes — it finds 0 v4l2 devices either way). Apps that take an explicit
device path still work fine with it.

**Microphone verified 2026-08-20:** 5 s capture off `hw:0,6`, RMS -33.3 dBFS, peak -18.6 dBFS.
Beamformer and DRC both on. Note `audioop` was removed in Python 3.14 — compute RMS manually.

Do NOT hardcode /dev/videoN anywhere: the v4l2loopback bridge takes whatever number is free
at probe time — it was video48 on one boot and video0 on the next. gb5-verify.sh now finds
it by card name ("Integrated Camera"). Suite is 62 checks as of 2026-08-20.

