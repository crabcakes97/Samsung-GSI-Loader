# Patched artifacts — provenance (5.9.16)

This file records, for each patched artifact in `assets/`, its base as far
as known, what changed as far as known, and the rebuild recipe. It exists
because the LOS 24 rebuild cannot start from zero knowledge — which is
exactly where it stands today without this file.

## HONEST LIMIT — read this first

**The class-level diff vs stock LineageOS 23.2 jars is still OPEN.** The
tree contains only the patched binaries — no source, no diff, no patch
description beyond the bind sites in `master_prepare.sh`. The stock LOS 23.2
framework/services jars are not in the tree and were not fetched. **No
claim below about which classes or methods the patches change should be
believed without that diff, and none is invented here.** What IS known is
the bind site (which guest file each artifact replaces), the gating (23.2
only), the file sizes/hashes (so a future diff can prove it is comparing
the same blobs), and the fork's stated purpose for the patches: making the
23.2 guest tolerate the host vendor HALs / Samsung environment.

If you are about to write "the patch changes class X" — stop, do the diff
first (recipe in "Rebuild recipe" below), and update this file with the
result.

## Gating (all artifacts)

`master_prepare.sh` reads FRAMEWORK_VERSION from env or
`$STAGE/framework_version` (written by Java `detectFrameworkVersion` from
the guest build.prop). **Patches apply to 23.2 ONLY; for any other version
all patch binds are skipped** (with a log line, not a UI warning unless Java
surfaces it). Missing version = legacy flag behavior + warning. A failed
framework bind is FATAL in 5.9.13; the PermissionController bind is
warning-only. The patches are NEVER carried to another Lineage version: a
23.2 jar on a 24 guest would be a version mismatch, not a patch.

SHA-256 hashes below were computed from the 5.9.16 tree's `assets/` on
2026-10-28. If a hash differs, you are not looking at the same blob.

## framework_patched.jar

- File: `assets/framework_patched.jar`
- Size: 16,056,887 bytes
- SHA-256: `537dd6d7b56be9b58635c23fe3a5599d3a0c45e3fb76721688daaa532ae3664f`
- Base (as far as known): LineageOS 23.2 `system/framework/framework.jar`.
  Exact LOS 23.2 build/date: NOT recorded in the tree — open item. The
  preset GSIs this fork ships for are MisterZtr LOS 23.2-20260524 builds;
  do not assume the jar was built from that exact build without verifying
  (the diff against stock 23.2 jars would settle it).
- Bind site: → guest `system/framework/framework.jar`
  (`master_prepare.sh`, patch-bind section).
- What changed (as far as known): NOT ESTABLISHED at class level — see
  HONEST LIMIT. Stated purpose only: help the 23.2 guest tolerate the host
  vendor HALs / Samsung environment.
- Failure mode: a failed bind is FATAL (prepare aborts).

## services_patched.jar

- File: `assets/services_patched.jar`
- Size: 15,219,116 bytes
- SHA-256: `02efaac0908f25857af2b18ad9e6e0fa2d1855dbe76752852213e6600e71afbc`
- Contents: classes.dex + classes2.dex + classes3.dex.
- Base (as far as known): LineageOS 23.2 `system/framework/services.jar`.
  Exact LOS 23.2 build/date: NOT recorded in the tree — open item (same
  caveat as framework_patched.jar).
- Bind site: → guest `system/framework/services.jar`
  (`master_prepare.sh`, patch-bind section).
- What changed (as far as known): NOT ESTABLISHED at class level — see
  HONEST LIMIT. Stated purpose only: same as framework_patched.jar.
- Failure mode: a failed bind is FATAL (prepare aborts).

## 6.21 merge (6.19 diagnostics + 6.20 isolation)

- 6.21 is the 6.19 tree (signal_generate-only tracer with sig==9 filter,
  per-heartbeat re-assert, trace_pipe reader child, death classification,
  dumpsys vold probe, vold.log bundle sections, PID-targeted kills, oom
  shield) merged with the 6.20 tree (own-vold-name isolation, lock/secret
  guards, skip-data-dirs option). Three-way merge on the f9a074b base with
  zero conflicts; no behavior from either side was dropped. The only
  overlapping lines were the chmod/hash loops in `MainActivity.java`, which
  6.20 had extended (`gvld_patch` + `services_isolated.jar`); the merged
  file keeps the extensions.
- `assets/zygote_exec` is the 6.19 binary: 464,656 bytes, SHA-256
  `c3cec7be40cdc89569d3d4d5944fad2e15e56fa4de358a53f1641a4b1765d2c5`.
  (The 6.20 tree carried the older 453,792-byte binary alongside the newer
  source; the merge keeps the 6.19 binary.)
- All isolation flags default OFF, as in 6.20. No README change.

## services_isolated.jar (6.20 — guest service isolation)

- File: `assets/services_isolated.jar`
- Size: 15,219,068 bytes
- SHA-256: `df915cbd2513bff5d95aa827d89d1a2839fa74dca6390c59ab60832ee4fd98b1`
- Base: `assets/services_patched.jar` in THIS tree (same 3 dex files,
  byte-identical sizes; every edit is same-size, so no dex grows).
  Produced by `tools/dex_patch.py` (stdlib-only Python; no smali
  round-trip). The input blob's own provenance is the OPEN item above;
  this section documents ONLY the 6.20 delta, which is fully enumerated
  below and machine-verified (see "Verification").
- Bind site: → guest `system/framework/services.jar`, INSTEAD of
  `services_patched.jar`, only when `GUEST_ISOLATION=1` (and
  `PATCH_FRAMEWORK=1`) in `gsi_flags.conf` (`master_prepare.sh`,
  patch-bind section). Missing jar + flag on = FATAL abort, never a
  silent fallback to the non-isolated jar. Default OFF: stock guest
  behavior is byte-identical (no bind happens unless the flag is on).
- Why: the 6.18 on-device bundle showed the guest's system_server dying
  ~4–9 s after start by its OWN Java crash — `IllegalStateException:
  Failed to protect CE key for user 0` (`LockSettingsService.
  setCeStorageProtection` ← `IVold.setCeStorageProtection` ← vold
  `ServiceSpecificException` code 0) during the one-time user-0
  migration; system_server dies first, zygote exits after it. Prime
  hypothesis (unproven): guest vold + host vold both register the
  binder name `vold` in the SHARED servicemanager, and the guest
  system_server talks to the HOST vold, which refuses a CE key it
  didn't create. This jar + `gvld_patch` (below) give the guest its own
  vold name so the guest never talks to the host's vold.
- Credit: mechanisms re-implemented from OneOS
  (fahadalijaved/OneOS, `switcher/patches/guest_own_vold.py`,
  `guest_no_vold_keys.py`, `guest_no_gatekeeper.py`,
  `guest_no_weaver.py`, `guest_no_wipe_secrets.py`,
  `guest_storage_guards.py`), studied READ-ONLY in
  `~/workspace/oneos-look/`. No OneOS code was copied, no OneOS patcher
  was run, no OneLineage-derived file was copied. Everything below is
  fresh code in this tree implementing the same mechanisms by different
  means (same-size DEX byte edits instead of smali insertion, because
  no smali assembler exists on the build VM).

### 6.20 delta, enumerated (all verified by tools/dex_patch.py + baksmali)

- T1 own-vold name: the string `vold` → `gvld` in the string tables of
  classes.dex + classes2.dex (same length, in place), covering exactly
  3 `ServiceManager` lookups, each verified to be followed by
  `getService`/`getServiceOrThrow`: `StorageManagerService.connectVold`,
  `StorageManagerService$StorageManagerInternalImpl.prepareStorageDirs`,
  `StatsPullAtomService.getIVoldService`. No other `vold` string use
  exists in the jar. NOTE: the guest vold binary must ALSO register
  `gvld` (see `gvld_patch`); without it the `getServiceOrThrow` lookup
  throws. The two halves are coupled by design (one checkbox).
- T2 vold key calls dropped (nopped; all void-returning, verified per
  site — no success value is ever faked): `IVold.createUserStorageKeys`
  x1, `destroyUserStorageKeys` x1, `unlockCeStorage` x1,
  `lockCeStorage` x1. `setCeStorageProtection`: ZERO client call sites
  in this blob — see the pre-existing neuter note below.
- T3 gatekeeper: `LockSettingsService.setLockCredentialInternal` and
  `setLockCredentialWithTokenInternalLocked` return false at entry
  (3-unit overwrites); `IGateKeeperService.enroll` x4 nopped (result →
  null), `clearSecureUserId` x3 nopped, `reportDeviceSetupComplete` x1
  nopped. Read-only `verifyChallenge`/`getSecureUserId` untouched.
- T4 weaver: `SyntheticPasswordManager.getWeaverService()` returns null
  at entry (3-unit overwrite). Lineage's choke point; OneOS nulled
  `getWeaverServiceLocked`, the Pixel/ColorOS equivalent.
- T5 wipe secrets: `RecoverySystemService.deleteSecrets()` returns at
  entry (2-unit overwrite). Fail-closed containment verified: no
  `ISecretkeeper.deleteAll`, `IVold.destroy*`, or
  `sys.erase_secure_element` reference remains outside `deleteSecrets()`
  and the `IVold$Stub` server side. `ExtendedWipeWithoutReboot` /
  `DuressWipe` do not exist in this build (left out, per OneOS).
- T6/T7 storage guards: `UserDataPreparer.destroyUserDataLI` returns at
  entry (3-unit overwrite); its one `RecoverySystem.
  rebootPromptAndWipeUserData` call (in `prepareUserDataLI`, not a
  `wipeData` method as in OneOS's builds) nopped; 34 destructive
  `IVold`/`IInstalld`/`AndroidKeyStoreMaintenance` calls dropped
  (keystore int results read as success 0, per OneOS); `StorageManager-
  Service.isCeStorageUnlocked` returns true at entry;
  `StorageStatsService.isQuotaSupported` returns false at entry.
- Entry overwrites use NO log call (a same-size patch cannot insert one
  without shifting code); guard activity is reported by the patcher
  and logged once by staging. Try-range bounds inside a window are
  harmless (the replacement cannot throw); branch targets inside a
  window abort the patcher (fail closed).
- HARD SAFETY RULE (observed, not just intended): isolation ONLY.
  Nothing forces, bypasses, or spoofs `setCeStorageProtection` / the
  CE-key migration succeeding; nothing makes the host vold accept the
  call or re-wrap the real CE key; no guest write reaches host
  gatekeeper/weaver/secret state. `setCeStorageProtection` is covered
  by the neuter below + T1, never by faking vold's answer.

### Pre-existing neuter found in the input blob (NOT introduced by 6.20)

`StorageManagerService$StorageManagerInternalImpl.
setCeStorageProtection(I[B)V` in `services_patched.jar` is ALREADY
`[return-void; nop x8; ...]` with a `RemoteException` catch around
nops and NO `IVold` call — a prior patch in the prebuilt blob (author
and date not recorded in the tree). That is why T2 finds zero
`setCeStorageProtection` client sites: the only intermediary is
already dead code. Verified by the patcher on every run
(`ce_neuter_verified`); if the neuter ever differs, the patcher aborts
rather than assuming coverage. This PARTIALLY narrows the HONEST LIMIT
for this one method only; the rest of the blob's diff vs stock 23.2
remains OPEN. The 6.18 crash happened with patches OFF (stock
services.jar), where this neuter does not run.

### Verification (on-VM only; NOTHING is proven on-device)

- `tools/dex_patch.py --selfcheck`: all 119,122 methods in the 3 dex
  files parse with boundary-validated branches/try ranges.
- Patcher run: 62 edits, all global assertions pass (report in
  `tools/dex_patch_report.txt`).
- `tools/dex_patch.py --verify` on the output: clean + all 4 entry
  guards present in exactly one dex each.
- Baksmali re-disassembly of the output: guards, `gvld` strings, and
  dropped calls confirmed in smali form; both dex files parse fully.
- Dex sizes byte-identical to the input (same-size invariant).

### Rebuild recipe

```
python3 tools/dex_patch.py --in assets/services_patched.jar \
    --out assets/services_isolated.jar --report tools/dex_patch_report.txt
python3 tools/dex_patch.py --verify --in assets/services_isolated.jar
```
Any missing/ambiguous site aborts the run (non-zero exit, no output).
Do NOT hand-edit the jar; re-run the patcher.

### Known gaps (6.20, honest)

1. The AIDL registration is NOT patched: the guest vold still
   registers `android.system.vold.IVold/default` (the
   `VendorVoldNativeService::try_start` tbz→b patch needs SHA-pinned
   offsets that do not exist on the build VM — no GSI image here).
   The legacy `vold` name (the crash path) IS closed; the AIDL name is
   a residual collision surface until pins exist.
2. The binary-side patch is GENERIC, not pinned (6.24): `gvld_patch`
   parses the ELF, finds every adrp+add/adr reference to the single
   standalone narrow `vold` literal, and classifies each by following
   its register forward to the consuming call (SERVICE = String16
   ctor; LOGTAG = the one shared local log helper, body-corroborated).
   It patches only when at least one SERVICE reference exists and
   every other reference is a proven LOGTAG; anything else aborts
   staging in LEARN mode with a per-reference trace. No pin table is
   needed for a new GSI unless its vold uses a shape the classifier
   has never seen — then it LEARNs and the trace says what to add.
3. `framework_patched.jar` is untouched: the 6.20 isolation covers
   services.jar only. If the framework jar also resolves `vold`
   anywhere, that is an open item for the stock-vs-patched diff.
4. Ownership is UNPROVEN until the 6.19 diagnostics (dumpsys vold
   ownership + vold.log) run: this jar assumes the two-vold hypothesis
   but does not prove it.

## gvld_patch (6.24 — guest vold binary patcher; rewritten from the 6.20 UTF-16 design in 6.23, classifier rewritten in 6.24)

- File: `assets/gvld_patch`
- Size: 433,760 bytes
- SHA-256: `66962927e1673d19a9a9c419d4d4bd9d7c8d021f38294de7e85c26a16a1ecafd`
- Format: ARM aarch64 static ELF executable, stripped. Source:
  `src/native/gvld_patch.c` (plain C, libc only).
- Build (NDK 29, API 21, static):
  `aarch64-linux-android21-clang -O2 -Wall -static -o assets/gvld_patch
  src/native/gvld_patch.c && llvm-strip assets/gvld_patch`
  (Host test build: same source with `cc`; 20/20 synthetic-ELF
  harness cases pass — service-only, service+logs, hoisted-register
  loop, tail-branch, counted-ctor length 4/5/non-constant,
  non-log third use, suffix-only, two literals, zero literals,
  gap adrp+add, adr form, two log callees, helper without __errno,
  UTF-16-only, non-stack x0, non-constant w0, frame-pointer x0 —
  and both exported real binaries classify exactly as prescribed:
  guest vold 1 SERVICE + 9 LOGTAG, service.incremental.so 2 SERVICE.)
- Use site: `master_prepare.sh`, `GUEST_OWN_VOLD=1` block (after the
  framework binds). Tries `$ROOTFS/system/bin/vold`, then
  `$ROOTFS/system/lib64/libvold.so` (VoldNativeService may live in
  either); first file that patches cleanly (exit 0) is bind-mounted
  over its original path (image is mounted read-only, never modified).
  Exit 2 (LEARN) on a candidate → try the next; no candidate patches
  → FATAL abort with the learn log in the staging output. Exit 1 =
  I/O error, also fatal. `service.incremental.so` is best-effort only
  (patched + bound if possible, never fatal).
- What it patches: the single standalone NARROW `vold\0` literal →
  `gvld\0` (2 bytes change: `v`→`g`, `o`→`v`; `l`, `d` unchanged).
  It verifies ELF64 LE + AArch64, requires EXACTLY ONE standalone
  literal, classifies every code reference by register-following
  (see `src/native/gvld_patch.c` header for the full design), and
  self-checks the output (byte-identical except the 2 bytes; full
  re-classification of the patched buffer finds zero `vold`
  references and the same reference count on `gvld`; no standalone
  `vold` remains). No code bytes are touched; the tbz patch is NOT
  attempted (see gap 1 above).
- Failure mode: FATAL abort of staging (fail closed). The helper never
  modifies its input; output goes to `$STAGE/vold_gvld_*`.
- RescueParty note: no new handling needed — `switch_to_gsi.sh`
  already sets `persist.sys.disable_rescue=true` + `sys.rescue_boot_count=0`
  before every guest boot (verified in-tree). The OneOS requirement
  that RescueParty be off is already satisfied by the existing flow.

## PermissionController_patched.apk

- File: `assets/PermissionController_patched.apk`
- Size: 26,008,661 bytes
- SHA-256: `4c3978e8d72c82013726d8e1ea4914c04ebef4fa099339dafd9b53543f402df3`
- Base (as far as known): LineageOS 23.2 PermissionController. Exact LOS
  23.2 build/date: NOT recorded in the tree — open item.
- Bind site: late bind once `/apex/com.android.permission` exists
  (`master_prepare.sh`, APEX sections); also gated on the 23.2 version check.
- What changed (as far as known): NOT ESTABLISHED — see HONEST LIMIT.
- Failure mode: bind failure is warning-only (unlike the framework jars).

## clean_apex_info_list.xml

- File: `assets/clean_apex_info_list.xml`
- Size: 17,317 bytes
- SHA-256: `871abb213bd4282ab86c6ac2223fa7859844e24d17fcf47d518bbc2010e3a83d`
- Base (as far as known): the clean LineageOS 23.2 APEX set (not the host's
  APEX list, which would include Samsung APEXes the guest must not see).
- Use site: `master_prepare.sh` APEX sections — used as the apex-info-list
  only if USE_LINEAGE_APEX_LIST=1; otherwise the host's list is used.
  Remaining `/apex/*` entries are bound except `*samsung*`.
- What changed (as far as known): it IS the 23.2 set, as opposed to a
  patched file — but the per-APEX membership vs stock 23.2 has not been
  diffed either. Treat the membership list as "as shipped", not "verified
  against stock 23.2".

## zygote_exec

- File: `assets/zygote_exec`
- Size: 6,400 bytes
- SHA-256: `895b62e9057cd8c1350b24982cd3e340ede8edfd9bd917051a115eba6da73e29`
- Format: ARM aarch64 static ELF, no section header. No source in tree —
  **black box, and the single most critical binary in the tree**: it is
  what `master_inner.sh` execs to start the guest zygote + system_server.
- Base: none — this is a fork/OneLineage-built helper, not a patched
  Lineage artifact. Its origin beyond that is NOT recorded in the tree.
- Use site: copied by `switch_to_gsi.sh` into `$STAGE/data/` and exec'd by
  `master_inner.sh` as the last step of the pivot.
- What changed / what it does internally: NOT ESTABLISHED — no source, no
  symbols (no section header), cannot be audited or rebuilt from the tree.
  Any claim about its internals is a guess. If it assumes 23.2-era zygote
  interfaces, a LOS 24 guest may need a replacement — unknowable without
  source or a test boot.
- Related binaries (NOT patches, listed so they are not confused with the
  above): `simg2img` (ARM64 dynamic PIE, built from
  anestisb/android-simg2img with NDK clang per the install comment) and
  `7zz` (ARM64 static, 23.01 upstream) — installer tools, not guest patches.

## Rebuild recipe (what LOS 24 would require — unstartable until a base exists)

1. A LOS 24 GSI base to patch against. As of 2026-10-28 none is public:
   MisterZtr's latest is LOS 23.2-20260524, TrebleDroid's unofficial
   Android 17 GSI table is empty. Device-specific LOS 24 ROMs exist but are
   not GSIs. Until a LOS 24 base exists, this is unstartable work, not
   deferred work.
2. Stock LOS 24 framework/services/PermissionController sources (AOSP +
   Lineage) AND stock LOS 23.2 sources, so each 23.2 patch's semantic change
   can be re-derived by diffing the shipped blobs above against stock 23.2
   (this also closes the OPEN class-level diff and the exact-base question
   in one step — record the result in this file when done).
3. Re-apply each semantic change to the LOS 24 sources, rebuild the
   jars/apk, and re-verify boot — first in the container, then against the
   watchdog bars (home = bar one, up past ~2 min = bar two; see
   TROUBLESHOOTING.md).
4. Re-derive the clean apex-info list for LOS 24's APEX set (do not carry
   the 23.2 list over).
5. Re-verify zygote_exec still works against a LOS 24 guest (black-box
   binary; if it assumes 23.2-era zygote interfaces, it may need
   replacement — unknowable without source or a test boot).

## Signing cert (build continuity — kept here so it is never lost)

5.9.16 is signed with the relocated keystore
(`~/workspace/onelineage-generic/gsi-loader.keystore`, alias
`androiddebugkey`, owner CN=OneLineage, O=WeWaffles, C=US). Cert SHA-256:

`3f4ed94497375a9fbe998dd82b265f65d0c5152baf11f11da9ec0397b85f883f`

(`verify_apk.sh` gates on this fingerprint; `build_apk_linux.sh` refuses
to auto-generate a replacement keystore.) If a future build's cert differs,
it will NOT update over 5.9.15/5.9.16 — stop and fix the keystore, do not
ship it.
