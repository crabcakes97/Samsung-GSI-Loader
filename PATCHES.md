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
