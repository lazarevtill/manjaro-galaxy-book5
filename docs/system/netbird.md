# NetBird on the Galaxy Book5

Mesh VPN, `wt0`, `100.76.0.0/16`, FQDN `gb5.in.vpn`. Currently 0.77.1.

## It is NOT managed by pacman

Installed by the official `install.sh`, which drops binaries straight into
`/usr/bin`. `pacman -Qo /usr/bin/netbird` says *no package owns it*. Consequences:

* `gb5-safe-update` will never update it. Updating is manual (below).
* Nothing verifies its integrity — no package signature check on the installed files.

### The installer leaves a local root escalation

It writes the binaries owned by the **invoking user**:

    -rwxr-xr-x 1 lazarevtill lazarevtill  /usr/bin/netbird

and `netbird.service` runs that file **as root**. Anything running as that user
— a malicious npm or Gradle dependency, a browser exploit, a container escape —
can overwrite it and own root at the next service restart or boot. Fixed here to
`root:root`, but **re-running the installer undoes it**. After any manual update:

    sudo chown root:root /usr/bin/netbird /usr/bin/netbird-ui

Also note `/var/run/netbird.sock` is mode `0666`, so any local user can control
the VPN. That is upstream's default, not a local change.

## Updating

    v=0.77.1   # check https://github.com/netbirdio/netbird/releases/latest
    cd "$(mktemp -d)"
    base=https://github.com/netbirdio/netbird/releases/download/v$v
    curl -sSLO $base/netbird_${v}_linux_amd64.tar.gz
    curl -sSLO $base/netbird-ui-linux-gtk3_${v}_linux_amd64.tar.gz
    curl -sSLO $base/netbird_${v}_checksums.txt
    curl -sSLO $base/netbird-ui_gtk3_checksums.txt
    sha256sum -c --ignore-missing netbird_${v}_checksums.txt
    sha256sum -c --ignore-missing netbird-ui_gtk3_checksums.txt   # must both say OK
    tar xzf netbird_${v}_linux_amd64.tar.gz netbird
    tar xzf netbird-ui-linux-gtk3_${v}_linux_amd64.tar.gz netbird-ui
    sudo systemctl stop netbird
    sudo install -o root -g root -m 755 netbird netbird-ui /usr/bin/
    sudo systemctl start netbird

**Do not do this while a kernel update is pending a reboot.** See below.

## The UI

`netbird-ui` was already installed and never appeared because the upstream
default build links against **WebKitGTK 6.0**, which is not installed here:

    ldd /usr/bin/netbird-ui | grep 'not found'
      libwebkitgtk-6.0.so.4      => not found
      libjavascriptcoregtk-6.0.so.1 => not found

Use the **GTK3** release asset (`netbird-ui-linux-gtk3_*`) instead: it links
against the `webkit2gtk-4.1` already present, so it needs no new 131 MiB
dependency. It is a StatusNotifierItem tray app and works on Plasma 6 Wayland;
the `Gdk-CRITICAL gdk_window_get_display` lines at startup are harmless.

The tarballs ship no `.desktop` file and no icon, which is the other reason it
never showed up in the launcher. Both are in `netbird/` here; the icon comes from
`client/ui/assets/netbird-systemtray-connected.png` in the upstream repo.

Autostart is managed **by the app itself** (it writes
`~/.config/autostart/netbird.desktop` on first run, and its tray menu toggles
it). Do not add a second entry — let the app own it, or its toggle silently
disagrees with reality.

From the tray you get: connect/disconnect, profiles, **networks/routes**
selection, and exit nodes. The CLI equivalents are `netbird routes list` and
`netbird routes select <ID>`.

## The trap that cost an outage

Between a kernel upgrade and the reboot, `/usr/lib/modules/$(uname -r)` is
deleted. NetBird's nftables firewall manager then cannot build its tables and
**every restart fails**:

    init firewall: router init: create containers: initialize tables:
    conn.Receive: netlink receive: no such file or directory

Established by probing each expression individually rather than guessing:

| nft feature | before reboot |
|---|---|
| table, chain, set, counter | OK |
| `ct state` | FAIL — `nft_ct` is `=m`, `.ko` deleted |
| `fib` | FAIL — `nft_fib_ipv4` |
| `masquerade` | FAIL — `nft_masq` |

The running daemon survives only because it started before the upgrade. This is
**not version-specific** (0.77.0 and 0.77.1 fail identically) and **no flag
avoids it** — `--disable-firewall`, `--disable-server-routes`,
`NB_FORCE_USERSPACE_FIREWALLS` and `NB_FORCE_USERSPACE_ROUTER` are all evaluated
*after* the firewall manager is constructed, which is where it dies.

So: **after a kernel update, do not restart NetBird until you have rebooted.**
If it is already down, you do not have to reboot immediately — the deleted
modules can be restored from a Timeshift snapshot; see the recovery section in
`docs/system/docker.md`.

## A stopped NetBird can leave a stale resolv.conf

Found the hard way on 2026-08-23. NetBird takes over `/etc/resolv.conf` and
restores a snapshot when it stops. If the machine **changes network** while it is
stopped, that snapshot is stale: the file claims to be NetworkManager-generated
but holds the *old* LAN's resolver, and NetworkManager does not rewrite it.

Symptom: nothing resolves at all — including `vpn.lazarev.cloud`, so NetBird
cannot reconnect either, and reports

    Management: Disconnected, reason: ... dial context: context deadline exceeded

which looks like a server problem and is not. Check `cat /etc/resolv.conf`
against `nmcli -g IP4.DNS dev show wlo1`; if they disagree:

    sudo nmcli general reload dns-full

## Overlapping subnets are handled correctly

Worth recording because it looks alarming and is fine. The advertised network
`Network-NS` is `192.168.100.0/22`, and the laptop was later sitting on that
exact LAN with its default gateway inside it. NetBird detected the overlap and
did **not** install the route over the local one:

    default via 192.168.100.1 dev wlo1
    192.168.100.0/22 dev wlo1              <-- stayed on the LAN interface, not wt0

Gateway stayed reachable, internet stayed up, and the network still shows as
`Selected`. No action needed.

## DNS

NetBird owns `/etc/resolv.conf` and points it at `100.76.231.97`, which is this
host's **own wt0 address**. Its upstream split is server-side:

    [1.1.1.1:53, 1.0.0.1:53]                for [.]
    [192.168.100.200:53, 100.76.162.191:53] for [in.lazarev.cloud, lazarev.cloud]

So public queries already reach Cloudflare by design; only `lazarev.cloud` names
stay internal. When NetBird stops, NetworkManager restores `resolv.conf` to
`192.168.18.1`. Docker deliberately does **not** inherit any of this — see the
DNS section of `docs/system/docker.md` for why it is pinned instead.
