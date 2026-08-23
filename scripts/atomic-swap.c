#include <errno.h>
#include <stdio.h>
#include <string.h>

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: atomic-swap source target\n");
        return 64;
    }
    if (renamex_np(argv[1], argv[2], RENAME_SWAP) != 0) {
        fprintf(stderr, "atomic swap failed: %s\n", strerror(errno));
        return 1;
    }
    return 0;
}
