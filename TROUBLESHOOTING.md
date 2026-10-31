# Troubleshooting (5.9.16)

Symptom → evidence mapping. The rule for every symptom below: **capture the
evidence before you reboot, re-install, or wipe anything** — most of this
evidence is report-once or lives in logs that the next boot overwrites. Work
the ladder cheapest-first: pstore verdict, then the diagnostics bundle, then
live session state, then the discriminating boot test.

Paths: stage root is `/data/local/tmp/lineage_stage`; a slot's files live
under `slots/<name>/` (Default slot = the stage root itself). App-side logs
are in the app's log view; script logs are named below.

> Status note: 5.9.16 is build-verified only until on-device testing proves
> it. Nothing in this file claims a symptom is fixed on-device — it tells
> you what to capture so a fix can be proven.

## 1. Boot animation forever (guest never reaches home)

What it usually means: the guest started (animation runs) but something in
the guest never finished — a service never came up, system_server is
crash-looping, or a HAL wait never resolves. A16-guest-on-A17-vendor skew
is a leading suspect, but it is not the only one.

Capture, in order:

1. **Boot diagnostics bundle** — Experimental menu → boot diagnostics, or
   read `<slot>/boot_diagnostics.log`. It contains: fs type from magic,
   stage mounts (head-30), takeover log tail-60, inner log tail-60,
   watchdog log tail-40, logcat crash buffer tail-40, logcat system
   FATAL/AndroidRuntime/EIO/erofs tail-40, dmesg erofs tail-20, guest
   processes (head-10).
2. Read the bundle for the cut point:
   - Takeover tail shows a failure (mount failure, PATCH_BIND_FAILED) →
     prepare-stage cause.
   - Inner tail stops before the zygote_exec launch line → pivot/exec
     cause.
   - Guest services started (surfaceflinger/bootanimation/vold/wificond
     lines present) but no home → guest-side hang; look at the logcat
     system lines for a system_server crash loop or HAL wait.
3. **Guest service state** (needs a guest session up + guest root shell):
   guest system_server alive? `service list` from the guest side? A guest
   that never starts system_server vs one that starts it and crash-loops
   are different bugs with different fixes.
4. If the app's 10-min watchdog fires while you watch: note whether the
   bundle was captured BEFORE return (it should be — the watchdog captures
   it, then returns with the guest preserved). The app surfaces the bundle
   head-200 per slot on next launch, then deletes bundle + timeout marker
   (report-once) — copy it out before dismissing it.

Do NOT force-restart mid-diagnosis if you can avoid it: a force-restart
destroys the live session state and leaves only the pstore verdict (below)
to work with.

## 2. Full-device reboot during a guest session

This is the most important symptom to get right, because three different
causes look identical ("the phone rebooted") and only the pstore verdict
tells them apart. **Do not guess watchdog vs erofs vs RescueParty.**

Capture (cheapest, decisive — do this FIRST):

1. Re-apply temp root, then launch the GSI app **before tapping anything**.
   The launch sweep runs `pstore_check.sh` when a stale marker was cleared
   and surfaces the verdict in the app log. Copy the verdict + excerpt out
   immediately — it is report-once via `/data/local/tmp/pstore_consumed`
   (path + hash), so an already-reported panic never resurfaces, and the
   full excerpt is not kept unless you save it.
2. Read the verdict wording:
   - `PSTORE_PANIC` + excerpt contains **"Software Watchdog Timer
     expired"** → kernel softdog watchdog fire: nobody wrote to the
     watchdog device for the full 100 s. The kicker path (feeder and/or
     host watchdogd) was dead or missing — see §3. If the guest had
     demonstrably reached home first, the kicker itself is the problem
     (watchdog as cause); if the guest never started system_server AND the
     feeder is proven alive, the hang must have broken kicking some other
     way (mechanism still open — say so, don't invent one).
   - `PSTORE_PANIC` + `EROFS_HINT` (trace mentions erofs) → erofs/loop
     lines are the tie-breaker toward a filesystem-driver cause. Note:
     ext4 guests panic too (matched-version case), so erofs lines alone do
     not prove erofs is the cause — they only point at it.
   - `PSTORE_NO_PANIC` → NOT a kernel panic: RescueParty / userspace /
     manual reboot. Look at RescueParty status (Experimental menu) and the
     boot diagnostics bundle instead of the watchdog path.
   - `PSTORE_EMPTY` / `PSTORE_UNAVAILABLE` → pstore is not usable on this
     kernel; move to live capture (§3) — do not treat "no pstore" as "no
     panic".
3. Caveat, stated in the script itself: an earlier host crash's panic could
   still be sitting in pstore and be misattributed to the guest session.
   EROFS/loop lines in the excerpt are the tie-breaker, not proof.

## 3. Watchdog timeout (100 s panic, or 10-min app watchdog return)

First, be precise about WHICH watchdog fired — they are different things:

- **100 s, full-device reboot, "Software Watchdog Timer expired" in
  pstore** = kernel softdog. The app's 10-min watchdog cannot save this
  (the kernel panicked long before 10 min). The fix lives in the kick path:
  feeder hardening + guest-side kicker + container hardening (5.9.16), NOT
  in disabling the host watchdog (that would leave the real phone
  unprotected).
- **10 min, clean return to One UI, guest preserved, `<slot>/
  boot_watchdog_timeout` marker** = app boot watchdog. It fires when the UI
  Activator never wrote "Home activated!" to
  `/data/local/tmp/ui_activator.log`. If the guest actually reached home by
  another path, or the UI Activator died before writing the string, this is
  a FALSE timeout returning a healthy guest — check the UI Activator log
  before concluding the guest failed.

Live-session evidence (needs a guest session up + a host root shell; run at
30 s, 90 s, 150 s into a session if possible — a feeder alive at 30 s and
dead at 150 s is the smoking gun):

- `ls -l /dev/watchdog*`
- `cat /sys/class/watchdog/watchdog*/identity` (which device is softdog)
- `cat /sys/class/watchdog/watchdog*/timeout` (what timeout is configured)
- `ps -ef | grep -E "watchdogd|/dev/watchdog"` (is host watchdogd and/or
  the fork feeder alive mid-session?)
- A test write to /dev/watchdog — does it succeed, or EBUSY (host
  watchdogd already holds the node open, making the feeder a silent no-op)?

Also capture in the same round: the **"SELinux mode:"** line from
`<slot>/takeover_app.log` (Permissive vs Enforcing — if setenforce 0
failed, SELinux denials are a live suspect), and dmesg **DEFEX** / RKP /
sec_watchdog lines (DEFEX denials would implicate a later root exec being
blocked; `setenforce 0` does NOT disable DEFEX). The Experimental menu
already has a kernel-log snapshot (last 200) and live `dmesg -w` — use
those, no new tooling needed.

What does NOT explain a 100 s panic, so you can stop chasing it: RKP (would
name RKP, not softdog), TIMA (passive measurement, kills nothing),
sec_watchdog as executioner (would print its own message, not the softdog
string), and "the guest hung" on its own (a guest hang does not stop
host-side kicking without a second mechanism).

### 5.9.18: kernel watchdog timeout control (session-scoped)

5.9.18 narrows the 5.9.16 "do not disable" rule deliberately: the
kernel watchdog timeout is neutralized DURING SESSIONS ONLY, then
restored. At guest launch, switch_to_gsi.sh records each watchdog
node's original timeout to
`/data/local/tmp/gsi_watchdog_timeout.orig`, then asks the driver to
disable (0) or take its maximum via the sysfs timeout store (the same
watchdog_set_timeout WDIOC_SETTIMEOUT uses). return_to_oneui.sh writes
the originals back and verifies by read-back. A reboot resets every
timeout to the driver default on its own, so the host is never left
permanently unprotected.

What to look for in `<slot>/takeover_app.log` at launch:
WATCHDOG_TIMEOUT_ORIGINAL (node + original value),
WATCHDOG_TIMEOUT_DISABLED (0 stuck) or WATCHDOG_TIMEOUT_SET_MAX
(value achieved), and on return WATCHDOG_TIMEOUT_RESTORED. If you see
WATCHDOG_TIMEOUT_CONTROL_UNAVAILABLE instead, the driver rejected
timeout control and the session runs on the 5.9.16 feeder + guest
kicker — do NOT assume the timeout is gone.

The app boot watchdog (10 min auto-return) is UNCHANGED in 5.9.18: it
is a userspace return trigger, not a kernel panic source, and it
remains the only auto-return net during sessions. Removing it would
only remove auto-return; it would not fix a kernel panic.

Tradeoff: with the kernel timeout neutralized, a genuine hang during
a session will NOT auto-reboot — force-restart manually (power +
volume down) or tap Return. Outside sessions the host timeout is
restored, so host protection is intact.

## 4. Return partial (RETURN_PARTIAL, or "return may need manual reboot")

`return_to_oneui.sh` verifies (no rootfs mount, zygote running, Enforcing)
and reports RETURN_OK, else RETURN_PARTIAL + exit 1. 5.9.16 logs each
restore step's result, so a partial return now names the stuck piece —
capture that per-step report instead of just "partial":

- Which unmounts remain (unmount loop runs 50 passes over stage rootfs
  mounts)?
- Which services failed to restart (surfaceflinger / zygote / audioserver /
  cameraserver / media / media.extractor / media.metrics / wificond)?
- What is the SELinux mode read-back (Enforcing expected)?
- Is the launcher DB restore on the UID/GID-from-stat path or the 10160
  fallback (fallback is logged loudly in 5.9.16 — a wrong-UID restore
  silently corrupts the home layout)?

Java light path: if the liveness guard says no guest is running anywhere,
the app just clears stale markers and reports "Already in One UI" without
touching host services — that is the intended behavior, not a failed return.

If return is stuck and nothing else works, `--reboot` reboots after
best-effort return, and a plain reboot always lands back on working One UI
(nothing is flashed).

## 5. Install failures

Work through these in order — most "install failures" are format confusion
or a corrupt download, not a broken installer:

1. **Install button does nothing** (the 5.9.16 bug report: selecting a
   local file / Custom flow → Install does nothing): capture the app log
   around the tap (picker → copy → Custom → installGsi preconditions →
   enablement state). 5.9.16 fixes the Install-button path; if it still
   does nothing on 5.9.16, the log around the tap is the whole diagnosis —
   report the exact precondition that failed, not just "nothing happened".
2. **DOWNLOAD_CORRUPT**: `7zz t` failed on the archive. Java auto-retries
   once (download path only). Check whether a mirror served a bad file:
   presets are SourceForge `use_mirror=autoselect` (mirror-dependent);
   5.9.16 falls back to a direct SourceForge URL on mirror failure and
   records which mirror served the file.
3. **UNKNOWN_FORMAT / unsupported**: `super.img` is rejected by name (no
   lpunpack — convert with lpunpack on a PC first). `.zst` / raw `.lz4` /
   `.br` are rejected (bundled 7zz 23.01 limits — decompress first, e.g.
   `zstd -d`). ROM zips are rejected (no sdat2img). 5.9.16 prints the exact
   conversion to do instead of a bare rejection line.
4. **AMBIGUOUS / MULTIPLE_IMAGES**: the candidate list is logged — check
   which `*.img` files were in the stage dir. Note the installer sweeps
   every `*.img` at any depth + every file >100 MB in the stage dir before
   extraction (5.9.16 logs every swept path first); anything you stored in
   the stage dir is deleted, by design — keep personal files out of it.
5. **CANDIDATE_EMPTY / size weirdness**: historical root cause was 32-bit
   overflow on raw byte sizes; the installer now uses awk doubles and never
   a shell integer test on byte sizes. If it recurs, capture the exact
   candidate sizes from the log.
6. **"Will it fit / will it boot"**: 5.9.16 reports free space, detected
   image Android version vs host vendor version, and a plain warning when
   GSI < vendor ("this guest is older than your vendor; expect HAL
   trouble") BEFORE boot. An A16 guest on an A17 vendor failing at the
   framework/HAL boundary is expected behavior, not an installer bug.
7. **A failed install never destroys a working image**: the working
   `system.raw` is never touched during install (copy to `system.raw.new`,
   size-check, rename). If a previously working slot stops booting after a
   failed install of a DIFFERENT slot, capture the slot's stage dir listing
   — that is a different bug from install corruption.

## 6. The discriminating test (when the ladder hasn't settled it)

If pstore + bundle + live state still leave watchdog-vs-skew open, run the
A17 two-bar test: Google A17 GSI (QPR3 Beta no-GMS first, QPR1 fallback, or
RestlessOS QPR0), local file, NEW SLOT, patches off.

- Bar one: reaches home.
- Bar two: stays up past ~2 min.
- Bar-one-pass + bar-two-fail = watchdog gap (kicker fix territory).
- Both fail = guest/kernel-level problem (or a second watchdog).
- Both pass = skew was the trigger on this phone (plus kicker verified
  working).

DSU is a diagnostic vehicle only, not a product replacement: it sidesteps
the container (real guest init, real services) but is likely
signature-blocked for Lineage on a locked bootloader, and Samsung's
acceptance of Google-signed GSIs on this phone is unverified. If a
DSU-booted A17 stays up past 2 min, the container is indicted; if it still
panics at 100 s, the problem is guest/kernel-level. DSU needs ~10 GB free +
dynamic partitions + a DSU loader (`com.android.dynsystem`) — verify the
loader exists before promising anything.

## 7. 6.0 log markers (new in this build)

- `WATCHDOG_FEEDER: native ioctl feeder staged` — the P1 binary was
  staged; if you see the "missing from $STAGE" line instead, the
  supervisor fell back to the shell worker (check the asset sync).
- `WATCHDOG_FEEDER_KILL: native feeder SIGTERM sent (magic close)`
  on return — the binary stopped cleanly. A remainder SIGKILL line
  after it means the binary ignored SIGTERM.
- `zygote_exec exited with code N after Ns` + `ZYGOTE_RESTART_CAP_REACHED`
  — the P3 loop. A cap line with N=1 and tiny Ns means the new
  zygote_exec binary itself is failing; check
  `/data/zygote_stderr.log` and `/data/zygote_exec.log` before
  anything else.
- `ACONFIG_OVERLAY_OK` / `ACONFIG_OVERLAY_FAIL`,
  `PRELOADED_CLASSES_CLEARED`, `APEX_FILTER_6.0: kept K, dropped D`
  — P4/P5/P8 prepare steps. A dropped count of 0 on a foreign guest
  is suspicious (the filter may not have run); a large dropped
  count is expected on a host list full of Samsung entries.
- `A17_SERVICES_PATCH_DISABLED` on an SDK 37 guest is EXPECTED in
  6.0 (P6 ships disabled — the jar is unverified). It is not a bug
  report; an A17 guest booting unpatched is the designed behavior
  until the jar is DEX-verified.
- `HOST_BACKUP_6.0` at takeover, `shared_prefs restored (6.0 host
  backup)` / `appwidgets.xml restored` / `Quick Settings tiles
  restored` on return — P11. Missing backup lines mean
  backup_host.sh was absent from the stage (asset sync issue).

## 8. Evidence checklist (copy this into a bug report)

- [ ] App version + versionCode (5.9.16 / 30)
- [ ] Slot name + GSI (preset or local file, Android version, ext4/erofs)
- [ ] Symptom (§1–§5 above) + time into the session when it happened
- [ ] Pstore verdict verbatim (PSTORE_PANIC / NO_PANIC / EMPTY /
      UNAVAILABLE) + excerpt lines, if a reboot happened
- [ ] Boot diagnostics bundle (`<slot>/boot_diagnostics.log`) or its
      head-200 as surfaced by the app
- [ ] Takeover log tail (`<slot>/takeover_app.log`, `$STAGE/data/
      takeover.log`) — especially the "SELinux mode:" line and IMS gate
      outcome
- [ ] UI Activator log (`/data/local/tmp/ui_activator.log`) — was "Home
      activated!" written?
- [ ] Live session state if captured (watchdog node, identity, timeout,
      feeder/watchdogd ps lines at 30/90/150 s)
- [ ] dmesg DEFEX/RKP lines if any
- [ ] Per-step return report if RETURN_PARTIAL
- [ ] Diagnostics bundle export (Experimental menu, 5.9.16) attached if
      available — this replaces pasting fragments
