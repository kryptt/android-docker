/*
 * mount_nfs — Minimal NFS mount helper for Android
 *
 * Android's toybox `mount` command does not support NFS filesystem types.
 * This binary calls the mount() syscall directly with NFS-specific options.
 *
 * Usage: mount_nfs <server:/path> <mountpoint> [nfsvers]
 *   nfsvers: 3 (default) or 4
 *
 * Cross-compile for aarch64:
 *   aarch64-linux-gnu-gcc -static -o mount_nfs mount_nfs.c
 */

#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <sys/mount.h>

int main(int argc, char *argv[]) {
    if (argc < 3) {
        fprintf(stderr, "Usage: %s <server:/path> <mountpoint> [nfsvers]\n", argv[0]);
        return 1;
    }

    const char *source = argv[1];
    const char *target = argv[2];
    const char *vers = (argc > 3) ? argv[3] : "3";

    /* Extract server address (everything before ':') */
    const char *colon = strchr(source, ':');
    if (!colon || colon == source) {
        fprintf(stderr, "Bad source (expected server:/path): %s\n", source);
        return 1;
    }

    /* Build options string with bounds check */
    char addr[256];
    size_t addr_len = (size_t)(colon - source);
    if (addr_len >= sizeof(addr)) {
        fprintf(stderr, "Server address too long\n");
        return 1;
    }
    memcpy(addr, source, addr_len);
    addr[addr_len] = '\0';

    char opts[512];
    int n = snprintf(opts, sizeof(opts), "nolock,addr=%s,vers=%s,proto=tcp", addr, vers);
    if (n < 0 || (size_t)n >= sizeof(opts)) {
        fprintf(stderr, "Options string too long\n");
        return 1;
    }

    const char *fstype = (strcmp(vers, "4") == 0) ? "nfs4" : "nfs";

    printf("mount -t %s -o %s %s %s\n", fstype, opts, source, target);

    if (mount(source, target, fstype, 0, opts) != 0) {
        fprintf(stderr, "mount failed: %s (errno=%d)\n", strerror(errno), errno);
        return 1;
    }
    printf("OK\n");
    return 0;
}
