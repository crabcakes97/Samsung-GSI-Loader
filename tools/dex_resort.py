#!/usr/bin/env python3
"""DEX string rename via a dexlib2 round-trip (baksmali/smali).

Why this exists: DEX requires string_ids sorted by UTF-16 code-point
value, and every other table references strings by index into that
sorted array. Renaming a string in place (same-length byte edit, the
6.20 approach in tools/dex_patch.py) changes the string's sort
position without re-sorting: "vold" -> "gvld" sorts earlier than its
neighbour "volId", so classes.dex/classes2.dex came out
DEX-INVALID ("Out-of-order string_ids") and the runtime rejected
them, killing the guest system_server at startup (6.24 on-device
finding). Hand-rolling the re-sort + index remap would have to touch
string_ids order, every type/field/method id naming via a string
index, every const-string operand, and debug-info string references
(delta-ULEB): too much fragile surface for a generic pipeline step.

This module does the rename the way the second-opinion prescription
requires: disassemble the owning classes*.dex to smali (baksmali),
edit the single const-string literal in the identified method only,
reassemble with smali. The assembler builds the dex from scratch
from the symbolic model, so string_ids ordering and every reference
are remapped automatically; there is no separate remap step to get
wrong. The function is reusable: dex_resort_patch(jar, old, new)
renames any one literal the same way.

Fail-closed rules (every run):
  * Census at the string-item level, exact equality (DEX strings are
    already atomic items; "volId" is a different item and cannot
    confuse this the way ELF .rodata tail-merging can). Exactly one
    exact match per dex -> proceed; zero -> skip the dex, no-op;
    more than one -> abort.
  * Classification identical to tools/dex_patch.py T1: every
    const-string/const-string-jumbo use of the string must be
    immediately followed by an invoke to
    Landroid/os/ServiceManager; getService/getServiceOrThrow.
    Anything else aborts. (The DEX-side analogue of the
    SERVICE/LOGTAG discipline on the native binaries.)
  * Verification, every run: dexdump reports zero "Out-of-order
    string_ids" on every rebuilt dex; zero items equal the old
    literal and exactly one equals the new literal, at the same
    call site(s); and a smali-tree diff between the pre- and
    post-round-trip disassemblies shows ONLY the renamed
    const-string line(s) -- any other difference aborts. (One
    benign assembler normalization is accounted for: smali drops
    redundant zero static initializers, e.g. ".field ... :Z = false"
    re-emitted without "= false"; those spellings are semantically
    identical, and only exact zero-values are tolerated.)
  * Only the rebuilt classes*.dex entries are replaced in the jar;
    every other entry is copied byte-identical.

Build-time dependency only (host JRE + jars; never on-device):
  smali/baksmali/dexlib2/util 2.5.2, antlr-runtime 3.5.2,
  jsr305 3.0.2, plus guava + jcommander from the Android SDK tree.
  Default location: ~/workspace/altbuild/tmp/smali303 (SHA-256
  pinned below; a corrupt or mismatched jar aborts with the download
  commands). Download (Google mirror of Maven Central):
    base=https://maven-central.storage-download.googleapis.com/maven2
    org/smali/smali/2.5.2/smali-2.5.2.jar
    org/smali/baksmali/2.5.2/baksmali-2.5.2.jar
    org/smali/dexlib2/2.5.2/dexlib2-2.5.2.jar
    org/smali/util/2.5.2/util-2.5.2.jar
    org/antlr/antlr-runtime/3.5.2/antlr-runtime-3.5.2.jar
    com/google/code/findbugs/jsr305/3.0.2/jsr305-3.0.2.jar
  Override with --smali-dir / $SMALI_JAR_DIR; guava/jcommander
  resolve from the SDK tree unless --guava/--jcommander are given.

Usage:
  dex_resort.py --in services.jar --out services_renamed.jar \
      --old vold --new gvld [--report report.txt] [--smali-dir DIR]
Exit non-zero on any failed check. Only the Python standard library
plus the smali toolchain above (invoked as subprocesses).
"""

import difflib
import glob
import hashlib
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dex_patch import Dex, DexError  # noqa: E402

EXPECTED_SHA256 = {
    "smali-2.5.2.jar": "136c5c4653d6531bd7b6f10f35f8691cb96432e727d30b4d5579826ee01e9419",
    "baksmali-2.5.2.jar": "1ed236266d7dc4907aade0b19a34f77efac25342b63c8ace52e579039941b389",
    "dexlib2-2.5.2.jar": "5a5c8982d8bd7d6e3bb1a0713049e3c78b719ec32b20f6b619885cec30a0dd61",
    "util-2.5.2.jar": "4f580a9cff3ebb83cb3fd20bec88e37e4f183796ca652732992611620282daea",
    "antlr-runtime-3.5.2.jar": "ce3fc8ecb10f39e9a3cddcbb2ce350d272d9cd3d0b1e18e6fe73c3b9389c8734",
    "jsr305-3.0.2.jar": "766ad2a0783f2687962c8ad74ceecc38a28b9f72a2d085ee438b7813e928d0c7",
}

INVOKE_OPS = (0x6E, 0x6F, 0x70, 0x71, 0x72, 0x74, 0x75, 0x76, 0x77, 0x78)


class Toolchain:
    """Resolved smali/baksmali toolchain (jars + java + dexdump)."""

    def __init__(self, smali_dir=None, java=None, dexdump=None,
                 guava=None, jcommander=None):
        self.smali_dir = self._resolve_dir(smali_dir)
        self.jars = self._resolve_jars()
        self.java = self._resolve_java(java)
        self.dexdump = self._resolve_dexdump(dexdump)
        self.guava = self._resolve_lib(guava, "guava",
                                       "com/google/guava/guava/*/guava-*.jar")
        self.jcommander = self._resolve_lib(jcommander, "jcommander",
                                            "com/beust/jcommander/*/jcommander-*.jar")

    def _resolve_dir(self, smali_dir):
        cands = []
        if smali_dir:
            cands.append(smali_dir)
        if os.environ.get("SMALI_JAR_DIR"):
            cands.append(os.environ["SMALI_JAR_DIR"])
        cands.append(os.path.expanduser("~/workspace/altbuild/tmp/smali303"))
        cands.append(os.path.join(os.path.dirname(os.path.abspath(__file__)), "smali"))
        for c in cands:
            if c and os.path.isdir(c) and os.path.exists(
                    os.path.join(c, "smali-2.5.2.jar")):
                return c
        raise DexError(
            "dex_resort: smali jars not found (looked in %s). Download the "
            "2.5.2 jars per the module docstring into "
            "~/workspace/altbuild/tmp/smali303/ or pass --smali-dir." % cands)

    def _resolve_jars(self):
        jars = {}
        for name, want in EXPECTED_SHA256.items():
            p = os.path.join(self.smali_dir, name)
            if not os.path.exists(p):
                raise DexError("dex_resort: missing jar %s in %s" % (name, self.smali_dir))
            h = hashlib.sha256(open(p, "rb").read()).hexdigest()
            if h != want:
                raise DexError("dex_resort: jar %s hash mismatch (got %s, want %s); "
                               "re-download it, do not use a corrupt copy."
                               % (name, h, want))
            jars[name] = p
        return jars

    def _resolve_java(self, java):
        if java and os.path.exists(java):
            return java
        for cand in (os.path.expanduser("~/workspace/toolchain/jdk21/bin/java"),
                     os.path.join(os.environ.get("JAVA_HOME", ""), "bin", "java")):
            if cand and os.path.exists(cand):
                return cand
        found = shutil.which("java")
        if found:
            return found
        raise DexError("dex_resort: no java found (need a JRE on the build host)")

    def _resolve_dexdump(self, dexdump):
        if dexdump and os.path.exists(dexdump):
            return dexdump
        roots = []
        if os.environ.get("ANDROID_HOME"):
            roots.append(os.environ["ANDROID_HOME"])
        roots.append(os.path.expanduser("~/workspace/onelineage/android-sdk"))
        for root in roots:
            hits = sorted(glob.glob(os.path.join(root, "build-tools", "*", "dexdump")),
                          reverse=True)
            if hits:
                return hits[0]
        found = shutil.which("dexdump")
        if found:
            return found
        raise DexError("dex_resort: no dexdump found (need the Android SDK "
                       "build-tools on the build host for the sort check)")

    def _resolve_lib(self, explicit, label, pattern):
        if explicit and os.path.exists(explicit):
            return explicit
        base = os.path.expanduser(
            "~/workspace/onelineage/android-sdk/cmdline-tools/latest/lib/external")
        hits = sorted(glob.glob(os.path.join(base, pattern)))
        if hits:
            return hits[-1]
        raise DexError("dex_resort: %s jar not found under the Android SDK tree "
                       "(pattern %s)" % (label, pattern))

    def classpath(self, extra_jar):
        parts = [self.jars["dexlib2-2.5.2.jar"], self.jars["util-2.5.2.jar"],
                 extra_jar, self.guava, self.jcommander,
                 self.jars["antlr-runtime-3.5.2.jar"], self.jars["jsr305-3.0.2.jar"]]
        return ":".join(parts)

    def run(self, args, cwd=None):
        r = subprocess.run(args, cwd=cwd, capture_output=True, text=True, timeout=600)
        return r


def _smali_escape(s):
    out = []
    for ch in s:
        o = ord(ch)
        if ch == "\\":
            out.append("\\\\")
        elif ch == '"':
            out.append('\\"')
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\r":
            out.append("\\r")
        elif ch == "\t":
            out.append("\\t")
        elif o < 0x20 or o == 0x7F:
            out.append("\\u%04x" % o)
        else:
            out.append(ch)
    return "".join(out)


def classify_sites(dex, old_literal):
    """Census + call-site classification for one dex.

    Returns (string_idx, sites) where sites are (desc, name, proto, pc).
    string_idx is None when the literal is absent (sites empty). Raises
    DexError on >1 string item, or on any use that is not a
    ServiceManager.getService/getServiceOrThrow lookup. Mirrors T1 in
    tools/dex_patch.py exactly (same census, same skip set, same
    invoke check) so the two implementations must agree."""
    old_b = old_literal.encode("utf-8")
    ids = [i for i, (_off, s) in enumerate(dex.strings) if s == old_b]
    if len(ids) > 1:
        raise DexError("dex_resort: expected at most one string %r per dex, "
                       "found %d in %s" % (old_literal, len(ids), dex.name))
    if not ids:
        return None, []
    idx = ids[0]
    sites = []
    for desc, methods in dex.classes.items():
        if "IVold" in desc or "IInstalld" in desc:
            continue
        for (name, proto), coff in methods.items():
            if not coff:
                continue
            _regs, _off, insns, _tries = dex.parse_code(coff)
            for k, (pc0, op, ln, raw) in enumerate(insns):
                sidx = None
                if op == 0x1A:  # const-string
                    sidx = struct.unpack_from("<H", raw, 2)[0]
                elif op == 0x1B:  # const-string/jumbo
                    sidx = struct.unpack_from("<I", raw, 2)[0]
                if sidx != idx:
                    continue
                nxt = insns[k + 1] if k + 1 < len(insns) else None
                if nxt is None or nxt[1] not in INVOKE_OPS:
                    raise DexError("dex_resort: %r string in %s.%s not followed "
                                   "by an invoke" % (old_literal, desc, name))
                midx = struct.unpack_from("<H", nxt[3], 2)[0]
                cls2, mname, _mp = dex.method_ref(midx)
                if cls2 != "Landroid/os/ServiceManager;" or mname not in (
                        "getService", "getServiceOrThrow"):
                    raise DexError("dex_resort: %r string in %s.%s followed by "
                                   "%s.%s, not ServiceManager.getService*"
                                   % (old_literal, desc, name, cls2, mname))
                sites.append((desc, name, proto, pc0))
    return idx, sites


def _method_sig_from_header(line):
    """'.method ... name(params)ret' -> (name, '(params)ret') or None."""
    toks = line.split()
    if not toks:
        return None
    sig = toks[-1]
    lp = sig.find("(")
    if lp < 0:
        return None
    return sig[:lp], sig[lp:]


def _edit_smali_tree(tree_dir, sites, old_literal, new_literal):
    """Edit the const-string literal in the site methods only.

    Returns the number of lines changed. Raises DexError unless the
    count equals len(sites) and no old-literal const-string remains
    anywhere in the tree."""
    old_q = '"%s"' % _smali_escape(old_literal)
    new_q = '"%s"' % _smali_escape(new_literal)
    by_file = {}
    for (desc, name, proto, _pc) in sites:
        rel = desc[1:-1] + ".smali"
        by_file.setdefault(rel, set()).add((name, proto))
    changed = 0
    pat = re.compile(r'^(\s*const-string(?:/jumbo)?\s+v\d+,\s*)".*"\s*$')
    for rel, want in by_file.items():
        path = os.path.join(tree_dir, rel)
        if not os.path.exists(path):
            raise DexError("dex_resort: smali file %s missing for %s" % (rel, desc))
        lines = open(path, encoding="utf-8").read().split("\n")
        cur = None
        for i, line in enumerate(lines):
            s = line.strip()
            if s.startswith(".method"):
                cur = _method_sig_from_header(s)
            elif s.startswith(".end method"):
                cur = None
            elif cur in want:
                m = pat.match(line)
                if m and line.strip().endswith(old_q):
                    lines[i] = m.group(1) + new_q
                    changed += 1
        open(path, "w", encoding="utf-8").write("\n".join(lines))
    if changed != len(sites):
        raise DexError("dex_resort: smali edit changed %d lines, expected %d "
                       "(one per classified site)" % (changed, len(sites)))
    # No old-literal const-string may remain anywhere in the tree.
    for root, _dirs, files in os.walk(tree_dir):
        for fn in files:
            if not fn.endswith(".smali"):
                continue
            for line in open(os.path.join(root, fn), encoding="utf-8"):
                if "const-string" in line and old_q in line:
                    raise DexError("dex_resort: old-literal const-string remains "
                                   "after edit: %s" % line.strip())
    return changed


def _normalize_field_line(line):
    """Strip a redundant zero static initializer from a .field line.

    baksmali renders an encoded static value of false/0/null, but
    smali reassembly drops it: the dexlib2 writer omits initializers
    equal to the type default, and the runtime default-initializes
    those fields to the same value. The spellings are therefore
    semantically identical, and the assembler's normalization must
    not trip the diff check. Only exact zero-values are stripped
    (false, 0, 0x0, 0.0, null); any other initializer still diffs
    and fails the check."""
    m = re.match(r'^(\s*\.field\b.*?)(\s*=\s*(?:false|0|0x0|0\.0|null))\s*$', line)
    return m.group(1) if m else line


def _smali_tree_diff(old_dir, new_dir, sites, old_literal, new_literal):
    """Assert the ONLY differences are the renamed const-string lines.

    The smali assembler's one benign normalization (dropping
    redundant zero static initializers, see _normalize_field_line)
    is accounted for; every other difference aborts."""
    old_q = '"%s"' % _smali_escape(old_literal)
    new_q = '"%s"' % _smali_escape(new_literal)
    site_files = {desc[1:-1] + ".smali" for (desc, _n, _p, _pc) in sites}
    all_files = set()
    for base in (old_dir, new_dir):
        for root, _dirs, files in os.walk(base):
            for fn in files:
                if fn.endswith(".smali"):
                    all_files.add(os.path.relpath(os.path.join(root, fn), base))
    diffs = 0
    for rel in sorted(all_files):
        a = os.path.join(old_dir, rel)
        b = os.path.join(new_dir, rel)
        la = open(a, encoding="utf-8").read().split("\n") if os.path.exists(a) else []
        lb = open(b, encoding="utf-8").read().split("\n") if os.path.exists(b) else []
        la = [_normalize_field_line(x) for x in la]
        lb = [_normalize_field_line(x) for x in lb]
        if la == lb:
            continue
        if rel not in site_files:
            raise DexError("dex_resort: smali diff outside site methods: %s" % rel)
        sm = difflib.SequenceMatcher(a=la, b=lb, autojunk=False)
        for tag, i1, i2, j1, j2 in sm.get_opcodes():
            if tag == "equal":
                continue
            if tag != "replace" or (i2 - i1) != (j2 - j1):
                raise DexError("dex_resort: smali diff in %s is not a pure line "
                               "replacement (%s)" % (rel, tag))
            for x, y in zip(la[i1:i2], lb[j1:j2]):
                if "const-string" not in x or old_q not in x:
                    raise DexError("dex_resort: non-literal smali diff in %s: %r"
                                   % (rel, x))
                if y != x.replace(old_q, new_q):
                    raise DexError("dex_resort: unexpected smali diff in %s: %r -> %r"
                                   % (rel, x, y))
                diffs += 1
    if diffs != len(sites):
        raise DexError("dex_resort: smali diff shows %d literal changes, expected %d"
                       % (diffs, len(sites)))
    return diffs


def _dexdump_sorted_check(tc, dex_path, dex_name):
    r = tc.run([tc.dexdump, dex_path])
    out = (r.stdout or "") + (r.stderr or "")
    if r.returncode != 0:
        raise DexError("dex_resort: dexdump failed on %s: %s" % (dex_name, out[:300]))
    bad = [ln for ln in out.split("\n") if "Out-of-order string_ids" in ln]
    if bad:
        raise DexError("dex_resort: dexdump reports out-of-order string_ids in "
                       "%s: %s" % (dex_name, bad[0]))
    return True


def rename_dex_bytes(dex_bytes, dex_name, old_literal, new_literal, tc, work_base,
                     expect_sites=None):
    """Rename one literal in one dex via baksmali/smali round-trip.

    Returns (new_bytes_or_None, report_lines). None means no-op (the
    literal is absent from this dex); the caller must keep the
    original bytes untouched in that case. When expect_sites is
    given, the independently re-derived site set must match it
    exactly, or the run aborts."""
    report = []
    dex = Dex(dex_bytes, dex_name)
    dex.self_check()
    _idx, sites = classify_sites(dex, old_literal)
    if expect_sites is not None and sorted(sites) != sorted(expect_sites):
        raise DexError("dex_resort: re-derived sites %s != expected %s in %s"
                       % (sites, expect_sites, dex_name))
    if _idx is None:
        report.append("%s: no %r string, no-op" % (dex_name, old_literal))
        return None, report
    if not sites:
        raise DexError("dex_resort: %r string present in %s but no classified "
                       "ServiceManager lookup sites; refusing to rename blind"
                       % (old_literal, dex_name))
    report.append("%s: %d site(s) for %r" % (dex_name, len(sites), old_literal))
    for (desc, name, proto, pc) in sites:
        report.append("  site: %s.%s%s pc %d" % (desc, name, proto, pc))
    work = tempfile.mkdtemp(prefix="dexresort-", dir=work_base)
    try:
        in_path = os.path.join(work, "in.dex")
        open(in_path, "wb").write(dex_bytes)
        tree_a = os.path.join(work, "a")
        r = tc.run([tc.java, "-cp", tc.classpath(tc.jars["baksmali-2.5.2.jar"]),
                    "org.jf.baksmali.Main", "disassemble", in_path, "-o", tree_a])
        if r.returncode != 0:
            raise DexError("dex_resort: baksmali failed on %s: %s"
                           % (dex_name, (r.stderr or r.stdout or "")[:400]))
        tree_edit = os.path.join(work, "edit")
        shutil.copytree(tree_a, tree_edit)
        n = _edit_smali_tree(tree_edit, sites, old_literal, new_literal)
        report.append("%s: smali edit changed %d const-string line(s)" % (dex_name, n))
        out_path = os.path.join(work, "out.dex")
        r = tc.run([tc.java, "-cp", tc.classpath(tc.jars["smali-2.5.2.jar"]),
                    "org.jf.smali.Main", "assemble", tree_edit, "-o", out_path])
        if r.returncode != 0:
            raise DexError("dex_resort: smali failed on %s: %s"
                           % (dex_name, (r.stderr or r.stdout or "")[:400]))
        new_bytes = open(out_path, "rb").read()
        # Verify 1: parses + self-check.
        dex2 = Dex(new_bytes, dex_name + " (rebuilt)")
        dex2.self_check()
        # Verify 2: dexdump sort check.
        _dexdump_sorted_check(tc, out_path, dex_name)
        report.append("%s: dexdump clean (string_ids sorted)" % dex_name)
        # Verify 3: census + same sites, new literal.
        _idx2, sites2 = classify_sites(dex2, new_literal)
        if _idx2 is None or sorted(sites2) != sorted(sites):
            raise DexError("dex_resort: rebuilt %s sites differ: %s vs %s"
                           % (dex_name, sites2, sites))
        _idx0, _s0 = classify_sites(dex2, old_literal)
        if _idx0 is not None:
            raise DexError("dex_resort: rebuilt %s still contains %r"
                           % (dex_name, old_literal))
        report.append("%s: census clean (0x %r, 1x %r, same %d site(s))"
                      % (dex_name, old_literal, new_literal, len(sites)))
        # Verify 4: smali-tree diff shows ONLY the literal changes.
        tree_b = os.path.join(work, "b")
        r = tc.run([tc.java, "-cp", tc.classpath(tc.jars["baksmali-2.5.2.jar"]),
                    "org.jf.baksmali.Main", "disassemble", out_path, "-o", tree_b])
        if r.returncode != 0:
            raise DexError("dex_resort: baksmali (verify) failed on %s" % dex_name)
        d = _smali_tree_diff(tree_a, tree_b, sites, old_literal, new_literal)
        report.append("%s: smali-tree diff clean (%d literal line(s) only)"
                      % (dex_name, d))
        return new_bytes, report
    finally:
        if not os.environ.get("DEXRESORT_KEEP_WORK"):
            shutil.rmtree(work, ignore_errors=True)
        else:
            report.append("work dir kept: %s" % work)


def dex_resort_patch(in_jar, out_jar, old_literal, new_literal, report_path,
                     tc, work_base):
    """Reusable entry point: rename old_literal -> new_literal in a jar."""
    with zipfile.ZipFile(in_jar) as zin:
        infos = zin.infolist()
        datas = {info.filename: zin.read(info.filename) for info in infos}
    report = ["dex_resort: %s -> %s in %s" % (old_literal, new_literal, in_jar)]
    rebuilt = []
    for info in infos:
        if not info.filename.endswith(".dex"):
            continue
        new_bytes, lines = rename_dex_bytes(
            datas[info.filename], info.filename, old_literal, new_literal,
            tc, work_base)
        report.extend("  " + ln for ln in lines)
        if new_bytes is not None:
            datas[info.filename] = new_bytes
            rebuilt.append(info.filename)
    report.append("rebuilt dexes: %s" % (", ".join(rebuilt) if rebuilt else "(none)"))
    with zipfile.ZipFile(out_jar, "w", zipfile.ZIP_DEFLATED) as zout:
        for info in infos:
            zout.writestr(info, datas[info.filename])
    with open(report_path, "w") as f:
        f.write("\n".join(report) + "\n")
    print("\n".join(report))
    return rebuilt


def main(argv):
    in_jar = argv[argv.index("--in") + 1]
    out_jar = argv[argv.index("--out") + 1]
    old_literal = argv[argv.index("--old") + 1] if "--old" in argv else "vold"
    new_literal = argv[argv.index("--new") + 1] if "--new" in argv else "gvld"
    report_path = (argv[argv.index("--report") + 1] if "--report" in argv
                   else "dex_resort_report.txt")
    smali_dir = argv[argv.index("--smali-dir") + 1] if "--smali-dir" in argv else None
    work_base = os.environ.get("DEXRESORT_TMP",
                               os.path.expanduser("~/workspace/altbuild/tmp"))
    os.makedirs(work_base, exist_ok=True)
    tc = Toolchain(smali_dir=smali_dir)
    dex_resort_patch(in_jar, out_jar, old_literal, new_literal, report_path,
                     tc, work_base)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
