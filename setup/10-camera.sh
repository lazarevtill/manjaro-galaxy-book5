#!/bin/bash
# Camera: patched sensor driver, a /dev/video bridge, and an all-GPU pipeline.
#
# Four separate problems, each of which alone leaves you with a dead camera:
#
#   1. The sensor refuses to probe. The in-tree ov02e10 driver only accepts a
#      19.2 MHz clock; this board feeds it 26 MHz.
#   2. The image is upside down and the colours are wrong. The module is mounted
#      inverted, but ACPI reports rotation 0, so libcamera never asks for the
#      flip — and the sensor shifts its Bayer phase on one axis when flipped.
#   3. Applications see ~48 raw Bayer nodes and no usable camera, because only
#      libcamera can debayer that data.
#   4. Left at the stock frame timing the sensor runs 1.354x fast, which costs a
#      third of the maximum exposure and shows up as noise.
#
# Idempotent: safe to re-run.

set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
HERE=$(cd "$(dirname "$0")/.." && pwd)

echo "==> Packages"
pacman -S --needed --noconfirm dkms v4l2loopback-dkms v4l2-relayd libcamera \
    gst-plugin-va gst-plugins-good gst-plugins-bad pipewire-libcamera >/dev/null
echo "    ok"

echo "==> Sensor driver (DKMS ov02e10-26mhz)"
# Bundled rather than patched on the fly: the Bayer order was found empirically
# by testing all four and matching channel means against a known-good capture,
# and the frame timing is derived from this board's clock. Re-deriving either
# from a description is a much worse experience than shipping the source.
if [ "$(dkms status ov02e10-26mhz 2>/dev/null | grep -c installed)" -gt 0 ]; then
    echo "    already installed"
else
    rm -rf /usr/src/ov02e10-26mhz-1.0
    cp -r "$HERE/dkms/ov02e10-26mhz" /usr/src/ov02e10-26mhz-1.0
    dkms add    ov02e10-26mhz/1.0 >/dev/null 2>&1 || true
    dkms build  ov02e10-26mhz/1.0
    dkms install ov02e10-26mhz/1.0 --force
    echo "    built and installed"
fi

echo "==> Hide the raw IPU6 nodes from application enumeration"
# Clearing ID_V4L_CAPABILITIES stops anything that asks udev from offering the
# ~48 unusable Bayer nodes. libcamera is unaffected: it walks the media graph.
# Browsers ignore this and need the PipeWire route below instead.
install -Dm644 "$HERE/config/system/99-ipu6-hide-raw-nodes.rules" \
    /etc/udev/rules.d/99-ipu6-hide-raw-nodes.rules
udevadm control --reload && udevadm trigger --subsystem-match=video4linux
echo "    ok"

echo "==> v4l2loopback: two devices"
# One for the camera bridge, one for the NPU effects app if it gets installed.
# Both labels go in a single comma-separated string: modprobe takes one value
# per option, and card_label="A","B" leaves a stray quote inside each label.
install -Dm644 "$HERE/config/camera/modprobe-v4l2loopback.conf" /etc/modprobe.d/v4l2-relayd.conf
if [ "$(lsmod | grep -c '^v4l2loopback')" -gt 0 ]; then
    echo "    module already loaded — reload it or reboot to pick up the new options"
else
    modprobe v4l2loopback && echo "    loaded"
fi

echo "==> Relay pipeline"
install -Dm644 "$HERE/config/camera/v4l2-relayd.env" /etc/default/v4l2-relayd
install -Dm644 "$HERE/config/camera/10-dmabuf.conf" \
    /etc/systemd/system/v4l2-relayd@.service.d/10-dmabuf.conf
# sync=false on the sink. Without it the output pipeline drops every frame that
# misses a deadline it was never told about, and renders one per second instead
# — a camera that freezes for ~1s at a time. The drop-in is a copy of the stock
# ExecStart plus that one flag, so re-derive it if the package updates its unit.
install -Dm644 "$HERE/config/camera/20-sync-false.conf" \
    /etc/systemd/system/v4l2-relayd@.service.d/20-sync-false.conf
systemctl daemon-reload
systemctl restart v4l2-relayd || true
echo "    ok"

echo "==> Browser camera enumeration"
# Chromium and Firefox open /dev/video* directly and ignore the udev hint, so
# they list 49 "cameras" of which 47 produce nothing. PipeWire shows only the
# real ones.
U=${SUDO_USER:-}
if [ -n "$U" ]; then
    home=$(getent passwd "$U" | cut -d: -f6)
    f="$home/.config/brave-flags.conf"
    if [ -d "$home/.config" ] && ! grep -qs WebRtcPipeWireCamera "$f"; then
        echo "--enable-features=WebRtcPipeWireCamera" >> "$f"
        chown "$U:$U" "$f"
        echo "    Brave: PipeWire camera enabled (restart it)"
    fi
    echo "    Firefox: set media.webrtc.camera.allow-pipewire = true in about:config"
fi

echo
echo "Done. Verify with:"
echo "  cam -l                                   # libcamera sees the sensor"
echo "  v4l2-ctl -d /dev/videoN --list-formats-ext   # N = the 'Integrated Camera' loopback"
echo
echo "The loopback's number moves between boots — find it by card name, never hardcode it."
