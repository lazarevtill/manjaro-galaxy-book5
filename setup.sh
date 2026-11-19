#!/bin/bash
# Galaxy Book5 Pro H on Arch/Manjaro — guided setup.
#
# Runs the steps in setup/ in order, checking the hardware matches first. Each
# step is idempotent, so re-running is safe and is the normal way to repair
# something after a kernel update.
#
#   sudo ./setup.sh            everything except Secure Boot, with a prompt each
#   sudo ./setup.sh --list     what the steps are
#   sudo ./setup.sh 10 30      just those steps
#
# Secure Boot is deliberately excluded from a full run: it needs BIOS steps that
# cannot be done from Linux, and it is the only part that can leave the machine
# unbootable. Run setup/50-secureboot.sh directly, after reading it.

set -uo pipefail
cd "$(dirname "$0")"
[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }

# 50-secureboot and 60-hibernate are deliberately NOT in the default run.
# Both change how the machine boots, and 60 additionally writes an unencrypted
# copy of your RAM to disk on every hibernate. Run them explicitly:
#     ./setup.sh 50-secureboot
#     ./setup.sh 60-hibernate
steps=(10-camera 20-speakers 30-fingerprint 40-system)

if [ "${1:-}" = "--list" ]; then
    echo "  00-precheck     is this the right machine?           (always runs)"
    echo "  10-camera       sensor driver, bridge, GPU pipeline"
    echo "  20-speakers     bind the three unenumerated amps"
    echo "  30-fingerprint  SDCP libfprint + three fixes + PAM"
    echo "  40-system       power, memory, wireless, snapshots"
    echo "  50-secureboot   custom keys + signed UKI   (run directly, reads first)"
    exit 0
fi

echo "── Precheck ─────────────────────────────────────────"
if ! bash setup/00-precheck.sh; then
    echo
    echo "Refusing to continue. Override only if you understand each warning:" >&2
    echo "  bash setup/10-camera.sh   # etc, individually" >&2
    exit 1
fi

if [ $# -gt 0 ]; then
    wanted=()
    for arg in "$@"; do
        for s in "${steps[@]}"; do [[ $s == $arg-* ]] && wanted+=("$s"); done
    done
    steps=("${wanted[@]}")
    [ ${#steps[@]} -gt 0 ] || { echo "no matching step; try --list" >&2; exit 1; }
fi

for s in "${steps[@]}"; do
    echo
    echo "── ${s#*-} ─────────────────────────────────────────"
    printf 'Run %s? [y/N/q] ' "$s"
    read -r a </dev/tty
    case "$a" in
        [Qq]) echo "Stopped."; exit 0 ;;
        [Yy]) bash "setup/$s.sh" || { echo "  $s FAILED — fix it before continuing" >&2; exit 1; } ;;
        *)    echo "  skipped" ;;
    esac
done

echo
echo "── Verify ───────────────────────────────────────────"
if [ -x /usr/local/sbin/gb5-verify.sh ]; then
    /usr/local/sbin/gb5-verify.sh | tail -4
else
    install -Dm755 gb5-verify.sh /usr/local/sbin/gb5-verify.sh
    /usr/local/sbin/gb5-verify.sh | tail -4
fi
echo
echo "A reboot is needed before the camera and speakers are fully up."
