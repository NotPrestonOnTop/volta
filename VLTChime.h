//
//  VLTChime.h - makes the short startup chime as a WAV file in memory.
//  Plain C (no audio files ship with Volta), so it can be tested off-device.
//
#ifndef VLT_CHIME_H
#define VLT_CHIME_H

#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define VLT_CHIME_RATE 22050
#define VLT_CHIME_SECONDS 1.1

static inline void vlt_put32(uint8_t *p, uint32_t v) { p[0] = v & 0xFF; p[1] = (v >> 8) & 0xFF; p[2] = (v >> 16) & 0xFF; p[3] = (v >> 24) & 0xFF; }
static inline void vlt_put16(uint8_t *p, uint16_t v) { p[0] = v & 0xFF; p[1] = (v >> 8) & 0xFF; }

// One soft bell-like note: a sine with a quick attack and a smooth fade.
static inline double vlt_note(double t, double start, double hertz, double length) {
    double local = t - start;
    if (local < 0 || local > length) return 0;
    double attack = local < 0.012 ? local / 0.012 : 1;
    double fade = exp(-3.2 * local / length) * (1 - local / length);
    return sin(2 * M_PI * hertz * local) * attack * fade;
}

// Three rising notes (C, G, C). Returns malloc'd bytes of a complete 16-bit
// mono WAV file and stores their count in *length; NULL if out of memory.
static inline uint8_t *vlt_chime_wav(size_t *length) {
    uint32_t frames = (uint32_t)(VLT_CHIME_RATE * VLT_CHIME_SECONDS);
    uint32_t dataBytes = frames * 2;
    uint8_t *wav = (uint8_t *)malloc(44 + dataBytes);
    if (!wav) return NULL;
    memcpy(wav, "RIFF", 4);          vlt_put32(wav + 4, 36 + dataBytes);
    memcpy(wav + 8, "WAVEfmt ", 8);  vlt_put32(wav + 16, 16);
    vlt_put16(wav + 20, 1);          /* PCM */
    vlt_put16(wav + 22, 1);          /* mono */
    vlt_put32(wav + 24, VLT_CHIME_RATE);
    vlt_put32(wav + 28, VLT_CHIME_RATE * 2);
    vlt_put16(wav + 32, 2);          vlt_put16(wav + 34, 16);
    memcpy(wav + 36, "data", 4);     vlt_put32(wav + 40, dataBytes);
    for (uint32_t i = 0; i < frames; i++) {
        double t = (double)i / VLT_CHIME_RATE;
        double sample = 0.30 * vlt_note(t, 0.00, 523.25, 0.55)
                      + 0.28 * vlt_note(t, 0.16, 783.99, 0.65)
                      + 0.26 * vlt_note(t, 0.34, 1046.50, 0.76);
        if (sample > 1) sample = 1;
        if (sample < -1) sample = -1;
        vlt_put16(wav + 44 + i * 2, (uint16_t)(int16_t)lrint(sample * 32767));
    }
    if (length) *length = 44 + dataBytes;
    return wav;
}

#endif
