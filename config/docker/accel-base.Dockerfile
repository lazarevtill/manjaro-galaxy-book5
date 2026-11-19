# iGPU + NPU base, tracking the host's own Arch packages.
#
# Distro images lag badly on this silicon. Ubuntu 24.04's media driver does not
# know PCI 8086:7D51 and libva fails with "unknown libva error" -- which reads
# like a permissions problem and is not. The NPU is stricter still: its
# user-mode driver in the container must not be much older than the host's
# intel_vpu kernel driver. Pulling the same Arch packages the host runs makes
# both match by construction (iHD 26.2.4, intel-npu-driver 1.35.0).
#
# The GPU and NPU OpenVINO plugins are SEPARATE Arch packages. Install only
# "openvino" and Core().available_devices returns just ["CPU"] -- no error, no
# warning. Same trap that bit the NPU camera work.
FROM archlinux:base
RUN pacman -Syu --noconfirm --needed \
      intel-media-driver libva-utils ffmpeg \
      intel-compute-runtime intel-npu-driver \
      openvino openvino-intel-gpu-plugin openvino-intel-npu-plugin python-openvino \
 && pacman -Scc --noconfirm >/dev/null
ENV LIBVA_DRIVER_NAME=iHD
