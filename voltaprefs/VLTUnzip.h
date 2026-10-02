//
//  VLTUnzip.h
//  A small zip extractor (stored and deflate entries), used to open .tendies
//  files. Plain C on top of zlib so it can be tested off-device.
//

#ifndef VLT_UNZIP_H
#define VLT_UNZIP_H

#ifdef __cplusplus
extern "C" {
#endif

// Extracts zipPath into destDir (created if needed).
// Returns the number of files written, or a negative VLTUnzipError.
int vlt_unzip(const char *zipPath, const char *destDir);

enum {
    VLTUnzipErrOpen     = -1,   // cannot read the zip
    VLTUnzipErrFormat   = -2,   // not a zip, or damaged
    VLTUnzipErrTooBig   = -3,   // more than the limits below
    VLTUnzipErrWrite    = -4,   // cannot write into destDir
    VLTUnzipErrUnsupported = -5 // encrypted or unknown compression
};

#define VLT_UNZIP_MAX_FILES 4000
#define VLT_UNZIP_MAX_BYTES (600ULL * 1024 * 1024)

#ifdef __cplusplus
}
#endif
#endif
