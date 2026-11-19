# Documentation index

Topic notes for the Galaxy Book5 Pro H on Manjaro. The narrative is
[`../HISTORY.md`](../HISTORY.md); open work is [`../TASKS.md`](../TASKS.md);
agents start at [`../AGENTS.md`](../AGENTS.md).

## Hardware

| Note | What it covers |
|---|---|
| [hardware/setup-notes.md](hardware/setup-notes.md) | The non-stock pieces: DKMS camera, DKMS speakers, replaced libfprint, fingerprint and PAM. |
| [hardware/audit-results.md](hardware/audit-results.md) | Settled state of hotkeys, inputs, sensors, codecs, camera app paths. Do not re-investigate. |
| [hardware/camera-pipeline.md](hardware/camera-pipeline.md) | The relay chain, the 1-second stall behind it, and how to benchmark it honestly. |
| [hardware/npu-camera-effects.md](hardware/npu-camera-effects.md) | Background blur on the NPU, and the four upstream bugs fixed to get it running. |
| [hardware/wireless-and-6ghz.md](hardware/wireless-and-6ghz.md) | Why 6 GHz cannot be enabled here, traced to a BIOS ACPI variable. |

## Power and battery

| Note | What it covers |
|---|---|
| [power/battery-plan.md](power/battery-plan.md) | Where the watts actually go, measured. Start here for battery questions. |
| [power/power-and-tuning.md](power/power-and-tuning.md) | Which daemon owns which power knob, every measurement and its traps. Read before installing TLP. |

## System

| Note | What it covers |
|---|---|
| [system/secureboot-uki.md](system/secureboot-uki.md) | Why GRUB cannot work under Secure Boot here; UKI + systemd-boot and their footguns. |
| [system/hibernation.md](system/hibernation.md) | Why hibernation could not work, the 20 GiB btrfs swapfile that fixed it, and that it writes RAM to an unencrypted disk. |
| [system/encryption.md](system/encryption.md) | Disk encryption: the measured cost, the recommendation and the live-USB procedure. Decided, not executed. |
| [system/snapshots-and-rollback.md](system/snapshots-and-rollback.md) | What protects a rolling distro carrying three DKMS modules. |
| [system/docker.md](system/docker.md) | The `@docker` subvolume, the published-port hole against the VPN, pinned container DNS, recovering a module tree. |
| [system/netbird.md](system/netbird.md) | NetBird: not pacman-managed, the installer's root escalation, the GTK3 UI, the restart-after-kernel-update trap. |
| [system/pam.md](system/pam.md) | The PAM changes for fingerprint, and how to test a stack without locking yourself out. |

## About this repository

| Note | What it covers |
|---|---|
| [publishing.md](publishing.md) | Editing, previewing, checking and publishing the web page in `../site/`. |
| [not-included.md](not-included.md) | What is deliberately absent (secrets, separate projects) and why. |
| [archive/morning-summary-2026-08-22.md](archive/morning-summary-2026-08-22.md) | The overnight battery run in one page (historical; figures as of that day). |
