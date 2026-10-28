# GSI Loader Samsung

Hot-switch between stock **One UI** and a **GSI of your choice** on a rooted Samsung phone, with no reflashing and no second partition. The GSI lives as a file under `/data/local/tmp`, boots as a container with its own zygote and system_server, and hands the screen back to One UI when you're done. Nothing is flashed, nothing touches the host system, and rebooting always lands you back on working One UI.

Current version: **5.9.15**.

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

Edit the paths at the top of `build_apk_linux.sh` (JDK 17, Android SDK build-tools 34.0.0, android-34 platform), then run it. It produces a debug-signed APK with the same debug key across builds, so upgrades install cleanly over previous versions. Package is `com.cronch.gsiloader` (renamed from `com.wewaffles.onelineage` in 5.9.2). Because the package changed, this installs as a fresh app alongside any older build — uninstall the old one when ready. The staged GSI in `/data/local/tmp` is shared, so the new app sees the already-installed image; app preferences reset to defaults on first run.

## Credits

- **Original OneLineage project by WeWaffles** — https://github.com/WeWaffles/OneLineage
- **LineageOS GSI builds by MisterZtr** (SourceForge)
- **Fork and ongoing work by [crabcakes97](https://github.com/crabcakes97)**
- LineageOS and Android are trademarks of their respective owners. Not affiliated with Samsung, Google, or LineageOS.
