# NPU camera effects — background blur and auto-framing

Samsung Galaxy Book5 Pro H, Intel Core Ultra 7 255H (Arrow Lake-H), Manjaro.
Set up 2026-08-21.

Windows gets background blur from Samsung's Studio Effects, which runs on the NPU.
The Linux equivalent is [linux-studio-effects](https://github.com/ericjchang/linux-studio-effects):
MODNet segmentation through OpenVINO on the NPU, composited onto the frame and
published as a virtual camera through v4l2loopback. Any app that takes a webcam —
Meet, Zoom, Teams, OBS — sees it as an ordinary camera.

Installed at `~/projects/linux-studio-effects`.

## Measured on this machine

| | |
|---|---|
| MODNet FP16, 1x3x256x256, on NPU | **11.3 ms/frame**, ~88 fps of headroom |
| NPU compile time | 0.6 s |
| Face detection (auto-framing) | CPU, the project puts it there deliberately |

The project's README quotes ~23 ms on NPU; Arrow Lake-H does it in half that. There is
plenty of margin for 30 fps with the CPU left alone, which is the whole reason to use the
NPU rather than the CPU or iGPU — it holds inference at a fraction of the power.

## The two things that do not work out of the box here

**`/dev/video10` is already taken.** The project's `setup-v4l2loopback.sh` pins its
virtual camera there. On this laptop the IPU6 claims about 48 nodes at probe time and
`/dev/video10` is `Intel IPU6 ISYS Capture 9`. Pinned to `/dev/video60` instead.

**There is already a v4l2loopback in use.** `v4l2-relayd` feeds the real camera into one,
so the module must be loaded with two devices, not one, or running the setup script
silently does nothing (it sees the module loaded and returns success while
`/dev/video10` never appears). `/etc/modprobe.d/v4l2-relayd.conf`:

    options v4l2loopback devices=2 exclusive_caps=1,1 video_nr=-1,60 \
            card_label="Integrated Camera,StudioEffects"

Note the quoting: modprobe takes one value per option, so both labels go inside a single
comma-separated string. Writing `card_label="A","B"` leaves a stray quote inside each
label — the devices appear as `Integrated Camera"` and `"StudioEffects`.

## Python on Arch

Python 3.14 has no wheels for several of the dependencies. Take them from the distro and
let the venv see them, then pip only what is missing:

    sudo pacman -S python-opencv python-psutil
    python3 -m venv --system-site-packages .venv
    .venv/bin/pip install pyvirtualcam

`openvino` and `python-openvino` are already installed system-wide (2026.3.0) and report
`['CPU', 'NPU']` from inside the venv.

## Models

Not shipped; fetched on first run, or manually into `src/models/weights/`:

- `modnet-fp16.onnx` (13 MB) — https://huggingface.co/Xenova/modnet, note the file must
  be renamed from `model_fp16.onnx` to `modnet-fp16.onnx`
- `face-detection-adas-0001.{xml,bin}` (2 MB) — OpenVINO Open Model Zoo

## Config

`config/default.toml`, changed from stock:

- `device_path = "/dev/video60"` (was `/dev/video10`)
- `width = 1920`, `height = 1088` — the relay loopback offers exactly one discrete size,
  and asking for 1280x720 leaves OpenCV negotiating a format the device does not have
- `[effects.background] enabled = true`

## Running

    ~/projects/linux-studio-effects/scripts/run.sh            # virtual camera
    ~/projects/linux-studio-effects/scripts/run.sh --preview  # local window
    ~/projects/linux-studio-effects/scripts/run.sh --gui      # tray + settings
    ~/projects/linux-studio-effects/scripts/run.sh --benchmark

Then pick **StudioEffects** as the camera in the meeting app. The unprocessed camera
stays available as **Integrated Camera**.

The first open of the relay device takes a couple of seconds because v4l2-relayd starts
the libcamera pipeline on demand; a client that gives up immediately reports the camera
as unavailable. Opening it once to warm it up first avoids that.

## Four upstream bugs fixed locally

Committed in the clone (`git log`), worth sending upstream:

1. **1 fps pipeline.** A V4L2 device hands out a small ring of buffers;
   v4l2loopback defaults to two. Reading in a tight loop costs ~25 ms per read,
   the true frame interval. Do ~30 ms of work between reads and the reads
   themselves start blocking -- measured 274 ms, then 977 ms, degrading run over
   run as the consumer falls behind. The producer was fine throughout (the
   bridge held 40 fps). Fixed by draining the camera in its own thread and
   letting the processing loop take the newest frame: **1.0 fps -> 30 fps**.
2. **`cv2.VideoCapture(index)` without a backend.** OpenCV 5 tries GStreamer
   first, which fails on a v4l2loopback device that already has a producer, and
   reports it as "camera busy/unavailable" -- sending you after a phantom
   conflict. `cv2.CAP_V4L2` opens it immediately.
3. **Setting a capture size the device does not offer.** It does not fail
   loudly: the device keeps its own format and every read stalls ~1 s, which
   reads as slow hardware rather than a rejected request.
4. **Full-resolution Gaussian blur.** 51 taps over 1920x1088x3 is ~12 ms, more
   than the NPU segmentation it accompanies. Blurring a quarter-size copy is
   visually identical -- the detail discarded is what the blur exists to
   destroy.

Measured after the fixes: 30 fps steady, 31 ms/frame of work, read 0 ms.

## Launcher

`Camera Effects` in the application menu
(`/usr/share/applications/studio-effects.desktop`).

## Prerequisites already satisfied here

- `intel_vpu` loaded, `/dev/accel/accel0` present
- user in `render` and `video` groups
