/*
 * Offline check of the AIR -> SPIR-V translator: translate each metallib given on the command
 * line and run spirv-val on the result. Usage: a2s-check [-o OUTDIR] FILE.metallib...
 * Prints "ok|FAIL|INVALID <file> [reason]" per file and a summary; exit status 1 on any failure.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "air2spv.h"

static char *slurp(const char *path, size_t *len)
{
    FILE *f = fopen(path, "rb");
    char *buf;

    if (!f) {
        return NULL;
    }
    fseek(f, 0, SEEK_END);
    *len = ftell(f);
    fseek(f, 0, SEEK_SET);
    buf = malloc(*len ? *len : 1);
    if (fread(buf, 1, *len, f) != *len) {
        free(buf);
        buf = NULL;
    }
    fclose(f);
    return buf;
}

int main(int argc, char **argv)
{
    const char *outdir = "/tmp";
    int ok = 0, bad = 0, i = 1;

    if (argc > 2 && !strcmp(argv[1], "-o")) {
        outdir = argv[2];
        i = 3;
    }
    for (; i < argc; i++) {
        size_t len, bclen;
        char *lib = slurp(argv[i], &len), cmd[4096], out[2048];
        const void *bc = lib ? air2spv_metallib_bitcode(lib, len, &bclen) : NULL;

        if (!bc && lib && len > 4 && (!memcmp(lib, "BC\xc0\xde", 4) || !memcmp(lib, "\xde\xc0\x17\x0b", 4))) {
            bc = lib;           /* raw AIR bitcode (synthetic tests) */
            bclen = len;
        }
        A2SResult r = { 0 };
        const char *base = strrchr(argv[i], '/') ? strrchr(argv[i], '/') + 1 : argv[i];

        if (!bc) {
            printf("FAIL %s (no bitcode)\n", argv[i]);
            bad++;
        } else if (air2spv_translate(bc, bclen, &r) || !r.spirv) {
            printf("FAIL %s %s\n", argv[i], r.error);
            bad++;
        } else {
            FILE *f;

            snprintf(out, sizeof(out), "%s/%s.spv", outdir, base);
            f = fopen(out, "wb");
            if (!f) {
                perror(out);
                exit(2);
            }
            fwrite(r.spirv, 4, r.nwords, f);
            fclose(f);
            snprintf(cmd, sizeof(cmd), "spirv-val --target-env vulkan1.3 '%s' >/dev/null 2>&1", out);
            if (system(cmd)) {
                printf("INVALID %s (spirv-val %s)\n", argv[i], out);
                bad++;
            } else {
                ok++;
            }
            free(r.spirv);
        }
        free(lib);
    }
    printf("%d ok, %d failed\n", ok, bad);
    return bad != 0;
}
