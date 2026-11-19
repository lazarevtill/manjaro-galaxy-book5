# Fingerprint authentication

`pam_fprintd.so` is placed in five services:

    sudo  sddm  login  polkit-1        -auth sufficient
    kde-fingerprint                    -auth required   (lock screen)

**The lock screen was missed at first**, and it is the one that matters most —
it is where most fingerprint verifies happen. Plasma authenticates unlock through
`/usr/lib/pam.d/kde-fingerprint`, a *vendor* file, so `/etc/pam.d/kde-fingerprint`
overrides it rather than editing it (a package update would revert an edit).

That stack is `required`, not `sufficient`, because it is fingerprint-only and
Plasma runs it alongside the password stack — it must not short-circuit.

### A difference left deliberately unchanged

`kde-fingerprint` runs `pam_faillock preauth` **before** `pam_fprintd`. The other
four run `pam_fprintd` **first**, which means a faillock-locked account can still
authenticate by fingerprint on sudo, sddm, login and polkit.

That ordering predates these changes and has not been altered, because it is a
security-posture decision rather than a bug fix. Fingerprint failures themselves never increment faillock (it counts `pam_unix`
failures), so there is no risk of *locking yourself out* — but that is the wrong
direction to worry about. The real consequence is that **`pam_faillock` provides
no brute-force protection on this machine**: an account already locked out of
password auth can still be authenticated by fingerprint on sudo, sddm, login and
polkit, indefinitely. On a match-on-chip sensor the practical risk is low, but it
is a genuine posture choice rather than an inconsequential ordering. If the bypass is unwanted, move the `-auth sufficient
pam_fprintd.so` line to after the `system-auth` include in those four files.

Both parts of that matter and neither is safe to change:

- **`-`** means a missing or unloadable module is not an error — **for a
  `sufficient` or `optional` module.** Tested: with the module deleted, and with
  it present but unloadable, all four `sufficient` stacks returned `PAM_AUTH_ERR`
  and reached the password prompt.

  **It does not save a `required` module.** `-auth required <missing>` returns
  `PAM_MODULE_UNKNOWN` and the stack fails — the `-` only suppresses the log
  line. That is why `kde-fingerprint` is safe only because Plasma runs it beside
  the password stack, not because of the `-`. Do not copy that pattern anywhere
  it would short-circuit.
- **`sufficient`** means a fingerprint match ends authentication successfully,
  while a failure *falls through* to the password stack below. Password auth is
  never removed, only skipped when the finger matches.

## Retries

    -auth sufficient pam_fprintd.so max-tries=5 timeout=45

`pam_fprintd` defaults to `max-tries=3` and `timeout=30`. Raised to 5 attempts.

**The timeout matters more than it looks.** It is a *total* budget across all
attempts, not per attempt — leaving it at 30 s would often cut you off after
three or four tries and quietly defeat the point of raising `max-tries`. 45 s
gives five attempts room to happen.

The trade-off: if you would rather just type your password, you wait out the
fingerprint prompt first. Lower `timeout` to make that fallback faster.

## What was verified, and what needs a real finger

Measured against a throwaway `gb5-fptest` service so the real stacks were never
touched, with **no finger on the sensor**:

| setting | fingerprint stage held |
|---|---|
| `max-tries=1 timeout=45` | 20.5 s |
| `max-tries=3 timeout=45` | 17.7 s |
| `max-tries=5 timeout=45` | 20.5 s |
| `max-tries=5 timeout=10` | **10.4 s** |

**`timeout` is confirmed live** — dropping it to 10 cut the stage to 10.4 s.

**`max-tries` is not verifiable this way, and the reason is mechanical.** With no
finger present the device returns a timeout or error, not a failed *match*.
`max-tries` counts failed matches, so with nothing to match it never counts and
the stage ends on the device error regardless of the value. The three 45 s rows
above are identical because none of them ever registered an attempt.

So the retry count can only be exercised by actually presenting a finger that
fails to match:

```bash
sudo -k && sudo true          # then touch the sensor with a NON-enrolled finger
```

You should get up to five prompts before it falls through to `Password:`.
Only `right-index-finger` is enrolled, so any other finger produces a genuine
failed match, which is exactly what `max-tries` counts.

## Verifying a change without locking yourself out

`pamtester` is not packaged on Arch. `bin/pam-check.py` does the same job via
libpam: it authenticates with a deliberately **wrong** password and checks the
return code.

    python3 bin/pam-check.py sudo "$USER"

    rc=7   stack OK       — wrong password correctly rejected
    rc=6   STACK BROKEN   — PAM_SERVICE_ERR, the config does not parse
    rc=0   UNEXPECTED     — a wrong password was accepted

Distinguishing 7 from 6 is the whole point: both are "authentication did not
succeed", but only one of them means you have broken the machine.

**Each failed test increments `pam_faillock`.** Four service tests will lock the
account for 10 minutes. Always finish with:

    faillock --user "$USER" --reset

## Reverting

Timestamped backups sit beside each file:

    ls /etc/pam.d/*.bak-*
    cp /etc/pam.d/sudo.bak-YYYYMMDD-HHMMSS /etc/pam.d/sudo

Copies of the current working files are in [`config/pam/`](../../config/pam/).
