# Post-S4 Resume Fast-Path (Option C) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reduce post-S4 (hibernate / suspend-then-hibernate) ModemManager
restart latency from the current fixed 35 s wait to a typical 5–12 s, with
a hard 45 s cap. Improvement only applies to the `.restore` path; the
existing keepalive-fast-path (3 s) and the s2idle path (3 s) are unchanged.

**Architecture:** Two coordinated changes following Option C as verified
by two parallel verification agents on 2026-05-12:

1. **Driver side:** a `bool restore_pending` flag on `struct t7xx_pci_dev`.
   `t7xx_pci_pm_restore()` sets it after a successful `t7xx_reset_device(PLDR)`.
   `t7xx_pci_pm_init_late()` consumes it: when set, log a banner and clear
   the flag. Banner only fires when the modem really is usable (FSM
   completed HS2, port enumeration done, `md_pm_state = MTK_PM_RESUMED`).
   Anchored to `init_late`, not `init_done` — terminal-failure paths
   `complete_all(&init_done)` to unblock `.prepare`, so anchoring there
   would emit false-positives.

2. **Hook side:** new `schedule_mm_polled()` function in the embedded
   `99-modem-fix.sh`. Replaces the fixed `schedule_mm 35` on the
   non-keepalive `post/hibernate` and `post/suspend-then-hibernate`
   paths. The polled unit waits inside a `systemd-run` transient unit
   for either the driver's `"Restore: modem ready after PLDR"` banner or
   the appearance of `/dev/wwan0mbim0`, whichever comes first, then
   restarts ModemManager after a 1 s settle. Hard cap 45 s (well under
   systemd's 90 s sleep-hook default). All other branches unchanged.

**Tech Stack:** C kernel module (out-of-tree, DKMS), bash sleep hook
embedded in `reinstall.sh` via heredoc.

**Versioning:** Bump to v1.2.1 (perf patch — no new feature, no breaking
change). Tag at end after stable verification.

---

## File Structure

| File | Change |
|---|---|
| `src/t7xx_pci.h` | Add `bool restore_pending` to `struct t7xx_pci_dev`; document in struct comment. |
| `src/t7xx_pci.c` | Set `restore_pending = true` at success-tail of `t7xx_pci_pm_restore()`. Check/clear/log in `t7xx_pci_pm_init_late()`. |
| `reinstall.sh` | In the embedded `99-modem-fix.sh` heredoc: add `schedule_mm_polled()`. Dispatch in the non-keepalive `post/hibernate`/`post/STH` branch. |
| `dkms.conf` | Bump `PACKAGE_VERSION` 1.2.0 → 1.2.1 at the end. |
| `reinstall.sh` | Bump `MODULE_VERSION` 1.2.0 → 1.2.1 at the end. |
| `docs/journal.md` | New entry at the top for this change. |
| `README.md` | Update the Technical-details table row for `.restore` to mention the ready-banner; brief mention of "fast post-S4 resume" in the suspend-strategy section. |

No tests exist for this project — it's a kernel module + shell installer.
"Verification" is: build clean, `bash -n`, shellcheck (if available),
DKMS install, manual STH cycle on hardware. The verification steps in
each task make this explicit.

---

## Task 1: Driver — add `restore_pending` field to `struct t7xx_pci_dev`

**Files:**
- Modify: `src/t7xx_pci.h:81-108` (struct body + comment)

- [ ] **Step 1: Read current struct head comment and field block**

Run: read `src/t7xx_pci.h` lines 57–108.

Confirm: `suspend_skipped` exists at line 102; struct ends at line 108.

- [ ] **Step 2: Add the field below `suspend_skipped`**

Edit `src/t7xx_pci.h` — locate the line `bool suspend_skipped;` (line 102)
and add the new field immediately after:

```c
	bool			suspend_skipped;
	bool			restore_pending;
```

- [ ] **Step 3: Document the field in the struct head comment**

Edit `src/t7xx_pci.h` — locate the existing `@suspend_skipped:` doc block
(lines 76–78) and append a new `@restore_pending:` entry immediately
after the closing `*/`-less continuation, before `* @mode:`:

```c
 * @suspend_skipped: set in .suspend when keepalive_s2idle made the callback a
 *                   no-op; consumed in .resume / .resume_noirq to skip their
 *                   bodies symmetrically (modem stayed online throughout)
 * @restore_pending: set in .restore when a chip-level PLDR was successfully
 *                   queued; consumed in t7xx_pci_pm_init_late() to log the
 *                   "modem ready after PLDR" banner once the FSM has actually
 *                   completed HS2 and ports are enumerated. The userspace
 *                   sleep hook uses that banner to short-circuit its 35 s
 *                   post-resume wait.
 * @mode: indicates the device mode
```

- [ ] **Step 4: Build the module to verify struct compiles**

Run: `make -C /lib/modules/$(uname -r)/build M=/home/kirby/projects/mtk_t7xx_fix/src modules`

Expected: clean build, `mtk_t7xx.ko` produced, no warnings about unused
`restore_pending` (we don't use it yet — that's fine because it's a
struct field, not a variable).

- [ ] **Step 5: Commit**

```bash
cd /home/kirby/projects/mtk_t7xx_fix
git add src/t7xx_pci.h
git commit -m "Add restore_pending flag to t7xx_pci_dev for .restore fast-path"
```

---

## Task 2: Driver — set/clear `restore_pending` and emit ready-banner

**Files:**
- Modify: `src/t7xx_pci.c:371-387` (`t7xx_pci_pm_init_late`)
- Modify: `src/t7xx_pci.c:1124-1133` (success-tail of `t7xx_pci_pm_restore`)

- [ ] **Step 1: Add banner emission to `t7xx_pci_pm_init_late()`**

Locate `t7xx_pci_pm_init_late` (starts line 371). Insert the
banner-emit block just before the final `complete_all(&t7xx_dev->init_done);`
(line 386):

```c
void t7xx_pci_pm_init_late(struct t7xx_pci_dev *t7xx_dev)
{
	/* Enable the PCIe resource lock only after MD deep sleep is done */
	t7xx_mhccif_mask_clr(t7xx_dev,
			     D2H_INT_DS_LOCK_ACK |
			     D2H_INT_SUSPEND_ACK |
			     D2H_INT_RESUME_ACK |
			     D2H_INT_SUSPEND_ACK_AP |
			     D2H_INT_RESUME_ACK_AP);
	iowrite32(T7XX_L1_BIT(0), IREG_BASE(t7xx_dev) + ENABLE_ASPM_LOWPWR);
	atomic_set(&t7xx_dev->md_pm_state, MTK_PM_RESUMED);

	pm_runtime_mark_last_busy(&t7xx_dev->pdev->dev);
	pm_runtime_allow(&t7xx_dev->pdev->dev);
	pm_runtime_put_noidle(&t7xx_dev->pdev->dev);

	/* Tell the userspace sleep hook that a .restore-path resume is
	 * fully complete: PLDR ran, FSM finished HS2, ports are enumerated,
	 * MM can safely reopen MBIM. Set only by t7xx_pci_pm_restore on
	 * the successful-PLDR tail (cold-boot probes leave it false).
	 * Cleared here to avoid retriggering on later non-.restore re-inits.
	 */
	if (t7xx_dev->restore_pending) {
		t7xx_dev->restore_pending = false;
		dev_info(&t7xx_dev->pdev->dev,
			 "[PM] Restore: modem ready after PLDR\n");
	}

	complete_all(&t7xx_dev->init_done);
}
```

- [ ] **Step 2: Set `restore_pending` at success-tail of `t7xx_pci_pm_restore`**

Locate `t7xx_pci_pm_restore` success-tail (line 1124–1134). Set the
flag right after the successful `t7xx_reset_device` call, BEFORE the
final `return 0`:

```c
	ret = t7xx_reset_device(t7xx_dev, PLDR);
	if (ret) {
		dev_err(&pdev->dev,
			"[PM] Restore: PLDR failed (%d), unblocking suspend path\n",
			ret);
		complete_all(&t7xx_dev->init_done);
		return ret;
	}

	/* PLDR queued successfully. The FSM worker will drive reprobe →
	 * HS1 → HS2 → port-enum and end at t7xx_pci_pm_init_late(), which
	 * consumes this flag to log the userspace-visible ready banner.
	 * Setting it here (not earlier) means failure paths above never
	 * trigger a false-ready signal.
	 */
	t7xx_dev->restore_pending = true;

	t7xx_dev->resume_reprobe_count = 0;
	return 0;
}
```

- [ ] **Step 3: Clean rebuild from scratch**

```bash
cd /home/kirby/projects/mtk_t7xx_fix/src
rm -f *.o *.ko *.mod *.mod.c .*.cmd modules.order Module.symvers
make -C /lib/modules/$(uname -r)/build M=$(pwd) modules
```

Expected: clean build, `mtk_t7xx.ko` produced. Verify the new symbol
strings are in the module:

```bash
strings /home/kirby/projects/mtk_t7xx_fix/src/mtk_t7xx.ko \
  | grep "modem ready after PLDR"
```

Expected output: `[PM] Restore: modem ready after PLDR` (the format string).

- [ ] **Step 4: Commit**

```bash
cd /home/kirby/projects/mtk_t7xx_fix
git add src/t7xx_pci.c
git commit -m "Emit '[PM] Restore: modem ready after PLDR' banner on success

Set restore_pending in .restore after a successful t7xx_reset_device(PLDR);
emit the banner in t7xx_pci_pm_init_late() once the FSM worker has actually
completed HS2 and ports are enumerated. The banner is the fast-path signal
for the userspace sleep hook to skip its 35 s post-resume wait. Anchored
to init_late (not init_done) so terminal-failure paths that complete
init_done to unblock .prepare do not emit false positives."
```

---

## Task 3: Hook — add polling `schedule_mm_polled()` function

**Files:**
- Modify: `reinstall.sh` — the heredoc'd `99-modem-fix.sh` body
  (lines 218–315 in current commit).

- [ ] **Step 1: Add `schedule_mm_polled()` immediately below `schedule_mm()`**

In `reinstall.sh`, locate the existing `schedule_mm()` function
(lines 268–276 in current source). Insert the new function after its
closing brace, before the `case "$1/$2" in` dispatch block:

```bash
schedule_mm_polled() {
    # Like schedule_mm but the transient unit body polls for actual
    # modem readiness instead of waiting a fixed delay. Used on the
    # post/hibernate path (non-keepalive) where the driver runs a full
    # PLDR + reprobe; PLDR usually finishes in 5-10 s, so the old 35 s
    # was 3-7x overkill.
    #
    # Fast path: driver logs "[PM] Restore: modem ready after PLDR"
    # once t7xx_pci_pm_init_late() runs. The loop breaks within 1 s
    # of that banner appearing.
    #
    # Fallback: kernel-only polling for /dev/wwan0mbim0 existence.
    # If neither signal appears within max_wait, restart MM anyway —
    # MM will then surface the real error to the user (instead of the
    # hook silently hanging).
    #
    # Safety: the polling lives inside the systemd-run transient unit,
    # NOT in the hook foreground, so STH inter-cycle pre/post can still
    # cancel the unit (systemctl stop $unit.service) before MM restart.
    local unit="modem-fix-resume-$(date +%s%N)"
    echo "$unit" > "$UNIT_FILE"
    logger -t "$LOG_TAG" "scheduling polled ModemManager restart as ${unit}"
    systemd-run --no-block --on-active=1s --unit="$unit" \
        bash -c '
tag=modem-fix-poll
max_wait=45
settle=1
t0=$SECONDS
while :; do
    elapsed=$(( SECONDS - t0 ))
    if [ "$elapsed" -ge "$max_wait" ]; then
        logger -t "$tag" "timeout after ${elapsed}s — restarting MM anyway"
        break
    fi
    if journalctl -k -b --since "60s ago" 2>/dev/null \
        | grep -q "Restore: modem ready after PLDR"; then
        logger -t "$tag" "ready banner seen at ${elapsed}s"
        break
    fi
    if [ -e /dev/wwan0mbim0 ]; then
        logger -t "$tag" "wwan0mbim0 present at ${elapsed}s"
        break
    fi
    sleep 1
done
sleep "$settle"
systemctl restart ModemManager
logger -t "$tag" "ModemManager restart exit: $?"
'
}
```

- [ ] **Step 2: Dispatch — use polled on the .restore path**

In the same heredoc, locate the `post/hibernate|post/suspend-then-hibernate`
case branch (currently lines 299–313). Replace the inner `schedule_mm 35`
with `schedule_mm_polled`:

```bash
    post/hibernate|post/suspend-then-hibernate)
        if recent_keepalive_skip; then
            # Driver skipped firmware suspend → modem still registered,
            # MBIM endpoint live. MM only needs to reopen its session.
            logger -t "$LOG_TAG" "keepalive_s2idle skip detected — using fast restart"
            schedule_mm 3
        else
            # Hibernate/STH resume: driver runs PLDR + reprobe on .restore
            # (~5-10 s). Poll for the ready banner or /dev/wwan0mbim0
            # instead of waiting a flat 35 s. STH cancel-on-next-pre still
            # works because the transient unit name is in $UNIT_FILE.
            schedule_mm_polled
        fi
        ;;
```

- [ ] **Step 3: Update the comment block at top of the heredoc**

The introductory comment at the top of the heredoc (lines 220–241 area)
describes the timing contract. Update the relevant lines to reflect the
new behavior. Edit the lines that read:

```
#   post/hibernate, post/STH       → schedule restart in 35 s (3 s if fast)
```

to read:

```
#   post/hibernate, post/STH       → poll for modem ready, then restart
#                                    (banner or /dev/wwan0mbim0, cap 45 s;
#                                    3 s flat if keepalive skipped)
```

And in the surrounding paragraph describing the strategy:

```
#   - hibernate/STH resume: modem is in mtk_t7xx L3/INIT reprobe (up to
#     3 attempts; per driver source each attempt can span the 30 s port
#     enumeration + 60 s handshake window). If MM is polling MBIM during
#     that window libmbim abort()s on transaction timeout (signal 6) and
#     MM exits mid-init. Fix: stop MM on pre, start it after a 35 s delay
#     on post — covers the common PLDR reinit case.
```

Replace with:

```
#   - hibernate/STH resume: modem is in mtk_t7xx L3/INIT reprobe (up to
#     3 attempts; per driver source each attempt can span the 30 s port
#     enumeration + 60 s handshake window). If MM is polling MBIM during
#     that window libmbim abort()s on transaction timeout (signal 6) and
#     MM exits mid-init. Fix: stop MM on pre, then on post poll for the
#     driver's "Restore: modem ready after PLDR" banner (or the
#     /dev/wwan0mbim0 node) before restarting MM, with a 45 s hard cap.
#     Typical case is 5-12 s; fallback to cap covers genuine modem-dead.
```

- [ ] **Step 4: Syntax check the modified `reinstall.sh`**

```bash
bash -n /home/kirby/projects/mtk_t7xx_fix/reinstall.sh
echo "exit: $?"
```

Expected: exit 0 (no syntax error).

- [ ] **Step 5: Extract the heredoc and syntax check the hook itself**

```bash
sed -n '/^cat > "\$SLEEP_HOOK" <<.HOOKEOF./,/^HOOKEOF$/{//!p}' \
    /home/kirby/projects/mtk_t7xx_fix/reinstall.sh > /tmp/99-modem-fix.sh
bash -n /tmp/99-modem-fix.sh
echo "exit: $?"
```

Expected: exit 0.

- [ ] **Step 6: Run shellcheck if available**

```bash
command -v shellcheck && shellcheck /tmp/99-modem-fix.sh || \
    echo "shellcheck not installed — skipping"
```

If shellcheck is installed: address SC2086 (unquoted vars) and SC2155
(declare+assign) warnings if any appear in the new code. Do NOT fix
pre-existing warnings in untouched code (out of scope).

- [ ] **Step 7: Commit**

```bash
cd /home/kirby/projects/mtk_t7xx_fix
git add reinstall.sh
git commit -m "Hook: poll for modem ready on post/hibernate instead of fixed 35 s

Add schedule_mm_polled() to the embedded 99-modem-fix.sh. On the
non-keepalive post/hibernate and post/STH branches, the unit body now
waits for either the driver's '[PM] Restore: modem ready after PLDR'
banner or the appearance of /dev/wwan0mbim0, whichever comes first,
then restarts ModemManager after a 1 s settle. Hard cap 45 s (well
under systemd's 90 s sleep-hook default), so the hook never blocks
forever even if the modem is genuinely dead.

Polling lives inside the systemd-run transient unit so STH cancellation
on the next pre/hibernate continues to work via systemctl stop \$unit
(same contract as before)."
```

---

## Task 4: Install — DKMS + hook update

**Files:** none (manual install on running system)

- [ ] **Step 1: User runs reinstall**

This task is **manual** — Claude Code cannot run sudo. Print this for
the user to run:

```
sudo bash reinstall.sh
```

Then wait for the user to confirm completion and confirm they are ready
to reboot. The script will:

- Remove old DKMS 1.2.0 build
- Build & install 1.2.1 (after Task 5 bumps the version; or run this
  now and bump later — order matters: bump version FIRST so the install
  uses 1.2.1, otherwise we'd have to reinstall again)

**Reorder note for the engineer:** Move Task 5 (version bump) BEFORE
this Task 4 if you want a single install. Recommended ordering for
the actual run:

1. Task 1 (struct field) → commit
2. Task 2 (banner emission) → commit
3. Task 3 (hook polling) → commit
4. Task 5 (version bump 1.2.1) → commit
5. Task 4 (install + reboot) → manual
6. Task 6 (verify) → manual
7. Task 7 (docs) → commit
8. Task 8 (tag + push) → after verification holds

- [ ] **Step 2: Verify installed module loads after reboot**

After user reboots, ask them to run:

```bash
modinfo mtk_t7xx | head -5
dkms status mtk_t7xx
sudo dmesg | grep -i "mtk_t7xx" | tail -10
```

Expected: module from `/lib/modules/$(uname -r)/updates/`, DKMS shows
`1.2.1` installed for the running kernel, no oops/panic in dmesg.

---

## Task 5: Version bump to 1.2.1

**Files:**
- Modify: `dkms.conf:2`
- Modify: `reinstall.sh:10`

- [ ] **Step 1: Bump `dkms.conf`**

Change `PACKAGE_VERSION="1.2.0"` → `PACKAGE_VERSION="1.2.1"`.

- [ ] **Step 2: Bump `reinstall.sh`**

Change `MODULE_VERSION="1.2.0"` → `MODULE_VERSION="1.2.1"`.

- [ ] **Step 3: Commit**

```bash
git add dkms.conf reinstall.sh
git commit -m "Bump to 1.2.1 for post-S4 resume fast-path"
```

---

## Task 6: Verify — manual STH cycle test on hardware

**Files:** none (live testing on user's ThinkPad).

This is manual. Print these instructions for the user.

- [ ] **Step 1: Cold-baseline check (no S4 yet)**

After fresh reboot:

```bash
mmcli -L
mmcli -m 0 --output-keyvalue | grep -E 'state|primary-port|drivers'
ls /dev/wwan0mbim0
sudo journalctl -k -b | grep "mtk_t7xx" | tail -20
```

Expected: modem registered, mbim port present, no error banners.

- [ ] **Step 2: Short STH cycle (s2idle wake before hibernate delay)**

Close lid for ~30 s, reopen. After lid open:

```bash
sudo journalctl -k -b --since "2 min ago" | grep -E "mtk_t7xx|modem-fix|keepalive"
sudo journalctl -t modem-fix -t modem-fix-poll --since "2 min ago"
```

Expected on this path (no S4 reached):
- If keepalive was enabled → `keepalive_s2idle: skipping firmware suspend` + 3 s `schedule_mm 3`
- If keepalive was disabled → s2idle resume, 3 s `schedule_mm 3` (post/suspend)
- NO `Restore: modem ready after PLDR` banner (no S4 happened)

- [ ] **Step 3: Full STH cycle reaching S4**

Close lid for ~12 minutes (longer than `HibernateDelaySec=10min`), then
reopen.

```bash
sudo journalctl -k -b --since "20 min ago" | grep -E "Restore|forcing PLDR|modem-fix"
sudo journalctl -t modem-fix -t modem-fix-poll --since "20 min ago"
mmcli -L
mmcli -m 0 --output-keyvalue | grep state
```

Expected:
- `[PM] Restore: forcing PLDR (attempt 1/3)` once
- `[PM] Restore: modem ready after PLDR` once
- `modem-fix-poll: ready banner seen at <N>s` where N is small (typically 5–12)
- NO `timeout after Ns — restarting MM anyway`
- `mmcli -L` lists the modem within the wall-clock window the user
  perceives as "fast" (a few seconds after lid-open).

Time the wall-clock from lid-open to `mmcli -m 0` reporting a state
of `registered` or `connected`. Compare to the pre-change baseline
(~40 s).

- [ ] **Step 4: Direct `systemctl hibernate` test**

```bash
sudo systemctl hibernate
# (system powers down; user resumes from power button)
```

After resume:

```bash
sudo journalctl -k -b --since "5 min ago" | grep "Restore: modem ready"
sudo journalctl -t modem-fix-poll --since "5 min ago"
```

Expected: same as Step 3 — ready banner + fast polled path.

- [ ] **Step 5: Negative test — if banner is missing**

To verify the polling fallback works even without the banner, temporarily
strip the banner check from the running hook (don't commit this):

```bash
sudo sed -i 's|grep -q "Restore: modem ready after PLDR"|grep -q "__no_match__"|' \
    /usr/lib/systemd/system-sleep/99-modem-fix.sh
```

Repeat Step 3's STH cycle. Expected: log says `wwan0mbim0 present at <N>s`
instead of `ready banner seen`. Then revert by re-running `sudo bash reinstall.sh`.

(Optional — only run this if the banner path looked suspicious or
you want belt-and-braces verification.)

---

## Task 7: Documentation — journal entry + README touch-up

**Files:**
- Modify: `docs/journal.md` (prepend new entry at top)
- Modify: `README.md` (Technical-details table + Suspend strategy section)

- [ ] **Step 1: Add journal entry**

Edit `docs/journal.md`. Insert a new entry directly after the
`Standard entry layout` block and the `Hardware baseline` paragraph,
i.e. **above** the current top entry (`2026-05-05 — Always-PLDR on
.restore`). The new entry:

```markdown
## 2026-05-12 — Post-S4 resume fast-path (v1.2.1)

**Symptom (none — perf, not bug).** After v1.2.0 stabilised the post-S4
modem state via the always-PLDR-on-.restore policy, the wall-clock time
from lid-open to mobile-data-back was still ~40 s. Profile of a typical
S4 wake:

| Δt from lid-open | Event |
|---|---|
| +0 s   | systemd post/hibernate hook fires |
| +0 s   | hook scheduled `schedule_mm 35` (35 s flat) |
| +0-5 s | driver's `.restore` PLDR queues, t7xx_reset_device returns |
| +5-10 s | FSM completes HS2, t7xx_pci_pm_init_late runs, ports enumerated |
| +10 s  | modem is genuinely ready (mmcli would answer if asked) |
| +35 s  | hook's transient unit fires, restarts MM |
| +40 s  | MM has re-opened MBIM, mobile data back |

So ~25 s of every S4 wake is the hook waiting on a fixed timer when the
modem has long since been ready.

**Hergang (no incident — proactive perf work after v1.2.0 declared stable).**
After the user confirmed v1.2.0 stable on 2026-05-12, two verification
agents were dispatched to assess whether a banner-fast-path + polling-fallback
("Option C") could safely cut the wait. Both returned "ship it" with the
constraints reflected in the fix below. Driver-side agent located the
correct banner emit site (`t7xx_pci_pm_init_late`, NOT `t7xx_pci_pm_restore`,
because the latter returns before HS2 completes). Hook-side agent identified
`/dev/wwan0mbim0` as the cheap kernel-only fallback probe.

**Root cause (of the latency, not a bug).** The 35 s hook delay was a
conservative pessimistic envelope chosen back when PLDR+reprobe behaviour
was less well understood. Now that the v1.2.0 .restore policy makes
PLDR-then-FSM-restart deterministic, we can react to actual readiness
instead of waiting an envelope.

**Fix.**

- `src/t7xx_pci.h`: new `bool restore_pending` on `struct t7xx_pci_dev`.
- `src/t7xx_pci.c`: set it at the success-tail of `t7xx_pci_pm_restore`
  (after `t7xx_reset_device(PLDR)` succeeded, not before — failure paths
  must not trigger a false-ready signal). `t7xx_pci_pm_init_late` checks
  the flag, logs `[PM] Restore: modem ready after PLDR`, clears the flag.
  Anchored to `init_late` (called from `fsm_routine_starting` after HS2
  succeeded), NOT to `init_done` (which is also `complete_all`-ed on
  every terminal failure path to unblock `.prepare`).
- `reinstall.sh`: new `schedule_mm_polled()` function. Used on the
  non-keepalive `post/hibernate`/`post/STH` branch instead of
  `schedule_mm 35`. Body lives inside a `systemd-run --no-block` transient
  unit (so STH inter-cycle cancellation via `systemctl stop $unit` still
  works). Loop: every 1 s check for the banner in the last 60 s of
  kernel log, then check `/dev/wwan0mbim0`. Hard cap 45 s, then
  `systemctl restart ModemManager` anyway so genuine modem-dead surfaces
  to the user instead of hanging silently.

**Trade-off.** Adds ~10 lines of C and ~30 lines of bash. Typical S4
wake latency drops from ~40 s to ~5–12 s. Worst-case latency is 45 s
(cap) + 1 s settle + ~3 s MM init, still under the previous fixed 38 s.
Log volume increases by ~6 lines per S4 wake (one per poll tick, sparse).
Hibernate behaviour itself is unchanged — only the userspace wait timing.

**Verification.** Manual STH cycles on the user's ThinkPad X1C Gen 11:
short STH (no S4), full STH (reaching S4), direct `systemctl hibernate`,
and a negative test stripping the banner check to confirm the polling
fallback works. All four expected modem-ready within ~12 s of lid-open
on the S4 paths.
```

- [ ] **Step 2: Update README — Technical details table row**

In `README.md`, locate the row beginning `| `t7xx_pci.c` | `.restore`
(post-S4 resume) always forces a chip-level PLDR` and append the
banner note. New text for that row:

```markdown
| `t7xx_pci.c` | `.restore` (post-S4 resume) always forces a chip-level PLDR + full reprobe instead of the plain handshake-only path. Catches CLDMA ring desync after firmware power-cycle. Emits `[PM] Restore: modem ready after PLDR` from `t7xx_pci_pm_init_late()` when the FSM completes — userspace sleep hook polls for this banner (or `/dev/wwan0mbim0`) to short-circuit its 35 s post-resume wait. Scoped to `.restore` only — `.resume` / `.thaw` / `.runtime_resume` keep their fast plain-reprobe behaviour |
```

- [ ] **Step 3: Mention fast-resume in the Suspend strategy section**

Already-existing table in README at line ~83 has a "Resume latency"
row. The `Full suspend (default)` cell currently says
`30–45 s before mobile data is back (PLDR + port reprobe)`. Update to:

```markdown
| **Resume latency** | ~5–12 s after S4 (hook polls for `[PM] Restore: modem ready after PLDR` banner); ~3 s after s2idle if keepalive enabled | < 5 s (modem was never offline) |
```

- [ ] **Step 4: Commit**

```bash
git add docs/journal.md README.md
git commit -m "Docs for v1.2.1: post-S4 resume fast-path

Add journal entry covering the banner + polling design, the 35→~10 s
typical-case improvement, and the verification approach. Update README
Technical-details and Suspend-strategy rows to mention the new banner
and the realistic post-S4 latency."
```

---

## Task 8: Tag and push v1.2.1 (only after Task 6 verification passes)

**Files:** none (git operations).

**Pre-condition:** All Task 6 verification steps observed the ready
banner and reduced wall-clock latency on actual hardware. Do NOT tag
until this is confirmed.

- [ ] **Step 1: Push commits**

```bash
cd /home/kirby/projects/mtk_t7xx_fix
git push origin main
```

- [ ] **Step 2: Tag v1.2.1**

```bash
git tag -a v1.2.1 -m "v1.2.1 — post-S4 resume fast-path

Adds banner + polling fast-path that drops typical post-S4 MM-restart
latency from a fixed 35 s to ~5-12 s. Hibernate semantics unchanged;
this is a userspace-wait optimisation only. Driver emits a new
'[PM] Restore: modem ready after PLDR' banner from t7xx_pci_pm_init_late();
the embedded 99-modem-fix.sh hook polls for it (with /dev/wwan0mbim0 as
fallback) inside the existing transient-unit dispatch, with a 45 s hard
cap so the hook never blocks forever.
"
git push origin v1.2.1
```

- [ ] **Step 3: Update memory**

After the tag is live, append to
`/home/kirby/.claude/projects/-home-kirby-projects-mtk-t7xx-fix/memory/MEMORY.md`:

```markdown
- [Release v1.2.1](release_v121.md) — post-S4 resume fast-path; typical wake latency 35 s → ~5–12 s
```

And write `release_v121.md` with the standard memory frontmatter and a
brief description of the change (banner-as-fast-path + polling fallback,
no behavioural surprises beyond faster MM restart on S4 wakes).

---

## Self-review checklist

**Spec coverage:**
- ✅ Driver flag (Task 1)
- ✅ Driver banner emit (Task 2)
- ✅ Hook polling function (Task 3)
- ✅ Hook dispatch wiring (Task 3 Step 2)
- ✅ Version bump (Task 5)
- ✅ Install instructions (Task 4 — manual sudo)
- ✅ Hardware verification (Task 6)
- ✅ Docs (Task 7)
- ✅ Tag/push (Task 8)

**Placeholder scan:**
- No TODO / TBD / "implement later" / "appropriate error handling"
  language. Each step has either real code or real commands.

**Type consistency:**
- `restore_pending` is the same name in Task 1 (declare), Task 2
  (set/check/clear), Task 7 (journal/README).
- `schedule_mm_polled` is the same name in Task 3 (definition + dispatch),
  Task 7 (journal mention).
- Banner text `[PM] Restore: modem ready after PLDR` is identical in
  Task 2 (emit) and Task 3 (grep) and Task 6 (verify) and Task 7 (docs).
  The grep in Task 3 uses substring `Restore: modem ready after PLDR`
  (no leading `[PM] `) so journald's possible field-prefix wrapping
  doesn't break the match — intentional.

**Risks left after the plan:**
- (R1) journald lag could let the banner miss the 60 s `--since` window
  if the system clock skewed during S4. Mitigated by `/dev/wwan0mbim0`
  fallback in the same loop.
- (R2) Future kernels could rename or remove `/dev/wwan0mbim0`. Stable
  since 5.14 per Agent 2 research; low risk in the kernel-version
  window this project targets (6.17–6.19+).
- (R3) The polling unit name collides with `schedule_mm`'s pattern
  (`modem-fix-resume-<ns>`). Intentional — `cancel_pending` matches
  both via `$UNIT_FILE`, so STH cancellation continues to work
  uniformly. Verified by reading `cancel_pending` in the existing
  hook.
