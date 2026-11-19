#!/bin/bash
# Simulate a reboot for the SDCP claim, without rebooting.
#
# Enrollments on this sensor are bound to the host keypair in
# /var/lib/fprint/<driver>/<id>/sdcp-claim. Stock libfprint scopes that claim to
# the kernel boot_id and mints a fresh keypair on the next boot, which makes the
# device disown every template. The local build keeps the keypair and only
# rederives the session secrets.
#
# This rewrites the boot_id inside the claim to a bogus value and restarts
# fprintd, putting the daemon in exactly the state it is in after a real reboot.
#
# A finger touch is REQUIRED to prove anything. fprintd only queries the device
# when it performs a match, and only prunes its own records after a match fails
# ("failed to match during action, verifying local storage" -> "Deleted stored
# finger N ... as it is unknown to device"). Reading fprintd-list on its own
# reports the host-side record and will happily show fingers the sensor has
# already forgotten.
#
# Usage:
#   gb5-test-sdcp-persistence.sh arm      # fake a previous boot, restart fprintd
#   <touch the sensor: Test in the Fingerprint app, or lock and unlock>
#   gb5-test-sdcp-persistence.sh check    # read the verdict

set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }

MODE=${1:-arm}
USER_NAME=${2:-lazarevtill}
CLAIM=$(find /var/lib/fprint -name sdcp-claim -print -quit)
STATE=/run/gb5-sdcp-test

count_fingers() {
    sudo -u "$USER_NAME" fprintd-list "$USER_NAME" 2>/dev/null |
        grep -cE '^ *- #[0-9]+:' || true
}

claim_boot_id() { strings "$CLAIM" | grep -m1 -E '^[0-9a-f]{8}-[0-9a-f]{4}-'; }

case "$MODE" in
arm)
    [ -n "$CLAIM" ] || { echo "no sdcp-claim file — enroll a finger first" >&2; exit 1; }
    before=$(count_fingers)
    [ "$before" -gt 0 ] || { echo "no fingers enrolled for $USER_NAME" >&2; exit 1; }

    # Timestamp filters are unreliable here: booting from Windows leaves the RTC
    # on local time, so the first seconds of each journal are stamped in the
    # future and --since matches them forever. Use a cursor.
    journalctl -u fprintd -n1 -o json --no-pager |
        python3 -c 'import sys,json; print(json.load(sys.stdin)["__CURSOR"])' > "$STATE.cursor"
    echo "$before" > "$STATE.before"

    # The boot_id is the last field of the serialised GVariant: a NUL-terminated
    # UUID string. Swap one hex digit so it can never match the running boot.
    python3 - "$CLAIM" <<'PY'
import re, sys
p = sys.argv[1]
d = bytearray(open(p, 'rb').read())
m = list(re.finditer(rb'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}', bytes(d)))
assert m, "no boot_id UUID found in claim file"
s = m[-1].start()
d[s] = ord('f') if d[s] != ord('f') else ord('0')
open(p, 'wb').write(d)
PY
    systemctl restart fprintd
    echo "armed: claim now reads as boot $(claim_boot_id), $before finger(s) enrolled"
    echo
    echo "Now touch the sensor — Test in the Fingerprint app, or lock and unlock."
    echo "Then run: gb5-test-sdcp-persistence.sh check"
    ;;

check)
    [ -f "$STATE.cursor" ] || { echo "nothing armed — run 'arm' first" >&2; exit 1; }
    before=$(cat "$STATE.before")
    after=$(count_fingers)
    log=$(journalctl -u fprintd --no-pager --after-cursor "$(cat "$STATE.cursor")")

    echo "fingers before: $before    after: $after"

    if ! grep -qE "match|identif|verif|Deleted stored" <<<"$log"; then
        echo "INCONCLUSIVE — no match attempt in the log; the sensor was never touched" >&2
        exit 2
    fi

    # A successful match rewrites the claim with the running boot_id, because
    # a fresh Connect happened and was cached.
    if [ "$(claim_boot_id)" = "$(cat /proc/sys/kernel/random/boot_id)" ]; then
        reconnected="yes"
    else
        reconnected="no"
    fi
    echo "reconnected and re-cached the claim: $reconnected"

    if grep -qi "unknown to device" <<<"$log"; then
        echo "FAIL — the device disowned the templates across a host re-pair" >&2
        grep -i "unknown to device" <<<"$log" >&2
        exit 1
    fi
    if [ "$after" -ne "$before" ]; then
        echo "FAIL — finger count changed from $before to $after" >&2
        exit 1
    fi
    echo "PASS — enrollments survived a simulated reboot"
    rm -f "$STATE.cursor" "$STATE.before"
    ;;

*) echo "usage: $0 {arm|check} [username]" >&2; exit 1 ;;
esac
