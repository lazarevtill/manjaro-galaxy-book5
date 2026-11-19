# True black for an OLED

On an emissive panel a black pixel is an *off* pixel. Grey is not. KDE's dark
themes are dark **grey** — Manjaro Breath Dark draws windows at `rgb(40,46,51)`
and views at `rgb(24,25,29)`.

## What it is worth

Measured anchors on this machine: a full-black screen draws ~5 W, full white
~15 W, so ~10 W of panel emission spans that range. Scaling by relative
luminance:

| Background | Relative luminance | Modelled panel cost |
|---|---|---|
| Breath Dark window `rgb(40,46,51)` | 2.64% | ~5.26 W |
| Breath Dark view `rgb(24,25,29)` | 0.98% | ~5.10 W |
| **True black `rgb(0,0,0)`** | **0.00%** | **~5.00 W** |

**About 264 mW.** Real, free, and directionally certain — but *below* the
demonstrated resolution of measurement on this desktop, where a brightness A/B
could not separate 0.2 W. It is applied because the physics is sound, not
because it can be confirmed afterwards. Do not expect to see it in a graph.

## What was changed, and what deliberately was not

    GB5TrueBlack.colors        window + view backgrounds -> 0,0,0
    GB5TrueBlack.colorscheme   Konsole/Yakuake background -> 0,0,0
    GB5TrueBlack.profile       terminal profile referencing the above
    wallpaper                  org.kde.color, solid 0,0,0

**Foregrounds, borders and accent colours are untouched.** They are thin strokes
covering almost no screen area, so flattening them would cost contrast and
legibility for a saving too small to measure. Alternate list rows are `rgb(8,8,8)`
rather than pure black — 0.24% luminance, roughly 24 mW, against unreadable
zebra striping.

The gain is proportional to *area*, so the wallpaper and terminal background are
where nearly all of it comes from. A black window frame around a white document
saves nothing worth having.

## Installing

    cp GB5TrueBlack.colors      ~/.local/share/color-schemes/
    cp GB5TrueBlack.colorscheme ~/.local/share/konsole/
    cp GB5TrueBlack.profile     ~/.local/share/konsole/
    plasma-apply-colorscheme GB5TrueBlack
    kwriteconfig6 --file konsolerc --group 'Desktop Entry' \
                  --key DefaultProfile GB5TrueBlack.profile

Existing terminal tabs keep their old profile until reopened.

## Reverting

    plasma-apply-colorscheme BreathDark

Config backups from the change are under `~/.config/gb5-theme-backup-*`.

## HDR and black — unresolved, with a script to settle it

The interesting question is not HDR's own cost but whether HDR **lifts black**,
which would undermine everything above. In theory it should not: SDR code 0 maps
to PQ 0 and the pixel stays off. But the panel could switch drive mode in HDR, or
KWin's SDR→HDR mapping could clamp to a non-zero floor. Neither is visible from
configuration.

**A first attempt on 2026-08-22 failed and was discarded in full:**

    HDR on    12.45 W        HDR on    48.80 W   <- impossible
    HDR off    8.27 W        HDR on     0.00 W   <- charger reconnected
    HDR off    4.88 W        HDR off    0.00 W   <- charger reconnected

The charger went back in three arms into six. Even the battery arms were
unusable — `HDR off` gave 8.27 W then 4.88 W in consecutive arms, a 3.4 W spread
*within one condition*, larger than any effect being looked for.

`bin/gb5-hdr-black-test` exists so that cannot happen quietly again. It:

- **refuses to start** on AC, with the battery too low to finish, or with CPU
  busy above 4% (a single saturated core is only ~6% of sixteen, so the
  threshold is deliberately low);
- **voids the run** rather than salvaging it if the charger is reconnected;
- runs ~8 gauge steps per arm — about 70 minutes each, because anything shorter
  measures the 49 mAh quantisation rather than the panel;
- records **CPU busy per arm** and reports `CONFOUNDED` if it drifts more than 3
  points, since a steady background load cancels across alternated arms but one
  that starts or finishes mid-run does not;
- reports `NOT MEASURABLE` when the difference is inside the quantisation,
  which is not the same claim as "no difference".

Run it on an idle machine, unplugged, when the laptop is not needed for ~5 hours:

    sudo gb5-hdr-black-test --dry-run     # check preconditions only
    sudo gb5-hdr-black-test               # 4 arms, ~5 h

**Until then, leave HDR on.** The risk is speculative, the theory says it costs
nothing on black, and any real cost is bounded by the ~0.2 W that has repeatedly
proved unresolvable on this machine. The true-black theming is worth ~264 mW and
does not depend on the HDR answer either way.
