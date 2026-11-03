#!/usr/bin/env python3
"""Guest-service isolation patcher for LineageOS services.jar (CronchGSI 6.20).

Re-implements, as verified DEX edits, the isolation
mechanisms OneOS documents in switcher/patches/guest_own_vold.py,
guest_no_vold_keys.py, guest_no_gatekeeper.py, guest_no_weaver.py,
guest_no_wipe_secrets.py and guest_storage_guards.py (study only; this
code is written fresh for this tree, credited to fahadalijaved/OneOS in
PATCHES.md). T2-T7 are same-size DEX byte edits: every edit preserves
instruction boundaries and code sizes, so branch targets, try ranges
and debug info stay valid. T1 is the exception: renaming a string
in place breaks DEX string_ids ordering (the renamed string sorts
earlier than its neighbour), which the runtime rejects, so T1 goes
through a dexlib2 round-trip (tools/dex_resort.py: baksmali, edit
the one const-string literal, smali reassemble) that rebuilds the
dex with correct ordering. The dex header checksum and SHA-1
signature are recomputed after patching.

Transforms (all fail-closed: any missing/ambiguous site aborts the run):
  T1  own-vold name: the "vold" string used by the three ServiceManager
      lookups (StorageManagerService.connectVold,
      StorageManagerService$StorageManagerInternalImpl.prepareStorageDirs,
      StatsPullAtomService.getIVoldService) becomes "gvld" via a
      dexlib2 round-trip (tools/dex_resort.py), which rebuilds the dex
      with correctly sorted string_ids. Fails if any other const-string
      "vold" exists, or if a lookup does not immediately follow its string.
  T2  vold key calls dropped: every invoke-interface to IVold
      createUserStorageKeys/destroyUserStorageKeys/setCeStorageProtection/
      unlockCeStorage/lockCeStorage outside the IVold AIDL stub becomes
      nops (the call never reaches any vold; no key state is created
      anywhere). All five methods must appear at least once. All five are
      void-returning in this dex (verified per call site); a non-void one
      aborts the run rather than guessing a success value.
  T3  gatekeeper: setLockCredentialInternal and
      setLockCredentialWithTokenInternalLocked return false at entry via an
      entry-window overwrite (const/4 + return + nop padding, never
      crossing an instruction boundary or a branch/try target); every
      IGateKeeperService enroll/clearSecureUserId/reportDeviceSetupComplete
      invoke becomes a nop (enroll's move-result-object becomes const/4
      null). Read-only verifyChallenge/getSecureUserId are untouched.
  T4  weaver: SyntheticPasswordManager.getWeaverService() returns null at
      entry (Lineage's choke point; OneOS nulled getWeaverServiceLocked,
      the Pixel/ColorOS equivalent). The guest then takes the no-weaver
      paths and never enrolls, reads or writes a weaver slot.
  T5  wipe secrets: RecoverySystemService.deleteSecrets() returns at
      entry. Afterwards no ISecretkeeper.deleteAll / IVold destroy*
      calls may remain outside deleteSecrets() and the IVold stub.
  T6  preparer: UserDataPreparer.destroyUserDataLI returns at entry; its
      one rebootPromptAndWipeUserData call becomes nops (dead code behind
      the entry return; belt and braces). Zero such calls may remain.
  T7  storage destructive calls dropped: void IVold/IInstalld calls that
      destroy/wipe/move/format user data, and AndroidKeyStoreMaintenance
      calls that clear/re-key users, become nops (non-void returns get
      their move-result rewritten to a zero const). AIDL stub classes
      are never touched.

Entry-window overwrite rule (T3a/T4/T5/T6): the replacement sequence
covers a prefix of whole instructions at the method entry; no BRANCH or
switch target may land strictly inside the prefix (a jump there could
skip the guard return); try-range bounds inside are harmless because the
replacement (const/4 + return*) cannot throw. The replacement is
[const/4 v0, 0x0; return*; nop...] (or [return-void; nop...] for void
methods). No log call is inserted: the overwrite must not introduce new
throw points inside try ranges. Guard activity is reported by this tool
and logged once by the loader at staging time.

Usage:
  dex_patch.py --in services.jar --out services_isolated.jar --report report.txt
  dex_patch.py --verify --in services_isolated.jar   (assert transforms present)
Exit non-zero on any failed check. Only the Python standard library.
"""

import hashlib
import os
import struct
import sys
import zipfile
import zlib

# ---------------------------------------------------------------- dex model

NOP = 0x00


def uleb(data, off):
    result = 0
    shift = 0
    while True:
        b = data[off]
        off += 1
        result |= (b & 0x7F) << shift
        if not b & 0x80:
            return result, off
        shift += 7


def decode_mutf8(raw):
    # MUTF-8 -> UTF-8, via UTF-16 code units (handles surrogate pairs).
    units = bytearray()
    i = 0
    while i < len(raw):
        b = raw[i]
        if b == 0xC0 and i + 1 < len(raw) and raw[i + 1] == 0x80:
            units += b"\x00\x00"
            i += 2
        elif b & 0xE0 == 0xC0:
            units += struct.pack(">H", ((b & 0x1F) << 6) | (raw[i + 1] & 0x3F))
            i += 2
        elif b & 0xF0 == 0xE0:
            units += struct.pack(">H", ((b & 0x0F) << 12) | ((raw[i + 1] & 0x3F) << 6)
                                 | (raw[i + 2] & 0x3F))
            i += 3
        else:
            units += struct.pack(">H", b)
            i += 1
    return bytes(units).decode("utf-16-be", "replace").encode("utf-8")


OPLEN = {op: None for op in range(0x100)}


def _set(ops, ln):
    for _o in ops:
        OPLEN[_o] = ln


# Lengths in 16-bit code units, per the Dalvik bytecode specification.
_set([0x00, 0x01, 0x04, 0x07, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10,
      0x11, 0x12, 0x1D, 0x1E, 0x21, 0x27, 0x28], 1)
_set([0x7B, 0x7C, 0x7D, 0x7E, 0x7F, 0x80, 0x81, 0x82, 0x83, 0x84, 0x85, 0x86,
      0x87, 0x88, 0x89, 0x8A, 0x8B, 0x8C, 0x8D, 0x8E, 0x8F], 1)
_set([0xAF, 0xB0, 0xB1, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7, 0xB8, 0xB9, 0xBA,
      0xBB, 0xBC, 0xBD, 0xBE, 0xBF, 0xC0, 0xC1, 0xC2, 0xC3, 0xC4, 0xC5, 0xC6,
      0xC7, 0xC8, 0xC9, 0xCA, 0xCB, 0xCC, 0xCD, 0xCE], 1)
_set([0x02, 0x05, 0x08, 0x13, 0x15, 0x16, 0x19, 0x1A, 0x1C, 0x1F, 0x20,
      0x22, 0x23, 0x29], 2)
_set([0x2D, 0x2E, 0x2F, 0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37,
      0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D], 2)
_set([0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4A, 0x4B, 0x4C, 0x4D, 0x4E,
      0x4F, 0x50, 0x51, 0x52, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59,
      0x5A, 0x5B, 0x5C, 0x5D, 0x5E, 0x5F, 0x60, 0x61, 0x62, 0x63, 0x64,
      0x65, 0x66, 0x67, 0x68, 0x69, 0x6A, 0x6B, 0x6C, 0x6D], 2)
_set([0x90, 0x91, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99,
      0x9A, 0x9B, 0x9C, 0x9D, 0x9E, 0x9F, 0xA0, 0xA1, 0xA2, 0xA3, 0xA4,
      0xA5, 0xA6, 0xA7, 0xA8, 0xA9, 0xAA, 0xAB, 0xAC, 0xAD, 0xAE], 2)
_set([0xCF, 0xD0, 0xD1, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8, 0xD9,
      0xDA, 0xDB, 0xDC, 0xDD, 0xDE, 0xDF, 0xE0, 0xE1, 0xE2, 0xE3], 2)
_set([0x03, 0x06, 0x09, 0x14, 0x17, 0x1B, 0x24, 0x25, 0x26, 0x2A, 0x2B,
      0x2C], 3)
_set([0x6E, 0x6F, 0x70, 0x71, 0x72, 0x74, 0x75, 0x76, 0x77, 0x78, 0xE6,
      0xE7], 3)
OPLEN[0x18] = 5   # const-wide (51l)
OPLEN[0xE5] = 4   # invoke-polymorphic (45cc)
OPLEN[0xFA] = 3   # invoke-custom (35c)
OPLEN[0xFB] = 3   # invoke-custom/range (3rc)
# 0x3e-0x43, 0x73, 0x79, 0x7a, 0xe4, 0xe8-0xff: unused/unknown -> None (fail closed).


class DexError(Exception):
    pass


class Dex:
    def __init__(self, data, name):
        self.data = bytearray(data)
        self.name = name
        if len(data) < 112 or data[0:4] != b"dex\n":
            raise DexError("%s: not a dex file" % name)
        # Header ids section: 12 uint32s starting at offset 56.
        (self.string_ids_size, self.string_ids_off,
         self.type_ids_size, self.type_ids_off,
         self.proto_ids_size, self.proto_ids_off,
         self.field_ids_size, self.field_ids_off,
         self.method_ids_size, self.method_ids_off,
         self.class_defs_size, self.class_defs_off) = struct.unpack_from(
            "<12I", data, 56)
        self.strings = []
        for i in range(self.string_ids_size):
            off = struct.unpack_from("<I", data, self.string_ids_off + 4 * i)[0]
            size, p = uleb(data, off)
            end = data.index(b"\x00", p)
            self.strings.append((off, decode_mutf8(data[p:end])))
        self.types = []
        for i in range(self.type_ids_size):
            idx = struct.unpack_from("<I", data, self.type_ids_off + 4 * i)[0]
            self.types.append(self.strings[idx][1].decode("utf-8", "replace"))
        self.protos = []
        for i in range(self.proto_ids_size):
            shorty, ret, params = struct.unpack_from("<III", data, self.proto_ids_off + 12 * i)
            self.protos.append((ret, params))
        self.methods = []
        for i in range(self.method_ids_size):
            cls, proto, nam = struct.unpack_from("<HHI", data, self.method_ids_off + 8 * i)
            self.methods.append((cls, proto, nam))
        self.classes = {}  # descriptor -> {(name, proto_str): code_off}
        for i in range(self.class_defs_size):
            (cls, _acc, _sup, _if, _src, _ann, cdata, _sv) = struct.unpack_from(
                "<8I", data, self.class_defs_off + 32 * i)
            desc = self.types[cls]
            methods = {}
            if cdata:
                p = cdata
                nsf, p = uleb(data, p)
                nif, p = uleb(data, p)
                ndm, p = uleb(data, p)
                nvm, p = uleb(data, p)
                for _ in range(nsf + nif):
                    _f, p = uleb(data, p)
                    _a, p = uleb(data, p)
                # Direct and virtual lists each restart their method-index
                # delta at 0 (verified empirically on this dex).
                midx = 0
                for _ in range(ndm + nvm):
                    if _ == ndm:
                        midx = 0
                    d, p = uleb(data, p)
                    midx += d
                    _a, p = uleb(data, p)
                    coff, p = uleb(data, p)
                    mcls, mproto, mname = self.methods[midx]
                    methods[(self.strings[mname][1].decode("utf-8", "replace"),
                             self.proto_str(mproto))] = coff
            self.classes[desc] = methods

    def proto_str(self, proto_idx):
        ret, params_off = self.protos[proto_idx]
        parts = [self.types[ret]]
        if params_off:
            # type_list: uint32 size, then size x uint16 type_idx (NOT uleb).
            n = struct.unpack_from("<I", self.data, params_off)[0]
            for k in range(n):
                t = struct.unpack_from("<H", self.data, params_off + 4 + 2 * k)[0]
                parts.append(self.types[t])
        return "(" + "".join(parts[1:]) + ")" + parts[0]

    def method_ref(self, idx):
        cls, proto, nam = self.methods[idx]
        return (self.types[cls], self.strings[nam][1].decode("utf-8", "replace"),
                self.proto_str(proto))

    def string_at(self, idx):
        return self.strings[idx][1]

    def parse_code(self, code_off):
        """Return (regs, insns_off, insns, tries).
        insns: [(pc_units, opcode, length_units, raw_bytes)] with switch and
        fill-array payloads recorded as data spans. Raises DexError on any
        inconsistency (fail closed)."""
        d = self.data
        regs, ins, outs, tries_size, _dbg, insns_size = struct.unpack_from("<HHHHII", d, code_off)
        insns_off = code_off + 16
        total = insns_size
        insns = []
        pc = 0
        while pc < total:
            unit_off = insns_off + 2 * pc
            unit = struct.unpack_from("<H", d, unit_off)[0]
            op = unit & 0xFF
            if op == 0x00 and (unit >> 8) in (0x01, 0x02, 0x03):
                kind = unit >> 8
                if kind in (0x01, 0x02):
                    size = struct.unpack_from("<H", d, unit_off + 2)[0]
                    # ident + size + first_key/keys + targets, in 16-bit units
                    span_units = (4 + 2 * size) if kind == 0x01 else (2 + 4 * size)
                else:
                    elem_w = struct.unpack_from("<H", d, unit_off + 2)[0]
                    count = struct.unpack_from("<I", d, unit_off + 4)[0]
                    span_units = 4 + ((elem_w * count + 1) // 2)
                insns.append((pc, op, span_units, bytes(d[unit_off:unit_off + 2 * span_units])))
                pc += span_units
                continue
            ln = OPLEN.get(op)
            if ln is None:
                raise DexError("%s: unknown opcode 0x%02x at pc %d" % (self.name, op, pc))
            insns.append((pc, op, ln, bytes(d[unit_off:unit_off + 2 * ln])))
            pc += ln
        if pc != total:
            raise DexError("%s: code overrun pc=%d size=%d" % (self.name, pc, total))
        targets = set()
        for (pc0, op, ln, raw) in insns:
            if op == 0x28:
                off = struct.unpack_from("<b", raw, 1)[0]
                targets.add(pc0 + off)
            elif op in (0x29, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39,
                        0x3A, 0x3B, 0x3C, 0x3D):
                off = struct.unpack_from("<h", raw, 2)[0]
                targets.add(pc0 + off)
            elif op in (0x2A, 0x2B, 0x2C):
                off = struct.unpack_from("<i", raw, 2)[0]
                targets.add(pc0 + off)
        bounds = {p for (p, _, _, _) in insns}
        for t in targets:
            if t not in bounds and t != total:
                raise DexError("%s: branch target %d not on a boundary" % (self.name, t))
        tries = []
        tries_off = insns_off + 2 * total
        if total % 2 == 1:
            tries_off += 2
        for i in range(tries_size):
            start, count, hoff = struct.unpack_from("<IHH", d, tries_off + 8 * i)
            tries.append((start, count))
            if start not in bounds or ((start + count) not in bounds and (start + count) != total):
                raise DexError("%s: try range %d..%d not boundary-aligned" % (self.name, start, start + count))
        return regs, insns_off, insns, tries

    def self_check(self):
        """Parse every method's code; any inconsistency aborts."""
        for desc, methods in self.classes.items():
            for (name, _proto), coff in methods.items():
                if coff:
                    self.parse_code(coff)


# ---------------------------------------------------------------- transforms

INVOKE_INTERFACE = (0x72, 0x78)
INVOKE_STATIC = (0x71, 0x77)
MOVE_RESULT = 0x0A
MOVE_RESULT_WIDE = 0x0B
MOVE_RESULT_OBJECT = 0x0C
CONST4 = 0x12
CONST_WIDE16 = 0x16
RETURN_VOID = 0x0E
RETURN = 0x0F
RETURN_WIDE = 0x10
RETURN_OBJECT = 0x11


def _unit(op, reg=0, lit=0):
    return struct.pack("<H", (lit << 12) | (reg << 8) | op)


def _nop_units(n):
    return b"\x00\x00" * n


class Patcher:
    def __init__(self, dex):
        self.dex = dex
        self.edits = []  # (abs_off, old_bytes, new_bytes, note)
        self.report = []
        self.counts = {}  # aggregated globally by process()
        self.rename = None  # T1: (sites, new_name) for the smali round-trip

    def log(self, msg):
        self.report.append(msg)

    def edit(self, abs_off, new_bytes, note):
        old = bytes(self.dex.data[abs_off:abs_off + len(new_bytes)])
        if old == new_bytes:
            return
        self.edits.append((abs_off, old, new_bytes, note))

    def code_of(self, cls_desc, name, proto):
        methods = self.dex.classes.get(cls_desc)
        if methods is None:
            raise DexError("class %s not found" % cls_desc)
        coff = methods.get((name, proto))
        if coff is None:
            raise DexError("%s.%s%s not found" % (cls_desc, name, proto))
        if coff == 0:
            raise DexError("%s.%s%s has no code (abstract/native)" % (cls_desc, name, proto))
        return coff

    def parse(self, cls_desc, name, proto):
        coff = self.code_of(cls_desc, name, proto)
        _regs, insns_off, insns, tries = self.dex.parse_code(coff)
        return coff, insns_off, insns, tries

    def targets_in(self, insns, tries):
        """(branch_targets, try_points) that must not fall strictly inside an
        entry overwrite. Branch targets inside are fatal (a jump there could
        skip the guard return). Try-range starts/ends inside are harmless:
        the replacement (const/4 + return*) cannot throw, so no handler
        can fire for it; the OneOS precedent inserts the same guard before
        the same try ranges. Payload spans are branch targets via their
        switch, so overwriting one is caught by the branch-target check."""
        branch = set()
        for (pc0, op, ln, raw) in insns:
            if op == 0x28:
                branch.add(pc0 + struct.unpack_from("<b", raw, 1)[0])
            elif op in (0x29, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39,
                        0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F, 0x40, 0x41, 0x42, 0x43):
                branch.add(pc0 + struct.unpack_from("<h", raw, 2)[0])
            elif op in (0x2A, 0x2B, 0x2C):
                branch.add(pc0 + struct.unpack_from("<i", raw, 2)[0])
        tryp = set()
        for (s, c) in tries:
            tryp.add(s)
            tryp.add(s + c)
        return branch, tryp

    def entry_return(self, cls_desc, name, proto, ret_kind, label, required=True):
        """Overwrite the method entry with [const/4 v0,lit; return*] (+nops).
        ret_kind: 'V' (return-void), 'Z'/'I' (const/4 0 + return),
        'Z1' (const/4 1 + return), 'Z0' (const/4 0 + return),
        'L' (const/4 0 + return-object). Fail closed on interior targets.
        With required=False a method absent from this dex is skipped
        (the caller asserts globally that exactly one dex guarded it)."""
        methods = self.dex.classes.get(cls_desc)
        if methods is None or (name, proto) not in methods:
            if required:
                raise DexError("%s.%s%s not found" % (cls_desc, name, proto))
            self.log("%s: %s.%s not in this dex, skipped" % (label, cls_desc, name))
            return False
        coff, insns_off, insns, tries = self.parse(cls_desc, name, proto)
        if ret_kind == 'V':
            seq = _unit(RETURN_VOID)
            need = 1
        elif ret_kind in ('Z', 'I', 'Z0'):
            seq = _unit(CONST4, 0, 0) + _unit(RETURN)
            need = 2
        elif ret_kind == 'Z1':
            seq = _unit(CONST4, 0, 1) + _unit(RETURN)
            need = 2
        elif ret_kind == 'L':
            seq = _unit(CONST4, 0, 0) + _unit(RETURN_OBJECT)
            need = 2
        else:
            raise DexError("entry_return: unsupported return kind %r" % ret_kind)
        # accumulate whole instructions from pc 0 to >= need units
        prefix = 0
        for (pc0, _op, ln, _raw) in insns:
            prefix += ln
            if prefix >= need:
                break
        else:
            raise DexError("%s.%s: method too short for entry guard" % (cls_desc, name))
        pts, tryp = self.targets_in(insns, tries)
        inside = sorted(p for p in pts if 0 < p < prefix)
        if inside:
            raise DexError("%s.%s: branch target(s) %s inside entry window "
                           "(window %d units)" % (cls_desc, name, inside, prefix))
        try_inside = sorted(p for p in tryp if 0 < p < prefix)
        new = seq + _nop_units(prefix - need)
        self.edit(insns_off, new, "%s: %s returns at entry (%d-unit overwrite)" % (label, name, prefix))
        self.log("%s: %s%s returns at entry, %d-unit overwrite, no interior branch targets%s" %
                 (label, name, proto, prefix,
                  ("; try-range bound(s) %s inside (harmless: replacement cannot throw)" % try_inside)
                  if try_inside else ""))
        return True

    def invoke_method_idx(self, raw):
        return struct.unpack_from("<H", raw, 2)[0]

    def drop_invoke(self, insns_off, insns, idx, note, result_fix):
        """Replace insns[idx] (invoke) with nops; fix up a following
        move-result per result_fix: None (void), 'zero' (const/4 0),
        'null' (const/4 0, object). Returns units consumed."""
        pc0, op, ln, raw = insns[idx]
        if op not in (0x6E, 0x6F, 0x70, 0x71, 0x72, 0x74, 0x75, 0x76, 0x77, 0x78):
            raise DexError("drop_invoke: pc %d is not an invoke (op 0x%02x)" % (pc0, op))
        self.edit(insns_off + 2 * pc0, _nop_units(ln), note)
        nxt = insns[idx + 1] if idx + 1 < len(insns) else None
        if result_fix is None:
            if nxt is not None and nxt[1] in (MOVE_RESULT, MOVE_RESULT_WIDE, MOVE_RESULT_OBJECT):
                raise DexError("drop_invoke: void call at pc %d followed by move-result" % pc0)
            return ln
        if nxt is None or nxt[1] not in (MOVE_RESULT, MOVE_RESULT_WIDE, MOVE_RESULT_OBJECT):
            # The result may be legitimately discarded (R8/d8 omit move-result
            # when the value is unused: e.g. LockSettingsService.createNewUser
            # drops onUserAdded's int result). Nopping the call alone is safe;
            # nothing downstream can observe the missing result.
            if nxt is not None and nxt[1] == 0x0D:
                raise DexError("drop_invoke: non-void call at pc %d followed by move-exception" % pc0)
            return ln
        npc, nop, nln, nraw = nxt
        reg = (nraw[1]) if False else None
        # move-result operand: destination register is in the high byte of unit 0
        reg = (struct.unpack_from("<H", nraw, 0)[0] >> 8) & 0xFF
        if nop == MOVE_RESULT_WIDE:
            # replace invoke + move-result-wide (ln+1 units) with
            # const-wide/16 vReg,0 (2 units) + nops
            total = ln + 1
            new = struct.pack("<HH", (reg << 8) | CONST_WIDE16, 0) + _nop_units(total - 2)
            self.edit(insns_off + 2 * pc0, new, note + " (wide zero result)")
            return total
        self.edit(insns_off + 2 * npc, _unit(CONST4, reg, 0), note + " (zero/null result)")
        return ln

    def for_each_method(self):
        for desc, methods in self.dex.classes.items():
            for (name, proto), coff in methods.items():
                if coff:
                    yield desc, name, proto, coff


# ---------------------------------------------------------------- T1: gvld

def transform_gvld(p, new_name=b"gvld"):
    dex = p.dex
    vold_ids = [i for i, (_off, s) in enumerate(dex.strings) if s == b"vold"]
    if len(vold_ids) > 1:
        raise DexError("T1: expected at most one string 'vold' per dex, found %d" % len(vold_ids))
    if not vold_ids:
        # This dex has no 'vold' string at all (e.g. classes3.dex): nothing to do.
        p.log("T1: no 'vold' string in this dex")
        return
    vold_idx = vold_ids[0]
    sites = []  # (cls, name, proto, pc, string_idx)
    for desc, name, proto, coff in p.for_each_method():
        if "IVold" in desc or "IInstalld" in desc:
            continue
        _regs, insns_off, insns, _tries = dex.parse_code(coff)
        for k, (pc0, op, ln, raw) in enumerate(insns):
            if op == 0x1A:  # const-string
                sidx = struct.unpack_from("<H", raw, 2)[0]
                if sidx == vold_idx:
                    sites.append((desc, name, proto, pc0, k, insns))
            elif op == 0x1B:  # const-string/jumbo
                sidx = struct.unpack_from("<I", raw, 2)[0]
                if sidx == vold_idx:
                    sites.append((desc, name, proto, pc0, k, insns))
    # Every const-string 'vold' in this dex must be a ServiceManager lookup;
    # the global count (exactly 3 across all dexes) is asserted by process().
    for (desc, name, proto, pc0, k, insns) in sites:
        nxt = insns[k + 1]
        if nxt[1] not in (0x6E, 0x6F, 0x70, 0x71, 0x72, 0x74, 0x75, 0x76, 0x77, 0x78):
            raise DexError("T1: 'vold' string in %s.%s not followed by an invoke" % (desc, name))
        cls2, mname, mproto = dex.method_ref(p.invoke_method_idx(nxt[3]))
        if cls2 != "Landroid/os/ServiceManager;" or mname not in ("getService", "getServiceOrThrow"):
            raise DexError("T1: 'vold' string in %s.%s followed by %s.%s, not ServiceManager.getService*" %
                           (desc, name, cls2, mname))
        p.log("T1: %s.%s%s: 'vold' lookup -> ServiceManager.%s" % (desc, name, proto, mname))
    p.counts["gvld_sites"] = p.counts.get("gvld_sites", 0) + len(sites)
    if not sites:
        return
    off, _s = dex.strings[vold_idx]
    _size, p0 = uleb(dex.data, off)
    if bytes(dex.data[p0:p0 + 4]) != b"vold" or dex.data[p0 + 4] != 0:
        raise DexError("T1: string data for 'vold' is not the expected MUTF-8 bytes")
    # The rename itself goes through the dexlib2 round-trip in
    # tools/dex_resort.py (an in-place byte edit would break
    # string_ids ordering). Record the spec; process() applies it
    # after the same-size T2-T7 edits, then re-verifies.
    p.rename = ([(desc, name, proto, pc0)
                 for (desc, name, proto, pc0, _k, _insns) in sites], new_name)
    p.counts["gvld_patched"] = 1
    p.log("T1: string 'vold' -> 'gvld' via dexlib2 round-trip (%d site(s))"
          % len(sites))


# ---------------------------------------------------------------- T2: vold keys

VOLD_KEYS = ("createUserStorageKeys", "destroyUserStorageKeys",
             "setCeStorageProtection", "unlockCeStorage", "lockCeStorage")


def transform_vold_keys(p):
    dex = p.dex
    counts = {n: 0 for n in VOLD_KEYS}
    for desc, name, proto, coff in p.for_each_method():
        if desc.startswith("Landroid/os/IVold"):
            continue
        _regs, insns_off, insns, _tries = dex.parse_code(coff)
        for k, (pc0, op, ln, raw) in enumerate(insns):
            if op not in INVOKE_INTERFACE:
                continue
            cls2, mname, mproto = dex.method_ref(p.invoke_method_idx(raw))
            if cls2 == "Landroid/os/IVold;" and mname in VOLD_KEYS:
                if not mproto.endswith(")V"):
                    raise DexError("T2: IVold.%s has non-void return %s in %s.%s "
                                   "(OneOS builds: all void; refusing to guess a success value)" %
                                   (mname, mproto, desc, name))
                p.drop_invoke(insns_off, insns, k, "T2: IVold.%s dropped" % mname, None)
                counts[mname] += 1
    for n, c in counts.items():
        p.counts["voldkey_" + n] = p.counts.get("voldkey_" + n, 0) + c
    # NOTE: a zero count for setCeStorageProtection is resolved GLOBALLY by
    # process() via _verify_ce_neuter (the intermediary lives in one dex only).
    p.log("T2: IVold key calls dropped: %s" %
          ", ".join("%s x%d" % (n, counts[n]) for n in VOLD_KEYS))


def _verify_ce_neuter(p):
    """Verify the prebuilt blob's neuter of the CE-key intermediary."""
    dex = p.dex
    cls = "Lcom/android/server/StorageManagerService$StorageManagerInternalImpl;"
    try:
        _coff, _off, insns, _t = p.parse(cls, "setCeStorageProtection", "(I[B)V")
    except DexError as e:
        raise DexError("T2: setCeStorageProtection has no call sites AND the "
                       "intermediary %s is missing (%s); refusing to assume coverage" % (cls, e))
    if not insns or insns[0][1] != RETURN_VOID:
        raise DexError("T2: setCeStorageProtection has no call sites but %s does not "
                       "return at entry (first op 0x%02x); refusing to assume coverage" %
                       (cls, insns[0][1] if insns else -1))
    for (pc0, op, ln, raw) in insns:
        if op in (0x6E, 0x6F, 0x70, 0x71, 0x72, 0x74, 0x75, 0x76, 0x77, 0x78):
            cls2, mname, _mp = dex.method_ref(p.invoke_method_idx(raw))
            if cls2 == "Landroid/os/IVold;":
                raise DexError("T2: neutered intermediary %s still calls IVold.%s at pc %d" %
                               (cls, mname, pc0))
    p.counts["ce_neuter_verified"] = 1
    p.log("T2: setCeStorageProtection: 0 client call sites; intermediary %s "
          "verified already neutered in the prebuilt blob (return-void at entry, no IVold call)" % cls)


# ---------------------------------------------------------------- T3: gatekeeper

def transform_gatekeeper(p):
    dex = p.dex
    lss = "Lcom/android/server/locksettings/LockSettingsService;"
    if p.entry_return(lss, "setLockCredentialInternal",
                      "(Lcom/android/internal/widget/LockscreenCredential;"
                      "Lcom/android/internal/widget/LockscreenCredential;IZ)Z", 'Z', "T3",
                      required=False):
        p.counts["gk_guard_setlock"] = 1
    if p.entry_return(lss, "setLockCredentialWithTokenInternalLocked",
                      "(Lcom/android/internal/widget/LockscreenCredential;J[BI)Z", 'Z', "T3",
                      required=False):
        p.counts["gk_guard_token"] = 1
    enroll = clear = report = 0
    for desc, name, proto, coff in p.for_each_method():
        if not desc.startswith("Lcom/android/server/locksettings/"):
            continue
        _regs, insns_off, insns, _tries = dex.parse_code(coff)
        for k, (pc0, op, ln, raw) in enumerate(insns):
            if op not in INVOKE_INTERFACE:
                continue
            cls2, mname, mproto = dex.method_ref(p.invoke_method_idx(raw))
            if cls2 != "Landroid/service/gatekeeper/IGateKeeperService;":
                continue
            if mname == "enroll" and mproto == "(I[B[B[B)Landroid/service/gatekeeper/GateKeeperResponse;":
                p.drop_invoke(insns_off, insns, k, "T3: IGateKeeperService.enroll dropped", 'null')
                enroll += 1
            elif mname == "clearSecureUserId" and mproto == "(I)V":
                p.drop_invoke(insns_off, insns, k, "T3: IGateKeeperService.clearSecureUserId dropped", None)
                clear += 1
            elif mname == "reportDeviceSetupComplete" and mproto == "()V":
                p.drop_invoke(insns_off, insns, k, "T3: IGateKeeperService.reportDeviceSetupComplete dropped", None)
                report += 1
    p.counts["gk_enroll"] = p.counts.get("gk_enroll", 0) + enroll
    p.counts["gk_clear"] = p.counts.get("gk_clear", 0) + clear
    p.counts["gk_report"] = p.counts.get("gk_report", 0) + report
    p.log("T3: gatekeeper sites dropped: enroll x%d, clearSecureUserId x%d, reportDeviceSetupComplete x%d" %
          (enroll, clear, report))


# ---------------------------------------------------------------- T4: weaver

def transform_weaver(p):
    if p.entry_return("Lcom/android/server/locksettings/SyntheticPasswordManager;",
                      "getWeaverService", "()Landroid/hardware/weaver/IWeaver;", 'L', "T4",
                      required=False):
        p.counts["weaver_guard"] = 1


# ---------------------------------------------------------------- T5: wipe secrets

def transform_wipe(p):
    if p.entry_return("Lcom/android/server/recoverysystem/RecoverySystemService;",
                      "deleteSecrets", "()V", 'V', "T5", required=False):
        p.counts["wipe_guard"] = 1
    dex = p.dex
    # fail closed: no dangerous call/string outside deleteSecrets() / IVold$Stub
    danger_calls = {("Landroid/hardware/security/secretkeeper/ISecretkeeper;", "deleteAll"),
                    ("Landroid/os/IVold;", "destroyMetadataKey"),
                    ("Landroid/os/IVold;", "destroySystemStorageKey"),
                    ("Landroid/os/IVold;", "destroyUserStorageKeys2")}
    bad = []
    for desc, name, proto, coff in p.for_each_method():
        if desc.startswith("Landroid/os/IVold"):
            continue
        if desc == "Lcom/android/server/recoverysystem/RecoverySystemService;" and name == "deleteSecrets":
            continue
        _regs, insns_off, insns, _tries = dex.parse_code(coff)
        for (pc0, op, ln, raw) in insns:
            if op in (0x6E, 0x6F, 0x70, 0x71, 0x72, 0x74, 0x75, 0x76, 0x77, 0x78):
                cls2, mname, _mp = dex.method_ref(p.invoke_method_idx(raw))
                if (cls2, mname) in danger_calls:
                    bad.append("%s.%s%s pc %d: %s.%s" % (desc, name, proto, pc0, cls2, mname))
            if op == 0x1A:
                sidx = struct.unpack_from("<H", raw, 2)[0]
                if dex.string_at(sidx) == b"sys.erase_secure_element":
                    bad.append("%s.%s%s pc %d: sys.erase_secure_element string" % (desc, name, proto, pc0))
    if bad:
        raise DexError("T5: dangerous wipe calls remain outside deleteSecrets():\n  " + "\n  ".join(bad))
    p.log("T5: no ISecretkeeper.deleteAll / IVold destroy* / erase_secure_element outside deleteSecrets()")


# ---------------------------------------------------------------- T7: storage guards

VOLD_DROP = ("destroyUserStorage", "prepareUserStorage", "format", "partition",
             "forgetPartition", "moveStorage", "onUserRemoved", "abortChanges",
             "startCheckpoint", "shutdown", "sdlockErase")
INSTALLD_DROP = ("destroyUserData", "destroyAppData", "clearAppData",
                 "clearAppDataWithPreservedCacheEntries", "destroyAppDataSnapshot",
                 "destroyCeSnapshotsNotSpecified", "destroyPccData", "rmPackageDir",
                 "cleanupInvalidPackageDirs", "moveCompleteApp", "moveAppDataPath",
                 "copyAppDataPath", "migrateAppData", "restoreAppDataSnapshot",
                 "onPrivateVolumeRemoved", "freeCache", "reconcileSdkData")
KEYSTORE_DROP = ("clearNamespace", "onUserRemoved", "onUserLskfRemoved", "onUserAdded",
                 "migrateKeyNamespace", "initUserSuperKeys", "deleteAllKeys")


def transform_storage(p):
    dex = p.dex
    counts = {}
    for desc, name, proto, coff in p.for_each_method():
        if desc.startswith("Landroid/os/IVold") or desc.startswith("Landroid/os/IInstalld"):
            continue
        _regs, insns_off, insns, _tries = dex.parse_code(coff)
        for k, (pc0, op, ln, raw) in enumerate(insns):
            if op in INVOKE_INTERFACE:
                cls2, mname, mproto = dex.method_ref(p.invoke_method_idx(raw))
                table = None
                if cls2 == "Landroid/os/IVold;":
                    table = VOLD_DROP
                elif cls2 == "Landroid/os/IInstalld;":
                    table = INSTALLD_DROP
                if table is not None and mname in table:
                    if not mproto.endswith(")V"):
                        raise DexError("T7: %s.%s has non-void return %s in %s.%s" %
                                       (cls2, mname, mproto, desc, name))
                    p.drop_invoke(insns_off, insns, k, "T7: %s.%s dropped" % (cls2, mname), None)
                    counts["%s.%s" % (cls2, mname)] = counts.get("%s.%s" % (cls2, mname), 0) + 1
            elif op in INVOKE_STATIC:
                cls2, mname, mproto = dex.method_ref(p.invoke_method_idx(raw))
                if cls2 == "Landroid/security/AndroidKeyStoreMaintenance;" and mname in KEYSTORE_DROP:
                    if mproto.endswith(")V"):
                        p.drop_invoke(insns_off, insns, k, "T7: AndroidKeyStoreMaintenance.%s dropped" % mname, None)
                    elif mproto.endswith(")I"):
                        p.drop_invoke(insns_off, insns, k, "T7: AndroidKeyStoreMaintenance.%s dropped" % mname, 'zero')
                    else:
                        raise DexError("T7: AndroidKeyStoreMaintenance.%s return %s (expected V or I)" %
                                       (mname, mproto))
                    counts["AndroidKeyStoreMaintenance.%s" % mname] = counts.get(
                        "AndroidKeyStoreMaintenance.%s" % mname, 0) + 1
    for key in ("Landroid/os/IInstalld;.destroyUserData", "Landroid/os/IVold;.destroyUserStorage",
                "Landroid/os/IVold;.prepareUserStorage",
                "AndroidKeyStoreMaintenance.clearNamespace"):
        p.counts["t7_" + key] = p.counts.get("t7_" + key, 0) + counts.get(key, 0)
    p.log("T7: storage calls dropped (%d total): %s" %
          (sum(counts.values()), ", ".join("%s x%d" % kv for kv in sorted(counts.items()))))
    # preparer
    if p.entry_return("Lcom/android/server/pm/UserDataPreparer;", "destroyUserDataLI",
                      "(Ljava/lang/String;II)V", 'V', "T7", required=False):
        p.counts["preparer_guard"] = 1
    # the one wipe call -> nops (dead code behind the entry return; OneOS logs
    # here via an inserted Slog call, which a same-size patch cannot express).
    # Lineage calls it from prepareUserDataLI, not a wipeData method, so scan
    # every method of the class.
    wiped = 0
    preparer_methods = dex.classes.get("Lcom/android/server/pm/UserDataPreparer;", {})
    for (mname, mproto), mcoff in preparer_methods.items():
        if not mcoff:
            continue
        _r, ioff, im, _t = dex.parse_code(mcoff)
        for k, (pc0, op, ln, raw) in enumerate(im):
            if op in INVOKE_STATIC:
                cls2, mn2, mp2 = dex.method_ref(p.invoke_method_idx(raw))
                if cls2 == "Landroid/os/RecoverySystem;" and mn2 == "rebootPromptAndWipeUserData":
                    p.drop_invoke(ioff, im, k, "T7: rebootPromptAndWipeUserData dropped (nop)", None)
                    wiped += 1
    p.counts["wipe_calls"] = p.counts.get("wipe_calls", 0) + wiped
    if wiped > 1:
        raise DexError("T7: expected at most one rebootPromptAndWipeUserData call, found %d" % wiped)
    p.log("T7: UserDataPreparer.destroyUserDataLI returns at entry; wipe call nopped (x%d)" % wiped)
    # isCeStorageUnlocked -> true; isQuotaSupported -> false
    if p.entry_return("Lcom/android/server/StorageManagerService;", "isCeStorageUnlocked",
                      "(I)Z", 'Z1', "T7b", required=False):
        p.counts["ce_unlocked_guard"] = 1
    if p.entry_return("Lcom/android/server/usage/StorageStatsService;", "isQuotaSupported",
                      "(Ljava/lang/String;Ljava/lang/String;)Z", 'Z0', "T7c", required=False):
        p.counts["quota_guard"] = 1


# ---------------------------------------------------------------- driver

def load_dexes(jar_path):
    out = []
    with zipfile.ZipFile(jar_path) as zf:
        for info in zf.infolist():
            if info.filename.endswith(".dex"):
                out.append((info.filename, zf.read(info.filename), info))
    if not out:
        raise DexError("%s: no .dex entries" % jar_path)
    return out


def apply_transforms(dex):
    p = Patcher(dex)
    transform_gvld(p)
    transform_vold_keys(p)
    transform_gatekeeper(p)
    transform_weaver(p)
    transform_wipe(p)
    transform_storage(p)
    return p


def fix_header(data):
    # signature: SHA-1 of everything after the 32-byte signature field;
    # checksum: adler32 of everything after the 12-byte checksum field.
    sig = hashlib.sha1(bytes(data[32:])).digest()
    data[12:32] = sig
    chk = zlib.adler32(bytes(data[12:])) & 0xFFFFFFFF
    struct.pack_into("<I", data, 8, chk)


def assert_global_counts(counts):
    """Fail-closed global assertions: the 3 gvld sites, the 5 vold key
    calls, the gatekeeper/weaver/wipe/preparer guards and the run-25
    damage paths must each be covered exactly as specified, across all
    dex files together (sites split across classes.dex/classes2.dex)."""
    def need(key, want, what):
        got = counts.get(key, 0)
        if got != want:
            raise DexError("global: %s: found %d, expected %s (%s)" % (key, got, want, what))
    need("gvld_sites", 3, "exactly 3 ServiceManager 'vold' lookups")
    for n in VOLD_KEYS:
        if n == "setCeStorageProtection":
            # Covered either by dropped call sites or by the verified
            # pre-existing neuter of the StorageManagerInternalImpl
            # intermediary (see _verify_ce_neuter).
            if counts.get("voldkey_" + n, 0) < 1 and counts.get("ce_neuter_verified", 0) < 1:
                raise DexError("global: IVold.setCeStorageProtection: no call sites and "
                               "no verified neuter of the intermediary")
            continue
        if counts.get("voldkey_" + n, 0) < 1:
            raise DexError("global: IVold.%s: no call sites found (expected at least one)" % n)
    if counts.get("gk_enroll", 0) < 1:
        raise DexError("global: no IGateKeeperService.enroll call sites found")
    if counts.get("gk_clear", 0) < 1:
        raise DexError("global: no IGateKeeperService.clearSecureUserId call sites found")
    if counts.get("gk_report", 0) < 1:
        raise DexError("global: no IGateKeeperService.reportDeviceSetupComplete call sites found")
    need("gk_guard_setlock", 1, "setLockCredentialInternal guarded once")
    need("gk_guard_token", 1, "setLockCredentialWithTokenInternalLocked guarded once")
    need("weaver_guard", 1, "getWeaverService guarded once")
    need("wipe_guard", 1, "deleteSecrets guarded once")
    need("preparer_guard", 1, "destroyUserDataLI guarded once")
    need("wipe_calls", 1, "exactly one rebootPromptAndWipeUserData call")
    need("ce_unlocked_guard", 1, "isCeStorageUnlocked guarded once")
    need("quota_guard", 1, "isQuotaSupported guarded once")
    for key in ("Landroid/os/IInstalld;.destroyUserData", "Landroid/os/IVold;.destroyUserStorage",
                "Landroid/os/IVold;.prepareUserStorage",
                "AndroidKeyStoreMaintenance.clearNamespace"):
        if counts.get("t7_" + key, 0) < 1:
            raise DexError("global: expected call %s not found (the run-25 damage path must be covered)" % key)


def process(in_jar, out_jar, report_path, dryrun=False, toolchain=None,
            work_base=None):
    entries = load_dexes(in_jar)
    # Phase 1: parse + record transforms (no bytes written yet).
    patchers = []
    counts = {}
    for (fname, raw, _info) in entries:
        dex = Dex(raw, fname)
        dex.self_check()
        p = apply_transforms(dex)
        patchers.append((fname, dex, p))
        for k, v in p.counts.items():
            counts[k] = counts.get(k, 0) + v
    # Phase 2: global fail-closed assertions. The setCeStorageProtection
    # neuter check runs here (the intermediary lives in one dex only).
    if counts.get("voldkey_setCeStorageProtection", 0) == 0:
        for (_fname, _dex, _p) in patchers:
            if "Lcom/android/server/StorageManagerService$StorageManagerInternalImpl;" in _dex.classes:
                _verify_ce_neuter(_p)
                counts["ce_neuter_verified"] = 1
                break
        else:
            raise DexError("global: IVold.setCeStorageProtection has no call sites and the "
                           "StorageManagerInternalImpl intermediary is absent from every dex")
    assert_global_counts(counts)
    # Phase 3: apply edits, round-trip the T1 rename, re-verify, fix headers.
    report_lines = []
    new_dexes = {}
    for (fname, dex, p) in patchers:
        for (off, old, new, note) in p.edits:
            if bytes(dex.data[off:off + len(new)]) != old:
                raise DexError("%s: edit target changed under us at %d (%s)" % (fname, off, note))
            dex.data[off:off + len(new)] = new
        data = bytes(dex.data)
        rlines = []
        if p.rename is not None:
            if toolchain is None:
                raise DexError("%s: T1 rename needs the smali toolchain "
                               "(see tools/dex_resort.py)" % fname)
            import dex_resort
            sites, new_name = p.rename
            data, rlines = dex_resort.rename_dex_bytes(
                data, fname, "vold", new_name.decode("utf-8"), toolchain,
                work_base, expect_sites=sites)
            if data is None:
                raise DexError("%s: T1 recorded a rename but the round-trip "
                               "found no string to rename" % fname)
        dex2 = Dex(data, fname + " (patched)")
        dex2.self_check()
        verify_clean(dex2)
        fix_header(dex2.data)
        new_dexes[fname] = bytes(dex2.data)
        report_lines.append("== %s: %d edits%s" % (
            fname, len(p.edits), " + dexlib2 round-trip" if p.rename else ""))
        report_lines.extend("  " + r for r in p.report)
        report_lines.extend("  dex_resort: " + r for r in rlines)
        report_lines.append("  header signature/checksum recomputed")
    report_lines.append("global counts: %s" % ", ".join("%s=%s" % kv for kv in sorted(counts.items())))
    if dryrun:
        report_lines.append("DRY RUN: no jar written")
    else:
        with zipfile.ZipFile(in_jar) as zin:
            with zipfile.ZipFile(out_jar, "w", zipfile.ZIP_DEFLATED) as zout:
                for info in zin.infolist():
                    data = zin.read(info.filename)
                    if info.filename in new_dexes:
                        data = new_dexes[info.filename]
                    zout.writestr(info, data)
    with open(report_path, "w") as f:
        f.write("\n".join(report_lines) + "\n")
    print("\n".join(report_lines))


def verify_clean(dex):
    """After patching, the dangerous patterns must be gone (except inside the
    stub/guarded methods, which the transforms already excluded)."""
    p = Patcher(dex)
    # T1: no 'vold' string referenced by a ServiceManager.getService lookup
    vold_ids = [i for i, (_o, s) in enumerate(dex.strings) if s == b"vold"]
    if vold_ids:
        raise DexError("verify: string 'vold' still present in string table")
    # T2/T7: no remaining target calls outside excluded classes
    for desc, name, proto, coff in p.for_each_method():
        if desc.startswith("Landroid/os/IVold") or desc.startswith("Landroid/os/IInstalld"):
            continue
        _r, _o, insns, _t = dex.parse_code(coff)
        for (pc0, op, ln, raw) in insns:
            if op in (0x6E, 0x6F, 0x70, 0x71, 0x72, 0x74, 0x75, 0x76, 0x77, 0x78):
                cls2, mname, _mp = dex.method_ref(p.invoke_method_idx(raw))
                if cls2 == "Landroid/os/IVold;" and mname in VOLD_KEYS:
                    raise DexError("verify: IVold.%s call remains in %s.%s" % (mname, desc, name))
                if cls2 == "Landroid/os/IVold;" and mname in VOLD_DROP:
                    raise DexError("verify: IVold.%s call remains in %s.%s" % (mname, desc, name))
                if cls2 == "Landroid/os/IInstalld;" and mname in INSTALLD_DROP:
                    raise DexError("verify: IInstalld.%s call remains in %s.%s" % (mname, desc, name))
                if cls2 == "Landroid/security/AndroidKeyStoreMaintenance;" and mname in KEYSTORE_DROP:
                    raise DexError("verify: keystore.%s call remains in %s.%s" % (mname, desc, name))
                if cls2 == "Landroid/service/gatekeeper/IGateKeeperService;" and mname in (
                        "enroll", "clearSecureUserId", "reportDeviceSetupComplete"):
                    raise DexError("verify: gatekeeper.%s call remains in %s.%s" % (mname, desc, name))


def main(argv):
    if "--selfcheck" in argv:
        in_jar = argv[argv.index("--in") + 1]
        total_methods = 0
        with zipfile.ZipFile(in_jar) as zf:
            for name in sorted(zf.namelist()):
                if not name.endswith(".dex"):
                    continue
                dex = Dex(zf.read(name), name)
                dex.self_check()
                n = sum(len(m) for m in dex.classes.values())
                total_methods += n
                print("selfcheck OK: %s (%d classes, %d methods)" % (name, len(dex.classes), n))
        print("selfcheck OK: %d methods total" % total_methods)
        return 0
    if "--verify" in argv:
        in_jar = argv[argv.index("--in") + 1]
        dexes = []
        for (fname, raw, _i) in load_dexes(in_jar):
            dex = Dex(raw, fname)
            dex.self_check()
            verify_clean(dex)
            dexes.append(dex)
        # entry guards must be present in exactly one dex each
        guards = [
            ("Lcom/android/server/locksettings/LockSettingsService;", "setLockCredentialInternal",
             "(Lcom/android/internal/widget/LockscreenCredential;"
             "Lcom/android/internal/widget/LockscreenCredential;IZ)Z", RETURN),
            ("Lcom/android/server/locksettings/SyntheticPasswordManager;", "getWeaverService",
             "()Landroid/hardware/weaver/IWeaver;", RETURN_OBJECT),
            ("Lcom/android/server/recoverysystem/RecoverySystemService;", "deleteSecrets",
             "()V", RETURN_VOID),
            ("Lcom/android/server/pm/UserDataPreparer;", "destroyUserDataLI",
             "(Ljava/lang/String;II)V", RETURN_VOID)]
        for (cls, name, proto, kind) in guards:
            found = 0
            for dex in dexes:
                methods = dex.classes.get(cls, {})
                if (name, proto) not in methods:
                    continue
                p = Patcher(dex)
                _c, ioff, insns, _t = p.parse(cls, name, proto)
                first = insns[0]
                if kind == RETURN_VOID:
                    ok = first[1] == RETURN_VOID
                else:
                    # value guards: [const/4 v0, 0; return*]
                    ok = (first[1] == CONST4 and len(insns) > 1 and insns[1][1] == kind
                          and (struct.unpack_from("<H", first[3], 0)[0] >> 12) == 0)
                if not ok:
                    raise DexError("verify: %s.%s does not return at entry (first ops %s)" %
                                   (cls, name, [hex(i[1]) for i in insns[:2]]))
                found += 1
            if found != 1:
                raise DexError("verify: %s.%s found in %d dexes, expected exactly 1" %
                               (cls, name, found))
        print("VERIFY OK: %s" % in_jar)
        return 0
    in_jar = argv[argv.index("--in") + 1]
    out_jar = argv[argv.index("--out") + 1]
    report_path = argv[argv.index("--report") + 1] if "--report" in argv else "/tmp/dex_patch_report.txt"
    smali_dir = argv[argv.index("--smali-dir") + 1] if "--smali-dir" in argv else None
    work_base = os.environ.get("DEXRESORT_TMP",
                               os.path.expanduser("~/workspace/altbuild/tmp"))
    os.makedirs(work_base, exist_ok=True)
    from dex_resort import Toolchain
    toolchain = Toolchain(smali_dir=smali_dir)
    process(in_jar, out_jar, report_path, dryrun="--dryrun" in argv,
            toolchain=toolchain, work_base=work_base)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
