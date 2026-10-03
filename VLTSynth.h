//
//  VLTSynth.h - Volta's system sounds, made in code as small WAV files.
//  Three packs (Chime, Arcade, Sci-Fi) times five events. Plain C so the
//  results can be checked off-device.
//
#ifndef VLT_SYNTH_H
#define VLT_SYNTH_H

#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define VLT_SYNTH_RATE 22050

enum { VLTPackChime = 0, VLTPackArcade, VLTPackSciFi, VLTPackCount };
enum { VLTSoundLock = 0, VLTSoundUnlock, VLTSoundPlug, VLTSoundUnplug, VLTSoundTick, VLTSoundCount };

// One note: when it starts, how long it lasts, its pitch at the start and at
// the end (a sweep when they differ), and how loud it is.
typedef struct { double start, length, fromHz, toHz, level; } VLTNote;

typedef struct { int count; VLTNote notes[4]; } VLTSoundSpec;

// wave: 0 sine (soft), 1 square (8-bit game), 2 sine with a faint octave (glassy)
static inline double vlt_wave(int wave, double phase) {
    double s = sin(phase);
    if (wave == 1) return (s >= 0 ? 1.0 : -1.0) * 0.55;
    if (wave == 2) return 0.8 * s + 0.2 * sin(2 * phase);
    return s;
}

static inline VLTSoundSpec vlt_sound_spec(int pack, int event) {
    static const VLTSoundSpec specs[VLTPackCount][VLTSoundCount] = {
        {   // Chime: soft bells, falling to lock and rising to unlock
            {2, {{0.00, 0.22, 880.0, 880.0, 0.9}, {0.09, 0.32, 587.3, 587.3, 0.9}}},
            {2, {{0.00, 0.22, 587.3, 587.3, 0.9}, {0.09, 0.34, 880.0, 880.0, 0.9}}},
            {3, {{0.00, 0.26, 523.3, 523.3, 0.8}, {0.11, 0.28, 659.3, 659.3, 0.8}, {0.22, 0.42, 784.0, 784.0, 0.9}}},
            {2, {{0.00, 0.22, 659.3, 659.3, 0.8}, {0.11, 0.36, 440.0, 440.0, 0.8}}},
            {1, {{0.00, 0.07, 1046.5, 1046.5, 0.7}}},
        },
        {   // Arcade: square-wave blips
            {2, {{0.00, 0.08, 660.0, 660.0, 0.8}, {0.08, 0.12, 330.0, 330.0, 0.8}}},
            {2, {{0.00, 0.08, 330.0, 330.0, 0.8}, {0.08, 0.12, 660.0, 660.0, 0.8}}},
            {4, {{0.00, 0.07, 392.0, 392.0, 0.8}, {0.07, 0.07, 523.3, 523.3, 0.8}, {0.14, 0.07, 659.3, 659.3, 0.8}, {0.21, 0.16, 784.0, 784.0, 0.8}}},
            {3, {{0.00, 0.07, 659.3, 659.3, 0.8}, {0.07, 0.07, 523.3, 523.3, 0.8}, {0.14, 0.16, 392.0, 392.0, 0.8}}},
            {1, {{0.00, 0.035, 880.0, 880.0, 0.7}}},
        },
        {   // Sci-Fi: sweeps
            {1, {{0.00, 0.30, 900.0, 260.0, 0.9}}},
            {1, {{0.00, 0.30, 260.0, 900.0, 0.9}}},
            {2, {{0.00, 0.40, 220.0, 1100.0, 0.8}, {0.30, 0.25, 1320.0, 1320.0, 0.6}}},
            {1, {{0.00, 0.40, 1100.0, 200.0, 0.8}}},
            {1, {{0.00, 0.06, 1500.0, 1100.0, 0.7}}},
        },
    };
    if (pack < 0 || pack >= VLTPackCount) pack = 0;
    if (event < 0 || event >= VLTSoundCount) event = 0;
    return specs[pack][event];
}

static inline void vlt_s_put32(uint8_t *p, uint32_t v) { p[0] = v & 0xFF; p[1] = (v >> 8) & 0xFF; p[2] = (v >> 16) & 0xFF; p[3] = (v >> 24) & 0xFF; }
static inline void vlt_s_put16(uint8_t *p, uint16_t v) { p[0] = v & 0xFF; p[1] = (v >> 8) & 0xFF; }

// Builds the sound as a complete 16-bit mono WAV file. loudness is 0 ... 1.
// Returns malloc'd bytes and stores their count in *length; NULL on failure.
static inline uint8_t *vlt_synth_wav(int pack, int event, double loudness, size_t *length) {
    VLTSoundSpec spec = vlt_sound_spec(pack, event);
    if (pack < 0 || pack >= VLTPackCount) pack = 0;
    if (loudness < 0) loudness = 0;
    if (loudness > 1) loudness = 1;
    double seconds = 0;
    for (int n = 0; n < spec.count; n++) {
        double end = spec.notes[n].start + spec.notes[n].length;
        if (end > seconds) seconds = end;
    }
    seconds += 0.03;   // a breath of silence so the tail is never cut
    uint32_t frames = (uint32_t)(VLT_SYNTH_RATE * seconds);
    uint32_t dataBytes = frames * 2;
    uint8_t *wav = (uint8_t *)malloc(44 + dataBytes);
    if (!wav) return NULL;
    memcpy(wav, "RIFF", 4);          vlt_s_put32(wav + 4, 36 + dataBytes);
    memcpy(wav + 8, "WAVEfmt ", 8);  vlt_s_put32(wav + 16, 16);
    vlt_s_put16(wav + 20, 1);        vlt_s_put16(wav + 22, 1);
    vlt_s_put32(wav + 24, VLT_SYNTH_RATE);
    vlt_s_put32(wav + 28, VLT_SYNTH_RATE * 2);
    vlt_s_put16(wav + 32, 2);        vlt_s_put16(wav + 34, 16);
    memcpy(wav + 36, "data", 4);     vlt_s_put32(wav + 40, dataBytes);

    int wave = pack == VLTPackArcade ? 1 : (pack == VLTPackSciFi ? 2 : 0);
    double phases[4] = {0, 0, 0, 0};
    for (uint32_t i = 0; i < frames; i++) {
        double t = (double)i / VLT_SYNTH_RATE, sample = 0;
        for (int n = 0; n < spec.count; n++) {
            const VLTNote *note = &spec.notes[n];
            double local = t - note->start;
            if (local < 0 || local > note->length) continue;
            double along = local / note->length;
            double hertz = note->fromHz + (note->toHz - note->fromHz) * along;
            phases[n] += 2 * M_PI * hertz / VLT_SYNTH_RATE;   // running phase, so sweeps stay smooth
            double attack = local < 0.006 ? local / 0.006 : 1;
            // Bells ring down; blips and sweeps hold, then let go quickly at the end.
            double fade = wave == 0 ? exp(-3.0 * along) * (1 - along) : (along > 0.8 ? (1 - along) / 0.2 : 1);
            sample += note->level * vlt_wave(wave, phases[n]) * attack * fade;
        }
        sample *= 0.45 * loudness;
        if (sample > 1) sample = 1;
        if (sample < -1) sample = -1;
        vlt_s_put16(wav + 44 + i * 2, (uint16_t)(int16_t)lrint(sample * 32767));
    }
    if (length) *length = 44 + dataBytes;
    return wav;
}

#endif
