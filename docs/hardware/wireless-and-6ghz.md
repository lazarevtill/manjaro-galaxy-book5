---
name: gb5-wireless-and-6ghz
description: "Why 6 GHz cannot be enabled on the Galaxy Book5's Intel BE201 under Linux — traced to a BIOS ACPI variable — and what the regulatory domain setting does and does not do"
metadata: 
  node_type: memory
  type: project
  originSessionId: 5f6b4d36-2b3c-40e8-8285-72954661d9dd
  modified: 2026-08-21T19:13:55.311Z
---

Settled 2026-08-21 on the user's Galaxy Book5 (`GB5`). Worth keeping because the
obvious answer ("set the regdomain") is wrong, and proving it took decompiling
the DSDT.

## The card

Intel **Wi-Fi 7 BE201 320MHz** (Arrow Lake CNVi, `8086:7740`), driver `iwlwifi`
with op_mode `iwlmld`. The PHY exposes Band 4 with **59 channels from 5955 MHz**
— and **all 59 are `(disabled)`**.

## Regulatory domain: set it, but know its limits

`/etc/conf.d/wireless-regdom` now sets `WIRELESS_REGDOM="RS"` (Serbia, matching
Europe/Belgrade). Unset, the kernel uses country `00` — the world domain, which
has **no 6 GHz allocation at all**. With RS the global domain gains
`5925-6425 MHz @ 320 MHz`.

**That does not enable 6 GHz here.** The PHY is **self-managed**: the firmware
owns its regulatory domain and `iw reg set` cannot override it. `iw reg get`
shows both — global `country RS: DFS-ETSI`, PHY `country RS: DFS-UNSET` listing
only 2.4 GHz and 5170-5250 MHz.

## Why 6 GHz is actually off

iwlwifi asks the ACPI `_DSM` with UUID `f21202bf-8f78-4dc6-a5b3-1f738e285ade`,
function 3 (`DSM_FUNC_ENABLE_6E`). In this DSDT that dispatches to `EFUN`:

```asl
If ((Arg2 == 0x03))
{
    Local0 = UHBS   /* \UHBS */
    Return (Local0)
}
```

`UHBS` is a **32-bit field in the ACPI NVS region**, written by the BIOS at boot:
`UHBS, 32,`. So 6 GHz enablement is a firmware decision.

There is **no Linux-side override**: `lar_disable` was removed in kernel 5.4, and
neither `iwlwifi` nor `iwlmld` exposes a relevant module parameter. BIOS is
current (`P05RHH.280.251204.01`) with nothing pending on LVFS.

The only route from Linux is a **DSDT override** — patch `EFUN` so function 3
returns an enabling value, compile with `iasl`, load via initramfs. That means
rebuilding and re-signing the UKI, and a malformed DSDT can leave the machine
unbootable. Not attempted; offered and not taken up.

## Do not skip the AP-side check first

When this was investigated the user's own AP (`lazarev.cloud`) was visible **only
at 2457 MHz** at −34 dBm — no 5 GHz sibling, no 6 GHz, and no **Reduced Neighbor
Report** in its beacon. RNR is how 6 GHz BSSs are discovered, because a client
whose 6 GHz channels are disabled cannot scan them directly. So even a working
card would have had nothing to join.

One thing the AP had right: `lazarev.cloud` uses **SAE (WPA3)**, which 6 GHz
mandates. A PSK-only SSID would fail regardless.

## Measuring this without fooling yourself

6 GHz channels start at **5955 MHz**, not 6000. A grep for `6[0-9]{3} MHz`
silently misses the first several and reports zero channels when 59 exist — that
mistake was made here and produced a wrong conclusion. Count with
`iw phy phy0 info | sed -n '/Band 4:/,$p' | grep -c 'MHz \['` and compare against
the `disabled` count.

## Related

[[gb5-hardware-audit-results]] for the rest of the peripheral audit,
[[gb5-secureboot-uki]] for the boot chain.
