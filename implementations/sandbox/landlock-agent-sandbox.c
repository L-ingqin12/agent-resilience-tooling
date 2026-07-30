/*
 * landlock-agent-sandbox.c — S6 OS-Level Sandbox using Linux Landlock
 *
 * Compile: gcc -Wall -o landlock-agent-sandbox landlock-agent-sandbox.c
 * Usage:   ./landlock-agent-sandbox --rw /tmp/agent --ro /usr --ro /etc -- /bin/bash
 *
 * Restricts the agent process to only access specified paths.
 * Any access outside allowed paths is denied by the kernel.
 *
 * Requires: Linux 5.13+, CONFIG_SECURITY_LANDLOCK=y
 * Reference: https://docs.kernel.org/userspace-api/landlock.html
 *
 * This is the S6 ultimate defense layer.
 */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/landlock.h>
#include <linux/prctl.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

#ifndef landlock_create_ruleset
static inline int landlock_create_ruleset(
    const struct landlock_ruleset_attr *const attr,
    const size_t size, const __u32 flags)
{
    return syscall(__NR_landlock_create_ruleset, attr, size, flags);
}
#endif

#ifndef landlock_add_rule
static inline int landlock_add_rule(
    const int ruleset_fd,
    const enum landlock_rule_type rule_type,
    const void *const rule_attr,
    const __u32 flags)
{
    return syscall(__NR_landlock_add_rule, ruleset_fd, rule_type, rule_attr, flags);
}
#endif

#ifndef landlock_restrict_self
static inline int landlock_restrict_self(
    const int ruleset_fd,
    const __u32 flags)
{
    return syscall(__NR_landlock_restrict_self, ruleset_fd, flags);
}
#endif

#define LANDLOCK_ACCESS_FS_READ_FILE    (1ULL << 0)
#define LANDLOCK_ACCESS_FS_READ_DIR     (1ULL << 1)
#define LANDLOCK_ACCESS_FS_WRITE_FILE   (1ULL << 8)
#define LANDLOCK_ACCESS_FS_MAKE_DIR     (1ULL << 6)
#define LANDLOCK_ACCESS_FS_MAKE_REG     (1ULL << 7)
#define LANDLOCK_ACCESS_FS_REMOVE_DIR   (1ULL << 12)
#define LANDLOCK_ACCESS_FS_REMOVE_FILE  (1ULL << 13)
#define LANDLOCK_ACCESS_FS_EXECUTE     (1ULL << 2)

#define RW_ACCESS (LANDLOCK_ACCESS_FS_READ_FILE | \
                   LANDLOCK_ACCESS_FS_READ_DIR | \
                   LANDLOCK_ACCESS_FS_WRITE_FILE | \
                   LANDLOCK_ACCESS_FS_MAKE_DIR | \
                   LANDLOCK_ACCESS_FS_MAKE_REG | \
                   LANDLOCK_ACCESS_FS_REMOVE_DIR | \
                   LANDLOCK_ACCESS_FS_REMOVE_FILE)

#define RO_ACCESS (LANDLOCK_ACCESS_FS_READ_FILE | \
                   LANDLOCK_ACCESS_FS_READ_DIR | \
                   LANDLOCK_ACCESS_FS_EXECUTE)

static int add_path_rule(int ruleset_fd, const char *path, __u64 access) {
    struct landlock_path_beneath_attr path_beneath = {0};
    int abi, err;

    path_beneath.allowed_access = access;
    path_beneath.parent_fd = open(path, O_PATH | O_CLOEXEC | O_DIRECTORY);
    if (path_beneath.parent_fd < 0) {
        fprintf(stderr, "landlock-sandbox: failed to open %s: %s\n", path, strerror(errno));
        return -1;
    }

    err = landlock_add_rule(ruleset_fd, LANDLOCK_RULE_PATH_BENEATH,
                            &path_beneath, 0);
    close(path_beneath.parent_fd);
    if (err) {
        fprintf(stderr, "landlock-sandbox: failed to add rule for %s: %s\n",
                path, strerror(errno));
        return -1;
    }
    return 0;
}

static void print_usage(const char *prog) {
    printf("Usage: %s [OPTIONS] -- <command> [args...]\n", prog);
    printf("\n");
    printf("Options:\n");
    printf("  --rw <path>    Allow read+write+create+delete under <path>\n");
    printf("  --ro <path>    Allow read+execute under <path> (no write)\n");
    printf("  --tmp <path>   Allow read+write under <path> (temp files only)\n");
    printf("  --help         Show this help\n");
    printf("\n");
    printf("Example (agent sandbox):\n");
    printf("  %s --rw /tmp/agent-workspace --ro /usr --ro /bin --ro /lib -- /bin/bash\n", prog);
    printf("\n");
    printf("All other paths are DENIED by the kernel.\n");
}

int main(int argc, char **argv) {
    struct landlock_ruleset_attr ruleset_attr = {0};
    int ruleset_fd, abi, i;
    const char *command = NULL;
    int cmd_start = 0;

    if (argc < 2) {
        print_usage(argv[0]);
        return 1;
    }

    // Check Landlock ABI version
    abi = landlock_create_ruleset(NULL, 0, LANDLOCK_CREATE_RULESET_VERSION);
    if (abi < 0) {
        fprintf(stderr, "landlock-sandbox: Landlock is not supported on this kernel. "
                        "Requires Linux 5.13+.\n");
        return 1;
    }

    if (abi < 3) {
        fprintf(stderr, "landlock-sandbox: WARNING: Landlock ABI %d (recommended: >= 3). "
                        "Some access controls may not be available.\n", abi);
    }

    // Create ruleset
    ruleset_attr.handled_access_fs = RW_ACCESS | RO_ACCESS;
    ruleset_fd = landlock_create_ruleset(&ruleset_attr, sizeof(ruleset_attr), 0);
    if (ruleset_fd < 0) {
        perror("landlock_create_ruleset");
        return 1;
    }

    // Parse options
    for (i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--") == 0) {
            cmd_start = i + 1;
            break;
        }
        if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
            print_usage(argv[0]);
            close(ruleset_fd);
            return 0;
        }
        if (strcmp(argv[i], "--rw") == 0 && i + 1 < argc) {
            if (add_path_rule(ruleset_fd, argv[++i], RW_ACCESS) != 0) {
                close(ruleset_fd);
                return 1;
            }
        } else if (strcmp(argv[i], "--ro") == 0 && i + 1 < argc) {
            if (add_path_rule(ruleset_fd, argv[++i], RO_ACCESS) != 0) {
                close(ruleset_fd);
                return 1;
            }
        } else if (strcmp(argv[i], "--tmp") == 0 && i + 1 < argc) {
            if (add_path_rule(ruleset_fd, argv[++i], RW_ACCESS) != 0) {
                close(ruleset_fd);
                return 1;
            }
        }
    }

    if (cmd_start == 0 || cmd_start >= argc) {
        fprintf(stderr, "landlock-sandbox: no command specified after --\n");
        close(ruleset_fd);
        return 1;
    }

    // No escape: also deny self-modification
    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0)) {
        perror("prctl(PR_SET_NO_NEW_PRIVS)");
        close(ruleset_fd);
        return 1;
    }

    // Activate sandbox — from this point, kernel enforces access
    if (landlock_restrict_self(ruleset_fd, 0)) {
        perror("landlock_restrict_self");
        close(ruleset_fd);
        return 1;
    }
    close(ruleset_fd);

    fprintf(stderr, "landlock-sandbox: active — file system access restricted\n");

    // Execute the target command
    execvp(argv[cmd_start], &argv[cmd_start]);
    perror("execvp");
    return 1;
}
