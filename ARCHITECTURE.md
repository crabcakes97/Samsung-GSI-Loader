# GSI Loader Samsung — Architecture (5.9.16)

Condensed from the full study report (v5.9.15 tree). This is the mechanism in
one place: install → switch/takeover → prepare → inner/pivot → guest session
→ return → guards / watchdog / diagnostics. If this file and the code ever
disagree, the code wins and this file must be fixed.

Package: `com.cronch.gsiloader`. Single activity (`MainActivity`, ~5,050
lines) plus shell scripts in `assets/`. Nothing is flashed; rebooting always
lands back on working One UI.

## The one fact that drives everything

**No guest init ever runs. PID 1 stays the host's init.** The guest is a
container, not a booted OS: the takeover stops host services, bind-mounts a
guest rootfs, and manually starts a handful of guest services. The guest has
no init, no init.rc service startup, no watchdogd of its own, no ImsService,
and no guest su daemon. Everything that would normally be init's job is
either done by host daemons, done by the takeover scripts, or simply missing
— and the missing pieces (especially watchdog kicking) are where the real
failure modes live. See "Watchdog" below.

## Install — `assets/install_image.sh`, driven by `installGsi`

1. Integrity test first: `7zz t` on the archive; failure → DOWNLOAD_CORRUPT
   (Java auto-retries once, download path only).
2. Full stale sweep: every `*.img` at any depth + every file >100 MB in the
   stage dir, except input/output. The working `system.raw` is never
   touched, so a failed install never destroys a working image.
3. Candidate pick: exact `system.img` / `system_a.img` / `system_b.img` →
   `*system*.img` (excluding system_ext) → any `*.img`, largest wins with a
   MULTIPLE_IMAGES log → single large non-.img file; otherwise AMBIGUOUS
   with the candidate list logged.
4. `super.img` rejected by name (no lpunpack in tree). `.zst` / raw `.lz4` /
   `.br` rejected (bundled 7zz 23.01 limits). ROM zips rejected (no sdat2img).
5. Sparse images (magic `3aff26ed`) → bundled aarch64 `simg2img` with
   header-size verification (total_blks × blk_sz, awk doubles — never a
   shell integer test or `$(())` on raw byte sizes; that 32-bit overflow was
   the true root cause of the old CANDIDATE_EMPTY bug).
6. Format check: ext4 magic `53ef` @1080, EROFS magic `e2e1f5e0` @1024, else
   UNKNOWN_FORMAT. Free-space check: candidate + 10% headroom (awk doubles).
7. Atomic install: copy to `system.raw.new`, size-check, rename over
   `system.raw`.

Guards: stage containment + a `gsi_guest_running` refusal while that slot's
guest runs.

## Switch / takeover — `assets/switch_to_gsi.sh`, driven by `bootGsi`

`bootGsi` gates: 500 ms debounce; root gate; battery guard; assetsReady
gate; `system.raw` existence gate (added 5.9.6 after 5.9.5 spawned a
takeover on a failed install); flags-file sync; size-checked engine sync
(big binaries skipped when version + size match, scripts always copied,
patched files removed when toggles off); `framework_version` file write when
the detected version is known; takeover launched detached via busybox setsid
or nohup, log to `<slot>/takeover_app.log`; boot progress polls the
takeover log up to 180 s, mapping [1/6]–[6/6] to 30–80%, stopping at
TAKEOVER LAUNCHED or 180 s with an honest "still running" note.

Takeover sequence:

1. Stage validation (Default or `slots/<clean name>` only); `guards.sh`
   validation + SLOT_RUNNING guard.
2. `preflight_host.sh`: host /system /vendor /product /odm read-only; no
   guest rootfs outside the staging root; staging root not a symlink.
   PREFLIGHT_OK/FAIL.
3. `setenforce 0` (guest userspace is foreign/unlabelled for Samsung
   policy; return restores enforcing). Note: this disables SELinux only —
   it does NOT disable DEFEX (see "Samsung protections" below).
4. **IMS gate**: `imsd` up + `dumpsys telephony.registry`
   `mVoiceRegState=0`, up to 45 × `sleep 2` = max 90 s, breaks early,
   progress echo every 10 s. The single largest host-side delay, kept
   deliberately — it is NOT a pointless wait.
5. adbd watchdog + imsd keepalive daemons written to `/data/local/tmp/` and
   supervised for the session.
6. `persist.sys.disable_rescue=true` + `sys.rescue_boot_count=0` with
   read-back logging (5.9.13) — RescueParty suppression, proven by read-back,
   not assumed.
7. One UI launcher DB snapshot to `/data/local/tmp/lineage_backups`.
8. Audio tuning (offload off, deep_buffer off); BPF/dnsproxyd tweaks.
9. `master_prepare.sh` (must exit 0), then the kill spree: `ctl.stop zygote`,
   `ctl.stop surfaceflinger`, `kill -9` surfaceflinger / bootanimation /
   app_process64 / zygote_exec / zygote64 / system_server (readiness loop,
   max 2 s), `ctl.stop` + kill media.codec / media.metrics (AIDL hash
   mismatch spin; mediaserver itself kept so MediaPlayer doesn't stall),
   `ctl.stop` + kill wificond (guest's own wificond starts in master_inner),
   imsd survival re-check, zygote-suppression loop (stops host zygote if
   init resurrects it).
10. Copies `master_inner.sh` + `zygote_exec` into `$STAGE/data/`; launches
    the takeover in an isolated mount namespace (`busybox unshare -m …
    master_inner.sh $STAGE/rootfs`, log to `$STAGE/data/takeover.log`);
    touches `$STAGE/.guest_running`.
11. UI Activator daemon: polls for guest system_server, waits for `mStatusBar`
    in dumpsys window, then exits bootanim, sets stay-on / screen timeout /
    refresh rate, gesture nav, HOME intent, `am unlock-user 0`, microG
    install if flagged, BPF uid-permission population, default route,
    emulated storage mount.
12. `boot_watchdog.sh` armed (10 min) if present.

## Prepare — `assets/master_prepare.sh`

- Step 1: watchdog feeder (see "Watchdog" — the fragile part).
- Loop nodes 50–150; loop-mount `system.raw` read-only (ext4 first, then
  EROFS fallback; mount failure fatal if `system/bin/sh` +
  `init.environ.rc` missing); warns on missing expected rootfs dirs;
  binderfs mount.
- **rbind host /dev into `$ROOTFS/dev`** (make-rprivate) — the guest sees
  the host's device nodes, including any /dev/watchdog node.
- Binds /linkerconfig, /vendor, /odm, /vendor_dlkm, /mnt (rbind),
  /system_ext/apex, /system/apex.
- **Patch gating: FRAMEWORK_VERSION from env or `$STAGE/framework_version`;
  23.2 ONLY, else all patch binds skipped; missing version = legacy flag
  behavior + warning.** See PATCHES.md.
- Patch binds: services_patched.jar → `system/framework/services.jar`,
  framework_patched.jar → `system/framework/framework.jar`, optional audio.so
  binds, framework-res_patched.apk; **failed framework bind is FATAL in
  5.9.13**, PermissionController bind warning-only.
- Staged /data tree (per-package dirs, SELinux relabel to `system_data_file` /
  `app_data_file`, ownership system:system 0771, bluetooth dirs uid 1002,
  /data bridge binds so host installd/artd write into the guest tree, bind
  `$STAGE/data` → `$ROOTFS/data`, host /data/adb + /data/apex + /data/media
  binds).
- Generates fix_app_dirs.sh / ensure_app_storage.sh / net_fix.sh /
  app_storage_loop.sh into `$STAGE/data/local/tmp/` (data-dir scaffolding,
  uid realignment, code-file read-only fix, adb_enabled=1 pre-seed, density
  staging, boot-failure log capture, net table 4242 + ip rule 14999, 10 s
  package-change sweep + launcher refresh).
- Section 6 su copy into `$ROOTFS/system/xbin` (tmpfs + copy from
  /data/adb/ksud or found su).
- Sections 7–9 APEX: tmpfs `$ROOTFS/apex`, apex-info-list from host or clean
  23.2 list only if USE_LINEAGE_APEX_LIST=1, direct-mount extracted APEX
  payloads via loop for ~19 named APEXes, bind remaining /apex/* except
  `*samsung*`, late PermissionController bind once /apex/com.android.permission
  exists.
- Share folder / density / guest-root hook section. Ends
  "ALL MOUNTS PREPARED SUCCESSFULLY".

## Inner / pivot — `assets/master_inner.sh`

`mount --make-rprivate /`; `pivot_root` (fallback: bind rootfs onto itself,
retry, else FATAL); proc mount; /data_mirror + /data/data binds;
`/data/media` + `/storage/emulated/0` + `/mnt/user/0/emulated` binds;
optional GSI_Shared bind; density staging; guest-root su bind/copy fallback;
/dev/null + su checks; starts guest surfaceflinger, bootanimation, vold
(with blkid/fsck contexts), wificond; gesture-nav idmap2 build;
app_storage_loop start; cleans stale zygote sockets; **`exec /data/zygote_exec`**
— guest zygote + system_server. Again: no guest init, ever.

## Guest session — what runs, what doesn't

- Host side still running: host init (PID 1), imsd + keepalive, adbd
  watchdog, host installd/artd (writing into the guest /data tree via
  binds), host mediaserver, host watchdogd (if any — unverified), the fork's
  watchdog feeder (started in master_prepare, host namespace).
- Guest side running: surfaceflinger, bootanimation, vold, wificond,
  zygote_exec → guest zygote + system_server, plus whatever system_server
  spawns.
- Guest sees: **host kernel, host vendor HALs** (/vendor, /odm binds), host
  /dev (rbind), host APEX (mostly), guest /system from the image, guest
  /data tree.

Consequence: a guest older than the vendor (e.g. Android 16 guest on an
Android 17 vendor) meets host HALs its framework was not built for. The
Treble rule is GSI ≥ vendor; no app code can fix that gap. Generation-matched
GSIs work best.

## Return — `assets/return_to_oneui.sh` + Java light path

`kill_guest_procs` (kills processes rooted under any lineage rootfs +
cmdline mentions; name-kills of system_server / zygote64 / surfaceflinger /
vold / wificond / bootanimation ONLY if a guest rootfs is mounted; **imsd
NEVER killed**); unbridges host /data trees first; launcher DB restore
(UID/GID from stat, fallback 10160); unmount loop (50 passes, stage rootfs
mounts); loop detach for system.raw; storage restore (bind /data/media/0 →
/storage/emulated/0); restarts surfaceflinger / zygote / audioserver /
cameraserver / media / media.extractor / media.metrics / wificond; launcher
force-stop + HOME intent; `setenforce 1`; verification (no rootfs mount,
zygote running, Enforcing) → RETURN_OK else RETURN_PARTIAL + exit 1;
`--reboot` reboots after best-effort return. Java light path: if the
liveness guard says no guest is running anywhere, just clear stale markers
and report "Already in One UI" without touching host services.

## Guards

`assets/guards.sh`: **liveness-only detection** since 5.9.13 — (1)
`$stage/rootfs` (or submount) in the mounts file, (2) any /proc PID rooted
under `$stage/rootfs` or cmdline mentioning it, (3) takeover script for
exactly this stage running (self-PID skipped). **The `.guest_running`
marker is deliberately NOT consulted** (force-restart leaves it stale
forever). Also stage/name validation, containment check, sha256 helper,
fs-type helper (sparse/ext4/erofs/unknown via magics). Sourced (never
executed) by snapshot/rollback/backup/verify/guest_root/install/switch/
prepare/check_slot_guard.

## Watchdog — the two watchdogs, and the 100 s kernel panic

There are two different watchdogs; confusing them is the project's most
expensive misunderstanding:

- **App boot watchdog** (`assets/boot_watchdog.sh`): 15 s × 40 rounds =
  600 s (10 min); "home reached" = UI Activator appended "Home activated!"
  to `/data/local/tmp/ui_activator.log`; exits when rootfs unmounted (mount
  state, NOT marker, since 5.9.13); on timeout captures a boot_diagnostics
  bundle BEFORE return, touches `<slot>/boot_watchdog_timeout`, runs
  return_to_oneui.sh (guest preserved — system.raw + guest data kept);
  missing return script = phone left as-is. This bounds *userspace hangs*.
- **Kernel watchdog**: the phone's watchdog device, configured timeout
  100 s. The panic string "Software Watchdog Timer expired" is verbatim from
  the kernel softdog driver (`drivers/watchdog/softdog.c`,
  `softdog_fire()`): it fires ONLY if nobody writes to the watchdog device
  for the full 100 s. **The 10-min app watchdog cannot save a kernel panic**
  — the kernel already panicked at 100 s, long before the app watchdog
  would act.

The session's only kernel-watchdog protection is the feeder in
master_prepare.sh: if no process cmdline contains "/dev/watchdog", it starts
`nohup busybox sh -c "while true; do echo -n 1 > /dev/watchdog 2>/dev/null;
sleep 2; done"` in the host namespace. Its fragilities (all provable from
code): silent failure (every write error discarded); open-write-close every
2 s with WDIOF_MAGICCLOSE semantics (works only while the loop keeps
running); not supervised or restarted by anything; leaks after return
(return never kills it); single-opener contention (if host watchdogd already
holds /dev/watchdog open, the feeder's opens fail EBUSY silently and the
feeder is a no-op); ps-grep detection, not a liveness check; starts BEFORE
the kill spree. 5.9.16 hardens this path (feeder hardening + guest-side
kicker + container hardening) — see README. It does NOT disable the host
watchdog: the host watchdog protects the real phone, and removing it would
leave the phone unprotected.

The takeover does NOT by name kill watchdogd or the feeder (checked: the
kill list is zygote, surfaceflinger, bootanimation, app_process64,
zygote_exec, zygote64, system_server, media.codec, media.metrics, wificond,
plus two pkill -f regex patterns that do not match the feeder's cmdline).
Guest mounts live in a separate mount namespace (`unshare -m`), so they
should not hide /dev/watchdog from host daemons — verify, don't assume.

Two cases, kept separate: (a) watchdog as SYMPTOM — guest crash-loops and
the session ends in a watchdog fire (but a guest hang alone does not stop
host-side kicking, so (a) alone needs a second mechanism that kills the
kicker); (b) watchdog as CAUSE — the kicker is broken/missing in the
container even for a healthy guest (fits the matched-version case: same
Android version on both sides, ext4 AND erofs both panic at 100 s). For the
S26 FE, (a)+(b) may combine. See TROUBLESHOOTING.md for the evidence ladder
that tells them apart.

## Samsung protections — direct vs indirect

DIRECT = the protection itself produces the softdog string; INDIRECT = the
protection blocks/kills something the guest needs → guest hangs → (if the
kicker is also dead) watchdog fires at 100 s.

- **DEFEX — INDIRECT only, SUSPECT.** Kernel-level protection allowing only
  authorized binaries to run with superuser privileges. Container operations
  that could fall under it: zygote_exec staged under `/data/.../data/
  zygote_exec` and executed as root, the guest su bind/copy, scripts run
  from `/data/local/tmp`. Counter-evidence: the guest REACHES the boot
  animation, so DEFEX did not block the main zygote_exec exec; it could
  still block a LATER root exec. Its signature would be a DEFEX denial in
  the kernel log, NOT the softdog string. KEY NUANCE: DEFEX is a separate
  LSM from SELinux — `setenforce 0` does NOT disable DEFEX.
- **RKP — RULED OUT as direct cause; indirect implausible.** EL2 hypervisor
  policing stage-2 page tables; container operations (mounts, pivot_root,
  kills, setprop, stopping zygote) request no kernel-memory operation, and
  temp root via KernelSU-Next LKM already coexists with RKP on this phone.
  An RKP violation's signature would name RKP, not softdog.
- **TIMA — RULED OUT as cause.** Passive measurement from TrustZone; logs
  events, does not kill processes or panic with the softdog string.
- **sec_watchdog — RULED OUT as the executioner.** The firing device is
  proven to be softdog by the verbatim panic string; a Samsung hardware-WDT
  driver would print its own message. It remains relevant only as a possible
  SECOND watchdog: if a hardware WDT is also armed, the fix must pet both.
- **SELinux — RULED OUT during the session PROVIDED `setenforce 0`
  succeeded.** Switch sets permissive before prepare and logs the result
  ("SELinux mode: …"); return restores enforcing. SELinux is kernel-global
  (not namespaced), so permissive covers the guest too. It becomes a suspect
  ONLY if the takeover log shows setenforce 0 failed. Evidence: the
  "SELinux mode:" line in `takeover_app.log`.

## Diagnostics

- `assets/boot_diagnostics.sh` (read-only except its one output file
  `<slot>/boot_diagnostics.log`): fs type from magic, stage mounts
  (head-30), takeover log tail-60, inner log tail-60, watchdog log tail-40,
  logcat crash buffer tail-40, logcat system FATAL/AndroidRuntime/EIO/erofs
  tail-40, dmesg erofs tail-20, guest processes (ps filtered on slot
  rootfs, head-10). Guest logcat is visible from host because /dev is
  rbind-shared (shared logd).
- `assets/pstore_check.sh`: answers ONE question after an unexpected reboot
  ended a guest session — kernel panic or userspace/manual reboot? Reads
  `/sys/fs/pstore/console-ramoops*` + `dmesg-ramoops*` + `/proc/last_kmsg`
  if present; verdicts PSTORE_PANIC (+EROFS_HINT if the trace mentions
  erofs), PSTORE_NO_PANIC, PSTORE_EMPTY, PSTORE_UNAVAILABLE (does NOT mount
  pstore — that would change system state). Report-once via
  `/data/local/tmp/pstore_consumed` (path + hash); nothing in pstore
  deleted. Caveat: an earlier host crash's panic could still be sitting in
  pstore and be misattributed; erofs/loop lines are the tie-breaker. Java
  runs it ONLY when the launch sweep cleared a stale marker, and surfaces
  the verdict in the app log; `surfaceWatchdogOutcome` surfaces the
  watchdog-timeout bundle head-200 per slot, then deletes bundle + timeout
  marker (report-once).
- 5.9.16 adds a one-tap diagnostics bundle export (app log + takeover log +
  inner log + boot_diagnostics + pstore excerpt + device info) from the
  Experimental menu.

## Slots, snapshots, other scripts

- Stage root: `/data/local/tmp/lineage_stage`; slots under
  `slots/<clean name>/`; Default slot is the original single install.
- backup_slot.sh: generations under `<stage>/backups/<name>/`, system.raw +
  data + meta + per-file data_manifest.txt, staged.tmp + rename, never
  overwrites, WARNS (does not refuse) while guest running — live data copy
  may be inconsistent (documented tradeoff).
- snapshot_slot.sh: same pattern under `snapshots/`, refuses while running
  + on name collision.
- rollback_slot.sh: sha/size-check snapshot system.raw, atomic via
  system.raw.new + rename, data dir swap via .new/.old (see README/known
  limits history: pre-5.9.16 rollback could split generations if data
  staging failed after system.raw was restored).
- verify_backup.sh: sha/size/manifest recompute + loop-mount check when
  possible, else structural magic/size checks.
- guest_root.sh: HONESTY NOTE — no su asset in tree, no guest-side su
  daemon; bind-mounted host su gives a root SHELL / host-root commands via
  guest_root_shell.sh nsenter, but guest apps still go through host su grant
  policy keyed to host identities. "Guest root" is shell-only, not app
  grants.
- inspect_image.sh (read-only), battery_guard.sh, check_slot_guard.sh,
  preflight_host.sh — small, as named.

## Build

`build_apk_linux.sh` (Linux; `build_apk.sh` is the untouched macOS original):
JDK 17, aapt2 compile/link with platform android-34, javac `-encoding UTF-8
-source 1.8 -target 1.8`, d8, zipalign, apksigner. Paths are parameterized
via env vars (`GSI_PROJECT_DIR`, `GSI_SDK_ROOT`, `GSI_JDK`, `GSI_OUT_APK`,
`GSI_KEYSTORE`) with defaults resolving to the current VM layout. The
signing keystore lives OUTSIDE the tree
(`~/workspace/onelineage-generic/gsi-loader.keystore`, cert SHA-256
`3f4ed944…` — see PATCHES.md for the full fingerprint); the build script
REFUSES to auto-generate a keystore when it is missing, because a fresh
keystore would silently change the cert and break update-over-install.
Post-build gate: `verify_apk.sh` (badging, apksigner verify + cert
fingerprint, manifest component, asset hash list). Delivery: `make_dist.sh`
(APK top level + source folder, keystores/build/.git excluded by
construction and by a post-zip scan).

## Known limits (honest, carried from the study)

- Guest voice calls do not work (no IMS stack in the guest).
- Return may still need a manual reboot in some cases.
- media.codec AIDL hash mismatch can cause high CPU during codec
  enumeration; host codec stack is stopped during the session.
- Guest Developer options can crash (DEV_OPTIONS_FIX flag is dead in the
  script — it explicitly prints "no workaround available"; do not document
  it as a feature). IMS_FIX / CODEC_FIX env vars are dead echoes.
- Deep-buffer/offload audio disabled by design; DTMF/deep-buffer glitches.
- Guest root is shell-only, not app grants.
- Patched binaries are binary-only with no source/diff in tree — see
  PATCHES.md. This blocks any LineageOS 24 rebuild until a LOS 24 base
  exists and each patch is re-derived.
- Manifest targets SDK 34 while the host/guest world is Android 17 — not a
  proven defect, but behavior deltas are unexamined.
