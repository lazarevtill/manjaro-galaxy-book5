#!/bin/bash
# gb5-boot-guard — keep the boot chain in the state the record says it is in,
# whatever path the update came through (gb5-safe-update, a manual pacman -Syu,
# pamac). Idempotent: on a healthy ESP it changes nothing and prints nothing.
#
#   gb5-boot-guard.sh --check   report what would be repaired, change NOTHING
#                               (exit 1 if anything would be). gb5-verify.sh
#                               uses this mode only -- a verifier that repairs
#                               shows a fault once and then erases the evidence.
#   gb5-boot-guard.sh --hook    repair; called by zzz-gb5-boot-guard.hook, i.e.
#                               AFTER zz-sbctl, inside pacman's transaction.
#   gb5-boot-guard.sh           repair, standalone. Refuses while a pacman
#                               transaction holds db.lck: mid-transaction the main
#                               UKI can be half-written, and copying it into the
#                               fallback and signing it would bless a broken image.
#
# Added 2026-11-19 (HISTORY Phase 8) after the first unattended kernel-series
# bump (7.1 -> 7.2) left three faults that every per-package check missed:
#   1. Manjaro's 98-install-grub.hook (grub 2.16) copied a shim_lock GRUB over
#      the removable fallback \EFI\BOOT\BOOTX64.EFI -- the firmware's last resort
#      after an NVRAM reset, and with Secure Boot on that GRUB refuses the kernel.
#   2. The fallback UKI still carried 7.1.13, whose module tree was deleted.
#   3. sbctl tracked two deleted 7.1 paths and none of the three live UKIs.
# Reviewed adversarially by Fable the same day; its findings are in Phase 8.
set -uo pipefail

MODE=repair
case "${1:-}" in
    --check) MODE=check ;;
    --hook)  MODE=hook ;;
    "")      MODE=repair ;;
    *) echo "usage: $0 [--check|--hook]" >&2; exit 2 ;;
esac

ESP=/boot/efi
UKI_DIR="$ESP/EFI/Linux"
SDBOOT="$ESP/EFI/systemd/systemd-bootx64.efi"
DBCERT=/var/lib/sbctl/keys/db/db.pem
SBDB=/var/lib/sbctl/files.json
STATE=/var/lib/gb5
rc=0
log()  { echo "gb5-boot-guard: $*"; }
fail() { echo "gb5-boot-guard: ERROR $*" >&2; rc=1; }
# In check mode every repair is reported instead of performed.
would() { echo "gb5-boot-guard: NEEDS REPAIR $*"; rc=1; }
fixing() { [ "$MODE" != check ]; }

for t in sbverify sbctl jq objcopy sha256sum; do
    command -v "$t" >/dev/null 2>&1 || { fail "required tool '$t' missing — cannot judge signatures, changing nothing"; exit 1; }
done
[ -r "$DBCERT" ] || { fail "cannot read $DBCERT (run as root)"; exit 1; }
# An unmounted ESP makes every ESP path look deleted, and step 4 would then
# drop them all from sbctl's database -- after which nothing re-signs GRUB or
# systemd-boot again. Refuse outright (Fable, second review).
mountpoint -q "$ESP" || { fail "$ESP is not mounted — changing nothing"; exit 1; }
if [ "$MODE" = repair ] && [ -e /var/lib/pacman/db.lck ]; then
    fail "a pacman transaction is running (db.lck) — not repairing now; the hook will run at its end"
    exit 1
fi

# Signed by OUR db key: sbverify checks the actual signature, not sbctl's
# database, which is exactly what drifted last time.
signed() { sbverify --cert "$DBCERT" "$1" >/dev/null 2>&1; }
# Kernel release embedded in a UKI (systemd-stub .uname section).
uki_kver() { objcopy -O binary --only-section=.uname "$1" /dev/stdout 2>/dev/null | tr -d '\0'; }
# sbctl's own database. `list-files --json` silently omits entries whose file is
# gone, so it can never show the dead ones this guard exists to drop.
db_paths() { jq -r 'keys[]' "$SBDB" 2>/dev/null; }
db_out()   { jq -r --arg p "$1" '.[$p].output_file // empty' "$SBDB" 2>/dev/null; }
tracked()  { [ "$(db_paths | grep -cxF "$1")" -gt 0 ]; }
db_set() {  # $1 = jq filter, rest = jq args. Temp file + rename, never in place.
    local f=$1; shift
    jq "$@" "$f" "$SBDB" > "$SBDB.gb5new" && [ -s "$SBDB.gb5new" ] \
        && mv -f "$SBDB.gb5new" "$SBDB" || { rm -f "$SBDB.gb5new"; return 1; }
}

# ── 1. systemd-boot itself ───────────────────────────────────────────────────
# bootctl prefers a pre-signed .efi.signed next to the package's binary, so
# `bootctl update` installs an already-signed loader: no window in which the
# boot menu is unsigned. Freshness is judged by a recorded sha256 of the source
# the .signed was made from -- NOT by mtime: pacman restores the package's
# mtime, so a newly installed systemd can carry an OLDER date than the .signed
# (the first draft used -nt and would have frozen systemd-boot forever).
SRC=/usr/lib/systemd/boot/efi/systemd-bootx64.efi
SRCSUM="$STATE/systemd-boot.src.sha256"
if [ -f "$SRC" ]; then
    cur=$(sha256sum "$SRC" | cut -d' ' -f1)
    if [ ! -f "$SRC.signed" ] || ! signed "$SRC.signed" || [ "$(cat "$SRCSUM" 2>/dev/null)" != "$cur" ]; then
        if fixing; then
            mkdir -p "$STATE"
            if sbctl sign -s -o "$SRC.signed" "$SRC" >/dev/null 2>&1 && signed "$SRC.signed"; then
                echo "$cur" > "$SRCSUM"; log "pre-signed $SRC.signed"
            else fail "could not pre-sign $SRC"; fi
        else would "pre-signed systemd-boot is missing, unsigned or older than the package"; fi
    fi
    if fixing && [ -f "$SRC.signed" ] && signed "$SRC.signed"; then
        # --variables=no: never touch NVRAM / BootOrder. --graceful: never fail
        # the transaction over the ESP. It copies only when the version is newer.
        out=$(bootctl update --graceful --variables=no 2>&1) || true
        case "$out" in *Copied*) log "systemd-boot updated: $(printf '%s' "$out" | tr '\n' ' ')";; esac
    fi
fi
signed "$SDBOOT" || fail "$SDBOOT is not signed by our key — the boot menu will not start under Secure Boot (removable path left as found)"

# ── 2. the removable fallback is the boot menu, never GRUB ───────────────────
# vfat is case-insensitive; find the removable path whatever its spelling.
REMOVABLE=$(find "$ESP/EFI" -maxdepth 2 -ipath "$ESP/EFI/boot/bootx64.efi" 2>/dev/null | head -1)
if [ -f "$SDBOOT" ] && signed "$SDBOOT"; then
    if [ -z "$REMOVABLE" ]; then
        if fixing; then
            REMOVABLE="$ESP/EFI/BOOT/BOOTX64.EFI"; mkdir -p "$ESP/EFI/BOOT"
            log "removable fallback was MISSING — creating it"
        else would "removable fallback \\EFI\\BOOT\\BOOTX64.EFI is missing"; fi
    fi
    if [ -n "$REMOVABLE" ] && ! cmp -s "$SDBOOT" "$REMOVABLE" 2>/dev/null; then
        if fixing; then
            [ -f "$REMOVABLE" ] && cp "$REMOVABLE" "/root/bootx64.efi.replaced-$(date +%F-%H%M%S)" 2>/dev/null
            if cp "$SDBOOT" "$REMOVABLE.gb5new" && sync && mv -f "$REMOVABLE.gb5new" "$REMOVABLE" && sync \
               && cmp -s "$SDBOOT" "$REMOVABLE" && signed "$REMOVABLE"; then
                log "removable fallback was not systemd-boot (old copy in /root); restored signed systemd-boot"
            else
                rm -f "$REMOVABLE.gb5new"; fail "could not restore the removable fallback $REMOVABLE"
            fi
        else would "removable fallback $REMOVABLE is not the signed systemd-boot"; fi
    fi
fi

# ── 3. fallback UKI carries a kernel that still has modules ──────────────────
# What the fallback is FOR, honestly: it is a copy of the main UKI, refreshed
# ONLY when its kernel's module tree is gone (a series bump or a point release
# that deleted it). Between such events it is left alone, so after a plain
# initramfs rebuild it is the previous, already-booted image of the same
# kernel -- protection against a bad initramfs/cmdline, not against a bad
# kernel. Right after a kernel change it is a copy of a never-booted image;
# the real escape from a bad kernel is the LTS UKI (manjaro-6.12).
# Known, not handled: a cmdline change (e.g. resume_offset) does not refresh
# the fallback -- gb5-verify's "every UKI shares the resume target" catches it.
main=$(ls -1 "$UKI_DIR"/manjaro-*.efi 2>/dev/null | grep -v -- '-fallback\.efi$' | sort -V | tail -1)
if [ -n "$main" ]; then
    main_k=$(uki_kver "$main")
    want_fb="${main%.efi}-fallback.efi"
    fb_k=""; [ -f "$want_fb" ] && fb_k=$(uki_kver "$want_fb")
    if [ -z "$main_k" ] || [ ! -d "/usr/lib/modules/$main_k" ]; then
        fail "main UKI $(basename "$main") carries '${main_k:-?}', which has no module tree — not building a fallback from it"
    elif ! signed "$main"; then
        fail "main UKI $(basename "$main") is not signed — not copying it into the fallback"
    elif [ ! -f "$want_fb" ] || [ -z "$fb_k" ] || [ ! -d "/usr/lib/modules/$fb_k" ] || ! signed "$want_fb"; then
        if fixing; then
            # temp name, then rename; sign at the FINAL path (sbctl records it).
            if cp "$main" "$want_fb.gb5new" && sync && mv -f "$want_fb.gb5new" "$want_fb" \
               && { signed "$want_fb" || sbctl sign "$want_fb" >/dev/null 2>&1; } && sync \
               && signed "$want_fb" && [ "$(uki_kver "$want_fb")" = "$main_k" ]; then
                log "fallback UKI $(basename "$want_fb") rebuilt for $main_k and signed"
            else
                rm -f "$want_fb.gb5new"; fail "fallback UKI rebuild FAILED (ESP space?)"
            fi
        else would "fallback UKI $(basename "$want_fb") missing, unsigned, or its kernel '${fb_k:-?}' has no modules"; fi
    fi
    # Remove fallbacks of superseded series ONLY once the current one is good.
    cur_fb_k=$( [ -f "$want_fb" ] && uki_kver "$want_fb" )
    if [ -n "$cur_fb_k" ] && signed "$want_fb" && [ -d "/usr/lib/modules/$cur_fb_k" ]; then
        while IFS= read -r f; do
            [ "$f" = "$want_fb" ] && continue
            k=$(uki_kver "$f")
            if [ -z "$k" ] || [ ! -d "/usr/lib/modules/$k" ]; then
                if fixing; then rm -f "$f" && log "removed stale fallback $(basename "$f") (kernel ${k:-?} has no modules)"
                else would "stale fallback $(basename "$f") (kernel ${k:-?} has no modules)"; fi
            fi
        done < <(ls -1 "$UKI_DIR"/manjaro-*-fallback.efi 2>/dev/null)
    fi
fi

# ── 4. sbctl's database matches the ESP ──────────────────────────────────────
# `sbctl sign -s` on a file that is ALREADY signed prints "File has already been
# signed" and returns 0 WITHOUT recording it -- and every UKI here arrives signed
# (mkinitcpio's sbctl post hook signs, untracked). So the entry is written into
# sbctl's own JSON, in the exact shape sbctl writes.
while IFS= read -r u; do
    tracked "$u" && continue
    if fixing; then
        signed "$u" || sbctl sign "$u" >/dev/null 2>&1
        db_set '.[$p] = {file: $p, output_file: $p}' --arg p "$u" && tracked "$u" \
            && log "now tracking $(basename "$u") in sbctl" \
            || fail "could not add $(basename "$u") to sbctl's database"
    else would "$(basename "$u") is not tracked by sbctl"; fi
done < <(ls -1 "$UKI_DIR"/manjaro-*.efi 2>/dev/null)
while IFS= read -r f; do
    [ -e "$f" ] && continue
    if fixing; then
        db_set 'del(.[$p])' --arg p "$f" && log "dropped dead sbctl entry $f" \
            || fail "could not drop dead sbctl entry $f"
    else would "sbctl tracks $f, which no longer exists"; fi
done < <(db_paths)

# ── 4b. every file sbctl tracks is actually signed ──────────────────────────
# zz-sbctl.hook fires on PATH triggers (boot/*, usr/lib/**/efi/*.efi* ...), and a
# grub-only upgrade matches none of them: 99-grub-disable-shim-lock.hook then
# rebuilds grubx64.efi and nothing re-signs it. Found 2026-11-19 by reinstalling
# grub and reading the signature back.
unsigned_tracked() {
    while IFS= read -r f; do
        [ -e "$f" ] || continue
        o=$(db_out "$f"); o=${o:-$f}
        [ -e "$o" ] && ! signed "$o" && echo "$o"
    done < <(db_paths)
}
lst=$(unsigned_tracked)
if [ -n "$lst" ]; then
    if fixing; then
        sbctl sign-all >/dev/null 2>&1 || fail "sbctl sign-all failed"
        lst=$(unsigned_tracked)
        [ -z "$lst" ] && log "re-signed tracked files that had lost their signature" \
            || fail "still unsigned after sign-all: $(echo $lst)"
    else would "tracked but unsigned: $(echo $lst)"; fi
fi

# ── 5. every Manjaro UKI is signed by our key ────────────────────────────────
while IFS= read -r u; do
    signed "$u" || fail "$(basename "$u") is NOT signed by our key"
done < <(ls -1 "$UKI_DIR"/manjaro-*.efi 2>/dev/null)

exit $rc
