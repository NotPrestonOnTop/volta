//
//  SavedCore.h - pulling a YouTube video id out of whatever link was shared.
//  Plain C so it can be tested off-device.
//
#ifndef VLT_SAVED_CORE_H
#define VLT_SAVED_CORE_H

#include <string.h>
#include <ctype.h>

#define VLT_VIDEO_ID_MAX 20

static inline int vlt_id_char(char c) {
    return isalnum((unsigned char)c) || c == '_' || c == '-';
}

// Copies the id that starts at p into out (if it is 6-20 id characters and
// ends at a URL boundary). Returns 1 on success.
static inline int vlt_take_id(const char *p, char *out) {
    size_t n = 0;
    while (vlt_id_char(p[n])) {
        if (++n > VLT_VIDEO_ID_MAX) return 0;
    }
    if (n < 6) return 0;
    char end = p[n];
    if (end != '\0' && end != '&' && end != '?' && end != '#' && end != '/' && !isspace((unsigned char)end)) return 0;
    memcpy(out, p, n);
    out[n] = '\0';
    return 1;
}

// Finds a video id in text that contains a YouTube link:
//   youtu.be/ID, youtube.com/watch?v=ID (v anywhere in the query),
//   youtube.com/shorts/ID, /live/ID, /embed/ID; with or without www./m./music.
// out must hold VLT_VIDEO_ID_MAX + 1 bytes. Returns 1 if one was found.
static inline int vlt_video_id(const char *text, char *out) {
    if (!text || !out) return 0;
    out[0] = '\0';
    if (strlen(text) > 2048) return 0;
    const char *host = strstr(text, "youtu.be/");
    if (host) {
        // must be the start of a host name, not the tail of another one
        if (host == text || host[-1] == '/' || host[-1] == '.' || isspace((unsigned char)host[-1])) {
            if (vlt_take_id(host + 9, out)) return 1;
        }
    }
    host = strstr(text, "youtube.com/");
    if (!host) return 0;
    if (!(host == text || host[-1] == '/' || host[-1] == '.' || isspace((unsigned char)host[-1]))) return 0;
    const char *path = host + 12;
    static const char *const prefixes[] = { "shorts/", "live/", "embed/", NULL };
    for (int i = 0; prefixes[i]; i++) {
        size_t length = strlen(prefixes[i]);
        if (strncmp(path, prefixes[i], length) == 0) return vlt_take_id(path + length, out);
    }
    if (strncmp(path, "watch", 5) != 0) return 0;
    const char *query = strchr(path, '?');
    while (query) {
        query++;   // past '?' or '&'
        if (strncmp(query, "v=", 2) == 0) return vlt_take_id(query + 2, out);
        const char *next = strchr(query, '&');
        const char *stop = strpbrk(query, "# \t\r\n");
        if (!next || (stop && stop < next)) break;
        query = next;
    }
    return 0;
}

#endif
