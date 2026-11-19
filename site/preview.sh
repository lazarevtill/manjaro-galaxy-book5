#!/bin/bash
# Preview galaxy-book5-enablement.html the way the published artifact renders it.
#
# The source file is deliberately a FRAGMENT — no <!doctype>, <html>, <head> or
# <body>. The artifact host supplies that wrapper at publish time, and adding
# our own would be published too. So editing it directly is correct; it just
# means opening the raw file in a browser is not quite what viewers see.
#
# This wraps a copy in /tmp and opens that. It also mimics the one thing the
# host does that matters for checking your work: stamping data-theme on the root
# element, so the light and dark palettes can both be inspected.
#
#   ./site/preview.sh          follow the desktop theme (what most viewers get)
#   ./site/preview.sh dark     force the dark palette
#   ./site/preview.sh light    force the light palette
#   ./site/preview.sh both     open both, side by side

set -euo pipefail
cd "$(dirname "$0")"
SRC=galaxy-book5-enablement.html
[ -f "$SRC" ] || { echo "$SRC not found" >&2; exit 1; }

wrap() {
    local theme="$1" out="$2"
    {
        printf '<!doctype html>\n<html%s>\n<head>\n<meta charset="utf-8">\n' \
               "${theme:+ data-theme=\"$theme\"}"
        printf '<meta name="viewport" content="width=device-width,initial-scale=1">\n'
        # The host applies a minimal reset before the page's own CSS.
        printf '<style>*{margin:0}img{max-width:100%%}</style>\n</head>\n<body>\n'
        cat "$SRC"
        printf '\n</body>\n</html>\n'
    } > "$out"
}

open_it() { (xdg-open "$1" >/dev/null 2>&1 &) ; echo "  opened $1"; }

case "${1:-system}" in
    system) wrap ""      /tmp/gb5-preview.html;      open_it /tmp/gb5-preview.html ;;
    dark)   wrap "dark"  /tmp/gb5-preview-dark.html; open_it /tmp/gb5-preview-dark.html ;;
    light)  wrap "light" /tmp/gb5-preview-light.html; open_it /tmp/gb5-preview-light.html ;;
    both)
        wrap "light" /tmp/gb5-preview-light.html
        wrap "dark"  /tmp/gb5-preview-dark.html
        open_it /tmp/gb5-preview-light.html
        open_it /tmp/gb5-preview-dark.html ;;
    *) echo "usage: $0 [system|light|dark|both]" >&2; exit 1 ;;
esac
