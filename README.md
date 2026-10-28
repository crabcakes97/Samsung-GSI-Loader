# GSI Loader Samsung

Hot-switch between stock **One UI** and a **GSI of your choice** on a rooted Samsung phone, with no reflashing and no second partition. The GSI lives as a file under `/data/local/tmp`, boots as a container with its own zygote and system_server, and hands the screen back to One UI when you're done. Nothing is flashed, nothing touches the host system, and rebooting always lands you back on working One UI.

Current version: **5.9.17**.

> **Status note:** 5.9.17 is **build-verified only** until on-device testing
> proves it. Nothing below claims on-device success for 5.9.17 — the
> changes are listed as shipped in the build, and the on-device verdict
> comes from testing, not from this file.

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
- LineageOS and Android are trademarks of their respective owners. Not affiliated with Samsung, Google, or LineageOS.
