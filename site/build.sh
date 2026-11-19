#!/bin/bash
# Wrap the page fragment into a complete document for GitHub Pages.
# The fragment (galaxy-book5-enablement.html) deliberately has no
# <!doctype>/<head>/<body>: the claude.ai artifact host adds those, and
# site/check.sh refuses a fragment that contains them. This script adds
# exactly what that host adds, so both publishing targets render the same.
#   ./site/build.sh [outdir]   (default: _site)
set -euo pipefail
# Resolve the output dir from the CALLER's cwd, before changing directory
# (the first CI run wrote to site/_site because of this order).
out=$(realpath -m "${1:-_site}"); mkdir -p "$out"
cd "$(dirname "$0")"
src=galaxy-book5-enablement.html
title=$(grep -m1 -oP '(?<=<title>)[^<]+' "$src")
desc="Manjaro Linux on the Samsung Galaxy Book5 Pro H: every fix, measurement and wrong turn."
{
  printf '<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n'
  printf '<meta name="viewport" content="width=device-width,initial-scale=1">\n'
  printf '<meta name="description" content="%s">\n' "$desc"
  printf '<meta property="og:title" content="%s">\n<meta property="og:description" content="%s">\n' "$title" "$desc"
  printf '<link rel="canonical" href="https://gb5.lazarev.cloud/">\n'
  printf '</head>\n<body>\n'
  cat "$src"
  printf '\n</body>\n</html>\n'
} > "$out/index.html"
touch "$out/.nojekyll"
echo "built $out/index.html ($(wc -c < "$out/index.html") bytes, title: $title)"
