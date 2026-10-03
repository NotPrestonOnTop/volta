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
//  Usage:   voltweaks-helper enable|disable <Name>      (no extension)
//           voltweaks-helper check                      (exit 0 if it has root)
//  Exit:    0 done, 2 bad arguments, 3 not root, 4 no such tweak, 5 failed
//
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

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

int main(int argc, char *argv[]) {
#ifndef VLT_HELPER_TEST
    if (geteuid() != 0) (void)setuid(0);   /* some jailbreaks grant this to set-uid tools on request */
    if (geteuid() != 0) {
        fprintf(stderr, "voltweaks-helper: not running as root\n");
        return 3;
    }
#endif
    if (argc == 2 && strcmp(argv[1], "check") == 0) return 0;

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
