# GSI Loader Samsung

Hot-switch between stock **One UI** and a **GSI of your choice** on a rooted Samsung phone, with no reflashing and no second partition. The GSI lives as a file under `/data/local/tmp`, boots as a container with its own zygote and system_server, and hands the screen back to One UI when you're done. Nothing is flashed, nothing touches the host system, and rebooting always lands you back on working One UI.

Current version: **6.10**.

> **Status note:** 6.10 is **build-verified only** until on-device testing
> proves it. The RestlessOS (Android 17) guest reaches `forkSystemServer`
> on device (SM-S741U1, S741U1UES2AZI7) with the 6.10 gate verified
> engaged — and the fd-64 allowlist abort persists identically, which
> exonerates the graphics-driver preload as the opener. The live wall
> is still the fd allowlist abort at the fork. Nothing below claims a
> booted home screen — the on-device verdict comes from testing, not
> from this file.

## What's new in 6.2–6.10

On-device status, stated plainly: the LineageOS 23.2 guest now reaches
`forkSystemServer` — past preload, past the APEX generation skew, past
the fd-table check. The live wall is a single abort at the system-server
fork (see 6.7–6.10). Everything below is build-verified; on-device proof
comes from testing, not from this file. Test device: Galaxy S26 FE
(SM-S741U1), build S741U1UES2AZI7, kernel 6.6.127-android15-8.

- **6.2 — OneOS panic ports.** Native feeder enumerates
  `/sys/class/watchdog` and pings every active software node; `/sys`
  is rbound (not a fresh sysfs) so the guest keeps cgroup2; `persist.*`
  properties are snapshotted before any persist write and restored on
  return, with a `persist.vendor.softdog=off` fallback. Mechanisms
  re-implemented from OneOS (see Credits) — original code in this
  tree, not copies.
- **6.3 — Boot-divergence fixes.** netd is restarted and `dnsresolver`
  re-registration awaited before the zygote loop; staged
  `settings_global.xml` is repaired (poisoned non-numeric ids removed,
  numeric ids preserved); diagnostics bundles export straight to
  Downloads with a working Share button, and boot-phase diagnostics
  (cgroup2, AID_SYSTEM, zygote-restart census) were added.
- **6.4 — Guest-derived classpaths (R1).** The guest's own
  `derive_classpath` runs after APEX mounts and its exports replace the
  baked lists (loud fallback on any failure). Zygote launcher logs
  (`zygote_exec.log`, `zygote_stderr.log`) are included in the
  diagnostics bundle and Previous Logs.
- **6.5 — Zygote stdio capture.** The starter's stdout/stderr are
  captured to `/data/zygote_stdio.log` (pipe + writer child), with
  per-attempt separators and exit-vs-signal reporting; a host logcat
  snapshot is taken at the restart cap; vold ownership/liveness is
  verified (diagnostic only). This capture is what named the
  generation-skew killer in the 6.5 run.
- **6.6 — Guest-wins APEX mounts + provenance logging.** Every APEX
  whose jars land on a boot/systemserver classpath is served from the
  guest payload (14 added to the step-8 mounts, plus a flattened-guest
  fallback); a core APEX with no guest payload logs a loud
  `APEX_SKEW_WARN` and every core APEX logs an `APEX_PROVENANCE` line.
  This fixed the 6.5 `NoSuchMethodError` (`isInZygote` — host A17
  conscrypt vs guest A16 core-libart) with the install patches OFF.
- **6.7 — Pre-exec fd-table dump + hardened fd sweep.** The launcher
  now closes every fd except 0/1/2 and the zygote socket fds out to
  1024, and dumps the full pre-exec fd table into `zygote_exec.log`.
  The 6.7 dump proved the launcher clean (exactly 5 fds at exec, no
  fd 68): the fd-68 FIFO abort is opened post-exec by ART/framework
  code, not by the launcher.
- **6.8 — Stdio mode switch + fd-check research.** The capture can run
  as a pipe (6.5 design) or a plain regular file, selected without a
  rebuild. AOSP-source research found the fork-time fd check skips
  fds 0/1/2 entirely, the FIFO type check fails before any allowlist,
  and preload-opened fds are NOT exempted at the system-server fork —
  so a FIFO opened during preload is scanned and fails. Prime
  post-exec suspect: graphics-driver preload (gated by
  `ro.zygote.disable_gl_preload`).
- **6.9 — File-mode stdio default.** File capture is now the default:
  no marker file, no env var, no root-shell step — install and Boot.
  Pipe mode stays as the opt-in A/B alternative. One change only
  versus 6.8. If the fd-68 abort persists in file mode, the next
  experiment is the graphics-driver-preload gate.
- **6.10 — App-side GL-preload gate (experiment).** The gate
  (`ro.zygote.disable_gl_preload=1`, session-scoped, snapshot +
  restore) is implemented in the app code only — no switch-script
  changes — because reads of the switch script are safety-flagged in
  this build environment. On-device result (RestlessOS, Android 17):
  gate verified engaged, abort persists identically (fd 64). The
  graphics-driver preload is exonerated as the opener; the opener of
  the second handle to the stdio log file is still unidentified.

## What's new in 6.1

ONE feature only, on top of 6.0 (engine, AnyGSI ports, watchdog handling,
slots, install flow, UI and themes unchanged):

- **Persistent per-session log history.** Every app launch is a session
  saved under the app's files dir in `log_history/<yyyyMMdd_HHmmss_SSS>/`
  (files-dir storage survives reboots; only app-data-clear or uninstall
  removes it). The Activity Log is written incrementally — every line
  appended and closed to `app_log.txt` as it arrives, so a mid-session
  reboot or panic still leaves every line up to the crash on disk.
- **Script logs captured with zero script changes.** On a clean Return
  (RETURN_OK only; RETURN_PARTIAL does not finalize), the session's
  takeover log (slot + stage), inner log (`data/takeover.log`) and boot
  diagnostics are copied from `/data/local/tmp/lineage_stage` into the
  session dir via the app's existing root helpers, and `outcome.txt` is
  written. After a reboot/crash, the next launch recovers any stage
  script logs not already preserved (attached to the unfinalized
  session, or to a new `*_recovered` dir if none exists) and marks the
  outcome unfinalized. Copies already preserved elsewhere are never
  duplicated, and recovery never overwrites. Without root, the app log
  is still recorded and script logs are noted as unavailable — launch
  is never blocked.
- **Previous Logs view.** A new "Previous logs" button in the log
  section lists saved sessions newest-first (timestamp + outcome +
  size / app-log line count); tapping one opens it read-only as a
  single scrollable view with per-source section headers. The last 20
  session dirs are kept; older ones are pruned automatically at
  startup (session dirs only). Live log streaming, save-logs,
  share-log and the diagnostics bundle export work exactly as before.
  Local-only; no log is uploaded.

## What's new in 6.0

Combined build, as ordered: the AnyGSI port (code grafts into this app —
our package, name, slots, features, and UI direction are unchanged; no
rebrand, no wholesale swap) plus a genuine visual overhaul. The two
areas are verified separately below so a regression attributes to the
right change.

### AnyGSI port (P1–P11, grafted — not adopted)

- **P1 — Native ioctl watchdog feeder.** The 5.9.16 supervision
  (supervisor + pidfile + liveness + guest kicker + host-watchdogd
  keepalive) is unchanged; only the petting method changes from shell
  open-write-close every 2 s to a native binary that holds
  /dev/watchdog open and issues WDIOC_KEEPALIVE every 5 s (write
  fallback, magic close on SIGTERM). Return kills the supervisor
  first, then SIGTERMs the binary (clean disarm) and SIGKILLs any
  remainder. Source: `src/native/watchdog_feeder.c`.
- **P2 — zygote_exec rebuilt with our lists.** Same 23.2-era
  classpaths as the 5.9.18 binary, now filtered per guest (merge env
  + defaults, expand placeholders, keep only files on disk, strip
  Samsung/Knox entries, dedupe, log to /data/zygote_exec.log), with
  stdio-to-null redirect, stray-fd close, socket setup with error
  logging to /data/zygote_stderr.log, and four exec fallbacks
  (64-bit JIT, 64-bit, 32-bit JIT, 32-bit). Source:
  `src/native/zygote_exec.c`. The 5.9.18 binary is kept outside the
  tree as a fallback reference, not in the APK.
- **P3 — Zygote restart loop, capped.** The inner script no longer
  ends the session on a single zygote death: it restarts with
  doubling backoff (2 s → 30 s cap) and gives up loudly after 5
  consecutive quick failures (ZYGOTE_RESTART_CAP_REACHED). A run
  lasting 120 s or more resets the count.
- **P4 — Aconfig handling.** Vendor/etc/aconfig overlay (overlayfs,
  tmpfs+rebind fallback), host /metadata bind, synthetic android.xr
  package data (xr.* assets), and inner-script pre-population of
  /metadata/aconfig from guest partitions + APEXes with
  aconfigd-system init steps — all best-effort, never fatal.
- **P5 — Preloaded-classes clearing.** A cleared list is bind-mounted
  over the guest's preload list at prepare time.
- **P6 — Android 17 services branch: SHIPPED DISABLED.** The
  candidate A17 services jar is binary-only with unverified
  provenance and no stock A17 services jar exists on the build VM
  to DEX-diff it against, so the gate cannot pass. The branch
  detects SDK 37 from build.prop and logs
  A17_SERVICES_PATCH_DISABLED; A17 guests boot unpatched, as in
  5.9.x. The unverified jar is NOT shipped in the APK. Enable only
  after a DEX-level comparison against stock A17 services, by
  shipping the verified jar and setting PATCH_A17_SERVICES=1.
- **P7 — Wider media codec stop list.** media.swcodec,
  mediaextractor, and Samsung's software C2 HAL service join
  media.codec/media.metrics (mediaserver stays up; Qualcomm's C2
  service is deliberately not stopped — Exynos phone).
- **P8 — APEX list filtering.** The apex-info list is filtered to
  entries whose module path exists in the guest rootfs, with
  Samsung/SEC/lifeguard entries stripped (counts logged as
  APEX_FILTER_6.0).
- **P9 — Missing partition binds.** odm_dlkm, system_dlkm, and
  config are bound when present on the host.
- **P10 — Late PermissionController bind: already present.**
  Verification during the 6.0 build found the post-APEX-payload
  second pass already in master_prepare.sh (the comparison study's
  claim was stale against the 5.9.18 tree). No change made; the
  pass is gated to 23.2 and logs loudly on failure.
- **P11 — Launcher/QS backup + restore.** backup_host.sh runs
  before the takeover stops anything (launcher databases +
  shared_prefs, appwidgets.xml, QS tiles, launcher UID) into
  /data/local/tmp/gsi_host_backup, a dir separate from the legacy
  databases restore; return restores the extras from it.
- **Deliberately NOT ported:** his app wholesale, his /data/lineage
  stage path, the S25 Ultra density-300 hardcode, his install flow,
  his unsupervised feeder launch, his uncapped restart loop, the
  microG flag, Qualcomm-specific bits, a wholesale
  framework_patched.jar swap, and any watchdogd/timeout item
  attributed to his tree (he does neither — 5.9.18 timeout control
  is our own work and stays separately attributable).
- **5.9.18 kept, not regressed:** the session-scoped kernel
  watchdog timeout control (neutralize at launch, restore on
  return) and the KEPT app boot watchdog are untouched in 6.0.

### Visual overhaul (visual only)

Genuinely redesigned, not another recolor: larger card radii with
outline strokes, true pill chips, 24 dp section rhythm, emphasized
section eyebrows, taller 52 dp primary buttons, larger flavor-card
padding, and a taller, roomier log console (220 dp). ZERO function
changes, ZERO ID renames/removals — every button works exactly as
before, and the skin/theme system works with the new look
unchanged (skin drawables untouched).

### Still needs on-device proof

- Feeder log showing the native ioctl binary alive through a
  session; session past 2 minutes.
- Zygote restart lines on a guest crash (and the cap line on a
  boot loop, not a spin).
- Aconfig pre-population lines + an A17 guest reaching home.
- A17_SERVICES_PATCH_DISABLED on an SDK 37 guest (expected until
  the jar is verified).
- Full UI regression: every button works, skins/themes render,
  Experimental dialog renders.
- 5.9.18 proofs still outstanding: timeout DISABLED/SET_MAX on
  launch, RESTORED on return.

## What's new in 5.9.18

- **Kernel watchdog timeout removed for sessions (session-scoped).**
  At guest launch, the kernel watchdog timeout (softdog "Software
  Watchdog Timer expired", ~100 s) is neutralized for the session only:
  the original timeout is recorded, then the driver is asked to disable
  (0) or take its maximum, via the sysfs timeout store (the same
  watchdog_set_timeout WDIOC_SETTIMEOUT uses). On return, the original
  timeout is restored and verified by read-back; a reboot resets it to
  the driver default on its own, so the scope holds even if return
  never runs. Host protection is intact outside sessions — this is NOT
  a permanent disable.
- **Failure is loud, fallback kept.** If the driver rejects timeout
  control, the session logs WATCHDOG_TIMEOUT_CONTROL_UNAVAILABLE and
  falls back to the 5.9.16 supervised feeder + guest kicker — it never
  pretends the timeout is gone.
- **Tradeoff, plainly:** while the timeout is neutralized, a genuine
  guest/host hang will NOT auto-reboot — force-restart manually
  (power + volume down). The app boot watchdog (10 min) is KEPT and
  is the only auto-return net during sessions: a guest that never
  reaches home still returns to One UI automatically. Manual Return
  is unchanged.
- **Still needs on-device proof:** the launch lines
  (WATCHDOG_TIMEOUT_DISABLED or WATCHDOG_TIMEOUT_SET_MAX), the return
  line (WATCHDOG_TIMEOUT_RESTORED), and a session past the old 100 s
  panic point.

## What's new in 5.9.17

- **The log actually scrolls now.** The 5.9.14 smart-follow gate could
  never re-open once content grew past the viewport + 80px slack, so the
  log froze at its first screenful and every tap looked dead. Following
  is now pin-aware: it follows the tail live unless you park the log
  above the tail by hand, and the log box keeps its own drags instead of
  losing them to the page scroll.
- **Reinstall works a second time.** A good install used to delete the
  picked cache file while the UI still pointed at it, so every later tap
  failed instantly with LOCAL_FILE_MISSING — invisible in the frozen log.
  The picked file is kept now, and a tap on a file that is genuinely gone
  refuses loudly ("pick the file again") instead of queueing a ghost task.
- **One install at a time.** Taps during a running install no longer queue
  duplicate wipe + install jobs; they log "already running" and return.
  The corrupt-download retry hands the guard to its retry task instead of
  fighting it.
- **Progress text stops lying.** The install-progress poller now owns a
  generation that completion bumps, so a late "Installing: ..." post can
  never overwrite the final "Installed" / "Install failed" text, and the
  progress file is reset in Java before each run so a poller can never
  replay a previous run's lines (including its "done") over a new run.
- **Light UI refresh + clean build.** Main-screen description walls are
  cut down, the Activity Log header matches the other section titles,
  same 5.9.5-derived design and skins, every button and function
  untouched. This build was compiled from wiped intermediates (build/
  deleted first, old APK deleted first), and the finished APK was
  verified fresh: its dex carries the new methods and log strings, its
  compiled layout carries the new short texts, and badging reads
  code 31 / 5.9.17.

## What's new in 5.9.16

- **Install-button fix.** Selecting a local file / Custom flow and tapping
  Install previously did nothing; the picker → copy → Custom → installGsi
  precondition/enablement path is fixed.
- **Safe watchdog fix (no watchdog disabling).** Watchdog reboots stop via
  reliable kicking, NOT by permanently disabling the host watchdog (that
  would leave the real phone unprotected): watchdog feeder hardening
  (verify the node, log write success/failure, supervise the feeder, kill
  it on return, start it after the kill spree), a guest-side kicker, and
  container hardening. The 10-min app watchdog still cannot save a 100 s
  kernel panic — the kick path is the fix.
- **Rollback atomicity.** System and data are staged and committed together
  (marker file), so a failed data stage can no longer leave system and
  data from different generations.
- **Verify with a structural verdict.** The mount check is mandatory when a
  loop device is available; when mounting was never attempted the result
  is VERIFY_STRUCTURAL, not VERIFY_OK — a file with right magic + size no
  longer "verifies OK" without a mount check.
- **Fail-closed guards.** Guard checks that throw no longer let the
  operation proceed.
- **Hash sync.** Asset/engine sync compares hashes, not lengths alone, so a
  same-length stale or corrupt asset/binary is no longer skipped.
- **Robust home detection.** The boot watchdog no longer depends on one
  string in one log file alone.
- **Separate streaming thread.** Log streaming/polling runs off the
  single-thread executor, so a hung stream cannot wedge install/boot/wipe.
- **Dead flags removed.** DEV_OPTIONS_FIX and the dead IMS/CODEC env vars
  are gone from UI/docs — they never did anything (the script explicitly
  ignored DEV_OPTIONS_FIX). Do not document them as features.
- **Return per-step reporting.** A partial return now names the stuck
  piece (unmounts remaining, which service failed to restart, SELinux
  read-back) instead of a bare RETURN_PARTIAL.
- **Kill census.** The takeover logs which target PIDs are gone and which
  survived the kill spree.
- **Per-service health checks.** Guest surfaceflinger/vold/wificond are
  verified alive (pid + service check) before zygote_exec, and a failure
  names WHICH service failed.
- **Install progress markers.** Long install steps (extraction,
  conversion) emit progress the UI polls, instead of a spinning bar for
  minutes.
- **Sweep logging.** The install sweep logs every path (name + size)
  before deleting it.
- **Format guidance.** Rejected formats print the exact conversion to do
  (e.g. zstd -d, lpunpack step) instead of a bare rejection.
- **Mirror fallback.** Preset downloads fall back to a direct SourceForge
  URL on mirror failure and record which mirror served the file.
- **Pre-install fit/boot report.** Free space, detected image Android
  version vs host vendor version, and a plain warning when GSI < vendor,
  before boot.
- **Slot reconcile.** A single records-vs-on-disk reconcile runs at launch,
  logging and repairing drift, instead of per-path cleanup logic.
- **Per-slot last-boot record.** Each slot records home reached / watchdog
  timeout / reboot / return, shown in the slot picker.
- **Diagnostics extension + bundle export.** Boot diagnostics now cover
  watchdog-node state, feeder liveness, SELinux mode, and DEFEX/RKP lines;
  the Experimental menu exports a one-tap diagnostics bundle (app log +
  takeover log + inner log + boot_diagnostics + pstore excerpt + device
  info).
- **Guide correction.** The "COMPATIBILITY PATCHES" guide paragraph now
  states the actual gating (detectFrameworkVersion reading the guest
  build.prop), not "patches turn on by themselves only for the 23.2
  presets" — preset origin and detected version are different mechanisms
  and can disagree on a renamed/repacked image.
- **detectFrameworkVersion keyed grep.** build.prop parsing is keyed, not
  positional, so a missing key no longer shifts every field.
- **Strings audit.** Unreferenced legacy strings removed.
- **Build parameterization + keystore out of tree.** See Building below.
- **Post-build gate + make dist.** `verify_apk.sh` gates every build
  (badging, apksigner verify + cert fingerprint, manifest component,
  asset hash list); `make_dist.sh` produces the delivery zip.
- **Docs.** New ARCHITECTURE.md (mechanism trace), PATCHES.md (patched
  artifact provenance, with the class-level diff honestly marked OPEN),
  TROUBLESHOOTING.md (symptom → evidence ladder).

> **Fork note:** GSI Loader Samsung is a fork of **OneLineage** by **WeWaffles** (https://github.com/WeWaffles/OneLineage). OneLineage proved the concept: a LineageOS GSI running as a container on a bootloader-locked Samsung. This fork keeps that core mechanism exactly as it was and rebuilds everything around it. Original authors keep full credit below.

## How it works

The app stages the GSI as `system.raw`, loop-mounts the guest rootfs read-only, and pivots into it, binding the host's `/vendor`, `/odm`, `/dev`, `/linkerconfig`, and APEX. Takeover stops only the host zygote (with `setenforce 0` during the switch); the guest runs on the host kernel and the host vendor HALs, always. Returning restores the host zygote and `setenforce 1`. The patched LineageOS 23.2 framework/services jars and PermissionController patch are bind-mounted only for 23.2 images — they are version-coupled and stay off for anything else.

## What this fork does that stock OneLineage doesn't

Stock OneLineage v5.7 is one LineageOS 23.2 GSI, one install, a basic UI, an installer that mounts ext4 only (hardcoded), and patch binds with no checks at all. This fork changes all of that:

- **Any GSI, not just Lineage 23.2.** Install a local file, download a preset, or grab any Treble image. The installer handles raw ext4 and EROFS, converts sparse images with a bundled `simg2img`, validates the format before touching anything, checks free space (sparse images expand 2–4x), and installs atomically — a failed install never destroys the working `system.raw`.
- **Named slots.** Multiple staged GSIs, each with its own `system.raw`, rootfs, and guest data under `/data/local/tmp/lineage_stage/slots/<name>/`. Create, delete, duplicate, wipe guest data only, and back up / restore per slot. The Default slot is the original single install, unchanged.
- **Snapshots and rollback.** Snapshot a slot before you break it, roll back when you do.
- **A shared folder** (`/sdcard/GSI_Shared`) both sides can see, plus a guest density setting.
- **A real UI.** 8 color themes plus extra skins, a separate UI styles menu (Stage / Compact / Focus / Wide), animations, colorful progress bars for each major function, an in-app boot menu, and a "How to use" guide. The Experimental menu is a themed dialog, not a plain list.
- **Diagnostics that actually exist.** Live log streaming with a log view you can scroll by hand (it follows the tail only while you're already watching it), kernel log snapshots, live logcat (errors-only and full), takeover log tails, boot diagnostics on demand, pstore panic checks, guest process lists, RescueParty status and toggle, and a device info dump that works without root. Tools that need root say so plainly instead of failing silently.
- **Boot safety nets.** A boot watchdog (no home screen in 10 minutes returns to One UI with the guest preserved), a clean-slate button that really empties the stage including dotfiles and stale mounts, and a battery display with install guards.
- **Root awareness.** The app shows whether root is available, which `su` binary is in use, and whether KernelSU-Next is detected, with a re-check button. Guest root access works through the host su bind. When root is absent, the app points at the unrooted path (Root-My-Galaxy-Next, KernelSU generic payload) instead of pretending everything is fine.

What didn't change: the container mechanism itself. That part is WeWaffles' work, and it still works the way it always did.

## Install and boot

1. Get root (temp root is fine — the container needs root for loop mounts, binds, and zygote control).
2. Install a GSI into a slot: pick a local file, download a preset, or use the LineageOS 23.2 presets (Vanilla / GAPPS, MisterZtr builds). Downloads pause and resume. There is a wipe-userdata-after-install toggle, default off.
3. Boot the slot. Patches apply automatically for 23.2 images only; anything else boots with its own files untouched.
4. Return to One UI from the app. If a guest ever hangs, the watchdog brings you back; if it reboots the phone on its own, re-apply temp root and relaunch the app before tapping anything — the diagnostics from the failed boot surface on launch.

A generation-matched GSI works best: an Android 17 guest on an Android 17 host. An Android 16 guest on an Android 17 vendor can fail where the guest framework meets the host's vendor HALs, and no app code can fix that gap.

## Requirements

- A rooted Samsung phone (temp root works)
- Enough free space on `/data` for the staged GSI plus headroom
- A GSI image: raw ext4, EROFS, or sparse (converted on install). `super.img` is not supported.

## Known limits (honest)

- Guest voice calls do not work (no IMS stack in the guest; the IMS keepalive helps data/SMS lean on One UI's `imsd`, it is not real IMS passthrough)
- Returning to One UI may still need a manual reboot in some cases
- The host's `media.codec` AIDL hash can differ from the guest's, which can cause high CPU during codec enumeration
- Guest Developer options can crash; DTMF and deep-buffer audio can glitch
- Guest root is via the host su bind — a native guest su daemon is not in place
- Snapshots are manual; there is no auto-snapshot yet

## Building (Linux)

Run `build_apk_linux.sh` (JDK 17, Android SDK build-tools 34.0.0,
android-34 platform, aapt2, javac `-encoding UTF-8 -source 1.8 -target
1.8`, d8, zipalign, apksigner — toolchain behavior unchanged in 5.9.16).
Paths are parameterized via environment variables with defaults resolving
to the current VM layout, so an unset environment builds exactly as
before: `GSI_PROJECT_DIR` (default: the script's directory),
`GSI_SDK_ROOT` (default `/home/hatch/workspace/onelineage/android-sdk`),
`GSI_JDK` (default the Temurin JDK 17, else apt JDK 17, else javac on
PATH), `GSI_OUT_APK` (default
`$GSI_PROJECT_DIR/../GSI-Loader-Samsung.apk`), `GSI_KEYSTORE` (default
`$GSI_PROJECT_DIR/../gsi-loader.keystore`).

Signing: the keystore lives OUTSIDE the tree at
`~/workspace/onelineage-generic/gsi-loader.keystore` (alias
`androiddebugkey`, cert SHA-256
`3f4ed94497375a9fbe998dd82b265f65d0c5152baf11f11da9ec0397b85f883f`), so
5.9.16 updates cleanly over 5.9.15. The build script REFUSES to
auto-generate a keystore when the file is missing — a fresh keystore would
silently change the cert and break update-over-install. If the build fails
on a missing keystore, set `GSI_KEYSTORE` to the relocated keystore; never
generate a new one to "fix" the build. Keystores must never appear in a
source zip (see `make_dist.sh`, which scans for and refuses them).

Build order: `./build_apk_linux.sh` → `./verify_apk.sh <apk>`
(post-build gate: badging package/versionCode/versionName, apksigner
verify + cert fingerprint, MainActivity manifest component, asset hash
list — any miss fails loudly) → `./make_dist.sh <apk>` (delivery zip: APK
at top level + `GSI-Loader-Samsung-source/` with src, res, assets,
manifest, build scripts, and docs; keystores, build/, .git, and probe-av
excluded; prints byte size + SHA-256).

Package is `com.cronch.gsiloader` (renamed from `com.wewaffles.onelineage` in 5.9.2). Because the package changed, this installs as a fresh app alongside any older build — uninstall the old one when ready. The staged GSI in `/data/local/tmp` is shared, so the new app sees the already-installed image; app preferences reset to defaults on first run.

## Credits

- **Original OneLineage project by WeWaffles** — https://github.com/WeWaffles/OneLineage
- **LineageOS GSI builds by MisterZtr** (SourceForge)
- **6.0 AnyGSI grafts (P1–P11): code grafted from AnyGSI by soundgram-project** — https://github.com/soundgram-project/AnyGSI — **mechanisms re-implemented/grafted into this tree's own scripts and native code, not a wholesale adoption of his app**
- **6.2 panic ports, 6.3 boot-divergence fixes, 6.4 guest-derived classpaths: mechanisms re-implemented from OneOS by fahadalijaved** — https://github.com/fahadalijaved/OneOS — **original implementations in this tree's own scripts/native code, not copies of OneOS files** (OneOS's NOTICE limits reuse of its OneLineage-derived files to OneOS's own publication; the mechanisms are credited here, the code is ours)
- LineageOS and Android are trademarks of their respective owners. Not affiliated with Samsung, Google, or LineageOS.
