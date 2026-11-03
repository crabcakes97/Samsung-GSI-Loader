/* gvld_patch.c — guest own-vold-name binary patcher (CronchGSI 6.20, rewritten 6.23, rewritten 6.24).
 *
 * Re-implements the MECHANISM OneOS documents for its vold_patched binary
 * patch (switcher/patches/guest_own_vold.py, studied read-only; this code
 * is written fresh, credited to fahadalijaved/OneOS in CREDITS): the
 * guest's storage daemon registers under a guest-private binder name
 * ("gvld") instead of "vold", so the guest framework (services_isolated.jar,
 * which resolves "gvld") never talks to the host's vold in the shared
 * servicemanager.
 *
 * 6.24 REWRITE — the 6.23 classifier was wrong in the way it decided
 * what a reference IS. It took the first bl within 24 instructions and
 * named the use by that callee. That misreads the real vold binary in
 * three ways, all proved by disassembly of the exported guest binary:
 *   (a) the log-tag use at 0x9d110 hoists the literal into callee-saved
 *       x22 before a loop; the first bl after the load is an unrelated
 *       umount2 call, and the real consumer is a mov into x1 much later;
 *   (b) the log-tag uses at 0x9d340/0x9d3a4 reach the log helper with an
 *       unconditional branch to a shared block; the linear window walks
 *       past the branch into an unrelated mount block;
 *   (c) the PLT stubs are unnamed for the statically-linked log helper,
 *       so "unknown callee" was read as OTHER even though every one of
 *       those sites is the same log helper with the same shape.
 * The 6.23 build therefore LEARNed on the real binary. The 6.24 design
 * below is the second-opinion prescription, verified by that reviewer
 * against the real binaries before it was written: approach (a)+(c)
 * combined, (b) as corroboration only, first-bl matching dropped
 * entirely.
 *
 * 6.24 design:
 *   1. Find the references. Look for adrp+add (the add up to 3
 *      instructions after the adrp) and adr pointing at a standalone
 *      NUL-bounded "vold". A target that is only a suffix of a longer
 *      string is a LEARN, not a candidate. Require exactly one
 *      standalone literal: zero, or two or more, is a LEARN.
 *   2. Classify each reference by following its register forward.
 *      Start from the register rd that the adrp/add or adr wrote, and
 *      walk forward linearly. Follow "mov x_n, rd". Follow
 *      unconditional b into its target block. Stop at the first bl or
 *      tail b, or at the end of the function. If the value sits in a
 *      callee-saved register (x19-x28) at a call, keep scanning past
 *      the call: the value survives it.
 *   3. Tag the use. SERVICE: at the call the literal is in x1 and the
 *      callee is String16::String16(char const*) (x0 stack-derived);
 *      also SERVICE for String16::String16(char const*, size_t) when
 *      the length argument is the constant 4. LOGTAG: the literal is
 *      in x1, w0 is a small constant, x2 is a format string loaded via
 *      adrp/add, and the callee is a local (non-PLT) function,
 *      corroborated by its body (large stack frame, calls __errno,
 *      reaches a log/write call, directly or through one local hop).
 *      All LOGTAG sites must share one callee. Anything else is
 *      UNKNOWN and the result is LEARN.
 *   4. Decision. Patch only if there is at least one SERVICE reference
 *      and every other reference is a proven LOGTAG. Exit 2 (LEARN)
 *      with the per-reference trace otherwise.
 *   5. Rewrite by rename in place. Change the one standalone literal
 *      "vold\0" to "gvld\0". This also renames the log tags, which is
 *      harmless and arguably better (guest-vold logs tell apart from
 *      host-vold logs). No surgical retarget: it would need a cave or
 *      a donor literal, more machinery than the rename needs.
 *   6. Cross-check. If .symtab symbols are present, confirm that the
 *      SERVICE site lies inside VoldNativeService::start. Logged, never
 *      gating: the symbols are usually stripped.
 *   7. Verify the output. Diff the output against the input: the only
 *      changed bytes are the literal's first two bytes ('v'->'g',
 *      'o'->'v'; 'l' and 'd' are already equal, so the 4-byte literal
 *      field changes in exactly 2 positions). Re-run the full
 *      classification on the output: zero "vold" references, the same
 *      reference count on "gvld". Confirm the output is the same size
 *      as the input.
 *   8. The runtime gate lives in zygote_exec.c (6.23, unchanged): it
 *      polls "service check gvld" before the guest system_server
 *      starts. The AIDL try_start tbz patch stays out of scope.
 *
 * What it deliberately does NOT do (documented gap, PATCHES.md): the
 * VendorVoldNativeService::try_start tbz->b patch that stops the guest
 * vold registering the AIDL name android.system.vold.IVold/default.
 * The AIDL registration remains a known residual surface, measured by
 * the staging scripts, until a generic design for it exists.
 *
 * Fail-closed design:
 *   - exit 0: the one literal patched, verification passed. Output
 *     written, verified byte-identical except the intended bytes.
 *     The staging script bind-mounts it.
 *   - exit 2 (LEARN): no standalone literal, more than one, no
 *     service-name reference, a suffix reference, an UNKNOWN
 *     reference, or any analysis failure. NO output is written.
 *     Diagnostics go to stdout for the staging log (every reference,
 *     its register, path, callee and class) so the next design step
 *     has real-device evidence. The staging script ABORTS on this
 *     code when the patch is required — never boot with
 *     half-isolation (framework asking for "gvld" that nothing owns).
 *   - exit 1: I/O or usage error, or post-patch verification failure.
 *
 * Usage: gvld_patch <input-file> <output-file>
 * Reads the whole input (refuses files over 64 MiB), never modifies the
 * input, preserves the input's permission bits on the output.
 * Plain C, no dependencies beyond libc. Build for the device with the
 * NDK aarch64 clang (static, stripped, like zygote_exec); the same
 * source builds on the host for testing.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <elf.h>

#define MAX_SIZE (64u * 1024u * 1024u)
#define WALK_CAP 2048    /* instructions walked per reference, at most */
#define BODY_CAP 256     /* instructions scanned per callee body */
#define MAX_VISITED 1024 /* distinct addresses visited per walk */

/* Reference classes. */
#define CLS_SERVICE 1
#define CLS_LOGTAG  2
#define CLS_UNKNOWN 3
#define CLS_SUFFIX  4

/* AArch64 relocation types we resolve. */
#define R_AARCH64_GLOB_DAT  1025
#define R_AARCH64_JUMP_SLOT 1026

struct plt_stub {
    uint64_t addr;      /* vaddr of the stub's adrp */
    const char *name;   /* symbol name from the relocation, or NULL */
};

struct ref {
    uint64_t insn_addr; /* vaddr of the adrp/adr */
    int rd;             /* register the load wrote */
    uint64_t lit_addr;  /* vaddr of the literal */
    size_t lit_off;     /* file offset of the literal */
    int is_suffix;      /* target is a suffix (non-standalone) literal */
    int gap;            /* 0 = adr, else 1..3 (add position after adrp) */
    int cls;            /* CLS_* */
    uint64_t consumer_addr; /* vaddr of the consuming bl / tail b */
    char callee[96];    /* PLT symbol name, "local:0x...", or "indirect" */
    uint64_t callee_addr;
    int steps;          /* instructions walked to the consumer */
    int holder_at_call; /* register holding the literal at the consumer */
    int w0_imm;         /* -1 when w0 was not a tracked constant */
    int w2_imm;         /* -1 when w2 was not a tracked constant */
    int x0_stack;       /* x0 was derived from sp at the consumer */
    char path[224];     /* compact walk trace: renames, branches, skips */
};

struct analysis {
    struct ref *refs;
    size_t nrefs, cap;
    size_t nstandalone; /* standalone literals found for the target */
    size_t lit_off;     /* file offset of the single standalone literal */
    uint64_t lit_addr;
    size_t nsuffix;     /* suffix (tail-merge) candidates in .rodata */
    int nservice, nlogtag;
    uint64_t logtag_callee; /* 0 = none yet; >1 distinct => LEARN */
    int multi_logtag_callee;
    int learn;
    const char *learn_why;
    char dbg_note[160];
};

struct ctx {
    const unsigned char *buf;
    size_t total;
    const Elf64_Phdr *ph;
    size_t nph;
    const struct plt_stub *stubs;
    size_t nstubs;
};

static int64_t sext(uint64_t v, int bits) {
    uint64_t sign = 1ull << (bits - 1);
    uint64_t mask = (bits >= 64) ? ~0ull : ((1ull << bits) - 1);
    v &= mask;
    return (int64_t)((v ^ sign) - sign);
}

static int range_ok(size_t off, size_t need, size_t total) {
    return off <= total && need <= total - off;
}

static uint32_t rd32(const unsigned char *buf, size_t off) {
    return (uint32_t)buf[off] | ((uint32_t)buf[off + 1] << 8) |
           ((uint32_t)buf[off + 2] << 16) | ((uint32_t)buf[off + 3] << 24);
}

/* Map a vaddr to a file offset through the PT_LOAD segments. */
static int vaddr_to_off(const Elf64_Phdr *ph, size_t nph,
                        uint64_t addr, size_t *off) {
    size_t i;
    for (i = 0; i < nph; i++) {
        if (ph[i].p_type != PT_LOAD) continue;
        if (addr >= ph[i].p_vaddr && addr < ph[i].p_vaddr + ph[i].p_filesz) {
            *off = (size_t)(ph[i].p_offset + (addr - ph[i].p_vaddr));
            return 1;
        }
    }
    return 0;
}

static int addr_is_exec(const struct ctx *c, uint64_t addr) {
    size_t i;
    for (i = 0; i < c->nph; i++) {
        if (c->ph[i].p_type != PT_LOAD || !(c->ph[i].p_flags & PF_X)) continue;
        if (addr >= c->ph[i].p_vaddr && addr < c->ph[i].p_vaddr + c->ph[i].p_filesz)
            return 1;
    }
    return 0;
}

static int fetch_insn(const struct ctx *c, uint64_t addr, uint32_t *insn) {
    size_t off;
    if (!addr_is_exec(c, addr)) return 0;
    if (!vaddr_to_off(c->ph, c->nph, addr, &off)) return 0;
    if (!range_ok(off, 4, c->total)) return 0;
    *insn = rd32(c->buf, off);
    return 1;
}

static const char *plt_name_at(const struct ctx *c, uint64_t addr) {
    size_t i;
    for (i = 0; i < c->nstubs; i++) {
        if (c->stubs[i].addr == addr) return c->stubs[i].name;
    }
    return NULL;
}

static const char *class_name(int cls) {
    switch (cls) {
    case CLS_SERVICE: return "SERVICE";
    case CLS_LOGTAG: return "LOGTAG";
    case CLS_SUFFIX: return "SUFFIX";
    default: return "UNKNOWN";
    }
}

/* ---- AArch64 decode helpers (only the forms the classifier needs) ---- */

static int is_adrp(uint32_t i) { return (i & 0x9F000000u) == 0x90000000u; }
static int is_adr(uint32_t i)  { return (i & 0x9F000000u) == 0x10000000u; }

static uint64_t page_target(uint32_t i, uint64_t pc) {
    uint64_t imm = (uint64_t)((((i >> 5) & 0x7FFFFu) << 2) | ((i >> 29) & 3u));
    return (pc & ~0xFFFULL) + (uint64_t)(sext(imm, 21) << 12);
}

static uint64_t adr_target(uint32_t i, uint64_t pc) {
    uint64_t imm = (uint64_t)((((i >> 5) & 0x7FFFFu) << 2) | ((i >> 29) & 3u));
    return pc + (uint64_t)sext(imm, 21);
}

/* ADD (immediate), 64-bit, no shift — the strict form the reference
 * scanner (xref.py / a64lib.py) pairs with adrp. */
static int is_add_imm_strict(uint32_t i, int *rd, int *rn, uint64_t *imm) {
    if ((i & 0xFF800000u) != 0x91000000u) return 0;
    *rd = (int)(i & 31u);
    *rn = (int)((i >> 5) & 31u);
    *imm = (uint64_t)((i >> 10) & 0xFFFu);
    return 1;
}

/* ADD/SUB (immediate), either width. shift is 0 or 12. */
static int is_add_imm(uint32_t i, int *sf, int *rd, int *rn, uint64_t *imm) {
    if ((i & 0x7F800000u) != 0x11000000u) return 0;
    *sf = (int)((i >> 31) & 1u);
    *rd = (int)(i & 31u);
    *rn = (int)((i >> 5) & 31u);
    *imm = (uint64_t)((i >> 10) & 0xFFFu);
    if (((i >> 22) & 1u) != 0) *imm <<= 12;
    return 1;
}

static int is_sub_imm(uint32_t i, int *sf, int *rd, int *rn, uint64_t *imm) {
    if ((i & 0x7F800000u) != 0x51000000u) return 0;
    *sf = (int)((i >> 31) & 1u);
    *rd = (int)(i & 31u);
    *rn = (int)((i >> 5) & 31u);
    *imm = (uint64_t)((i >> 10) & 0xFFFu);
    if (((i >> 22) & 1u) != 0) *imm <<= 12;
    return 1;
}

static int is_bl(uint32_t i, uint64_t pc, uint64_t *tgt) {
    if ((i & 0xFC000000u) != 0x94000000u) return 0;
    *tgt = pc + (uint64_t)(sext(i & 0x3FFFFFFu, 26) << 2);
    return 1;
}

static int is_b(uint32_t i, uint64_t pc, uint64_t *tgt) {
    if ((i & 0xFC000000u) != 0x14000000u) return 0;
    *tgt = pc + (uint64_t)(sext(i & 0x3FFFFFFu, 26) << 2);
    return 1;
}

static int is_ret(uint32_t i) { return (i & 0xFFFFFC1Fu) == 0xD65F0000u; }
static int is_br(uint32_t i)  { return (i & 0xFFFFFC1Fu) == 0xD61F0000u; }
static int is_blr(uint32_t i) { return (i & 0xFFFFFC1Fu) == 0xD63F0000u; }

/* MOVZ. Returns 1, sets *rd and *val (imm16 shifted by hw). */
static int is_movz(uint32_t i, int *rd, uint64_t *val) {
    uint64_t imm;
    int hw;
    if ((i & 0xFF800000u) != 0xD2800000u &&
        (i & 0xFF800000u) != 0x52800000u) return 0;
    imm = (uint64_t)((i >> 5) & 0xFFFFu);
    hw = (int)((i >> 21) & 3u);
    *rd = (int)(i & 31u);
    *val = imm << (16 * hw);
    return 1;
}

static int is_movk_movn(uint32_t i, int *rd) {
    if ((i & 0xFF800000u) != 0xF2800000u &&
        (i & 0xFF800000u) != 0x72800000u &&
        (i & 0xFF800000u) != 0x92800000u &&
        (i & 0xFF800000u) != 0x12800000u) return 0;
    *rd = (int)(i & 31u);
    return 1;
}

/* MOV (ORR rd, xzr, rm), either width. */
static int is_mov_orr(uint32_t i, int *rd, int *rm) {
    if ((i & 0xFF000000u) != 0xAA000000u &&
        (i & 0xFF000000u) != 0x2A000000u) return 0;
    if (((i >> 5) & 31u) != 31u) return 0; /* Rn must be xzr/wzr */
    *rd = (int)(i & 31u);
    *rm = (int)((i >> 16) & 31u);
    return 1;
}

/* LDR (unsigned offset) at buf[off], 64-bit. Used only for PLT naming. */
static int decode_ldr_u64(const unsigned char *buf, size_t off,
                          int *rn, uint64_t *offset) {
    uint32_t insn = rd32(buf, off);
    if ((insn & 0xFFC00000u) != 0xF9400000u) return 0;
    *rn = (int)((insn >> 5) & 31u);
    *offset = (uint64_t)(((insn >> 10) & 0xFFFu) * 8u);
    return 1;
}

/* Decode adrp at buf[off] (vaddr pc). Returns 1 and sets *rd, *page. */
static int decode_adrp(const unsigned char *buf, size_t off, uint64_t pc,
                       int *rd, uint64_t *page) {
    uint32_t insn;
    if (!is_adrp(rd32(buf, off))) return 0;
    insn = rd32(buf, off);
    *rd = (int)(insn & 31u);
    *page = page_target(insn, pc);
    return 1;
}

/* Does this instruction write GPR r? Approximate backstop for the
 * register walk: covers the forms that can carry a pointer value.
 * Stores, branches, compares (Rd==31) and FP/SIMD forms do not write
 * a GPR and return 0. */
static int writes_reg(uint32_t i, int r) {
    int rd;
    uint64_t dummy;
    if (r < 0 || r > 30) return 0;
    if (is_adrp(i) || is_adr(i)) {
        rd = (int)(i & 31u);
        return rd == r;
    }
    /* ADD/SUB immediate (Rd==31 is cmp/cmn: no write). */
    if (((i & 0x7F800000u) == 0x11000000u) ||
        ((i & 0x7F800000u) == 0x51000000u)) {
        rd = (int)(i & 31u);
        return rd == r && rd != 31;
    }
    /* ADD/SUB shifted register. */
    if (((i & 0xFF000000u) == 0x0B000000u) ||
        ((i & 0xFF000000u) == 0x8B000000u) ||
        ((i & 0xFF000000u) == 0x4B000000u) ||
        ((i & 0xFF000000u) == 0xCB000000u)) {
        rd = (int)(i & 31u);
        return rd == r && rd != 31;
    }
    /* Logical shifted register: AND/ORR/EOR/ANDS. */
    if (((i & 0xFF000000u) == 0x0A000000u) ||
        ((i & 0xFF000000u) == 0x8A000000u) ||
        ((i & 0xFF000000u) == 0x2A000000u) ||
        ((i & 0xFF000000u) == 0xAA000000u) ||
        ((i & 0xFF000000u) == 0x4A000000u) ||
        ((i & 0xFF000000u) == 0xCA000000u) ||
        ((i & 0xFF000000u) == 0x6A000000u) ||
        ((i & 0xFF000000u) == 0xEA000000u)) {
        rd = (int)(i & 31u);
        return rd == r && rd != 31;
    }
    /* MOVZ/MOVK/MOVN. */
    if (is_movz(i, &rd, &dummy) || is_movk_movn(i, &rd))
        return rd == r && rd != 31;
    /* Loads: unsigned-offset family, LDUR, literal, LDP. */
    if (((i & 0xFFC00000u) == 0xF9400000u) ||
        ((i & 0xFFC00000u) == 0xB9400000u) ||
        ((i & 0xFFC00000u) == 0x39400000u) ||
        ((i & 0xFFC00000u) == 0x79400000u) ||
        ((i & 0xFFC00000u) == 0x39800000u) ||
        ((i & 0xFFC00000u) == 0x79800000u) ||
        ((i & 0xFFC00000u) == 0xB9800000u) ||
        ((i & 0xFFC00000u) == 0xF8400000u) ||
        ((i & 0xFFC00000u) == 0xB8400000u)) {
        rd = (int)(i & 31u);
        return rd == r;
    }
    if (((i & 0xFF000000u) == 0x58000000u) ||
        ((i & 0xFF000000u) == 0x18000000u)) {
        rd = (int)(i & 31u);
        return rd == r;
    }
    if (((i & 0xFFC00000u) == 0xA9400000u) ||
        ((i & 0xFFC00000u) == 0x29400000u)) {
        int rt = (int)(i & 31u);
        int rt2 = (int)((i >> 10) & 31u);
        return r == rt || r == rt2;
    }
    return 0;
}

static int ends_with(const char *s, const char *suffix) {
    size_t sl = strlen(s), xl = strlen(suffix);
    if (sl < xl) return 0;
    return strcmp(s + sl - xl, suffix) == 0;
}

static int is_string16_epkc(const char *name) {
    if (!name) return 0;
    return ends_with(name, "String16C1EPKc") || ends_with(name, "String16C2EPKc");
}

static int is_string16_epkcm(const char *name) {
    if (!name) return 0;
    return ends_with(name, "String16C1EPKcm") || ends_with(name, "String16C2EPKcm");
}

static int is_log_output_callee(const char *name) {
    if (!name) return 0;
    if (strcmp(name, "write") == 0) return 1;
    if (strcmp(name, "writev") == 0) return 1;
    if (strcmp(name, "snprintf") == 0) return 1;
    if (strcmp(name, "vsnprintf") == 0) return 1;
    if (strncmp(name, "__android_log_", 14) == 0) return 1;
    return 0;
}

/* ---- LOGTAG corroboration (prescription step 3, part (b)) ---- */

/* Scan one function body starting at addr. Sets *frame (large stack
 * frame), *saw_errno, *saw_out; collects up to 8 direct local call
 * targets into locals[]. Stops at the first ret or BODY_CAP
 * instructions. Returns 0 if the address is not executable code. */
static int scan_body(const struct ctx *c, uint64_t addr,
                     int *frame, int *saw_errno, int *saw_out,
                     uint64_t *locals, int *nlocals) {
    uint64_t pc = addr;
    int n;
    *frame = 0;
    *saw_errno = 0;
    *saw_out = 0;
    *nlocals = 0;
    for (n = 0; n < BODY_CAP; n++) {
        uint32_t insn;
        uint64_t tgt;
        if (!fetch_insn(c, pc, &insn)) return 0;
        if (is_ret(insn)) break;
        /* SUB (immediate) sp, sp, #imm: the stack frame. Large means
         * imm >= 0x100; the real log helper uses 0x510. */
        {
            int sf, rd, rn;
            uint64_t imm;
            if (is_sub_imm(insn, &sf, &rd, &rn, &imm) &&
                rd == 31 && rn == 31 && imm >= 0x100)
                *frame = 1;
        }
        if (is_bl(insn, pc, &tgt)) {
            const char *nm = plt_name_at(c, tgt);
            if (nm) {
                if (strcmp(nm, "__errno") == 0) *saw_errno = 1;
                if (is_log_output_callee(nm)) *saw_out = 1;
            } else if (addr_is_exec(c, tgt) && *nlocals < 8) {
                locals[(*nlocals)++] = tgt;
            }
        }
        pc += 4;
    }
    return 1;
}

/* Corroborate a local callee as the async-safe log helper: large stack
 * frame, calls __errno, and reaches a log/write call directly or
 * through one local hop. */
static int corroborate_log_helper(const struct ctx *c, uint64_t callee) {
    int frame, saw_errno, saw_out, nlocals, k;
    uint64_t locals[8];
    if (!scan_body(c, callee, &frame, &saw_errno, &saw_out, locals, &nlocals))
        return 0;
    if (frame && saw_errno && saw_out) return 1;
    if (!frame || !saw_errno) return 0;
    /* One local hop: a directly-called local function that reaches a
     * log/write call. (The real helper's writev lives one hop down.) */
    for (k = 0; k < nlocals; k++) {
        int f2, e2, o2, n2;
        uint64_t l2[8];
        if (!scan_body(c, locals[k], &f2, &e2, &o2, l2, &n2)) continue;
        if (o2) return 1;
    }
    return 0;
}

/* Classify one consuming call. callee_is_plt names the callee through
 * the PLT map; otherwise callee_addr is a local code address.
 * loaded is the bitmask of registers holding adrp+add-loaded values. */
static int classify_consumer(const struct ctx *c, int holder,
                             int w0_imm, int w2_imm, int x0_stack,
                             uint32_t loaded, int callee_is_plt,
                             const char *callee_name, uint64_t callee_addr) {
    if (callee_is_plt) {
        if (is_string16_epkc(callee_name)) {
            if (holder == 1 && x0_stack) return CLS_SERVICE;
            return CLS_UNKNOWN;
        }
        if (is_string16_epkcm(callee_name)) {
            /* Counted constructor: SERVICE only when the length
             * argument is the constant 4. */
            if (holder == 1 && x0_stack && w2_imm == 4) return CLS_SERVICE;
            return CLS_UNKNOWN;
        }
        return CLS_UNKNOWN;
    }
    /* Local callee: LOGTAG shape plus body corroboration. */
    if (holder == 1 && w0_imm >= 0 && w0_imm <= 15 &&
        (loaded & (1u << 2)) != 0 &&
        corroborate_log_helper(c, callee_addr))
        return CLS_LOGTAG;
    return CLS_UNKNOWN;
}

static void path_append(char *path, size_t cap, const char *frag) {
    size_t len = strlen(path);
    size_t fl = strlen(frag);
    if (len + fl + 1 >= cap) return;
    if (len > 0) {
        if (len + 1 >= cap) return;
        path[len++] = ';';
        path[len] = '\0';
    }
    memcpy(path + len, frag, fl + 1);
}

/* Follow one reference's register forward to its consumer
 * (prescription step 2). Fills r->cls and the trace fields.
 * Returns 0 on a classified consumer, -1 when the walk fails
 * (r->cls is CLS_UNKNOWN and r->path carries the reason). */
static int walk_ref(const struct ctx *c, struct ref *r) {
    int holder = r->rd;
    uint64_t pc = r->insn_addr + 4;
    uint32_t loaded = 0;
    int w0_imm = -1, w2_imm = -1;
    /* stack_regs: bit r set when x_r holds a stack-derived address;
     * bit 31 stands for sp itself. x29 is seeded: under AAPCS64 it is
     * the frame pointer, set from sp in the prologue, and the real
     * service-name sites derive x0 from it (sub x0, x29, #imm). */
    uint32_t stack_regs = (1u << 31) | (1u << 29);
    int pend_rd = -1;
    uint64_t pend_deadline = 0;
    uint64_t visited[MAX_VISITED];
    size_t nvisited = 0;
    int steps = 0;
    char frag[40];

    r->cls = CLS_UNKNOWN;
    r->consumer_addr = 0;
    r->callee[0] = '\0';
    r->callee_addr = 0;
    r->steps = 0;
    r->holder_at_call = -1;
    r->w0_imm = -1;
    r->w2_imm = -1;
    r->x0_stack = 0;
    r->path[0] = '\0';
    if (holder >= 0 && holder <= 30) loaded |= (1u << holder);
    /* The walk starts after the ref's own load instruction. For an
     * adrp+add reference the add is still ahead of us: seed the
     * pending pair so the add is recognised as completing the load
     * instead of clobbering the holder. */
    if (r->gap > 0) {
        pend_rd = holder;
        pend_deadline = r->insn_addr + 12;
    }
    snprintf(frag, sizeof(frag), "ref x%d", holder);
    path_append(r->path, sizeof(r->path), frag);

    while (steps < WALK_CAP) {
        uint32_t insn;
        size_t vi;
        int dup = 0;
        if (!fetch_insn(c, pc, &insn)) {
            path_append(r->path, sizeof(r->path), "off-exec");
            return -1;
        }
        for (vi = 0; vi < nvisited; vi++) {
            if (visited[vi] == pc) { dup = 1; break; }
        }
        if (dup) {
            path_append(r->path, sizeof(r->path), "loop");
            return -1;
        }
        if (nvisited < MAX_VISITED) visited[nvisited++] = pc;
        if (is_ret(insn)) {
            path_append(r->path, sizeof(r->path), "ret");
            return -1;
        }
        if (is_br(insn)) {
            path_append(r->path, sizeof(r->path), "br-indirect");
            return -1;
        }
        /* Calls: bl (known target) and blr (indirect). */
        {
            uint64_t tgt = 0;
            int is_call = 0, is_indirect = 0;
            if (is_bl(insn, pc, &tgt)) {
                is_call = 1;
            } else if (is_blr(insn)) {
                is_call = 1;
                is_indirect = 1;
            }
            if (is_call) {
                if (holder >= 19 && holder <= 28) {
                    /* Callee-saved: the value survives the call.
                     * Caller-saved state dies: clear loaded and
                     * stack bits for x0-x18 and x30; keep x19-x29
                     * and sp. */
                    path_append(r->path, sizeof(r->path), "call-skipped");
                    loaded &= 0x3FF80000u;
                    stack_regs &= 0xBFF80000u;
                    w0_imm = -1;
                    w2_imm = -1;
                    pend_rd = -1;
                    pc += 4;
                    steps++;
                    continue;
                }
                /* Consumer. */
                r->consumer_addr = pc;
                r->steps = steps;
                r->holder_at_call = holder;
                r->w0_imm = w0_imm;
                r->w2_imm = w2_imm;
                r->x0_stack = (stack_regs & 1u) != 0;
                if (is_indirect) {
                    snprintf(r->callee, sizeof(r->callee), "indirect");
                    r->callee_addr = 0;
                    path_append(r->path, sizeof(r->path), "blr");
                    return -1;
                }
                {
                    const char *nm = plt_name_at(c, tgt);
                    if (nm) {
                        snprintf(r->callee, sizeof(r->callee), "%s", nm);
                        r->callee_addr = tgt;
                        r->cls = classify_consumer(c, holder, w0_imm,
                                                   w2_imm, r->x0_stack, loaded,
                                                   1, nm, tgt);
                    } else if (addr_is_exec(c, tgt)) {
                        snprintf(r->callee, sizeof(r->callee),
                                 "local:0x%llx", (unsigned long long)tgt);
                        r->callee_addr = tgt;
                        r->cls = classify_consumer(c, holder, w0_imm,
                                                   w2_imm, r->x0_stack, loaded,
                                                   0, NULL, tgt);
                    } else {
                        snprintf(r->callee, sizeof(r->callee), "off-exec");
                        r->callee_addr = tgt;
                        r->cls = CLS_UNKNOWN;
                    }
                    snprintf(frag, sizeof(frag), "bl @0x%llx",
                             (unsigned long long)pc);
                    path_append(r->path, sizeof(r->path), frag);
                }
                return (r->cls == CLS_UNKNOWN) ? -1 : 0;
            }
        }
        /* Unconditional branch: a PLT target is a tail call (the
         * consumer); a forward local target is followed into its
         * block; a backward target is a loop back-edge, scanned past
         * linearly (prescription step 2: for a callee-saved value,
         * keep scanning past loop back-edges to the first use). */
        {
            uint64_t tgt = 0;
            if (is_b(insn, pc, &tgt)) {
                const char *nm = plt_name_at(c, tgt);
                if (nm) {
                    r->consumer_addr = pc;
                    r->steps = steps;
                    r->holder_at_call = holder;
                    r->w0_imm = w0_imm;
                    r->w2_imm = w2_imm;
                    r->x0_stack = (stack_regs & 1u) != 0;
                    snprintf(r->callee, sizeof(r->callee), "%s", nm);
                    r->callee_addr = tgt;
                    r->cls = classify_consumer(c, holder, w0_imm, w2_imm,
                                               r->x0_stack, loaded, 1, nm, tgt);
                    snprintf(frag, sizeof(frag), "tail-b @0x%llx",
                             (unsigned long long)pc);
                    path_append(r->path, sizeof(r->path), frag);
                    return (r->cls == CLS_UNKNOWN) ? -1 : 0;
                }
                if (!addr_is_exec(c, tgt)) {
                    path_append(r->path, sizeof(r->path), "b-off-exec");
                    return -1;
                }
                if (tgt <= pc) {
                    snprintf(frag, sizeof(frag), "back-edge 0x%llx",
                             (unsigned long long)tgt);
                    path_append(r->path, sizeof(r->path), frag);
                    pc += 4;
                    steps++;
                    continue;
                }
                snprintf(frag, sizeof(frag), "b 0x%llx",
                         (unsigned long long)tgt);
                path_append(r->path, sizeof(r->path), frag);
                pc = tgt;
                steps++;
                continue;
            }
        }
        /* An adrp pending its add expires after 3 instructions. */
        if (pend_rd >= 0 && pc > pend_deadline) pend_rd = -1;
        /* MOV (ORR rd, xzr, rm): rename or overwrite. */
        {
            int mrd, mrm;
            if (is_mov_orr(insn, &mrd, &mrm)) {
                uint32_t bit;
                uint32_t sbit;
                if (mrm == holder) {
                    holder = mrd;
                    snprintf(frag, sizeof(frag), "mov x%d,x%d", mrd, mrm);
                    path_append(r->path, sizeof(r->path), frag);
                } else if (mrd == holder) {
                    path_append(r->path, sizeof(r->path), "mov-clobber");
                    return -1;
                }
                bit = (loaded >> mrm) & 1u;
                loaded &= ~(1u << mrd);
                if (bit) loaded |= (1u << mrd);
                /* Stack-derivation follows the copy; Rm==31 is xzr,
                 * not sp. Rd==31 (sp) is never tracked as a GPR. */
                sbit = (mrm == 31) ? 0 : ((stack_regs >> mrm) & 1u);
                if (mrd < 31) {
                    stack_regs &= ~(1u << mrd);
                    if (sbit) stack_regs |= (1u << mrd);
                }
                if (mrd == 0) w0_imm = -1;
                if (mrd == 2) w2_imm = -1;
                if (mrd == pend_rd) pend_rd = -1;
                pc += 4;
                steps++;
                continue;
            }
        }
        /* ADRP: starts a pending pair; writes its Rd at once. */
        if (is_adrp(insn)) {
            int ard = (int)(insn & 31u);
            if (ard == holder) {
                path_append(r->path, sizeof(r->path), "adrp-clobber");
                return -1;
            }
            loaded &= ~(1u << ard);
            if (ard < 31) stack_regs &= ~(1u << ard);
            if (ard == 0) w0_imm = -1;
            if (ard == 2) w2_imm = -1;
            pend_rd = ard;
            pend_deadline = pc + 12;
            pc += 4;
            steps++;
            continue;
        }
        /* ADR: single-instruction address load. */
        if (is_adr(insn)) {
            int ard = (int)(insn & 31u);
            if (ard == holder) {
                path_append(r->path, sizeof(r->path), "adr-clobber");
                return -1;
            }
            loaded &= ~(1u << ard);
            if (ard < 31) stack_regs &= ~(1u << ard);
            if (ard == 0) w0_imm = -1;
            if (ard == 2) w2_imm = -1;
            if (ard == pend_rd) pend_rd = -1;
            pc += 4;
            steps++;
            continue;
        }
        /* The pending pair's ADD: completes an adrp+add load. */
        if (pend_rd >= 0) {
            int ard, arn;
            uint64_t aimm;
            if (is_add_imm_strict(insn, &ard, &arn, &aimm) &&
                ard == pend_rd && arn == pend_rd) {
                loaded |= (1u << ard);
                if (ard < 31) stack_regs &= ~(1u << ard);
                if (ard == 0) w0_imm = -1;
                if (ard == 2) w2_imm = -1;
                pend_rd = -1;
                pc += 4;
                steps++;
                continue;
            }
        }
        /* ADD #0 as a move (not from sp, not a pair completion). */
        {
            int sf, ard, arn;
            uint64_t aimm;
            if (is_add_imm(insn, &sf, &ard, &arn, &aimm) && aimm == 0 &&
                arn != 31) {
                uint32_t bit;
                uint32_t sbit;
                if (arn == holder) {
                    holder = ard;
                    snprintf(frag, sizeof(frag), "add0 x%d,x%d", ard, arn);
                    path_append(r->path, sizeof(r->path), frag);
                } else if (ard == holder) {
                    path_append(r->path, sizeof(r->path), "add0-clobber");
                    return -1;
                }
                bit = (loaded >> arn) & 1u;
                loaded &= ~(1u << ard);
                if (bit) loaded |= (1u << ard);
                sbit = (stack_regs >> arn) & 1u;
                if (ard < 31) {
                    stack_regs &= ~(1u << ard);
                    if (sbit) stack_regs |= (1u << ard);
                }
                if (ard == 0) w0_imm = -1;
                if (ard == 2) w2_imm = -1;
                if (ard == pend_rd) pend_rd = -1;
                pc += 4;
                steps++;
                continue;
            }
        }
        /* MOVZ/MOVK/MOVN: constant loads and partial writes. */
        {
            int mrd;
            uint64_t mval;
            if (is_movz(insn, &mrd, &mval)) {
                if (mrd == holder) {
                    path_append(r->path, sizeof(r->path), "movz-clobber");
                    return -1;
                }
                if (mrd == 0) w0_imm = (mval <= 0xFFFFFFFFull) ? (int)mval : -1;
                if (mrd == 2) w2_imm = (mval <= 0xFFFFFFFFull) ? (int)mval : -1;
                loaded &= ~(1u << mrd);
                if (mrd < 31) stack_regs &= ~(1u << mrd);
                if (mrd == pend_rd) pend_rd = -1;
                pc += 4;
                steps++;
                continue;
            }
            if (is_movk_movn(insn, &mrd)) {
                if (mrd == holder) {
                    path_append(r->path, sizeof(r->path), "movk-clobber");
                    return -1;
                }
                if (mrd == 0) w0_imm = -1;
                if (mrd == 2) w2_imm = -1;
                loaded &= ~(1u << mrd);
                if (mrd < 31) stack_regs &= ~(1u << mrd);
                if (mrd == pend_rd) pend_rd = -1;
                pc += 4;
                steps++;
                continue;
            }
        }
        /* ADD/SUB from a stack-derived base (sp, the frame pointer,
         * or any register already known stack-derived): the result is
         * stack-derived. */
        {
            int sf, ard, arn;
            uint64_t aimm;
            if ((is_add_imm(insn, &sf, &ard, &arn, &aimm) ||
                 is_sub_imm(insn, &sf, &ard, &arn, &aimm)) &&
                ard != 31 &&
                (arn == 31 || ((stack_regs >> arn) & 1u) != 0)) {
                if (ard == holder) {
                    path_append(r->path, sizeof(r->path), "sp-clobber");
                    return -1;
                }
                stack_regs |= (1u << ard);
                if (ard == 0) w0_imm = -1;
                if (ard == 2) w2_imm = -1;
                loaded &= ~(1u << ard);
                if (ard == pend_rd) pend_rd = -1;
                pc += 4;
                steps++;
                continue;
            }
        }
        /* Generic backstop: any other write to the holder kills it. */
        if (writes_reg(insn, holder)) {
            path_append(r->path, sizeof(r->path), "write-clobber");
            return -1;
        }
        {
            int rr;
            for (rr = 0; rr < 31; rr++) {
                if (writes_reg(insn, rr)) {
                    loaded &= ~(1u << rr);
                    stack_regs &= ~(1u << rr);
                    if (rr == 0) w0_imm = -1;
                    if (rr == 2) w2_imm = -1;
                    if (rr == pend_rd) pend_rd = -1;
                }
            }
        }
        pc += 4;
        steps++;
    }
    path_append(r->path, sizeof(r->path), "walk-cap");
    return -1;
}

/* ---- Literal census ---- */

/* Count standalone NUL-bounded occurrences of the 4-byte target in the
 * whole file, and suffix (tail-merge) occurrences inside .rodata.
 * Standalone offsets go to *stand (cap nstand_cap); the first
 * standalone offset is returned via *first_stand when non-NULL. */
static void census_literals(const unsigned char *buf, size_t total,
                            const char *target,
                            const Elf64_Shdr *rodata,
                            size_t *stand_offs, size_t stand_cap,
                            size_t *nstand, size_t *nsuffix) {
    size_t off;
    *nstand = 0;
    *nsuffix = 0;
    if (total < 6) return;
    for (off = 1; off + 5 <= total; off++) {
        if (buf[off - 1] == 0 && memcmp(buf + off, target, 4) == 0 &&
            buf[off + 4] == 0) {
            if (*nstand < stand_cap) stand_offs[*nstand] = off;
            (*nstand)++;
        }
    }
    if (rodata) {
        size_t roff = (size_t)rodata->sh_offset;
        size_t rsize = (size_t)rodata->sh_size;
        size_t o;
        if (range_ok(roff, rsize, total)) {
            for (o = 0; o + 5 <= rsize; o++) {
                size_t off2 = roff + o;
                if (memcmp(buf + off2, target, 4) == 0 &&
                    buf[off2 + 4] == 0 &&
                    !(off2 > 0 && buf[off2 - 1] == 0))
                    (*nsuffix)++;
            }
        }
    }
}

static void analysis_add_ref(struct analysis *a, struct ref *r) {
    if (a->nrefs == a->cap) {
        size_t ncap = a->cap ? a->cap * 2 : 16;
        struct ref *nr = (struct ref *)realloc(a->refs, ncap * sizeof(*nr));
        if (!nr) return;
        a->refs = nr;
        a->cap = ncap;
    }
    a->refs[a->nrefs++] = *r;
}

/* Run the full reference analysis over buf[0..total) for the 4-byte
 * target ("vold" or, for verification, "gvld"). Fills *a (refs array
 * owned by the caller via analysis_free). Returns 0 on success
 * (analysis completed, even if it demands LEARN), -1 on structural
 * failure (also LEARN, with a->learn_why set). */
static int analyze(const unsigned char *buf, size_t total,
                   const char *target, struct analysis *a) {
    Elf64_Ehdr eh;
    Elf64_Phdr *ph = NULL;
    Elf64_Shdr *sh = NULL;
    size_t nph = 0, nsh = 0, i;
    const char *shstr = NULL;
    size_t shstr_size = 0;
    Elf64_Shdr *dynsym_sh = NULL, *dynstr_sh = NULL;
    Elf64_Shdr *relaplt_sh = NULL, *reladyn_sh = NULL;
    Elf64_Shdr *plt_sh = NULL, *pltgot_sh = NULL, *pltsec_sh = NULL;
    Elf64_Shdr *rodata_sh = NULL, *symtab_sh = NULL;
    const char *dynstr = NULL;
    size_t dynstr_size = 0;
    Elf64_Sym *dynsym = NULL;
    size_t ndynsym = 0;
    struct plt_stub *stubs = NULL;
    size_t nstubs = 0, stubcap = 0;
    size_t stand_offs[64];
    size_t nstand = 0, nsuffix = 0;
    int rc = -1;

    memset(a, 0, sizeof(*a));
    a->dbg_note[0] = '\0';

    if (total < sizeof(Elf64_Ehdr) || memcmp(buf, "\x7f" "ELF", 4) != 0 ||
        buf[EI_CLASS] != ELFCLASS64 || buf[EI_DATA] != ELFDATA2LSB) {
        a->learn_why = "not an ELF64 little-endian file";
        a->learn = 1;
        return -1;
    }
    memcpy(&eh, buf, sizeof(eh));
    if (eh.e_machine != EM_AARCH64) {
        a->learn_why = "e_machine is not AArch64";
        a->learn = 1;
        return -1;
    }
    if (eh.e_phoff == 0 || eh.e_phentsize < sizeof(Elf64_Phdr) ||
        eh.e_phnum == 0 || eh.e_phnum > 256) {
        a->learn_why = "no usable program headers";
        a->learn = 1;
        return -1;
    }
    nph = eh.e_phnum;
    if (!range_ok((size_t)eh.e_phoff, nph * sizeof(Elf64_Phdr), total)) {
        a->learn_why = "program headers out of range";
        a->learn = 1;
        return -1;
    }
    ph = (Elf64_Phdr *)(buf + eh.e_phoff);

    if (eh.e_shoff == 0 || eh.e_shentsize < sizeof(Elf64_Shdr) ||
        eh.e_shnum == 0 || eh.e_shnum > 1024) {
        a->learn_why = "no section headers; cannot name PLT stubs or relocations";
        a->learn = 1;
        return -1;
    }
    nsh = eh.e_shnum;
    if (!range_ok((size_t)eh.e_shoff, nsh * sizeof(Elf64_Shdr), total)) {
        a->learn_why = "section headers out of range";
        a->learn = 1;
        return -1;
    }
    sh = (Elf64_Shdr *)(buf + eh.e_shoff);
    if (eh.e_shstrndx < nsh) {
        Elf64_Shdr *ss = &sh[eh.e_shstrndx];
        if (range_ok((size_t)ss->sh_offset, (size_t)ss->sh_size, total)) {
            shstr = (const char *)(buf + ss->sh_offset);
            shstr_size = (size_t)ss->sh_size;
        }
    }
    if (!shstr) {
        a->learn_why = "no section-name string table";
        a->learn = 1;
        return -1;
    }
    for (i = 0; i < nsh; i++) {
        const char *name = "";
        if (sh[i].sh_name < shstr_size) name = shstr + sh[i].sh_name;
        if (sh[i].sh_type == SHT_DYNSYM && !dynsym_sh) dynsym_sh = &sh[i];
        else if (sh[i].sh_type == SHT_STRTAB && dynsym_sh &&
                 sh[i].sh_offset != 0 &&
                 strcmp(name, ".dynstr") == 0) dynstr_sh = &sh[i];
        if (strcmp(name, ".rela.plt") == 0) relaplt_sh = &sh[i];
        else if (strcmp(name, ".rela.dyn") == 0) reladyn_sh = &sh[i];
        else if (strcmp(name, ".plt") == 0) plt_sh = &sh[i];
        else if (strcmp(name, ".plt.got") == 0) pltgot_sh = &sh[i];
        else if (strcmp(name, ".plt.sec") == 0) pltsec_sh = &sh[i];
        else if (strcmp(name, ".rodata") == 0) rodata_sh = &sh[i];
        else if (sh[i].sh_type == SHT_SYMTAB && !symtab_sh) symtab_sh = &sh[i];
    }
    if (!dynsym_sh || !dynstr_sh) {
        a->learn_why = "no .dynsym/.dynstr";
        a->learn = 1;
        return -1;
    }
    if (!range_ok((size_t)dynsym_sh->sh_offset, (size_t)dynsym_sh->sh_size, total) ||
        !range_ok((size_t)dynstr_sh->sh_offset, (size_t)dynstr_sh->sh_size, total)) {
        a->learn_why = ".dynsym/.dynstr out of range";
        a->learn = 1;
        return -1;
    }
    dynsym = (Elf64_Sym *)(buf + dynsym_sh->sh_offset);
    ndynsym = (size_t)(dynsym_sh->sh_size / sizeof(Elf64_Sym));
    dynstr = (const char *)(buf + dynstr_sh->sh_offset);
    dynstr_size = (size_t)dynstr_sh->sh_size;
    if (!plt_sh && !pltgot_sh && !pltsec_sh) {
        a->learn_why = "no .plt/.plt.got/.plt.sec section";
        a->learn = 1;
        return -1;
    }

    /* Census first: exactly one standalone literal is required. */
    census_literals(buf, total, target, rodata_sh,
                    stand_offs, 64, &nstand, &nsuffix);
    a->nstandalone = nstand;
    a->nsuffix = nsuffix;
    if (nstand == 1) {
        size_t lit_off = stand_offs[0];
        a->lit_off = lit_off;
        /* Resolve the literal's vaddr: prefer the containing section
         * (segment file ranges can overlap, which misresolves it). */
        a->lit_addr = 0;
        if (rodata_sh && lit_off >= (size_t)rodata_sh->sh_offset &&
            lit_off < (size_t)rodata_sh->sh_offset + (size_t)rodata_sh->sh_size)
            a->lit_addr = rodata_sh->sh_addr + (lit_off - (size_t)rodata_sh->sh_offset);
        else {
            size_t k;
            for (k = 0; k < nph; k++) {
                size_t poff, psz;
                if (ph[k].p_type != PT_LOAD) continue;
                poff = (size_t)ph[k].p_offset;
                psz = (size_t)ph[k].p_filesz;
                if (lit_off >= poff && lit_off < poff + psz) {
                    a->lit_addr = ph[k].p_vaddr + (lit_off - poff);
                    break;
                }
            }
        }
    }
    if (nstand != 1) {
        a->learn_why = (nstand == 0) ? "no standalone literal" :
                                       "more than one standalone literal";
        a->learn = 1;
        /* Fall through: still build the PLT map and scan for refs so
         * the LEARN log carries the evidence. */
    }

    /* Build the GOT-slot -> symbol-name map from the relocations, then
     * name every PLT stub by decoding adrp+ldr. */
    {
        struct gotent { uint64_t got; uint32_t sym; int used; };
        struct gotent *map = NULL;
        size_t mapcap = 256, mapn = 0, k;
        Elf64_Shdr *relsh[2];
        int nrel = 0;
        map = (struct gotent *)calloc(mapcap, sizeof(*map));
        if (!map) {
            a->learn_why = "out of memory";
            a->learn = 1;
            free(stubs);
            return -1;
        }
        if (relaplt_sh) relsh[nrel++] = relaplt_sh;
        if (reladyn_sh) relsh[nrel++] = reladyn_sh;
        for (k = 0; k < (size_t)nrel; k++) {
            Elf64_Shdr *rs = relsh[k];
            size_t nreloc, r;
            if (rs->sh_entsize < sizeof(Elf64_Rela) ||
                !range_ok((size_t)rs->sh_offset, (size_t)rs->sh_size, total))
                continue;
            nreloc = (size_t)(rs->sh_size / sizeof(Elf64_Rela));
            for (r = 0; r < nreloc; r++) {
                Elf64_Rela *rel = (Elf64_Rela *)(buf + rs->sh_offset) +
                                  r * (rs->sh_entsize / sizeof(Elf64_Rela));
                uint32_t type = (uint32_t)rel->r_info;
                uint32_t sym = (uint32_t)(rel->r_info >> 32);
                size_t h;
                if (type != R_AARCH64_JUMP_SLOT && type != R_AARCH64_GLOB_DAT)
                    continue;
                if (sym == 0 || sym >= ndynsym) continue;
                h = (size_t)(rel->r_offset * 2654435761ull) % mapcap;
                while (map[h].used && map[h].got != rel->r_offset)
                    h = (h + 1) % mapcap;
                if (!map[h].used) {
                    map[h].used = 1;
                    map[h].got = rel->r_offset;
                    map[h].sym = sym;
                    mapn++;
                    if (mapn * 2 > mapcap) {
                        size_t ncap = mapcap * 2, j;
                        struct gotent *nm = (struct gotent *)calloc(ncap, sizeof(*nm));
                        if (!nm) break;
                        for (j = 0; j < mapcap; j++) {
                            size_t hh;
                            if (!map[j].used) continue;
                            hh = (size_t)(map[j].got * 2654435761ull) % ncap;
                            while (nm[hh].used) hh = (hh + 1) % ncap;
                            nm[hh] = map[j];
                        }
                        free(map);
                        map = nm;
                        mapcap = ncap;
                    }
                }
            }
        }
        /* Scan the PLT sections at 4-byte steps for adrp+ldr pairs. */
        {
            Elf64_Shdr *plts[3];
            int nplt = 0, p;
            if (plt_sh) plts[nplt++] = plt_sh;
            if (pltgot_sh) plts[nplt++] = pltgot_sh;
            if (pltsec_sh) plts[nplt++] = pltsec_sh;
            for (p = 0; p < nplt; p++) {
                Elf64_Shdr *ps = plts[p];
                size_t poff = (size_t)ps->sh_offset;
                size_t psz = (size_t)ps->sh_size;
                size_t o;
                if (!range_ok(poff, psz, total)) continue;
                for (o = 0; o + 8 <= psz; o += 4) {
                    int rd, rn;
                    uint64_t page, goff, got;
                    uint64_t pc = ps->sh_addr + o;
                    size_t h;
                    const char *nm = NULL;
                    if (!decode_adrp(buf, poff + o, pc, &rd, &page)) continue;
                    if (!decode_ldr_u64(buf, poff + o + 4, &rn, &goff)) continue;
                    if (rn != rd) continue;
                    got = page + goff;
                    h = (size_t)(got * 2654435761ull) % mapcap;
                    while (map[h].used && map[h].got != got)
                        h = (h + 1) % mapcap;
                    if (map[h].used) {
                        uint32_t si = map[h].sym;
                        if (dynsym[si].st_name < dynstr_size)
                            nm = dynstr + dynsym[si].st_name;
                    }
                    if (nstubs == stubcap) {
                        size_t ncap = stubcap ? stubcap * 2 : 32;
                        struct plt_stub *ns = (struct plt_stub *)realloc(
                            stubs, ncap * sizeof(*ns));
                        if (!ns) break;
                        stubs = ns;
                        stubcap = ncap;
                    }
                    stubs[nstubs].addr = pc;
                    stubs[nstubs].name = nm;
                    nstubs++;
                }
            }
        }
        free(map);
    }

    /* Scan executable segments for adrp+add / adr references whose
     * target is the standalone literal or a suffix candidate. The
     * add may sit up to 3 instructions after the adrp; the first
     * matching add decides (same rule as the reference scanner). */
    {
        struct ctx c;
        c.buf = buf;
        c.total = total;
        c.ph = ph;
        c.nph = nph;
        c.stubs = stubs;
        c.nstubs = nstubs;
        for (i = 0; i < nph; i++) {
            size_t poff, psz, o;
            uint64_t pvaddr;
            if (ph[i].p_type != PT_LOAD || !(ph[i].p_flags & PF_X)) continue;
            poff = (size_t)ph[i].p_offset;
            psz = (size_t)ph[i].p_filesz;
            pvaddr = ph[i].p_vaddr;
            if (!range_ok(poff, psz, total)) continue;
            for (o = 0; o + 4 <= psz; o += 4) {
                uint32_t insn = rd32(buf, poff + o);
                uint64_t pc = pvaddr + o;
                uint64_t tgt_addr = 0;
                int is_ref = 0, rd = -1, gap = 0;
                if (is_adr(insn)) {
                    tgt_addr = adr_target(insn, pc);
                    rd = (int)(insn & 31u);
                    gap = 0;
                    is_ref = 1;
                } else if (is_adrp(insn)) {
                    int ard, arn;
                    uint64_t page, aimm;
                    int k;
                    if (!decode_adrp(buf, poff + o, pc, &ard, &page)) continue;
                    for (k = 1; k <= 3; k++) {
                        size_t koff = o + (size_t)k * 4;
                        if (koff + 4 > psz) break;
                        if (is_add_imm_strict(rd32(buf, poff + koff),
                                              &ard, &arn, &aimm) &&
                            arn == ard) {
                            /* First matching add decides, even when
                             * its target is not a literal. */
                            tgt_addr = page + aimm;
                            rd = ard;
                            gap = k;
                            is_ref = 1;
                            break;
                        }
                    }
                }
                if (!is_ref || rd < 0 || rd > 30) continue;
                {
                    size_t toff;
                    struct ref r;
                    if (!vaddr_to_off(ph, nph, tgt_addr, &toff)) continue;
                    if (!range_ok(toff, 5, total)) continue;
                    if (memcmp(buf + toff, target, 4) != 0 || buf[toff + 4] != 0)
                        continue;
                    memset(&r, 0, sizeof(r));
                    r.insn_addr = pc;
                    r.rd = rd;
                    r.lit_addr = tgt_addr;
                    r.lit_off = toff;
                    r.gap = gap;
                    r.is_suffix = !(toff > 0 && buf[toff - 1] == 0);
                    if (r.is_suffix) {
                        r.cls = CLS_SUFFIX;
                        snprintf(r.callee, sizeof(r.callee), "suffix-target");
                        snprintf(r.path, sizeof(r.path),
                                 "suffix literal (byte before is not NUL)");
                    } else {
                        walk_ref(&c, &r);
                        if (r.cls == CLS_SERVICE) a->nservice++;
                        else if (r.cls == CLS_LOGTAG) {
                            a->nlogtag++;
                            if (a->logtag_callee == 0)
                                a->logtag_callee = r.callee_addr;
                            else if (a->logtag_callee != r.callee_addr)
                                a->multi_logtag_callee = 1;
                        }
                    }
                    analysis_add_ref(a, &r);
                }
            }
        }
    }
    free(stubs);

    /* Step 6 cross-check (log only, never gating): if .symtab exists,
     * confirm the SERVICE site lies inside VoldNativeService::start. */
    if (symtab_sh && a->nservice > 0) {
        size_t sidx = (size_t)symtab_sh->sh_link;
        if (sidx < nsh && sh[sidx].sh_type == SHT_STRTAB &&
            range_ok((size_t)sh[sidx].sh_offset, (size_t)sh[sidx].sh_size, total) &&
            range_ok((size_t)symtab_sh->sh_offset, (size_t)symtab_sh->sh_size, total)) {
            const char *strtab = (const char *)(buf + sh[sidx].sh_offset);
            size_t strsize = (size_t)sh[sidx].sh_size;
            Elf64_Sym *syms = (Elf64_Sym *)(buf + symtab_sh->sh_offset);
            size_t nsyms = (size_t)(symtab_sh->sh_size / sizeof(Elf64_Sym));
            size_t s;
            int confirmed = 0;
            for (s = 0; s < nsyms; s++) {
                const char *nm;
                if (syms[s].st_name >= strsize) continue;
                nm = strtab + syms[s].st_name;
                if (strstr(nm, "VoldNativeService") && strstr(nm, "start")) {
                    size_t k;
                    for (k = 0; k < a->nrefs; k++) {
                        uint64_t site = a->refs[k].insn_addr;
                        if (a->refs[k].cls == CLS_SERVICE &&
                            site >= syms[s].st_value &&
                            site < syms[s].st_value + syms[s].st_size)
                            confirmed = 1;
                    }
                }
            }
            snprintf(a->dbg_note, sizeof(a->dbg_note),
                     "symtab cross-check: %s",
                     confirmed ? "SERVICE site inside VoldNativeService::start"
                               : "no matching symbol range (not gating)");
        } else {
            snprintf(a->dbg_note, sizeof(a->dbg_note),
                     "symtab cross-check: skipped (no usable .symtab, not gating)");
        }
    } else {
        snprintf(a->dbg_note, sizeof(a->dbg_note),
                 "symtab cross-check: skipped (no .symtab, not gating)");
    }
    rc = 0;
    return rc;
}

static void analysis_free(struct analysis *a) {
    free(a->refs);
    a->refs = NULL;
}

static void log_refs(const struct analysis *a, const char *tag) {
    size_t i;
    for (i = 0; i < a->nrefs; i++) {
        const struct ref *r = &a->refs[i];
        printf("gvld_patch: %s: ref insn=0x%llx reg=x%d gap=%d literal_off=%zu "
               "target=0x%llx class=%s callee=%s consumer=0x%llx steps=%d "
               "holder=x%d w0=%d w2=%d x0stack=%d path=[%s]\n",
               tag, (unsigned long long)r->insn_addr, r->rd, r->gap,
               r->lit_off, (unsigned long long)r->lit_addr,
               class_name(r->cls),
               r->callee[0] ? r->callee : "(unknown)",
               (unsigned long long)r->consumer_addr, r->steps,
               r->holder_at_call, r->w0_imm, r->w2_imm, r->x0_stack,
               r->path);
    }
}

/* Decide whether patching may proceed. Returns 1 if the single
 * literal may be patched, 0 if LEARN. Sets *why on LEARN. */
static int decide_patch(const struct analysis *a, const char **why) {
    size_t i;
    if (a->learn) {
        *why = a->learn_why;
        return 0;
    }
    if (a->nstandalone != 1) {
        *why = (a->nstandalone == 0) ? "no standalone literal" :
                                       "more than one standalone literal";
        return 0;
    }
    if (a->nrefs == 0) {
        *why = "no references to the standalone literal";
        return 0;
    }
    if (a->nservice == 0) {
        *why = "no service-name reference to the standalone literal";
        return 0;
    }
    for (i = 0; i < a->nrefs; i++) {
        if (a->refs[i].is_suffix) {
            *why = "reference to a suffix (tail-merge) literal";
            return 0;
        }
        if (a->refs[i].cls == CLS_UNKNOWN) {
            *why = "UNKNOWN reference (see per-reference trace)";
            return 0;
        }
    }
    if (a->multi_logtag_callee) {
        *why = "LOGTAG references use more than one callee";
        return 0;
    }
    return 1;
}

int main(int argc, char **argv) {
    const char *in_path, *out_path;
    int in_fd = -1, out_fd = -1;
    unsigned char *buf = NULL, *orig = NULL;
    struct stat st;
    ssize_t got;
    size_t total = 0;
    struct analysis a;
    const char *why = NULL;
    int rc = 1;

    if (argc != 3) {
        fprintf(stderr, "usage: gvld_patch <input-file> <output-file>\n");
        return 1;
    }
    in_path = argv[1];
    out_path = argv[2];

    in_fd = open(in_path, O_RDONLY);
    if (in_fd < 0) {
        fprintf(stderr, "gvld_patch: cannot open %s: %s\n", in_path, strerror(errno));
        return 1;
    }
    if (fstat(in_fd, &st) != 0 || st.st_size <= 0 || (uint64_t)st.st_size > MAX_SIZE) {
        fprintf(stderr, "gvld_patch: bad size for %s\n", in_path);
        goto done;
    }
    buf = (unsigned char *)malloc((size_t)st.st_size);
    if (!buf) {
        fprintf(stderr, "gvld_patch: out of memory\n");
        goto done;
    }
    while (total < (size_t)st.st_size) {
        got = read(in_fd, buf + total, (size_t)st.st_size - total);
        if (got < 0) {
            if (errno == EINTR) continue;
            fprintf(stderr, "gvld_patch: read failed: %s\n", strerror(errno));
            goto done;
        }
        if (got == 0) break;
        total += (size_t)got;
    }
    if (total != (size_t)st.st_size) {
        fprintf(stderr, "gvld_patch: short read (%zu of %lld)\n", total, (long long)st.st_size);
        goto done;
    }
    orig = (unsigned char *)malloc(total);
    if (!orig) {
        fprintf(stderr, "gvld_patch: out of memory\n");
        goto done;
    }
    memcpy(orig, buf, total);

    if (analyze(buf, total, "vold", &a) != 0 || a.learn) {
        printf("gvld_patch: LEARN: %s\n",
               a.learn_why ? a.learn_why : "analysis failed");
        printf("gvld_patch: census: %zu standalone literal(s), %zu suffix candidate(s)\n",
               a.nstandalone, a.nsuffix);
        log_refs(&a, "LEARN");
        printf("gvld_patch: %s\n", a.dbg_note);
        analysis_free(&a);
        rc = 2;
        goto done;
    }
    printf("gvld_patch: census: %zu standalone literal(s) at file offset %zu (vaddr 0x%llx), %zu suffix candidate(s)\n",
           a.nstandalone, a.lit_off, (unsigned long long)a.lit_addr, a.nsuffix);
    printf("gvld_patch: %zu reference(s): %d SERVICE, %d LOGTAG\n",
           a.nrefs, a.nservice, a.nlogtag);
    log_refs(&a, "REF");
    printf("gvld_patch: %s\n", a.dbg_note);
    if (!decide_patch(&a, &why)) {
        printf("gvld_patch: LEARN: %s\n", why);
        analysis_free(&a);
        rc = 2;
        goto done;
    }
    {
        size_t lit_off = a.lit_off;
        size_t nrefs0 = a.nrefs;
        int nservice0 = a.nservice, nlogtag0 = a.nlogtag;
        analysis_free(&a);

        buf[lit_off] = 'g';
        buf[lit_off + 1] = 'v';

        /* Verify: byte diff confined to the literal, then re-run the
         * full classification on the patched buffer with target
         * "gvld", and confirm no standalone "vold" remains. */
        {
            struct analysis v;
            size_t i, diffs = 0;
            if (analyze(buf, total, "gvld", &v) != 0 || v.learn) {
                fprintf(stderr, "gvld_patch: verify failed: re-analysis refused the patched buffer\n");
                analysis_free(&v);
                rc = 1;
                goto done;
            }
            if (v.nstandalone != 1 || v.lit_off != lit_off ||
                v.nrefs != nrefs0 || v.nservice != nservice0 ||
                v.nlogtag != nlogtag0) {
                fprintf(stderr, "gvld_patch: verify failed: re-analysis counts differ (refs %zu/%zu, SERVICE %d/%d, LOGTAG %d/%d)\n",
                        v.nrefs, nrefs0, v.nservice, nservice0, v.nlogtag, nlogtag0);
                analysis_free(&v);
                rc = 1;
                goto done;
            }
            for (i = 0; i < v.nrefs; i++) {
                if (memcmp(v.refs[i].callee, "local:", 6) != 0 &&
                    v.refs[i].cls == CLS_LOGTAG) {
                    /* LOGTAG callees are local by construction; no-op. */
                }
            }
            if (memcmp(buf + lit_off, "gvld", 4) != 0 || buf[lit_off + 4] != 0) {
                fprintf(stderr, "gvld_patch: verify failed: patched address %zu does not read \"gvld\\0\"\n",
                        lit_off);
                analysis_free(&v);
                rc = 1;
                goto done;
            }
            for (i = 0; i < total; i++) {
                if (buf[i] != orig[i]) {
                    if (i != lit_off && i != lit_off + 1) {
                        fprintf(stderr, "gvld_patch: verify failed: unexpected diff at file offset %zu\n", i);
                        analysis_free(&v);
                        rc = 1;
                        goto done;
                    }
                    diffs++;
                }
            }
            if (diffs != 2) {
                fprintf(stderr, "gvld_patch: verify failed: %zu bytes differ, expected 2\n",
                        diffs);
                analysis_free(&v);
                rc = 1;
                goto done;
            }
            analysis_free(&v);
        }
        {
            /* Confirm no standalone "vold" literal survives. */
            struct analysis v2;
            if (analyze(buf, total, "vold", &v2) != 0) {
                /* A structural refusal here is itself a failure: the
                 * patched buffer must stay analyzable. */
                fprintf(stderr, "gvld_patch: verify failed: patched buffer no longer analyzes for \"vold\"\n");
                analysis_free(&v2);
                rc = 1;
                goto done;
            }
            if (v2.nstandalone != 0) {
                fprintf(stderr, "gvld_patch: verify failed: %zu standalone \"vold\" literal(s) remain\n",
                        v2.nstandalone);
                analysis_free(&v2);
                rc = 1;
                goto done;
            }
            analysis_free(&v2);
        }

        out_fd = open(out_path, O_WRONLY | O_CREAT | O_TRUNC, st.st_mode & 0777);
        if (out_fd < 0) {
            fprintf(stderr, "gvld_patch: cannot create %s: %s\n", out_path, strerror(errno));
            goto done;
        }
        {
            size_t off = 0;
            while (off < total) {
                got = write(out_fd, buf + off, total - off);
                if (got < 0) {
                    if (errno == EINTR) continue;
                    fprintf(stderr, "gvld_patch: write failed: %s\n", strerror(errno));
                    unlink(out_path);
                    goto done;
                }
                off += (size_t)got;
            }
        }
        if (fchmod(out_fd, st.st_mode & 0777) != 0) {
            fprintf(stderr, "gvld_patch: fchmod failed (non-fatal): %s\n", strerror(errno));
        }
        printf("gvld_patch: PATCHED literal at file offset %zu (\"vold\"->\"gvld\", 2 bytes)\n",
               lit_off);
        printf("gvld_patch: PATCHED %s -> %s (1 literal, 2 bytes changed, size %zu)\n",
               in_path, out_path, total);
        rc = 0;
    }

done:
    free(orig);
    if (in_fd >= 0) close(in_fd);
    if (out_fd >= 0) close(out_fd);
    free(buf);
    return rc;
}
