#!/bin/bash
# Catch the mistakes that are easy to make editing this page by hand.
#
# The published artifact is a fragment, so a browser will happily render a file
# with an unclosed <div> or a stray </p> and simply guess. That guess is not
# what the host renders. Check before publishing rather than after.

set -uo pipefail
cd "$(dirname "$0")"
SRC=galaxy-book5-enablement.html
fail=0

say()  { printf '  %-46s %s\n' "$1" "$2"; }
bad()  { say "$1" "FAIL — $2"; fail=1; }
good() { say "$1" "ok"; }

[ -f "$SRC" ] || { echo "$SRC not found" >&2; exit 1; }

# 1. Tag balance. The usual result of a hand edit going wrong.
tags=$(python3 - "$SRC" <<'PY'
import re, sys
s = open(sys.argv[1], encoding='utf-8').read()
bad = []
for t in ('section','div','table','thead','tbody','tr','td','th',
          'pre','ul','ol','li','dl','dt','dd','p','h1','h2','h3','h4','span','a'):
    o = len(re.findall(r'<%s[\s>]' % t, s))
    c = len(re.findall(r'</%s>' % t, s))
    if o != c:
        bad.append(f"{t} {o}/{c}")
print("; ".join(bad))
PY
)
if [ -n "$tags" ]; then bad "tags balanced" "$tags"; else good "tags balanced"; fi

# 2. The wrapper must not be re-introduced: the host adds it, and a second one
#    means a nested document.
if grep -qiE '<!doctype|<html[ >]|<head[ >]|<body[ >]' "$SRC"; then
    bad "no document wrapper" "found doctype/html/head/body — the host supplies these"
else
    good "no document wrapper"
fi

# 3. A <title> is what names the artifact in the gallery and the browser tab.
if grep -qi '<title>' "$SRC"; then good "has a <title>"; else bad "has a <title>" "missing"; fi

# 4. Every colour must be reachable in both themes. A colour defined ONLY inside
#    a prefers-color-scheme or [data-theme] block leaves the other theme unstyled
#    — this is the classic unreadable-artifact bug.
theme=$(python3 - "$SRC" <<'PY'
import re, sys
s = open(sys.argv[1], encoding='utf-8').read()
style = "\n".join(re.findall(r'<style>(.*?)</style>', s, re.S))
root_vars = set(re.findall(r'--([a-z0-9-]+)\s*:', style.split('@media')[0].split('[data-theme')[0]))
themed = set()
for block in re.findall(r'(?:@media[^{]*prefers-color-scheme|:root\[data-theme)[^{]*\{(.*?)\n  \}', style, re.S):
    themed |= set(re.findall(r'--([a-z0-9-]+)\s*:', block))
print(", ".join(sorted(themed - root_vars)))
PY
)
if [ -n "$theme" ]; then bad "every colour defined on :root" "only in a theme block: $theme"; else good "every colour defined on :root"; fi

# 5. External references. Only Google Fonts is reachable under the artifact CSP.
ext=$(grep -oE 'https?://[^"'"'"' )]+' "$SRC" | grep -vE 'fonts\.(googleapis|gstatic)\.com' \
      | grep -vE '^https?://(github\.com|raw\.githubusercontent\.com|www\.gnu\.org|uefi\.org|lists\.archlinux\.org|aur\.archlinux\.org|libcamera\.org|patchwork\.libcamera\.org|gitlab\.freedesktop\.org|git\.libcamera\.org|www\.phoronix\.com|jgrulich\.cz|jetm\.github\.io|ideasonboard\.com|archlinux\.org|semver\.org|fprint\.freedesktop\.org)' \
      | sort -u)
if [ -n "$ext" ]; then
    say "external asset hosts" "check these load under CSP:"; printf '      %s\n' $ext
else
    good "external asset hosts"
fi

echo
if [ "$fail" -eq 0 ]; then echo "  Looks publishable."; else echo "  Fix the failures above first." >&2; fi
exit $fail
