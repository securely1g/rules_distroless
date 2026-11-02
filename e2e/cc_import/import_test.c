#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <zstd.h>

int main(int argc, char **argv) {
    if (argc != 2 || strcmp(ZSTD_versionString(), "1.5.7") != 0) return 1;
    Dl_info info;
    if (!dladdr((void *)ZSTD_versionString, &info)) return 2;
    FILE *actual = fopen(info.dli_fname, "rb");
    FILE *expected = fopen(argv[1], "rb");
    if (!actual || !expected) return 3;
    int a, b;
    do {
        a = fgetc(actual);
        b = fgetc(expected);
        if (a != b) return 4;
    } while (a != EOF);
    if (ferror(actual) || ferror(expected)) return 5;
    fclose(actual);
    fclose(expected);
    printf("Imported Zstd %s from the declared Debian library: %s\n",
           ZSTD_versionString(), info.dli_fname);
    return 0;
}
