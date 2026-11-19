---
name: gb5-galaxybook5-hw-setup
description: Samsung Galaxy Book5 Pro H (965XHD, Arrow Lake-H) Linux hardware enablement — custom DKMS modules and replaced packages that stock Manjaro does not provide
metadata:
  type: project
---

The user's laptop `GB5` is a Samsung Galaxy Book5 Pro H (965XHD, Core Ultra 7 255H,
Arrow Lake-H) running Manjaro/KDE Wayland. Enabled on 2026-08-19; three pieces are
NOT stock and will break silently if replaced by a plain package update:

- **Camera**: custom DKMS `ov02e10-26mhz/1.0` in `/usr/src/ov02e10-26mhz-1.0`,
  derived from the v7.1.8 in-tree `ov02e10.c`. Two edits: accept the board's
  26 MHz clock (in-tree only allows 19.2 MHz), and force a 180-degree readout in
  `ov02e10_enable_streams()` while advertising `SRGGB10` instead of `SGRBG10`.
  The sensor shifts the Bayer phase on ONE axis when flipped — `SRGGB10` was
  determined empirically; `SGBRG10` (the naive derivation) renders red as green.
  Side effect of the un-retimed PLL: the sensor runs 26/19.2 = 1.354x fast, so
  ~40.6 fps instead of 30, and libcamera's AGC mis-meters slightly.
- **Fingerprint**: sensor is Egis/LighTuning `1c7a:05a5` (ETU906Axx-E). Stock
  libfprint does NOT support it. Replaced by AUR `libfprint-egismoc-sdcp-git`
  (TenSeventy7 fork). The AUR PKGBUILD's `provides` needed patching to
  `'libfprint-2.so=2-64'` or the install fails against fprintd's dependency.
  The PKGBUILD's `prepare()` also carries a LOCAL fix for a real upstream bug:
  `egismoc_close()` never cleared `self->task_ssm`, so any verify that timed out
  left it dangling and the next `egismoc_open()` hit
  `g_assert (self->task_ssm == NULL)`, killing fprintd with SIGABRT — meaning
  every fingerprint prompt that timed out took the daemon down. The patched
  build clears it on close and downgrades the open-time assert to a warning.
  Keep that `prepare()` block if the PKGBUILD is ever re-fetched from the AUR.
  A SECOND local fix in the same `prepare()` makes enrolments survive a reboot.
  SDCP sensors bind their templates to a host keypair; libfprint caches that
  keypair together with the derived session secrets in
  `/var/lib/fprint/<drv>/<id>/sdcp-claim`, but scopes the whole file to the
  kernel boot_id. On the next boot `fpi_sdcp_device_init_claim()` deletes it and
  takes the `generate_new:` path — `fpi_sdcp_set_host_keys (self, NULL, NULL)` —
  minting a fresh random EC keypair. The sensor sees an unfamiliar host, stops
  reporting the enrolment IDs, and fprintd prunes its own records:
  `Deleted stored finger N for user <u> as it is unknown to device.` The same
  happens after `claim_expiration_seconds` (86400) even without a reboot, and
  egismoc sets `supports_reconnect = FALSE` so SDCP Reconnect never runs.
  The patch splits the two things that file conflates: the session secrets are
  genuinely stale and get rederived, the keypair is a long-lived identity and is
  kept, and `is_connected` is left FALSE so a full SDCP Connect runs under the
  same `pk_h`. Verified by faking a previous boot_id in the claim: the device
  returned `enrollment ID 2: E7:01:63:2A:0D:7A:...` matching the host's stored
  print byte for byte. Note the host private key was ALREADY written to that
  file in the clear; this does not add anything to disk, but it does extend how
  long those bytes remain useful. Directory is 0700 root.
  Test harness: `gb5-test-sdcp-persistence.sh arm` / `... check`.
  CONFIRMED across a real reboot on 2026-08-21: the claim from the previous boot
  was reused, Connect succeeded, and the device returned the same enrolment ID.
  A THIRD local fix in `prepare()` stops a successful match being reported as a
  failure. `egismoc_identify_check_cb()` reports the result, libfprint then
  cancels whatever the driver still has in flight, the housekeeping command in
  `IDENTIFY_COMPLETE_SENSOR_RESET` dies with `G_IO_ERROR_CANCELLED`, and
  `egismoc_task_ssm_done()` passes that to `fpi_device_action_error()` — which
  discards the result already reported and never reaches `IDENTIFY_COMPLETE`
  where `fpi_device_verify_complete()` lives. The journal says it plainly:
  `report_verify_status: result verify-match` followed by
  `verify_cb: result verify-no-match`. The sensor recognises the finger and the
  login fails anyway. The patch records that a result was reported and treats a
  later cancellation as teardown rather than failure. The driver also must not sit
  in another USB round trip after reporting: fprintd cancels the operation the
  moment it sees the match, so the check callback now jumps straight to
  `IDENTIFY_COMPLETE` and skips the trailing `IDENTIFY_COMPLETE_SENSOR_RESET`
  (safe — every identify already begins with `IDENTIFY_SENSOR_RESET`).
  CONFIRMED 2026-08-21: `verify_cb: result verify-match`, after five consecutive
  `verify-no-match` results on the same finger before the fix.
  Working build tree: `/home/lazarevtill/.cache/gb5-build/fpaur`.
  Pinned via `IgnorePkg` in `/etc/pacman.conf`: the AUR `.SRCINFO` declares a
  placeholder `pkgver = 0`, and pacman's vercmp ranks numeric `0` above the real
  `r1831.<hash>`, so pamac shows a permanent phantom "update" to `0-1`. Accepting
  it would rebuild from the unmodified AUR PKGBUILD and silently drop both local
  fixes. To genuinely update: `git pull` in the build tree, re-apply the two
  PKGBUILD edits, `makepkg -f --nocheck`, then `pacman -U`.
- **Camera resolution**: `/etc/default/v4l2-relayd` sets what the bridge
  advertises. It was capped at 1280x720 while the sensor does 1920x1088, which is
  invisible locally but shows up as a soft picture in calls. Raised to full
  resolution 2026-08-21. PipeWire probes the loopback once and caches the result,
  so after changing this you MUST
  `systemctl --user restart pipewire wireplumber` or clients keep seeing the old
  size. Beware: that restart drops existing clients' audio connections — a
  browser that was running will lose its microphone until it is restarted.
- **Camera noise / sensor retiming** (2026-08-21): the real cause was light, not
  tuning. The mode's register list programs the PLL for the reference design's
  19.2 MHz MCLK; this board feeds 26 MHz, so SCLK came out at 36 MHz * 26/19.2 =
  48.75 MHz and the sensor ran 1.354x fast — 40.62 fps measured, for a mode named
  30fps. Exposure is set in lines, so a short frame means a short maximum
  exposure: 24.6 ms instead of 33.3 ms. Indoors the AGC ran out of exposure and
  made up the difference with gain, observed pinned at exposure 2242 with
  analogue gain 193 (= 12.1x, the register is 4.4 fixed point so 16 = 1x).
  Fixed in the DKMS source by adding blanking rather than re-deriving the PLL
  dividers: `vts_def` 2244 -> 3039 (= 2244 * 48.75/36). `vts_min` stays 2244 so
  the fast rate is still reachable by lowering vblank. Measured after:
  **30.01 fps exactly**, exposure max 2242 -> 3037, gain 193 -> 144 in the same
  room, and 23% less high-frequency energy in the frame. Want more light still?
  Raise `vts_def` further — every 1.354x costs proportional frame rate.
  Note the vblank control CANNOT be used as a runtime knob: the driver reapplies
  `vts_def` on every set_fmt, and libcamera caches the exposure range at
  configure() time, so a mid-stream change is ignored and then reset.
- **Camera lag in calls** (2026-08-21): `frei0r-filter-hqdn3d` in the relay
  pipeline was the cause. It had been added against the noise and measured as
  free — but that measurement was PNG-encode bound and therefore meaningless.
  In the real relay at 1920x1088 it collapses the pipeline: **6.1 fps, p90
  inter-frame gap 466 ms, worst 1041 ms**. Sub-second freezes, which is exactly
  what "the camera lags in Meet" looks like. Removing it: **30.0 fps over 120
  consecutive frames, gap median 33.3 ms, worst 37.7 ms**, still at full
  1920x1088. Resolution was never the problem — 1080p without the filter is
  solid; queues and `n-threads` do not rescue it, they just buffer the backlog.
  If noise needs attacking again, denoise AFTER a downscale, never at full
  resolution: 1280x720 with `hqdn3d spatial=0.06 temporal=0.15` holds 30 fps
  (worst gap 41 ms) and measures ~18% cleaner. Measure throughput with
  `fakesink`, never with an encoder in the chain.
- **Camera, final pipeline** (2026-08-21): all-GPU. VEBOX does the colour
  conversion and the noise reduction, nothing pixel-wise lands on the CPU.

      VIDEOSRC="libcamerasrc ! vapostproc ! video/x-raw(memory:VAMemory),format=NV12 ! vapostproc denoise=64 sharpen=0 disable-passthrough=true"

  Needs `gst-plugin-va` (VA-API driver iHD 26.2.4 already present). Two
  vapostproc stages deliberately: **VEBOX denoise is silently a no-op when the
  VPP input surface is RGB**, and libcamera's SoftISP hands us BGRx — measured
  flat at spatial 5.33-5.35 across denoise=0/16/32/48/64 before the NV12 stage
  was added. Never end VIDEOSRC with a capsfilter: `gst_parse_launch` rejects a
  description ending in caps, relayd then calls `gst_element_set_state()` on
  NULL and only the splash frame reaches the loopback.
  Measured: 300/300 frames, 30.00 fps, gap median 33.3, p99 34.9, max 39.1 ms,
  zero gaps over 100 ms; spatial noise ~10% below the CPU chain; relay CPU 20%
  of a core vs 24%. Better picture, fewer stalls, less power.
- **The 1033 ms stalls were GstBaseSink's one-second emergency clause.**
  v4l2-relayd runs two pipelines and copies buffers across carrying their
  original capture timestamps, but the output pipeline's only source is a live
  appsrc with min-latency 0, so it has no idea the input pipeline exists —
  every millisecond of capture is undeclared lateness against v4l2sink's ~38 ms
  budget (`max-lateness` 5 ms + one frame). Over budget, GstBaseSink drops every
  frame except the one per second it renders anyway ("if we did not receive
  anything valid for more than a second, render it anyway so the user sees
  something"); 1 s rounded to the next 33.3 ms frame = 1033 ms. relayd's bus
  watch handles only ERROR and STATE_CHANGED, so the warning is discarded and it
  fails silently. Adding `queue` makes it WORSE — more delay, so every frame
  takes the emergency path (1.4 fps = 1/1.033).
  Even the plain CPU chain sat 0-2 ms inside that budget and was caught falling
  off it in one paired run of three (11.85 fps, p99 1033.5 ms). Fixed for good
  with a drop-in adding `sync=false` to v4l2sink:
  `/etc/systemd/system/v4l2-relayd@.service.d/20-sync-false.conf`. That copy
  contains the stock ExecStart plus one flag — re-derive it from
  `systemctl cat v4l2-relayd@` if the package ever updates the unit.
- **Restarting the relay drops its node from PipeWire.** `wpctl status` then
  shows only the libcamera source and apps lose "Integrated Camera". Re-probe
  with `systemctl --user restart wireplumber` — wireplumber alone, NOT pipewire,
  which would drop every client's audio connection and cost a browser its
  microphone.
  CORRECTION to an earlier note here: the missing libcamera CameraSensorHelper
  for ov02e10 is NOT the cause. Reading `soft_simple.cpp` and `agc.cpp`, the AGC
  scales gain multiplicatively, and for a sensor whose gain is linear in the
  register code that is equivalent whether the helper is present or not; the one
  thing the helper would add, `blackLevel`, is already set by the tuning file.
- **Dual boot clock**: Windows writes LOCAL time to the RTC while Linux reads it
  as UTC, so every Windows -> Linux boot starts two hours off until NTP corrects
  it. This is not cosmetic: `journalctl --since` matches those future-stamped
  entries forever afterwards, which silently corrupts any log window you scope by
  time. Use `--after-cursor` when it matters. Fix on the Windows side with
  `dualboot-secureboot/windows-use-utc-clock.reg` (sets
  `HKLM\SYSTEM\CurrentControlSet\Control\TimeZoneInformation
  \RealTimeIsUniversal=1`), then `w32tm /resync /force`.
- **Speakers**: 4x MAX98390 amps; only 0x38 is ACPI-enumerated. DKMS
  `max98390-hda` + `max98390-hda-i2c-setup.service` create 0x39/0x3c/0x3d.
  From github.com/Andycodeman/samsung-galaxy-book-linux-fixes.

Secure Boot is now ENABLED, and the DKMS modules still load anyway: this kernel has
`CONFIG_LOCK_DOWN_KERNEL_FORCE_NONE=y`, no `CONFIG_LOCK_DOWN_IN_EFI_SECURE_BOOT`, and
`sig_enforce=N`, so module signatures are never enforced. No MOK enrollment needed.
See [[gb5-power-and-tuning]].

Secure Boot (19-20 Aug 2026) — now ENABLED; see [[gb5-secureboot-uki]]. How it was set up:
- sbctl keys created; grubx64.efi, bootx64.efi and the kernel are signed.
- CRITICAL: Manjaro's GRUB 2:2.14 embeds the `shim_lock` verifier and no shim is
  installed, so with Secure Boot ON GRUB would refuse the kernel with
  "prohibited by secure boot policy". Fixed by reinstalling GRUB with
  `--disable-shim-lock`. VERIFIED PROPERLY by parsing the PE `mods` section
  (grub_module_info64: magic u32, pad u32, offset u64, size u64; then
  {type u32, size u32} entries): module type 7 appears iff the flag is used.
  The installed grubx64.efi has type 7; the pre-fix backup does not.
  Upstream grub-core/kern/efi/sb.c `grub_shim_lock_verifier_setup()` returns
  EARLY when no shim protocol is found AND that marker is present, so neither
  the shim_lock verifier nor lockdown is ever registered — GRUB boots Linux
  normally under Secure Boot. `grub_lockdown()` is not called anywhere in sb.c.
  So NO UKI migration is needed; a subagent claimed otherwise but had analysed
  the pre-fix image. Note `strings`/filesize cannot detect this flag. Manjaro's own 98-install-grub.hook rebuilds
  WITHOUT that flag on every grub upgrade, so
  /etc/pacman.d/hooks/99-grub-disable-shim-lock.hook re-applies it (runs after
  98-install-grub, before zz-sbctl which re-signs).
- Enroll command is `sbctl enroll-keys -m -f` (-m keeps Microsoft certs for
  Windows' bootmgfw.efi and Option ROMs, -f keeps the firmware-builtin OEM db).
- Windows is BitLocker-encrypted: SUSPEND protection first with
  `manage-bde -protectors -disable C: -RebootCount 0`, never decrypt. Changing
  Secure Boot state alters PCR 7 and would otherwise force the recovery key.
  After enrollment, boot Windows from the firmware menu, NOT via GRUB chainload
  (chainloading changes PCR 7 too).
- The Samsung BIOS DOES expose key clearing, so Setup Mode was reachable and custom-key
  enrollment worked. Secure Boot has been enabled successfully.

Display (19 Aug 2026): HDR + wide colour gamut + adaptive sync + ALS
auto-brightness all enabled via kscreen-doctor. Enabling HDR made i915 turn on
DSC by itself, taking the panel from 8bpc to 10bpc (bpp=30) at 120 Hz — the
forced-DSC debugfs hack was NOT needed. NOTE: kscreen-doctor HANGS FOREVER
unless WAYLAND_DISPLAY is in its environment; always time-box it.

`sbctl enroll-keys -m -f` payload was dry-run validated on this machine with
`--export esl` (writes local files only): PK = sbctl key; KEK = sbctl + MS KEK
CA 2011 + MS KEK 2K CA 2023 + Samsung Mobile Experience NC KEK; db = sbctl +
MS UEFI CA 2011 + Windows Production PCA 2011 + Windows UEFI CA 2023 +
MS UEFI CA 2023 + MS Option ROM UEFI CA 2023 + Samsung Mobile Experience NC DB.
`-f` works because dbDefault/KEKDefault/PKDefault efivars exist on this firmware.

STATE AS OF 2026-08-19 03:35, reboot into BIOS firmware setup initiated:
Everything on the Linux side is DONE and verified — camera, speakers, fingerprint
(enrolled, right-index-finger, working at sddm/lockscreen/sudo/polkit), VA-API,
NPU/OpenCL, sleep (S0i2.2, 91%), display (HDR + WCG + VRR + auto-brightness, 10bpc
via automatic DSC), hotkeys, zram, thermald, adaptive power.

The ONLY thing outstanding is Secure Boot enrollment, which is blocked on two
human steps: (1) suspend BitLocker in Windows, (2) confirm the Samsung BIOS
exposes a clear-keys / Setup Mode option — unverifiable from Linux and a genuine
go/no-go. If it does not exist, custom-key enrollment is impossible on this
firmware and the fallback is a shim-based approach.

Local record kept at /root/gb5-enablement/ (README, the HTML write-up, the memory
notes, and gb5-verify.sh). Published page:
https://claude.ai/code/artifact/8323b4cd-a91b-47b4-b0df-31f2558a3a7e

On the next boot, gb5-verify-boot.service runs ~45 s into the graphical session,
writes /var/log/gb5-verify.log, then disables itself. Two checks that FAILED
pre-reboot ("clock still rejected", "fprintd coredumps this boot") were true only
of the pre-fix boot and should PASS in that log; if they do not, something
regressed.

2026-08-19 later: the AUR phantom-update was fixed properly instead of hidden — the
PKGBUILD now carries `epoch=1`, so `1:r1831.<hash>` outranks the AUR's placeholder `0-1`
unconditionally and pamac stops reporting an upgrade. The `IgnorePkg` line in
/etc/pacman.conf was removed as redundant. Keep `epoch=1` on any rebuild.

Fingerprint enrolment did NOT survive a reboot: fprintd logged "Deleted stored finger 7
for user lazarevtill as it is unknown to device". The SDCP claim cache is keyed to the
kernel boot id (documented, by design) and a new connection calls
`fpi_sdcp_set_host_keys(self, NULL, NULL)` -> fresh random host keypair. RESOLVED 2026-08-20: enrolment
DOES survive a reboot — both fingers were still enrolled after a clean UKI boot. The
earlier loss was caused by the BIOS Secure Boot key changes resetting the sensor, not by
the SDCP driver design. So only expect to re-enrol after BIOS/Secure Boot work.

A GUI now exists: `/usr/local/bin/fingerprint-manager` (PySide6), launcher
"Fingerprint" in the app menu. Live enroll/verify go through QProcess over the
fprintd-* CLI tools; list/delete use synchronous dbus-python. That split is deliberate —
PySide6's QtDBus returns QDBusArgument for complex types and mixing a GLib main loop with
Qt's is worse. See [[gb5-secureboot-uki]].

The fingerprint GUI is now a proper package, not a loose script:
`~/projects/fingerprint-manager` (git, GPL-3.0-or-later), app id
`cloud.lazarev.FingerprintManager`, homepage https://lazarev.cloud. Ships binary,
desktop entry, AppStream metainfo, scalable + symbolic icons; `make check` runs
py_compile + desktop-file-validate + appstreamcli. Build with `makepkg -si` from
`packaging/arch/` (the PKGBUILD builds from the tree two levels up, so makepkg's own
src/ does not collide with the app's src/). Installed as pacman package
`fingerprint-manager`. NOTE: Qt only populates icon theme search paths when a platform
theme plugin does it, so the app adds the XDG data dirs itself and falls back to loading
the installed SVG by path — `QIcon.fromTheme` alone returns null.

GOTCHA (cost a false bug report): `fprintd-verify` with no `-f` silently selects the
FIRST enrolled finger, not "any". With two fingers saved, only that one ever matched and
every other finger looked broken. pam_fprintd verifies against "any", so real
login/sudo/lock-screen accepted BOTH fingers the whole time — proved by a sudo PAM auth
returning Success with a deliberately wrong password while touching the "failing" finger.
fingerprint-manager 1.0.1 passes `-f any` and also offers a per-finger Test button.

