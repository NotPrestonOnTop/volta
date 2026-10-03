//
//  voltweaks-helper - switches one tweak on or off for the Voltweaks app.
//
//  The folder tweaks are loaded from belongs to root, and apps run as
//  "mobile", so this tool does the one step that needs root: renaming
//      <folder>/<Name>.dylib  <->  <folder>/<Name>.disabled
//  (the same convention iCleaner uses; the loader only opens ".dylib").
//
//  It is installed set-uid root, so it is written to do exactly that and
//  nothing else, whoever runs it:
//    - the folder is one of the fixed paths below, never taken from the caller
//    - the name is a plain file name: no "/", no leading ".", a short list of
//      allowed characters
//    - the rename happens relative to the opened folder, never replaces an
//      existing file, and only touches a regular file or a symlink entry
//
//  It has one other job, for Volta's Safety page: switching iOS's own
//  software-update services off or back on. That too takes nothing from the
//  caller: the service names and the launchctl paths are fixed below.
//
//  Usage:   voltweaks-helper enable|disable <Name>      (no extension)
//           voltweaks-helper ota-block | ota-allow      (iOS updates off / on)
//           voltweaks-helper ota-status                 (exit 0 blocked, 1 not blocked)
//           voltweaks-helper check                      (exit 0 if it has root)
//  Exit:    0 done, 2 bad arguments, 3 not root, 4 no such tweak, 5 failed,
//           6 launchctl not found
//
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <spawn.h>
#include <stdlib.h>
#include <sys/wait.h>

#ifdef VLT_HELPER_TEST   /* off-device tests point this at a scratch folder */
static const char *const kFolders[] = { VLT_HELPER_TEST, NULL };
#else
static const char *const kFolders[] = {
    "/var/jb/Library/MobileSubstrate/DynamicLibraries",
    "/var/jb/usr/lib/TweakInject",
    NULL
};
#endif

#define NAME_MAX_LEN 120

static int name_ok(const char *name) {
    size_t length = strlen(name);
    if (length == 0 || length > NAME_MAX_LEN || name[0] == '.' || name[0] == '-') return 0;
    for (size_t i = 0; i < length; i++) {
        unsigned char c = (unsigned char)name[i];
        int plain = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9');
        if (!plain && c != '.' && c != '_' && c != '-' && c != '+' && c != ' ') return 0;
    }
    return 1;
}

/* 0 done, 4 not in this folder, 5 failed */
static int flip(const char *folder, const char *name, int enable) {
    char from[NAME_MAX_LEN + 16], to[NAME_MAX_LEN + 16];
    snprintf(from, sizeof(from), "%s.%s", name, enable ? "disabled" : "dylib");
    snprintf(to, sizeof(to), "%s.%s", name, enable ? "dylib" : "disabled");

    int dir = open(folder, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (dir < 0) return 4;

    int result = 5;
    struct stat info;
    if (fstatat(dir, from, &info, AT_SYMLINK_NOFOLLOW) != 0) {
        result = 4;
    } else if (!S_ISREG(info.st_mode) && !S_ISLNK(info.st_mode)) {
        fprintf(stderr, "voltweaks-helper: %s is not a file\n", from);
    } else if (fstatat(dir, to, &info, AT_SYMLINK_NOFOLLOW) == 0) {
        fprintf(stderr, "voltweaks-helper: %s already exists\n", to);
    } else if (renameat(dir, from, dir, to) != 0) {
        fprintf(stderr, "voltweaks-helper: rename failed: %s\n", strerror(errno));
    } else {
        result = 0;
    }
    close(dir);
    return result;
}

/* ---- iOS software updates ---- */

/* The services that find, download and install iOS updates. Names that do not
   exist on a given iOS version are simply ignored by launchctl. */
static const char *const kUpdateServices[] = {
    "system/com.apple.mobile.softwareupdated",
    "system/com.apple.softwareupdateservicesd",
    "system/com.apple.OTATaskingAgent",
    "system/com.apple.mobile.NRDUpdated",
    NULL
};
/* Blocked means these two are off; the others are extras. */
static const char *const kUpdateCore[] = { "com.apple.mobile.softwareupdated", "com.apple.softwareupdateservicesd", NULL };

#ifdef VLT_LAUNCHCTL_TEST
static const char *const kLaunchctl[] = { VLT_LAUNCHCTL_TEST, NULL };
#else
static const char *const kLaunchctl[] = { "/var/jb/usr/bin/launchctl", "/var/jb/bin/launchctl", "/bin/launchctl", NULL };
#endif

static const char *find_launchctl(void) {
    for (int i = 0; kLaunchctl[i]; i++) {
        if (access(kLaunchctl[i], X_OK) == 0) return kLaunchctl[i];
    }
    return NULL;
}

extern char **environ;

/* Runs launchctl with up to two arguments and a fixed environment. If out is
   given, standard output is collected into it. Returns the exit code, -1 on failure. */
static int run_launchctl(const char *tool, const char *a, const char *b, char *out, size_t outSize) {
    char *const argv[] = { (char *)tool, (char *)a, (char *)b, NULL };
    char *const envp[] = { "PATH=/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin", NULL };
    int pipeFDs[2] = { -1, -1 };
    posix_spawn_file_actions_t actions;
    if (posix_spawn_file_actions_init(&actions) != 0) return -1;
    if (out) {
        if (pipe(pipeFDs) != 0) { posix_spawn_file_actions_destroy(&actions); return -1; }
        posix_spawn_file_actions_adddup2(&actions, pipeFDs[1], STDOUT_FILENO);
        posix_spawn_file_actions_addclose(&actions, pipeFDs[0]);
        posix_spawn_file_actions_addclose(&actions, pipeFDs[1]);
    } else {
        posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0);
    }
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);
    pid_t pid = 0;
    int spawned = posix_spawn(&pid, tool, &actions, NULL, argv, envp);
    posix_spawn_file_actions_destroy(&actions);
    if (out) close(pipeFDs[1]);
    if (spawned != 0) {
        if (out) close(pipeFDs[0]);
        return -1;
    }
    if (out) {
        size_t used = 0;
        ssize_t got;
        while (used + 1 < outSize && (got = read(pipeFDs[0], out + used, outSize - 1 - used)) > 0) used += (size_t)got;
        out[used] = '\0';
        char sink[512];
        while (read(pipeFDs[0], sink, sizeof(sink)) > 0) {}   /* let it finish even if the buffer is full */
        close(pipeFDs[0]);
    }
    int status = 0;
    while (waitpid(pid, &status, 0) < 0) {
        if (errno != EINTR) return -1;
    }
    return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

/* 0 done, 5 at least one core service could not be switched, 6 no launchctl */
static int ota_set(int block) {
    const char *tool = find_launchctl();
    if (!tool) return 6;
    int failed = 0;
    for (int i = 0; kUpdateServices[i]; i++) {
        int code = run_launchctl(tool, block ? "disable" : "enable", kUpdateServices[i], NULL, 0);
        if (code != 0 && i < 2) failed = 1;
        /* Stop a running copy now; a service that is not running makes this fail, which is fine. */
        if (block) (void)run_launchctl(tool, "bootout", kUpdateServices[i], NULL, 0);
    }
    return failed ? 5 : 0;
}

/* Is the line for this service marked off? launchctl prints one line each:
       "com.apple.x" => disabled      (newer)      "com.apple.x" => true      (older) */
static int line_says_off(const char *listing, const char *service) {
    char needle[128];
    snprintf(needle, sizeof(needle), "\"%s\"", service);
    const char *at = strstr(listing, needle);
    if (!at) return 0;
    const char *end = strchr(at, '\n');
    size_t length = end ? (size_t)(end - at) : strlen(at);
    char line[200];
    if (length >= sizeof(line)) length = sizeof(line) - 1;
    memcpy(line, at, length);
    line[length] = '\0';
    return strstr(line, "=> disabled") != NULL || strstr(line, "=> true") != NULL;
}

/* 0 blocked, 1 not blocked, 5 could not tell, 6 no launchctl */
static int ota_status(void) {
    const char *tool = find_launchctl();
    if (!tool) return 6;
    char *listing = (char *)malloc(256 * 1024);
    if (!listing) return 5;
    int code = run_launchctl(tool, "print-disabled", "system", listing, 256 * 1024);
    int result = 5;
    if (code == 0) {
        result = 0;
        for (int i = 0; kUpdateCore[i]; i++) if (!line_says_off(listing, kUpdateCore[i])) result = 1;
    }
    free(listing);
    return result;
}

int main(int argc, char *argv[]) {
#ifndef VLT_HELPER_TEST
    /* Become root in full (set-uid alone only changes the effective user, and
       launchctl looks at the real one). Some jailbreaks also grant this on request. */
    (void)setgid(0);
    (void)setuid(0);
    if (geteuid() != 0) {
        fprintf(stderr, "voltweaks-helper: not running as root\n");
        return 3;
    }
#endif
    if (argc == 2 && strcmp(argv[1], "check") == 0) return 0;
    if (argc == 2 && strcmp(argv[1], "ota-block") == 0) return ota_set(1);
    if (argc == 2 && strcmp(argv[1], "ota-allow") == 0) return ota_set(0);
    if (argc == 2 && strcmp(argv[1], "ota-status") == 0) return ota_status();

    if (argc != 3) return 2;
    int enable;
    if (strcmp(argv[1], "enable") == 0) enable = 1;
    else if (strcmp(argv[1], "disable") == 0) enable = 0;
    else return 2;
    if (!name_ok(argv[2])) return 2;

    /* The two folders are usually one folder under two names; the first that has the file wins. */
    int result = 4;
    for (int i = 0; kFolders[i]; i++) {
        result = flip(kFolders[i], argv[2], enable);
        if (result != 4) break;
    }
    return result;
}
