/* gvld_patch.c — guest own-vold-name binary patcher (CronchGSI 6.20).
 *
 * Re-implements the MECHANISM OneOS documents for its vold_patched binary
 * patch (switcher/patches/guest_own_vold.py, studied read-only; this code
 * is written fresh, credited to fahadalijaved/OneOS in PATCHES.md): the
 * guest's storage daemon registers under a guest-private binder name
 * ("gvld") instead of "vold", so the guest framework (services_isolated.jar,
 * which resolves "gvld") never talks to the host's vold in the shared
 * servicemanager.
 *
 * What it patches: the UTF-16LE String16 "vold" (bytes 76 00 6F 00 6C 00
 * 64 00) that VoldNativeService::start passes to the service manager, to
 * "gvld" (67 00 76 00 6C 00 64 00). Same length; only two bytes change
 * ('v'->'g', 'o'->'v'; 'l' and 'd' are identical). No code is touched.
 *
 * What it deliberately does NOT do (documented gap, PATCHES.md): the
 * VendorVoldNativeService::try_start tbz->b patch that stops the guest
 * vold registering the AIDL name android.system.vold.IVold/default.
 * Locating that instruction without SHA-pinned offsets is not safely
 * doable; the legacy "vold" name — the one the 6.18 CE-key crash went
 * through — is what this patch closes. The AIDL registration remains a
 * known residual surface until pins exist.
 *
 * Fail-closed design (no pins ship in 6.20; the Lineage 23.2 vold binary
 * was never available on the build VM):
 *   - exit 0: exactly ONE UTF-16 "vold" occurrence in an ELF64 LE
 *     AArch64 file that also mentions VoldNativeService (or the AIDL
 *     vold name). Output written, verified byte-identical except the
 *     two changed bytes. The staging script bind-mounts it.
 *   - exit 2 (LEARN): zero or ambiguous occurrences, or the ELF/sanity
 *     checks fail. NO output is written. Diagnostics go to stdout for
 *     the staging log (offsets, counts, what was checked) so a future
 *     pin table can be built from a real device. The staging script
 *     ABORTS on this code when the patch is required — never boot with
 *     half-isolation (framework asking for "gvld" that nothing owns).
 *   - exit 1: I/O or usage error.
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

#define MAX_SIZE (64u * 1024u * 1024u)

/* UTF-16LE "vold" -> "gvld" (8 bytes; only bytes 0 and 2 differ). */
static const unsigned char PAT_OLD[8] = {0x76, 0x00, 0x6f, 0x00, 0x6c, 0x00, 0x64, 0x00};
static const unsigned char PAT_NEW[8] = {0x67, 0x00, 0x76, 0x00, 0x6c, 0x00, 0x64, 0x00};

static long count_ascii(const unsigned char *buf, size_t len, const char *needle) {
    size_t nlen = strlen(needle);
    long count = 0;
    size_t i;
    if (len < nlen) return 0;
    for (i = 0; i + nlen <= len; i++) {
        if (memcmp(buf + i, needle, nlen) == 0) count++;
    }
    return count;
}

int main(int argc, char **argv) {
    const char *in_path, *out_path;
    int in_fd = -1, out_fd = -1;
    unsigned char *buf = NULL;
    struct stat st;
    ssize_t got;
    size_t total = 0;
    size_t i, found = 0;
    size_t found_off = 0;
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

    /* ELF64 LE, AArch64. e_ident[4]=2 (64-bit), e_ident[5]=1 (LE),
     * e_machine at offset 18 (uint16) = 183. */
    if (total < 64 || memcmp(buf, "\x7f" "ELF", 4) != 0 || buf[4] != 2 || buf[5] != 1) {
        printf("gvld_patch: LEARN: not an ELF64 little-endian file (%s)\n", in_path);
        rc = 2;
        goto done;
    }
    {
        uint16_t machine = (uint16_t)(buf[18] | (buf[19] << 8));
        if (machine != 183) {
            printf("gvld_patch: LEARN: e_machine=%u, not AArch64 (183)\n", machine);
            rc = 2;
            goto done;
        }
    }
    /* Sanity: this must be a vold-family binary, not an arbitrary file. */
    if (count_ascii(buf, total, "VoldNativeService") == 0 &&
        count_ascii(buf, total, "android.system.vold") == 0 &&
        count_ascii(buf, total, "vold") == 0) {
        printf("gvld_patch: LEARN: no vold-identifying strings in %s\n", in_path);
        rc = 2;
        goto done;
    }

    for (i = 0; i + 8 <= total; i++) {
        if (memcmp(buf + i, PAT_OLD, 8) == 0) {
            if (found == 0) found_off = i;
            found++;
            if (found > 1) break;
        }
    }
    printf("gvld_patch: %s: UTF-16 \"vold\" occurrences: %zu\n", in_path, found);
    if (found == 0) {
        printf("gvld_patch: LEARN: no UTF-16 \"vold\" service-name string; "
               "ASCII \"vold\" occurrences: %ld; VoldNativeService: %ld\n",
               count_ascii(buf, total, "vold"),
               count_ascii(buf, total, "VoldNativeService"));
        rc = 2;
        goto done;
    }
    if (found > 1) {
        printf("gvld_patch: LEARN: ambiguous: %zu occurrences (first at file offset %zu); "
               "pins required, refusing to guess\n", found, found_off);
        /* List every offset for the learn log. */
        {
            size_t k, n = 0;
            for (k = 0; k + 8 <= total && n < 16; k++) {
                if (memcmp(buf + k, PAT_OLD, 8) == 0) {
                    printf("gvld_patch: LEARN: occurrence %zu at offset %zu\n", n, k);
                    n++;
                }
            }
        }
        rc = 2;
        goto done;
    }

    /* Exactly one occurrence: patch it. */
    memcpy(buf + found_off, PAT_NEW, 8);
    /* Self-check: exactly two bytes differ from the original pattern. */
    {
        int diffs = 0;
        int j;
        for (j = 0; j < 8; j++) if (PAT_OLD[j] != PAT_NEW[j]) diffs++;
        if (diffs != 2) {
            fprintf(stderr, "gvld_patch: internal error: pattern diff count %d\n", diffs);
            rc = 1;
            goto done;
        }
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
    /* Verify the output: "gvld" present once, "vold" pattern gone. */
    {
        size_t n_new = 0, n_old = 0;
        for (i = 0; i + 8 <= total; i++) {
            if (memcmp(buf + i, PAT_NEW, 8) == 0) n_new++;
            if (memcmp(buf + i, PAT_OLD, 8) == 0) n_old++;
        }
        if (n_new != 1 || n_old != 0) {
            fprintf(stderr, "gvld_patch: self-check failed (gvld=%zu vold=%zu)\n", n_new, n_old);
            unlink(out_path);
            rc = 1;
            goto done;
        }
    }
    if (fchmod(out_fd, st.st_mode & 0777) != 0) {
        fprintf(stderr, "gvld_patch: fchmod failed (non-fatal): %s\n", strerror(errno));
    }
    printf("gvld_patch: PATCHED %s -> %s (UTF-16 \"vold\"->\"gvld\" at file offset %zu, "
           "2 bytes changed, size %zu)\n", in_path, out_path, found_off, total);
    rc = 0;

done:
    if (in_fd >= 0) close(in_fd);
    if (out_fd >= 0) close(out_fd);
    free(buf);
    return rc;
}
