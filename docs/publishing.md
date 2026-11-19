# Working on this locally

This repository is yours to edit. It is the **canonical** copy — `/root/gb5-enablement`
is no longer where the published page comes from, so nothing here gets overwritten
behind your back.

    site/galaxy-book5-enablement.html   the published page
    site/preview.sh                     see it the way viewers do
    site/check.sh                       catch edit mistakes before publishing
    sync.sh                             is this record still true of the machine?
    docs/  HISTORY.md  TASKS.md         the offline notes
    bin/                                the live scripts, copied from /usr/local/sbin
    systemd/  config/                   the live units and config, copied from /etc and the ESP

## Editing the page

Open `galaxy-book5-enablement.html` in any editor. One thing to know before you
start: **it is deliberately a fragment.** There is no `<!doctype>`, `<html>`,
`<head>` or `<body>` in it, because the artifact host wraps it at publish time.
If you add those tags the published page ends up with a document inside a
document. `check.sh` will tell you if that happens.

Everything else is ordinary HTML and CSS. The styling lives in one `<style>`
block at the top, driven by CSS custom properties, so changing a colour once
changes it everywhere.

## Seeing your changes

    ./site/preview.sh          as most viewers see it — follows your desktop theme
    ./site/preview.sh both     light and dark side by side
    ./site/preview.sh dark     force dark

Opening the raw file in a browser also works, roughly, but the preview wraps it
the way the host does and can stamp a theme on the root element — which is the
only reliable way to check both palettes.

## Before publishing

    ./site/check.sh

It checks tag balance, that the document wrapper has not crept in, that a
`<title>` is present, that no colour is defined *only* inside a
`prefers-color-scheme` or `[data-theme]` block, and that no unexpected external
host is referenced. That last one matters because the artifact CSP blocks
everything except Google Fonts — a remote image would silently not load.

The colour check is worth understanding: the page has three theme states, not
two. An explicit choice stamps `data-theme` on the root, but the default
"system" setting stamps nothing and relies on `prefers-color-scheme`. A colour
whose only definition sits inside a `[data-theme]` block never applies in that
un-stamped state, and the page renders one theme's text on the other theme's
background.

## Publishing

Ask me to publish and I will push this file to the existing artifact, keeping
the same URL:

    https://claude.ai/artifact/WCddFF3kcGqqFXVZoSwA8W

I cannot give you a way to publish it yourself — that runs through my tooling,
not a command you can call.

## Keeping it honest

Everything here except the notes is a **copy** of something live, and copies
drift — a kernel update rebuilds the DKMS source, a package update rewrites a
hook, someone edits a config in place. A record that quietly disagrees with the
machine is worse than no record, because it gets trusted.

    sudo ./sync.sh          report drift, change nothing
    sudo ./sync.sh --pull   refresh the copies, then review with git diff

It compares 25 files against their live originals and exits non-zero if any have
drifted or gone missing. Worth running after any kernel or package update that
touches the camera, the fingerprint stack or the boot chain — and before
publishing.

It needs root for a couple of the sources: `/boot/efi/loader/loader.conf` is
0700, so as a normal user it reports that one as unreadable rather than
pretending it matches.

## Tracking your changes

This is a git repository, so you can see what you changed and undo it:

    git diff                    what you have changed since the last commit
    git add -A && git commit    keep a checkpoint
    git checkout -- <file>      throw away changes to one file

Nothing is pushed anywhere; it is local history only.

## GitHub Pages (public): https://gb5.lazarev.cloud

Since 2026-11-19 the page is also public. Pushing to `main` on GitHub with a
change under `site/` runs `.github/workflows/pages.yml`: `site/check.sh`, then
`site/build.sh`, which wraps the fragment in exactly the `<!doctype>`/`<head>`/
`<body>` the artifact host adds, then deploys. Build locally with
`./site/build.sh _site`.

DNS: `gb5` CNAME -> `lazarevtill.github.io`, DNS-only (Cloudflare proxying would
stop GitHub issuing the certificate), managed as code in the infrastructure
repo (`platform/cloudflare/zone.tf`, `record_cname_gb5`). HTTPS is enforced; the
certificate is GitHub's (Let's Encrypt). If it ever shows "certificate not
yet created", clear and re-save the custom domain in the repo's Pages
settings — that restarts provisioning (it did on the first day).

The GitHub repo is published as a **single squashed commit** of `main`; the
full history stays local:

    git push --force github "$(git commit-tree 'main^{tree}' -m 'Update'):refs/heads/main"

