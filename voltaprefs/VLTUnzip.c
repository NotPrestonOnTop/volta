#include "VLTUnzip.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <limits.h>
#include <errno.h>
#include <sys/stat.h>
#include <zlib.h>

static uint16_t rd16(const unsigned char *p) { return (uint16_t)(p[0] | (p[1] << 8)); }
static uint32_t rd32(const unsigned char *p) { return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24); }

// Rejects anything that could land outside destDir.
static int name_is_safe(const char *name, size_t len) {
    if (len == 0 || len > 900 || name[0] == '/' || memchr(name, '\0', len) || memchr(name, '\\', len)) return 0;
    size_t start = 0;
    for (size_t i = 0; i <= len; i++) {
        if (i == len || name[i] == '/') {
            if (i - start == 2 && name[start] == '.' && name[start + 1] == '.') return 0;
            start = i + 1;
        }
    }
    return 1;
}

// mkdir -p for every directory component of path (not the last one).
static int make_parents(char *path) {
    for (char *p = path + 1; *p; p++) {
        if (*p != '/') continue;
        *p = '\0';
        if (mkdir(path, 0755) != 0 && errno != EEXIST) { *p = '/'; return -1; }
        *p = '/';
    }
    return 0;
}

static int read_at(FILE *f, long offset, unsigned char *buf, size_t n) {
    if (fseek(f, offset, SEEK_SET) != 0) return -1;
    return fread(buf, 1, n, f) == n ? 0 : -1;
}

// Copies or inflates one entry's data into out. Returns 0 on success.
static int extract_entry(FILE *zip, long dataOffset, uint32_t compressed, uint16_t method, FILE *out, unsigned long long *written) {
    enum { CHUNK = 64 * 1024 };
    unsigned char *in = malloc(CHUNK), *buf = malloc(CHUNK);
    int result = VLTUnzipErrFormat;
    if (!in || !buf || fseek(zip, dataOffset, SEEK_SET) != 0) goto done;

    if (method == 0) {
        uint32_t left = compressed;
        while (left > 0) {
            size_t want = left < CHUNK ? left : CHUNK;
            if (fread(in, 1, want, zip) != want) goto done;
            if (fwrite(in, 1, want, out) != want) { result = VLTUnzipErrWrite; goto done; }
            left -= (uint32_t)want;
            *written += want;
            if (*written > VLT_UNZIP_MAX_BYTES) { result = VLTUnzipErrTooBig; goto done; }
        }
        result = 0;
    } else {
        z_stream stream;
        memset(&stream, 0, sizeof(stream));
        if (inflateInit2(&stream, -MAX_WBITS) != Z_OK) goto done;   // raw deflate, as zip stores it
        uint32_t left = compressed;
        int status = Z_OK;
        while (status != Z_STREAM_END) {
            if (stream.avail_in == 0) {
                if (left == 0) break;
                size_t want = left < CHUNK ? left : CHUNK;
                if (fread(in, 1, want, zip) != want) break;
                left -= (uint32_t)want;
                stream.next_in = in;
                stream.avail_in = (uInt)want;
            }
            stream.next_out = buf;
            stream.avail_out = CHUNK;
            status = inflate(&stream, Z_NO_FLUSH);
            if (status != Z_OK && status != Z_STREAM_END) break;
            size_t produced = CHUNK - stream.avail_out;
            if (produced && fwrite(buf, 1, produced, out) != produced) { status = Z_ERRNO; result = VLTUnzipErrWrite; break; }
            *written += produced;
            if (*written > VLT_UNZIP_MAX_BYTES) { status = Z_ERRNO; result = VLTUnzipErrTooBig; break; }
        }
        inflateEnd(&stream);
        if (status == Z_STREAM_END) result = 0;
    }
done:
    free(in);
    free(buf);
    return result;
}

int vlt_unzip(const char *zipPath, const char *destDir) {
    FILE *zip = fopen(zipPath, "rb");
    if (!zip) return VLTUnzipErrOpen;
    int result = VLTUnzipErrFormat, files = 0;
    unsigned char *central = NULL;
    unsigned long long written = 0;

    // Find the "end of central directory" record in the last 64 KB.
    if (fseek(zip, 0, SEEK_END) != 0) goto done;
    long size = ftell(zip);
    if (size < 22) goto done;
    long tailLen = size < 65557 ? size : 65557;
    unsigned char *tail = malloc((size_t)tailLen);
    if (!tail) goto done;
    long eocd = -1;
    if (read_at(zip, size - tailLen, tail, (size_t)tailLen) == 0) {
        for (long i = tailLen - 22; i >= 0; i--) {
            if (rd32(tail + i) == 0x06054b50) { eocd = i; break; }
        }
    }
    uint16_t count = 0;
    uint32_t cdSize = 0, cdOffset = 0;
    if (eocd >= 0) {
        count = rd16(tail + eocd + 10);
        cdSize = rd32(tail + eocd + 12);
        cdOffset = rd32(tail + eocd + 16);
    }
    free(tail);
    if (eocd < 0 || (unsigned long long)cdOffset + cdSize > (unsigned long long)size) goto done;
    if (count > VLT_UNZIP_MAX_FILES) { result = VLTUnzipErrTooBig; goto done; }

    central = malloc(cdSize ? cdSize : 1);
    if (!central || read_at(zip, (long)cdOffset, central, cdSize) != 0) goto done;
    if (mkdir(destDir, 0755) != 0 && errno != EEXIST) { result = VLTUnzipErrWrite; goto done; }

    uint32_t pos = 0;
    for (uint16_t i = 0; i < count; i++) {
        if (pos + 46 > cdSize || rd32(central + pos) != 0x02014b50) goto done;
        uint16_t flags = rd16(central + pos + 8), method = rd16(central + pos + 10);
        uint32_t compressed = rd32(central + pos + 20), localOffset = rd32(central + pos + 42);
        uint16_t nameLen = rd16(central + pos + 28), extraLen = rd16(central + pos + 30), commentLen = rd16(central + pos + 32);
        if (pos + 46 + nameLen > cdSize) goto done;
        const char *name = (const char *)central + pos + 46;
        pos += 46u + nameLen + extraLen + commentLen;

        if (!name_is_safe(name, nameLen)) continue;                                  // skip, do not abort
        if (nameLen >= 9 && memcmp(name, "__MACOSX/", 9) == 0) continue;             // Finder metadata
        if (flags & 1) { result = VLTUnzipErrUnsupported; goto done; }               // encrypted
        if (method != 0 && method != 8) { result = VLTUnzipErrUnsupported; goto done; }

        char path[PATH_MAX];
        int n = snprintf(path, sizeof(path), "%s/%.*s", destDir, (int)nameLen, name);
        if (n <= 0 || n >= (int)sizeof(path)) continue;

        if (name[nameLen - 1] == '/') {                                              // directory entry
            if (make_parents(path) != 0) { result = VLTUnzipErrWrite; goto done; }
            continue;
        }

        unsigned char local[30];
        if (read_at(zip, (long)localOffset, local, 30) != 0 || rd32(local) != 0x04034b50) goto done;
        long dataOffset = (long)localOffset + 30 + rd16(local + 26) + rd16(local + 28);
        if ((unsigned long long)dataOffset + compressed > (unsigned long long)size) goto done;

        if (make_parents(path) != 0) { result = VLTUnzipErrWrite; goto done; }
        FILE *out = fopen(path, "wb");
        if (!out) { result = VLTUnzipErrWrite; goto done; }
        int status = extract_entry(zip, dataOffset, compressed, method, out, &written);
        fclose(out);
        if (status != 0) { result = status; goto done; }
        files++;
    }
    result = files;
done:
    free(central);
    fclose(zip);
    return result;
}
